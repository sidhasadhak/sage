import SwiftData
import Foundation

@Model
final class MemoryChunk {
    var id: UUID
    var sourceType: SourceType
    var sourceID: String
    var content: String
    var keywords: [String]
    var createdAt: Date
    var updatedAt: Date
    var embeddingData: Data?
    var isSpotlightIndexed: Bool

    @Relationship(deleteRule: .nullify)
    var note: Note?

    @Relationship(deleteRule: .nullify)
    var email: ImportedEmail?

    enum SourceType: String, Codable {
        case photo, contact, event, reminder, note, conversation, email
    }

    init(sourceType: SourceType, sourceID: String, content: String, keywords: [String] = []) {
        self.id = UUID()
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.content = content
        self.keywords = keywords
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isSpotlightIndexed = false
    }

    var openURL: URL? {
        switch sourceType {
        case .photo:
            return URL(string: "photos-redirect://")
        case .event:
            return URL(string: "calshow://")
        case .reminder:
            return URL(string: "x-apple-reminderkit://")
        case .contact:
            return URL(string: "addressbook://")
        case .note, .conversation, .email:
            return nil
        }
    }

    var photoAssetIdentifier: String? { sourceType == .photo ? sourceID : nil }

    var icon: String {
        switch sourceType {
        case .photo: return "photo"
        case .contact: return "person.circle"
        case .event: return "calendar"
        case .reminder: return "checklist"
        case .note: return "note.text"
        case .conversation: return "bubble.left.and.bubble.right"
        case .email: return "envelope"
        }
    }

    var typeLabel: String {
        sourceType.rawValue.capitalized
    }
}
