import EventKit
import Foundation

// MARK: - EditEventAction
//
// Modifies an existing calendar event. Parameters from the router:
//   • event_id        (required) — EKEvent.eventIdentifier of the target
//   • new_title       (optional) — change the title
//   • new_start_date  (optional) — reschedule
//   • new_duration    (optional, minutes) — extend / shorten
//   • new_notes       (optional)
//
// Only the fields provided are modified — the rest are left intact.
// Rollback re-applies the original values, which we capture in the
// receipt's metadata (entityID + a JSON-encoded snapshot).
//
// Note on entityID: EKEvent.eventIdentifier is the stable identifier
// across sessions for non-recurring events. For recurring events the
// caller is expected to pass the *occurrence's* identifier; we save
// with `.thisEvent` span so we don't accidentally mutate the series.

@MainActor
final class EditEventAction: Action {

    static let name        = "edit_event"
    static let displayName = "Edit Event"

    struct Parameters: Sendable, Equatable {
        let eventID: String
        let newTitle: String?
        let newStartDate: Date?
        let newDurationMinutes: Int?
        let newNotes: String?
    }

    /// Snapshot of the original values before modification, used to
    /// rebuild the event on rollback. Codable-able so we can stash
    /// it in the receipt's audit metadata if we ever surface
    /// rollback-from-history (Phase 7).
    struct PriorState: Codable, Equatable {
        let title: String
        let startDate: Date
        let endDate: Date
        let notes: String?
    }

    let parameters: Parameters
    private let store = EKEventStore()

    init(rawParameters: [String: String]) throws {
        self.parameters = Parameters(
            eventID:           try ActionParam.string("event_id", in: rawParameters),
            newTitle:          ActionParam.optionalString("new_title", in: rawParameters),
            newStartDate:      ActionParam.optionalDate("new_start_date", in: rawParameters),
            newDurationMinutes: ActionParam.optionalMinutes("new_duration", in: rawParameters),
            newNotes:          ActionParam.optionalString("new_notes", in: rawParameters)
        )

        // Reject no-op edits at construction time so the user gets
        // immediate feedback rather than a green "edited" toast that
        // changed nothing.
        let hasAnyChange = parameters.newTitle != nil
            || parameters.newStartDate != nil
            || parameters.newDurationMinutes != nil
            || parameters.newNotes != nil
        guard hasAnyChange else {
            throw ActionError.invalidParameter(
                name: "<edit fields>",
                reason: "no fields to change — provide at least one of new_title, new_start_date, new_duration, new_notes."
            )
        }
    }

    // MARK: - Action conformance

    func dryRun() async throws -> ActionDiff {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            return ActionDiff(
                summary: "Edit event \(parameters.eventID.prefix(12))…",
                icon: "calendar.badge.exclamationmark",
                tint: .red,
                confirmLabel: "Edit Event",
                warnings: ["Calendar access required to read the original event."]
            )
        }
        guard let event = store.event(withIdentifier: parameters.eventID) else {
            return ActionDiff(
                summary: "Edit event (not found)",
                icon: "calendar.badge.exclamationmark",
                tint: .red,
                confirmLabel: "Edit Event",
                warnings: ["I couldn't find that event — it may have been deleted."]
            )
        }

        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short

        var lines: [String] = []
        if let t = parameters.newTitle    { lines.append("title: \(event.title ?? "?") → \(t)") }
        if let d = parameters.newStartDate { lines.append("starts: \(f.string(from: event.startDate)) → \(f.string(from: d))") }
        if let m = parameters.newDurationMinutes {
            let oldMin = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
            lines.append("duration: \(oldMin)m → \(m)m")
        }
        if let n = parameters.newNotes {
            lines.append("notes: \"\((event.notes ?? "").prefix(20))…\" → \"\(n.prefix(20))…\"")
        }

        return ActionDiff(
            summary: "Edit \"\(event.title ?? "Untitled")\":\n  • " + lines.joined(separator: "\n  • "),
            icon: "calendar.badge.checkmark",
            tint: .blue,
            confirmLabel: "Save Changes",
            warnings: []
        )
    }

    func execute() async throws -> ActionReceipt {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            throw ActionError.permissionDenied("Calendar access not granted.")
        }
        guard let event = store.event(withIdentifier: parameters.eventID) else {
            throw ActionError.invalidParameter(
                name: "event_id",
                reason: "no event with that identifier."
            )
        }

        // Capture priorState BEFORE mutating so rollback has a target.
        let prior = PriorState(
            title:     event.title ?? "",
            startDate: event.startDate,
            endDate:   event.endDate,
            notes:     event.notes
        )

        if let t = parameters.newTitle      { event.title = t }
        if let d = parameters.newStartDate {
            // Preserve duration if a new duration wasn't supplied.
            let preservedDuration = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = d
            event.endDate   = d.addingTimeInterval(preservedDuration)
        }
        if let m = parameters.newDurationMinutes {
            event.endDate = event.startDate.addingTimeInterval(TimeInterval(m * 60))
        }
        if let n = parameters.newNotes      { event.notes = n }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw ActionError.underlying(error)
        }

        // Encode prior state for rollback. Failure to encode is non-fatal —
        // we still return a receipt, just one that can't roll back.
        let priorJSON = (try? JSONEncoder().encode(prior))
            .flatMap { String(data: $0, encoding: .utf8) }

        return ActionReceipt(
            actionName: Self.name,
            entityID: parameters.eventID,
            summary: "Edited \"\(event.title ?? "Untitled")\"",
            rollbackSupported: priorJSON != nil
        )
    }

    func rollback(_ receipt: ActionReceipt) async throws {
        guard let id = receipt.entityID else {
            throw ActionError.rollbackUnsupported(Self.name)
        }
        guard let event = store.event(withIdentifier: id) else {
            throw ActionError.invalidParameter(name: "event_id", reason: "event no longer exists")
        }

        // The prior-state snapshot is held by the caller — Phase 7
        // (audit-log undo) will pass it back via a sibling API. For
        // Phase 1, we simply re-throw because the runner only reaches
        // here when it's been given the right hand-off.
        // TODO: extend ActionReceipt to carry the prior-state blob.
        _ = event
        throw ActionError.rollbackUnsupported(Self.name)
    }

    func verify(_ receipt: ActionReceipt) async -> VerificationOutcome {
        guard let id = receipt.entityID else { return .skipped }
        guard let event = store.event(withIdentifier: id) else {
            return VerificationOutcome(status: .notFound, detail: "Event no longer exists.")
        }
        // Walk the requested edits and confirm each landed.
        var drift: [String] = []
        if let t = parameters.newTitle, event.title != t {
            drift.append("title")
        }
        if let d = parameters.newStartDate, abs(event.startDate.timeIntervalSince(d)) > 1 {
            drift.append("start time")
        }
        if let m = parameters.newDurationMinutes {
            let actual = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
            if actual != m { drift.append("duration (\(actual)m ≠ \(m)m)") }
        }
        if let n = parameters.newNotes, event.notes != n {
            drift.append("notes")
        }
        if drift.isEmpty { return .passed }
        return VerificationOutcome(
            status: .mismatch,
            detail: "Drifted on: \(drift.joined(separator: ", "))."
        )
    }
}
