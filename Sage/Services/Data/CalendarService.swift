import EventKit

final class CalendarService {

    static let store = EKEventStore()

    static func requestEventAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    static func requestReminderAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    static var eventAuthorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    static var reminderAuthorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    static func isAuthorizedForEvents() -> Bool {
        eventAuthorizationStatus == .fullAccess
    }

    static func isAuthorizedForReminders() -> Bool {
        reminderAuthorizationStatus == .fullAccess
    }

    static func fetchEvents(daysAhead: Int = 180, daysBehind: Int = 180) -> [EKEvent] {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -daysBehind, to: now)!
        let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: now)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
    }

    static func fetchReminders() async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            let predicate = store.predicateForReminders(in: nil)
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }
}
