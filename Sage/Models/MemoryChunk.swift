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

    // ── v1.2 Phase 2: tiered memory ─────────────────────────────────
    // Three-tier memory replaces the flat "everything is forever"
    // model. New chunks land in `.working`; the daily decay pass
    // demotes them to `.ephemeral` once their effective score drops
    // below threshold; ephemeral chunks are evicted on a 30-day
    // boundary unless re-accessed. Pinned chunks never decay.
    //
    // All four fields have safe defaults so SwiftData performs a
    // lightweight migration on the existing store.

    var tier: Tier = Tier.working

    /// User-pinned chunks survive the decay pass regardless of age.
    var pinned: Bool = false

    /// 0.0 (model-inferred / low-evidence) → 1.0 (user-confirmed).
    /// New chunks default to 1.0 because the original sources are
    /// authoritative — the model never wrote them. The Phase-3 PEV
    /// loop can downgrade chunks it created itself when stating a
    /// hypothesis.
    var confidence: Double = 1.0

    /// Bumped every time the chunk is included in a response context
    /// or directly opened by the user. Drives the decay clock —
    /// recently-used chunks effectively age slower.
    var lastAccessedAt: Date = Date()

    /// Half-life in days. Hot sources (calendar events, reminders)
    /// can override to age faster; cold sources (notes) age slower.
    /// Default 30 days fits most personal-data use cases.
    var decayHalfLifeDays: Double = 30

    @Relationship(deleteRule: .nullify)
    var note: Note?

    @Relationship(deleteRule: .nullify)
    var email: ImportedEmail?

    enum SourceType: String, Codable {
        case photo, contact, event, reminder, note, conversation, email
    }

    enum Tier: String, Codable {
        /// Just-arrived or recently-accessed; full retrieval weight.
        case working
        /// Aged-out or low-confidence; included in retrieval but
        /// down-weighted. Eviction candidate.
        case ephemeral
        /// Explicitly elevated by the user ("remember this") or
        /// by Phase-3 verification. Never decays.
        case longTerm
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

    /// Pure-function decay multiplier in [0, 1]. Ranking code
    /// multiplies semantic-similarity by this to push stale,
    /// unconfirmed chunks down the ranking without removing them.
    /// `pinned` and `.longTerm` short-circuit to 1.0.
    var decayMultiplier: Double {
        if pinned || tier == .longTerm { return 1.0 }
        let ageDays = max(0, Date().timeIntervalSince(lastAccessedAt) / 86_400)
        let halfLives = ageDays / max(decayHalfLifeDays, 1)
        // 0.5^n; clamp to floor 0.05 so an old chunk can still
        // surface if it's the only match.
        return max(0.05, pow(0.5, halfLives)) * confidence
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
