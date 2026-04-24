import EventKit
import Foundation

@MainActor
final class CalendarEventCreationService {
    private let store = EKEventStore()

    func createEvent(title: String, startDate: Date? = nil, notes: String? = nil) async throws {
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
