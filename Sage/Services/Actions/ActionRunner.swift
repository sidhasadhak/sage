import Foundation

// MARK: - ActionRunner
//
// Orchestrates the full lifecycle of a single action:
//   1. `prepare(_:)`   — runs `dryRun()`, stashes the diff + action,
//                        view model presents the preview sheet.
//   2. `confirm()`     — user tapped Approve → `execute()` → audit log.
//   3. `cancel()`      — user dismissed; nothing executed.
//   4. `rollback(_:)`  — undo a prior receipt (where supported).
//
// The runner is `@Observable`/`@Published`-bearing so views can react
// to lifecycle changes; in Phase 1 the chat VM owns presentation, so
// it just reads `current` to drive the bottom sheet.

@MainActor
final class ActionRunner: ObservableObject {

    enum State: Equatable {
        case idle
        case preview(ActionDiff)         // sheet visible, waiting for user
        case executing(String)           // action displayName
        case completed(ActionReceipt)
        case failed(String)              // localized error message
    }

    @Published private(set) var state: State = .idle

    /// Audit-log surface — so reviewers in Phase 7 can answer
    /// "what did Sage actually do today?".
    private let auditLogger: AuditLogger

    /// Held between `prepare` and `confirm`. Cleared on terminal
    /// states. Not exposed; only the runner mutates execution.
    private var pendingAction: AnyAction?

    init(auditLogger: AuditLogger) {
        self.auditLogger = auditLogger
    }

    // MARK: - Lifecycle

    /// Begin the dry-run flow for an action. Returns the diff so the
    /// caller can decide what UI to present (the chat VM uses it to
    /// show a bottom sheet). The action is held until `confirm()` or
    /// `cancel()`.
    @discardableResult
    func prepare(_ action: AnyAction) async -> Result<ActionDiff, Error> {
        do {
            let diff = try await action.dryRun()
            self.pendingAction = action
            self.state = .preview(diff)
            auditLogger.recordSuccess(
                actor: .action,
                action: "dry_run.\(action.name)",
                dataAccessed: diff.summary
            )
            return .success(diff)
        } catch {
            auditLogger.recordFailure(
                actor: .action,
                action: "dry_run.\(action.name)",
                error: error
            )
            self.state = .failed(error.localizedDescription)
            return .failure(error)
        }
    }

    /// Execute the action that was prepared. No-op if there's nothing
    /// to confirm — callers shouldn't rely on the no-op behaviour for
    /// flow control though.
    @discardableResult
    func confirm() async -> Result<ActionReceipt, Error> {
        guard let action = pendingAction else {
            return .failure(ActionError.unknownAction("nothing pending"))
        }
        state = .executing(action.displayName)
        do {
            let receipt = try await action.execute()
            auditLogger.recordSuccess(
                actor: .action,
                action: "execute.\(action.name)",
                dataAccessed: receipt.summary,
                metadata: receipt.entityID.map { ["entity_id": $0] }
            )
            state = .completed(receipt)
            pendingAction = nil
            return .success(receipt)
        } catch {
            auditLogger.recordFailure(
                actor: .action,
                action: "execute.\(action.name)",
                error: error
            )
            state = .failed(error.localizedDescription)
            // Don't clear pendingAction on failure — the user can retry
            // from the same preview without re-routing through the LLM.
            return .failure(error)
        }
    }

    /// User dismissed the preview without approving.
    func cancel() {
        if let action = pendingAction {
            auditLogger.record(
                actor: .action,
                action: "cancelled.\(action.name)",
                outcome: "rejected"
            )
        }
        pendingAction = nil
        state = .idle
    }

    /// Reset to idle — used by callers after they've consumed a
    /// .completed or .failed state. Without this the runner stays
    /// in a terminal state and the next `prepare` overwrites it
    /// without the UI seeing the transition.
    func reset() {
        pendingAction = nil
        state = .idle
    }

    /// Try to undo a previous receipt. Independent of any pending
    /// preview — the user can roll back actions from the audit log
    /// (Phase 7) long after the original execution.
    func rollback(_ receipt: ActionReceipt, with action: AnyAction) async -> Result<Void, Error> {
        guard receipt.rollbackSupported else {
            let err = ActionError.rollbackUnsupported(action.name)
            auditLogger.recordFailure(actor: .action, action: "rollback.\(action.name)", error: err)
            return .failure(err)
        }
        do {
            try await action.rollback(receipt)
            auditLogger.recordSuccess(
                actor: .action,
                action: "rollback.\(action.name)",
                dataAccessed: receipt.summary,
                metadata: receipt.entityID.map { ["entity_id": $0] }
            )
            return .success(())
        } catch {
            auditLogger.recordFailure(actor: .action, action: "rollback.\(action.name)", error: error)
            return .failure(error)
        }
    }
}
