import Foundation

// MARK: - Action layer
//
// Phase 1 of the v1.2 plan. The deal: every side-effecting thing Sage
// does goes through an `Action`. Actions are typed, schema-validated,
// and produce a previewable diff before execution. The LLM's job is
// to fill in `@Generable` parameters; it cannot construct an Action
// directly. Schema validation is the airlock between probabilistic
// model output and deterministic device behaviour.
//
// This file defines the abstract contract. Concrete actions live in
// Sage/Services/Actions/Concrete/.

// MARK: - ActionDiff
//
// What an action *will* do, presented to the user before commit. Phase
// 1 keeps this intentionally small — Phase 3 (Plan→Execute→Verify)
// will extend it with structured before/after pairs for richer UI.

struct ActionDiff: Sendable, Equatable {
    /// One-line human summary. Shown as the headline on the preview sheet.
    /// Example: "Create reminder \"Call dentist\" tomorrow 9 AM".
    let summary: String

    /// SF Symbol for the preview sheet header.
    let icon: String

    /// Tint colour name from the asset catalog or a system colour.
    /// Stored as a String so this struct stays Codable-friendly and
    /// independent of SwiftUI.
    let tint: ActionTint

    /// Label for the primary commit button. Verb form: "Create
    /// Reminder", "Add to Calendar", "Run Shortcut".
    let confirmLabel: String

    /// Soft warnings the user should see before approving. Examples:
    /// "no due date set", "conflicts with existing event 14:00–15:00".
    /// Empty array = green-light.
    let warnings: [String]

    enum ActionTint: String, Sendable, Equatable {
        case orange, blue, red, green, purple, gray
    }
}

// MARK: - ActionReceipt
//
// Proof of execution. Carries enough information to roll the action
// back later (where the underlying API supports it) and to write a
// meaningful audit row. Codable so it can survive a process restart
// — important for the "undo" UX after the app is backgrounded.

struct ActionReceipt: Sendable, Codable, Equatable {
    let id: UUID
    let actionName: String
    let executedAt: Date

    /// The platform-level identifier of whatever was created or
    /// modified — `EKEvent.eventIdentifier`, `EKReminder.calendarItemIdentifier`,
    /// a Shortcut URL, etc. `nil` when the action has no rollback
    /// target (e.g. running a Shortcut).
    let entityID: String?

    /// Short, user-facing string for the audit screen and undo toast.
    let summary: String

    /// True when `rollback(_:)` will undo this receipt. UI uses this
    /// to decide whether to show an "Undo" button on the success toast.
    let rollbackSupported: Bool

    init(
        actionName: String,
        entityID: String?,
        summary: String,
        rollbackSupported: Bool,
        executedAt: Date = Date()
    ) {
        self.id                = UUID()
        self.actionName        = actionName
        self.executedAt        = executedAt
        self.entityID          = entityID
        self.summary           = summary
        self.rollbackSupported = rollbackSupported
    }
}

// MARK: - ActionError

enum ActionError: LocalizedError {
    case unknownAction(String)
    case missingParameter(String)
    case invalidParameter(name: String, reason: String)
    case permissionDenied(String)
    case underlying(Error)
    case rollbackUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .unknownAction(let n):
            return "Sage doesn't know how to do that yet (action '\(n)')."
        case .missingParameter(let p):
            return "I need \(p.replacingOccurrences(of: "_", with: " ")) to do this. Could you provide it?"
        case .invalidParameter(let n, let r):
            return "The \(n) you gave isn't valid: \(r)"
        case .permissionDenied(let detail):
            return "Permission required: \(detail)"
        case .underlying(let e):
            return e.localizedDescription
        case .rollbackUnsupported(let n):
            return "I can't undo '\(n)' — that's a one-way operation."
        }
    }
}

// MARK: - Action protocol
//
// Every concrete action conforms to this. We keep the protocol
// @MainActor because every backing API in Phase 1 (EventKit,
// UIApplication, FileManager from Documents) is main-thread-friendly.
// If a future action needs background execution it can hop off via
// Task.detached internally.

@MainActor
protocol Action {
    /// snake_case wire name. MUST match the `intent` field the router
    /// emits. Stable identifier — don't rename without considering any
    /// audit log entries already in flight.
    static var name: String { get }

    /// Human-readable noun phrase used as the preview-sheet title.
    /// Example: "Create Reminder", "Edit Event".
    static var displayName: String { get }

    /// Build a diff describing what `execute()` will do. MUST be
    /// side-effect-free — implementations may read system state
    /// (calendar conflicts, etc.) but MUST NOT write.
    func dryRun() async throws -> ActionDiff

    /// Apply the action. MUST be idempotent if at all possible — if
    /// the user taps the confirm button twice we don't want two
    /// reminders. Return the receipt for rollback.
    func execute() async throws -> ActionReceipt

    /// Best-effort undo of a prior receipt. Throw
    /// `ActionError.rollbackUnsupported` if not implementable.
    func rollback(_ receipt: ActionReceipt) async throws
}

// MARK: - AnyAction
//
// Type-erased wrapper so the registry, runner, and view models can
// store and pass actions without knowing concrete types. The
// underlying action is captured in the closures.

@MainActor
struct AnyAction {
    let name: String
    let displayName: String

    private let _dryRun: () async throws -> ActionDiff
    private let _execute: () async throws -> ActionReceipt
    private let _rollback: (ActionReceipt) async throws -> Void

    init<A: Action>(_ action: A) {
        self.name        = A.name
        self.displayName = A.displayName
        self._dryRun  = { try await action.dryRun() }
        self._execute = { try await action.execute() }
        self._rollback = { receipt in try await action.rollback(receipt) }
    }

    func dryRun()  async throws -> ActionDiff    { try await _dryRun() }
    func execute() async throws -> ActionReceipt { try await _execute() }
    func rollback(_ receipt: ActionReceipt) async throws { try await _rollback(receipt) }
}

// MARK: - Parameter parsing helpers
//
// The router emits parameters as a `[String: String]` dict. Concrete
// action initialisers use these helpers to coerce values into typed
// fields. Keeping the helpers here means every action handles missing
// / malformed input the same way.

enum ActionParam {

    /// Required string. Throws `.missingParameter` if absent or empty
    /// after whitespace trimming.
    static func string(_ name: String, in raw: [String: String]) throws -> String {
        let value = raw[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { throw ActionError.missingParameter(name) }
        return value
    }

    /// Optional string. Returns `nil` for absent or whitespace-only values.
    static func optionalString(_ name: String, in raw: [String: String]) -> String? {
        let value = raw[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Date parsed via NSDataDetector — covers "tomorrow 3pm", ISO-8601,
    /// "next Friday", etc. `nil` for absent or unparseable values.
    static func optionalDate(_ name: String, in raw: [String: String]) -> Date? {
        guard let str = optionalString(name, in: raw) else { return nil }
        return parseDate(str)
    }

    /// Required date variant.
    static func date(_ name: String, in raw: [String: String]) throws -> Date {
        guard let str = optionalString(name, in: raw) else {
            throw ActionError.missingParameter(name)
        }
        guard let date = parseDate(str) else {
            throw ActionError.invalidParameter(name: name, reason: "couldn't read \"\(str)\" as a date")
        }
        return date
    }

    /// Duration in minutes. Falls back to nil for unrecognised values.
    static func optionalMinutes(_ name: String, in raw: [String: String]) -> Int? {
        guard let str = optionalString(name, in: raw) else { return nil }
        if let n = Int(str) { return n }
        // Tolerate "30m", "30 min", "1h"
        let lower = str.lowercased()
        if lower.hasSuffix("h"), let n = Double(lower.dropLast()) { return Int(n * 60) }
        if let suffixRange = lower.range(of: "m"),
           let n = Int(lower[..<suffixRange.lowerBound].trimmingCharacters(in: .whitespaces)) {
            return n
        }
        return nil
    }

    private static func parseDate(_ str: String) -> Date? {
        // First try ISO-8601 (the router's preferred output format).
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: str) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: str) { return d }

        // Then NSDataDetector for natural-language phrases.
        let types: NSTextCheckingResult.CheckingType = .date
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return nil }
        let range = NSRange(str.startIndex..., in: str)
        return detector.matches(in: str, options: [], range: range).first?.date
    }
}
