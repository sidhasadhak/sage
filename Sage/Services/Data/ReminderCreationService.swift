import EventKit
import Foundation

@MainActor
final class ReminderCreationService {
    private let store = EKEventStore()

    /// Returns the persisted reminder's `calendarItemIdentifier` so
    /// callers can verify the write landed (Phase 3 PEV controller)
    /// and roll it back later (action layer's Undo path).
    @discardableResult
    func createReminder(title: String, notes: String? = nil, dueDate: Date? = nil) async throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due = dueDate {
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.dueDateComponents = components
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    /// Lookup + delete by the identifier returned from `createReminder`.
    /// Used by CreateReminderAction.rollback().
    func deleteReminder(identifier: String) async throws {
        guard let item = store.calendarItem(withIdentifier: identifier),
              let reminder = item as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    /// Read-back for verification. Returns nil if the reminder no
    /// longer exists. Caller checks the title / due date for drift.
    func reminder(identifier: String) -> EKReminder? {
        store.calendarItem(withIdentifier: identifier) as? EKReminder
    }

    // Simple NLP: detect reminder intent and extract title + optional date
    func parseReminderIntent(from text: String) -> (title: String, dueDate: Date?)? {
        let lower = text.lowercased()
        let triggers = ["remind me to", "reminder to", "don't forget to", "remember to", "add reminder", "set reminder"]
        guard triggers.contains(where: { lower.contains($0) }) else { return nil }

        var title = text
        for trigger in triggers {
            if let range = lower.range(of: trigger) {
                title = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Try to extract a time/date
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        let date = matches?.first?.date

        // Clean up the title by removing the date portion
        if title.isEmpty { title = text }
        return (title: String(title.prefix(100)), dueDate: date)
    }
}
