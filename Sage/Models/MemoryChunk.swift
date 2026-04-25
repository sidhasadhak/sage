import SwiftData
import Foundation

@Model
final class MemoryChunk {
    // Indexed columns — these are the fields touched on every search,
    // every cache load, and every upsert lookup. Without indexes,
    // SwiftData (SQLite) performs full table scans which become a
    // visible cold-start tax once the library passes a few thousand
    // rows. Indexes are cheap on writes (we upsert in batches) and
    // dramatically speed up the read paths in IndexingService and
    // SemanticSearchEngine.
    // Note: `sourceType` is intentionally NOT indexed. It's a Codable enum,
    // which SwiftData persists via a transformer (a "composite" property),
    // and `#Index` rejects composite properties at ModelContainer init with
    // an `NSInvalidArgumentException: Can't create an index element with
    // composite property`. Filtering by source type stays fast in practice
    // because the result set is already narrowed by the indexed `updatedAt`
    // / `sourceDate` columns before the predicate runs.
    #Index<MemoryChunk>([\.updatedAt], [\.sourceID], [\.sourceDate])

    var id: UUID
    var sourceType: SourceType
    var sourceID: String
    var content: String
    var keywords: [String]
    var createdAt: Date
    var updatedAt: Date
    var embeddingData: Data?
    var isSpotlightIndexed: Bool
    var sourceDate: Date?

    /// Knowledge-graph entities extracted by the LLM (optional feature).
    /// Format: "type:name" e.g. ["person:John Smith", "place:Paris", "project:Q4"]
    /// nil = not yet processed. Empty array = processed but no entities found.
    var entities: [String]?

    @Relationship(deleteRule: .nullify)
    var note: Note?

    @Relationship(deleteRule: .nullify)
    var email: ImportedEmail?

    enum SourceType: String, Codable {
        case photo, contact, event, reminder, note, conversation, email
    }

    init(sourceType: SourceType, sourceID: String, content: String, keywords: [String] = [], sourceDate: Date? = nil) {
        self.id = UUID()
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.content = content
        self.keywords = keywords
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isSpotlightIndexed = false
        self.sourceDate = sourceDate
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
