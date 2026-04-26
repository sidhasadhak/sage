import Foundation
import SwiftUI

/// What Sage understood from a voice transcription.
///
/// The classifier (LLM-backed when the chat model is loaded, regex fallback
/// otherwise) reads the transcription and decides which app surface should
/// receive it — a note, a checklist, a reminder, a calendar event, or the
/// chat tab. The view then renders a preview screen the user confirms before
/// the action is committed.
struct VoiceIntent: Equatable {
    enum Kind: Equatable {
        case note
        case checklist(items: [String])
        case reminder(dueDate: Date?)
        case calendarEvent(startDate: Date?)
        case chat

        var displayName: String {
            switch self {
            case .note:           return "Note"
            case .checklist:      return "Checklist"
            case .reminder:       return "Reminder"
            case .calendarEvent:  return "Calendar Event"
            case .chat:           return "Ask Sage"
            }
        }

        var systemImage: String {
            switch self {
            case .note:           return "doc.text.fill"
            case .checklist:      return "checklist"
            case .reminder:       return "bell.fill"
            case .calendarEvent:  return "calendar"
            case .chat:           return "bubble.left.and.bubble.right.fill"
            }
        }

        var accent: Color {
            switch self {
            case .note:           return Color(red: 0.95, green: 0.7, blue: 0.1)  // amber
            case .checklist:      return .blue
            case .reminder:       return .orange
            case .calendarEvent:  return .red
            case .chat:           return .purple
            }
        }
    }

    var kind: Kind
    var title: String
    var transcription: String
    var summary: String          // human-readable “what Sage will do”

    static let placeholder = VoiceIntent(
        kind: .note,
        title: "Voice Note",
        transcription: "",
        summary: "Saved as a note"
    )
}
