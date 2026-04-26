import Foundation

// MARK: - PEVController
//
// Phase 3 of the v1.2 plan: closes the loop. The previous AgentLoop
// did Plan → Execute (read-only tools); this controller adds Verify
// and Summarize for any side-effecting action — and wires the
// receipt to a one-tap Undo while the chat is alive.
//
// The controller is intentionally narrow in Phase 3:
//   • Single-action verification — receipt → action.verify() →
//     human-readable outcome.
//   • Receipt summarisation — natural-language line describing what
//     changed, what was verified, and (when applicable) an Undo handle.
//   • Audit-log integration — every verify pass writes one row.
//
// Phase 3.5 will extend with multi-step Plans (the Generable Plan
// type that batches tool/action steps into one approval) using the
// existing AgentLoop as the planner. For now the structured Plan
// types are declared so callers can evolve without an API churn.

@MainActor
final class PEVController {

    private let auditLogger: AuditLogger

    init(auditLogger: AuditLogger) {
        self.auditLogger = auditLogger
    }

    // MARK: - Public API

    /// Run the closed loop on a freshly-executed action. Reads back
    /// state via the action's verify, writes one audit row, and
    /// returns a fully-baked Receipt with the natural-language
    /// summary the chat UI surfaces to the user.
    func close(
        action: AnyAction,
        receipt: ActionReceipt
    ) async -> Receipt {
        let outcome = await action.verify(receipt)

        switch outcome.status {
        case .passed, .skipped:
            auditLogger.recordSuccess(
                actor: .action,
                action: "verify.\(action.name)",
                dataAccessed: outcome.detail.isEmpty ? receipt.summary : outcome.detail,
                metadata: receipt.entityID.map { ["entity_id": $0] }
            )
        case .mismatch, .notFound:
            auditLogger.record(
                actor: .action,
                action: "verify.\(action.name)",
                dataAccessed: outcome.detail,
                outcome: "warning: \(outcome.status)",
                metadata: receipt.entityID.map { ["entity_id": $0] }
            )
        }

        return Receipt(
            action: action,
            actionReceipt: receipt,
            verification: outcome,
            summary: Self.summarise(action: action, receipt: receipt, outcome: outcome)
        )
    }

    // MARK: - Plan / PlanStep (Phase 3.5 surface)
    //
    // These types are declared so callers can target them ahead of
    // time. The full multi-step planner lands in Phase 3.5 — for now
    // ChatViewModel exercises the single-action path via `close(...)`.

    struct Plan: Sendable {
        let steps: [PlanStep]
        let verifyQueries: [String]
        let rationale: String
    }

    enum PlanStep: Sendable {
        /// Execute a registered Action through ActionRunner — preview
        /// + audit + verify all happen automatically.
        case action(intent: String, parameters: [String: String])

        /// Call a registered ToolRegistry tool (read-only).
        case tool(name: String, arguments: [String: String])

        /// Append a free-form line to the assistant reply.
        case message(String)
    }

    // MARK: - Receipt
    //
    // The user-facing artefact of one action turn. Drives the chat
    // bubble's confirmation line and the Undo affordance.

    struct Receipt: Sendable, Identifiable {
        let id = UUID()
        let action: AnyAction
        let actionReceipt: ActionReceipt
        let verification: VerificationOutcome
        let summary: String

        var canUndo: Bool { actionReceipt.rollbackSupported }
        var hasWarning: Bool { verification.isWarning }
    }

    // MARK: - Summary builder

    /// Compose the assistant-bubble line for a completed action.
    /// Format:
    ///   "✓ Created reminder \"Call dentist\" — verified. Tap to undo."
    ///   "⚠ Edited event but drifted on: title. (Tap to undo)"
    ///   "✓ Ran Shortcut "Goodnight"."
    static func summarise(
        action: AnyAction,
        receipt: ActionReceipt,
        outcome: VerificationOutcome
    ) -> String {
        let verifyTrailer: String
        switch outcome.status {
        case .passed:    verifyTrailer = " — verified."
        case .skipped:   verifyTrailer = "."
        case .mismatch:  verifyTrailer = " — but \(outcome.detail.lowercased())"
        case .notFound:  verifyTrailer = " — but the entity didn't persist."
        }

        let leadGlyph = outcome.isWarning ? "⚠" : "✓"
        let undoHint = receipt.rollbackSupported && !outcome.isWarning
            ? " Tap Undo to reverse."
            : ""
        return "\(leadGlyph) \(receipt.summary)\(verifyTrailer)\(undoHint)"
    }
}
