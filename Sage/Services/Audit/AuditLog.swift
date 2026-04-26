import Foundation
import SwiftData

// MARK: - AuditEvent
//
// Plan #6 (inspectable privacy) requires a tamper-evident record of
// what Sage looked at and why. Phase 0 lays the schema and the writer;
// Phase 7 ships the user-facing audit screen ("What did Sage do?").
//
// Every model invocation, retrieval call, and side-effecting action
// writes one row. The schema is intentionally narrow — broad enough
// to answer "what touched my data and when" without becoming an
// analytics pipeline.
//
// Privacy guarantees we maintain on this table:
//   • Stays on-device. Same SwiftData store as MemoryChunk, never
//     synced or exported automatically.
//   • Bounded retention: `AuditLogger.purgeOlderThan(...)` keeps the
//     last 30 days by default. Longer history is opt-in.
//   • Bounded cardinality: `dataAccessed` is a *summary*, never the
//     full content of what was retrieved (no leaking via the audit
//     log itself).

@Model
final class AuditEvent {

    /// Stable primary key; surfaced in audit-log views for tap-to-detail.
    var id: UUID

    #Index<AuditEvent>([\.timestamp], [\.actorRaw])
    var timestamp: Date

    /// Who acted. Stored as a raw string so we can add new actors
    /// (e.g. "vision.florence2") without a schema migration. The
    /// known set is captured in `Actor` for type-safe writers.
    var actorRaw: String

    /// What was done. Free-form snake_case verb. Examples:
    /// "classify", "generate", "search", "rerank", "execute".
    var action: String

    /// Optional one-line summary of what was touched. NEVER include
    /// the full content of retrieved memory — only counts, source IDs,
    /// or scope descriptors. Example: "search_memory query='dentist' results=8".
    var dataAccessed: String?

    /// Outcome of the call. Free-form but conventional values:
    /// "success", "error: <message>", "approved", "rejected", "cancelled".
    var outcome: String

    /// Optional small JSON-ish blob for callers that want to record
    /// extra structured fields without expanding the schema. Capped
    /// at 1 KB by the writer to prevent log bloat.
    var metadata: String?

    init(
        actor: String,
        action: String,
        dataAccessed: String?,
        outcome: String,
        metadata: String?,
        timestamp: Date = Date()
    ) {
        self.id            = UUID()
        self.timestamp     = timestamp
        self.actorRaw      = actor
        self.action        = action
        self.dataAccessed  = dataAccessed
        self.outcome       = outcome
        self.metadata      = metadata
    }
}

extension AuditEvent {
    /// Type-safe constants for the actors we control. New backends
    /// (Florence-2, KokoroTTS, etc.) add cases here as they land.
    enum Actor: String {
        case router          // intent classification
        case writer          // chat-model generation
        case embedder        // embedding lookup
        case reranker        // cross-encoder rerank
        case search          // semantic search engine
        case action          // ActionRunner — Phase 1
        case vision          // SmolVLM / Florence-2
        case asr             // Whisper / TranscriptionService
        case memory          // memory upsert / decay / pin
        case privacy         // air-gap toggle, permission grant
    }
}

// MARK: - AuditLogger
//
// Thin facade that the rest of the app uses. The intent is that
// services don't construct AuditEvent directly — they call
// `auditLogger.record(...)`. This gives us one place to add caps,
// rate limits, or off-switches later without touching call sites.

@MainActor
final class AuditLogger {

    private let modelContext: ModelContext

    /// Hard cap on the metadata blob. Anything longer is truncated
    /// with a marker — we'd rather have a trimmed audit row than
    /// blow up a write because some caller logged a giant payload.
    private let metadataCap = 1024

    /// Default retention. Phase 7's audit screen will let users
    /// override this in Settings.
    static let defaultRetentionDays = 30

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Primary write API. Non-throwing on purpose — audit failures
    /// must never block the user-visible operation. We swallow save
    /// errors and (Phase 7) surface them in Diagnostics.
    func record(
        actor: AuditEvent.Actor,
        action: String,
        dataAccessed: String? = nil,
        outcome: String,
        metadata: [String: String]? = nil
    ) {
        let metaStr = metadata.flatMap { Self.serialise($0, cap: metadataCap) }
        let event = AuditEvent(
            actor: actor.rawValue,
            action: action,
            dataAccessed: dataAccessed,
            outcome: outcome,
            metadata: metaStr
        )
        modelContext.insert(event)
        try? modelContext.save()
    }

    /// Convenience for the common success path — saves a few lines
    /// at every call site.
    func recordSuccess(
        actor: AuditEvent.Actor,
        action: String,
        dataAccessed: String? = nil,
        metadata: [String: String]? = nil
    ) {
        record(actor: actor, action: action, dataAccessed: dataAccessed,
               outcome: "success", metadata: metadata)
    }

    /// Convenience for the common error path.
    func recordFailure(
        actor: AuditEvent.Actor,
        action: String,
        error: Error,
        dataAccessed: String? = nil
    ) {
        record(actor: actor, action: action, dataAccessed: dataAccessed,
               outcome: "error: \(error.localizedDescription)", metadata: nil)
    }

    // MARK: Reads

    /// Most recent events, newest first. Used by the (Phase 7) audit
    /// screen and by Diagnostics.
    func recent(limit: Int = 200) -> [AuditEvent] {
        var descriptor = FetchDescriptor<AuditEvent>(
            sortBy: [SortDescriptor(\AuditEvent.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: Maintenance

    /// Trim rows older than the cutoff. Called from the existing
    /// background indexing task (Phase 8 will wire this).
    func purgeOlderThan(days: Int = AuditLogger.defaultRetentionDays) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<AuditEvent>(
            predicate: #Predicate { $0.timestamp < cutoff }
        )
        guard let stale = try? modelContext.fetch(descriptor) else { return }
        for ev in stale { modelContext.delete(ev) }
        try? modelContext.save()
    }

    // MARK: - Helpers

    private static func serialise(_ dict: [String: String], cap: Int) -> String? {
        guard !dict.isEmpty else { return nil }
        // Compact JSON; sortedKeys for stable test snapshots.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(dict),
              let str  = String(data: data, encoding: .utf8) else { return nil }
        if str.count <= cap { return str }
        return String(str.prefix(cap)) + "…"
    }
}
