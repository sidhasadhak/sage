import EventKit
import Foundation

@MainActor
final class CalendarEventCreationService {
    private let store = EKEventStore()

    /// Returns the persisted event's `eventIdentifier` so the
    /// Phase-3 PEV controller can verify the write landed and the
    /// action layer can roll it back.
    @discardableResult
    func createEvent(title: String, startDate: Date? = nil, notes: String? = nil) async throws -> String {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != .fullAccess {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { throw CalendarError.accessDenied }
        }

        let start = startDate ?? Date().addingTimeInterval(3600)
        let end = start.addingTimeInterval(3600)
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        guard event.calendar != nil else { throw CalendarError.noDefaultCalendar }
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? ""
    }

    /// Delete by identifier — paired with `createEvent` for the
    /// action layer's rollback path.
    func deleteEvent(identifier: String) async throws {
        guard let event = store.event(withIdentifier: identifier) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    /// Read-back for verification.
    func event(identifier: String) -> EKEvent? {
        store.event(withIdentifier: identifier)
    }
}

enum CalendarError: LocalizedError {
    case accessDenied
    case noDefaultCalendar

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Calendar access was denied. Please enable it in Settings."
        case .noDefaultCalendar: return "No default calendar found. Please set one up in the Calendar app."
        }
    }
}
