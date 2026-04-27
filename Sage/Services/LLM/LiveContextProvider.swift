import Foundation
import EventKit

// MARK: - LiveContextProvider
//
// Pre-loads every chat turn with fresh, ground-truth state from iOS:
//
//   • Today's date and time (eliminates the "I think it's June 2024"
//     hallucination — small models will *always* guess training-era
//     dates if not told otherwise).
//   • The user's actual upcoming calendar events for the next 7 days
//     — straight from EventKit, not the embedding index. Means the
//     writer can't invent meetings.
//   • The user's pending reminders due in the next 14 days — same
//     story.
//
// Injected by ContextBuilder.buildSystemPrompt at the top of the
// system prompt so the writer sees it first, every turn. Replaces
// the agent loop's `current_datetime` and `list_upcoming_events`
// tools as the *primary* source of this state — the tools are still
// registered as a fallback when the model wants to drill deeper.

@MainActor
final class LiveContextProvider {

    private let store = EKEventStore()

    /// `nonisolated` so callers from any actor (and default-argument
    /// resolution in `ContextBuilder.init`) can construct one without
    /// hopping to the main actor. The instance methods that touch
    /// EventKit / Date stay main-actor isolated.
    nonisolated init() {}

    /// Cap on how many events / reminders we inline. We cap by item
    /// count rather than character length because each item is small;
    /// 20 events covers a busy week comfortably and leaves prompt
    /// budget for retrieved memory chunks.
    private let maxEvents     = 20
    private let maxReminders  = 15

    /// Built once per chat turn from `ContextBuilder`.
    func snapshot() async -> String {
        var blocks: [String] = []

        blocks.append(dateBlock())

        if let events = await calendarBlock() {
            blocks.append(events)
        }

        if let reminders = await remindersBlock() {
            blocks.append(reminders)
        }

        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Date

    private func dateBlock() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        let date = f.string(from: Date())

        let timeF = DateFormatter()
        timeF.dateFormat = "h:mm a zzz"
        let time = timeF.string(from: Date())

        return """
        ## Right now
        Today is \(date). The current time is \(time). Use these values \
        verbatim — do NOT estimate or guess the date from training data.
        """
    }

    // MARK: - Calendar

    /// Returns nil when calendar access isn't granted (caller silently
    /// omits the block; the writer is told elsewhere not to claim
    /// "I can't access your calendar").
    private func calendarBlock() async -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return nil
        }

        let now = Date()
        guard let weekOut = Calendar.current.date(byAdding: .day, value: 7, to: now) else {
            return nil
        }

        let predicate = store.predicateForEvents(withStart: now, end: weekOut, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(maxEvents)

        if events.isEmpty {
            return """
            ## Upcoming calendar (next 7 days)
            The user has NO events scheduled in the next 7 days. \
            Do NOT invent meetings, lunches, or appointments.
            """
        }

        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let lines = events.map { e -> String in
            let when = f.string(from: e.startDate)
            let where_ = (e.location?.isEmpty == false) ? " @ \(e.location!)" : ""
            return "  • \(when): \(e.title ?? "Untitled")\(where_)"
        }

        return """
        ## Upcoming calendar (next 7 days, fresh from iOS Calendar)
        These are the user's actual scheduled events. When asked \
        about the calendar, quote ONLY from this list — do NOT invent \
        meetings, attendees, locations, or times.
        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: - Reminders
    //
    // EventKit's reminders API is callback-based with no async sugar,
    // so we wrap it in a checked continuation. Permission is split
    // from events (`.reminder` entityType), so it's possible to have
    // calendar but not reminders or vice versa.

    private func remindersBlock() async -> String? {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return nil
        }

        let predicate = store.predicateForReminders(in: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { fetched in
                continuation.resume(returning: fetched ?? [])
            }
        }

        let now = Date()
        let twoWeeks = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now

        // Pending + due-soon (or undated open reminders).
        let pending = reminders
            .filter { !$0.isCompleted }
            .filter { reminder in
                guard let due = reminder.dueDateComponents?.date else {
                    // Undated reminders: include them — they're "open todos".
                    return true
                }
                return due <= twoWeeks
            }
            .sorted { lhs, rhs in
                let l = lhs.dueDateComponents?.date ?? Date.distantFuture
                let r = rhs.dueDateComponents?.date ?? Date.distantFuture
                return l < r
            }
            .prefix(maxReminders)

        if pending.isEmpty {
            return """
            ## Open reminders
            The user has no open reminders due in the next 14 days.
            """
        }

        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let lines = pending.map { reminder -> String in
            let title = reminder.title ?? "Untitled"
            if let due = reminder.dueDateComponents?.date {
                return "  • \(f.string(from: due)): \(title)"
            }
            return "  • (no due date): \(title)"
        }

        return """
        ## Open reminders (next 14 days, fresh from iOS Reminders)
        These are the user's actual pending reminders. Quote ONLY \
        from this list — do NOT invent reminders or due dates.
        \(lines.joined(separator: "\n"))
        """
    }
}
