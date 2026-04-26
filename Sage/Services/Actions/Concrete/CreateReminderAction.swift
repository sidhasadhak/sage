import EventKit
import Foundation

// MARK: - CreateReminderAction
//
// Wraps the existing ReminderCreationService in the Phase-1 contract.
// Parameters expected from the router:
//   • title    (required) — what to remind about
//   • due_date (optional) — natural-language or ISO-8601 timestamp
//   • notes    (optional) — extra context body
//
// The underlying EventKit reminder is created with an EKAlarm at the
// due date (matches existing service behaviour). Rollback deletes the
// reminder by stored calendar-item identifier.

@MainActor
final class CreateReminderAction: Action {

    static let name        = "create_reminder"
    static let displayName = "Create Reminder"

    struct Parameters: Sendable, Equatable {
        let title: String
        let dueDate: Date?
        let notes: String?
    }

    let parameters: Parameters
    private let service: ReminderCreationService

    init(rawParameters: [String: String], service: ReminderCreationService) throws {
        self.parameters = Parameters(
            title:   try ActionParam.string("title", in: rawParameters),
            dueDate: ActionParam.optionalDate("due_date", in: rawParameters),
            notes:   ActionParam.optionalString("notes", in: rawParameters)
        )
        self.service = service
    }

    // MARK: - Action conformance

    func dryRun() async throws -> ActionDiff {
        let summary: String
        var warnings: [String] = []

        if let due = parameters.dueDate {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            summary = "Create reminder \"\(parameters.title)\" — due \(f.string(from: due))"
            // If the date is already in the past, warn before commit.
            if due < Date() {
                warnings.append("Due date is in the past.")
            }
        } else {
            summary = "Create reminder \"\(parameters.title)\""
            warnings.append("No due date — reminder won't trigger an alert.")
        }

        // Surface a missing-permission warning at preview time rather
        // than blowing up at execute. EKEventStore's reminders status
        // is checked separately from events.
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status != .fullAccess && status != .authorized {
            warnings.append("Reminders access required. Sage will ask the first time.")
        }

        return ActionDiff(
            summary: summary,
            icon: "bell.fill",
            tint: .orange,
            confirmLabel: "Create Reminder",
            warnings: warnings
        )
    }

    func execute() async throws -> ActionReceipt {
        // Phase 3: the service now returns the calendar-item identifier
        // so verify can read back and rollback can target the row.
        let id: String
        do {
            id = try await service.createReminder(
                title:   parameters.title,
                notes:   parameters.notes,
                dueDate: parameters.dueDate
            )
        } catch {
            throw ActionError.underlying(error)
        }

        return ActionReceipt(
            actionName: Self.name,
            entityID: id.isEmpty ? nil : id,
            summary: "Created reminder \"\(parameters.title)\"",
            rollbackSupported: !id.isEmpty
        )
    }

    func rollback(_ receipt: ActionReceipt) async throws {
        guard let id = receipt.entityID else {
            throw ActionError.rollbackUnsupported(Self.name)
        }
        do {
            try await service.deleteReminder(identifier: id)
        } catch {
            throw ActionError.underlying(error)
        }
    }

    func verify(_ receipt: ActionReceipt) async -> VerificationOutcome {
        guard let id = receipt.entityID else { return .skipped }
        guard let reminder = service.reminder(identifier: id) else {
            return VerificationOutcome(status: .notFound, detail: "Reminder didn't persist.")
        }
        if reminder.title != parameters.title {
            return VerificationOutcome(
                status: .mismatch,
                detail: "Saved title \"\(reminder.title ?? "")\" differs from \"\(parameters.title)\"."
            )
        }
        return .passed
    }
}
