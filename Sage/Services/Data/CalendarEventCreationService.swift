import EventKit
import Foundation

@MainActor
final class CalendarEventCreationService {
    private let store = EKEventStore()

    func createEvent(title: String, startDate: Date? = nil, notes: String? = nil) async throws {
        let start = startDate ?? Date().addingTimeInterval(3600)
        let end = start.addingTimeInterval(3600)
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
    }
}
