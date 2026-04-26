import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ResourceBudget
//
// The non-negotiable in v1.2 plan #11: Sage stays good *all day*, not
// just for 30-second demos. That means watching thermal pressure,
// low-power mode, and battery, and degrading the model stack when the
// device asks us to. This is the single source of truth other services
// consult before doing anything expensive.
//
// Subscribers (LLMService, IndexingService, Reranker, AgentLoop) react
// by capping context length, switching to smaller models, deferring
// background work, or refusing entirely. The view layer can also bind
// to `quality` to disable "high-quality mode" buttons live.
//
// We deliberately keep this dumb-and-explicit. No machine learning
// over telemetry — just a set of rules a human reviewer can audit:
//
//   thermalState ≥ .critical   OR  battery < 0.10 (unplugged)
//      → .minimal   (no Llama 3B, no SmolVLM swap, single-shot only)
//
//   thermalState ≥ .serious    OR  battery < 0.15 (unplugged)
//   OR  isLowPowerModeEnabled
//      → .fast      (cap ctx 2048, 1 agent iteration, no reranker reload)
//
//   else
//      → .full      (current behaviour)

@MainActor
final class ResourceBudget: ObservableObject {

    enum Quality: String, Sendable {
        case full     // unrestricted
        case fast     // capped context + single agent iteration
        case minimal  // no swappable models; system Foundation router only
    }

    // MARK: Published state

    /// Effective quality level, computed from the inputs below.
    /// Subscribers should always read THIS, not the raw signals — the
    /// rule set may change and this is the contract.
    @Published private(set) var quality: Quality = .full

    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var lowPowerMode: Bool = false
    /// 0.0–1.0. `1.0` when monitoring is disabled or unsupported, so
    /// non-iOS targets default to the optimistic case.
    @Published private(set) var batteryLevel: Float = 1.0
    @Published private(set) var isCharging: Bool = false

    /// Last time `quality` actually changed value. Surfaced in
    /// Diagnostics so we can tell users "throttled at 14:23 because device hot."
    @Published private(set) var lastQualityChangeAt: Date = Date()

    // MARK: Lifecycle

    private var observers: [NSObjectProtocol] = []

    init() {
        #if canImport(UIKit)
        // Battery monitoring is opt-in on iOS; without this the level is -1.
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        refreshSignals()
        recompute()
        installObservers()
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: Public helpers

    /// Quick yes/no for callers that just need the binary "do or skip"
    /// answer. Heavy work = anything that loads/swaps a model or runs
    /// a multi-step agent loop.
    var allowsHeavyWork: Bool { quality == .full }

    /// Soft cap on context length recommended by the budget. Callers
    /// may use a smaller value but should not exceed this.
    var recommendedContextChars: Int {
        switch quality {
        case .full:    return 16_000
        case .fast:    return  8_000
        case .minimal: return  4_000
        }
    }

    /// Maximum agent-loop iterations under the current budget.
    var maxAgentIterations: Int {
        switch quality {
        case .full:    return 3
        case .fast:    return 1
        case .minimal: return 0    // route directly, no planning
        }
    }

    /// Force a re-evaluation. Useful after privileged operations
    /// (e.g. user toggled airplane mode in Settings).
    func reassess() {
        refreshSignals()
        recompute()
    }

    // MARK: Internals

    private func installObservers() {
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.thermalState = ProcessInfo.processInfo.thermalState
                self?.recompute()
            }
        })

        observers.append(nc.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.recompute()
            }
        })

        #if canImport(UIKit)
        observers.append(nc.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.batteryLevel = max(UIDevice.current.batteryLevel, 0)
                self?.recompute()
            }
        })

        observers.append(nc.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isCharging = Self.chargingFromState()
                self?.recompute()
            }
        })
        #endif
    }

    private func refreshSignals() {
        thermalState = ProcessInfo.processInfo.thermalState
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        #if canImport(UIKit)
        let lvl = UIDevice.current.batteryLevel
        batteryLevel = lvl >= 0 ? lvl : 1.0    // unknown → optimistic
        isCharging   = Self.chargingFromState()
        #else
        batteryLevel = 1.0
        isCharging   = true
        #endif
    }

    private func recompute() {
        let new = Self.computeQuality(
            thermal: thermalState,
            lowPower: lowPowerMode,
            battery: batteryLevel,
            charging: isCharging
        )
        if new != quality {
            quality = new
            lastQualityChangeAt = Date()
        }
    }

    /// Pure function so it's trivially unit-testable. The thresholds
    /// were chosen to bias toward keeping Sage *useful* — we only drop
    /// to `.minimal` when the device is genuinely struggling.
    static func computeQuality(
        thermal: ProcessInfo.ThermalState,
        lowPower: Bool,
        battery: Float,
        charging: Bool
    ) -> Quality {
        // Critical signals: drop everything to the system router.
        if thermal == .critical { return .minimal }
        if !charging, battery < 0.10 { return .minimal }

        // Warning signals: keep working but stop being expensive.
        if thermal == .serious { return .fast }
        if lowPower             { return .fast }
        if !charging, battery < 0.15 { return .fast }

        return .full
    }

    #if canImport(UIKit)
    private static func chargingFromState() -> Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        case .unplugged, .unknown: return false
        @unknown default: return false
        }
    }
    #endif
}
