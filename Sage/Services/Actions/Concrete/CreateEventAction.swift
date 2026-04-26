import EventKit
import Foundation

// MARK: - CreateEventAction
//
// Wraps CalendarEventCreationService. Parameters from the router:
//   • title       (required)
//   • start_date  (optional — defaults to "in one hour")
//   • duration    (optional — minutes; defaults to 60)
//   • notes       (optional)
//   • location    (optional — Phase 1 ignores; CalendarEventCreationService
//                  needs an extension to wire this through)

@MainActor
final class CreateEventAction: Action {

    static let name        = "create_event"
    static let displayName = "Add to Calendar"

    struct Parameters: Sendable, Equatable {
        let title: String
        let startDate: Date?
        let durationMinutes: Int?
        let notes: String?
    }

    let parameters: Parameters
    private let service: CalendarEventCreationService

    init(rawParameters: [String: String], service: CalendarEventCreationService) throws {
        self.parameters = Parameters(
            title:           try ActionParam.string("title", in: rawParameters),
            startDate:       ActionParam.optionalDate("start_date", in: rawParameters),
            durationMinutes: ActionParam.optionalMinutes("duration", in: rawParameters),
            notes:           ActionParam.optionalString("notes", in: rawParameters)
        )
        self.service = service
    }

    // MARK: - Action conformance

    func dryRun() async throws -> ActionDiff {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short

        let start = parameters.startDate ?? Date().addingTimeInterval(3600)
        let dur   = parameters.durationMinutes ?? 60

        let summary = "Add \"\(parameters.title)\" to Calendar — \(f.string(from: start)) (\(dur) min)"
        var warnings: [String] = []

        if parameters.startDate == nil {
            warnings.append("Defaulting to one hour from now.")
        }
        if parameters.durationMinutes == nil {
            warnings.append("Defaulting to 60 minutes.")
        }

        let status = EKEventStore.authorizationStatus(for: .event)
        if status != .fullAccess {
            warnings.append("Calendar access required. Sage will ask the first time.")
        }

        return ActionDiff(
            summary: summary,
            icon: "calendar.badge.plus",
            tint: .blue,
            confirmLabel: "Add to Calendar",
            warnings: warnings
        )
    }

    func execute() async throws -> ActionReceipt {
        // Phase 3: capture eventIdentifier for verify + rollback.
        let id: String
        do {
            id = try await service.createEvent(
                title: parameters.title,
                startDate: parameters.startDate,
                notes: parameters.notes
            )
        } catch {
            throw ActionError.underlying(error)
        }

        return ActionReceipt(
            actionName: Self.name,
            entityID: id.isEmpty ? nil : id,
            summary: "Added \"\(parameters.title)\" to Calendar",
            rollbackSupported: !id.isEmpty
        )
    }

    func rollback(_ receipt: ActionReceipt) async throws {
        guard let id = receipt.entityID else {
            throw ActionError.rollbackUnsupported(Self.name)
        }
        do {
            try await service.deleteEvent(identifier: id)
        } catch {
            throw ActionError.underlying(error)
        }
    }

    func verify(_ receipt: ActionReceipt) async -> VerificationOutcome {
        guard let id = receipt.entityID else { return .skipped }
        guard let event = service.event(identifier: id) else {
            return VerificationOutcome(status: .notFound, detail: "Event didn't persist.")
        }
        if event.title != parameters.title {
            return VerificationOutcome(
                status: .mismatch,
                detail: "Saved title \"\(event.title ?? "")\" differs from \"\(parameters.title)\"."
            )
        }
        return .passed
    }
}
