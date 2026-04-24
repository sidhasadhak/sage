import Foundation

/// The structured result of LLM analysis on a voice transcription.
struct VoiceIntent {

    enum Action {
        /// A general note or thought to remember.
        case saveNote(title: String, body: String)
        /// A structured checklist (shopping list, to-do list, packing list …).
        case createList(title: String, items: [String])
        /// A task with an optional due date.
        case createReminder(title: String, dueDate: Date?, notes: String?)
        /// A calendar appointment.
        case createCalendarEvent(title: String, startDate: Date?, location: String?)
        /// A conversational question — route to the chat input.
        case chat(question: String)
    }

    let action: Action
    let labels: [String]          // up to 10 semantic tags
    let summary: String           // "I'll create a grocery list with 5 items."
    let transcription: String     // raw user speech
}

extension VoiceIntent.Action {
    var displayIcon: String {
        switch self {
        case .saveNote:           return "doc.text.fill"
        case .createList:         return "checklist"
        case .createReminder:     return "bell.fill"
        case .createCalendarEvent: return "calendar.badge.plus"
        case .chat:               return "bubble.left.fill"
        }
    }

    var displayTitle: String {
        switch self {
        case .saveNote:           return "Save Note"
        case .createList:         return "Create List"
        case .createReminder:     return "Set Reminder"
        case .createCalendarEvent: return "Add to Calendar"
        case .chat:               return "Send to Chat"
        }
    }

    var confirmLabel: String {
        switch self {
        case .saveNote:           return "Save Note"
        case .createList:         return "Create List"
        case .createReminder:     return "Set Reminder"
        case .createCalendarEvent: return "Add Event"
        case .chat:               return "Open in Chat"
        }
    }
}
