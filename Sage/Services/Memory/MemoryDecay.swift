import Foundation
import SwiftData

// MARK: - MemoryDecay
//
// Phase 2 of the v1.2 plan: memory becomes garbage-collected, not just
// embedded. Without decay, the search index grows monotonically and
// stale chunks dilute the semantic-similarity signal. The decay pass
// solves both:
//
//   • working    + score < threshold        → ephemeral (keep but rank lower)
//   • ephemeral  + age   > evictionDays     → delete (with cache + spotlight cleanup)
//   • longTerm   or pinned                  → never decays
//
// Idempotent: running twice in a row is safe. Cheap: O(rows) once a
// day, no model calls.
//
// Wired into IndexingService.indexAll once per day (gated by a
// UserDefaults timestamp).

@MainActor
final class MemoryDecay {

    private let modelContext: ModelContext
    private let searchEngine: SemanticSearchEngine
    private let spotlightService: SpotlightService
    private let auditLogger: AuditLogger?

    /// Working chunks with effective score below this get demoted to
    /// ephemeral. Tuned conservatively — we'd rather keep a stale
    /// chunk than wrongly demote a real one.
    static let demotionThreshold: Double = 0.20

    /// Ephemeral chunks older than this since last access are evicted.
    static let evictionDays: Double = 30

    /// Don't run the decay pass more often than once per day.
    static let minimumIntervalHours: Double = 20

    private static let lastRunKey = "delta.memoryDecayLastRun"

    init(
        modelContext: ModelContext,
        searchEngine: SemanticSearchEngine,
        spotlightService: SpotlightService,
        auditLogger: AuditLogger? = nil
    ) {
        self.modelContext     = modelContext
        self.searchEngine     = searchEngine
        self.spotlightService = spotlightService
        self.auditLogger      = auditLogger
    }

    // MARK: - Public

    /// Result summary, useful for the audit log + Diagnostics surface.
    struct PassResult: Equatable {
        var demoted: Int = 0
        var evicted: Int = 0
        var skipped: Int = 0   // returned untouched
        var pinnedSeen: Int = 0
    }

    /// Run the decay pass if the last run was more than
    /// `minimumIntervalHours` ago. Returns `nil` when skipped.
    @discardableResult
    func runIfDue(force: Bool = false) async -> PassResult? {
        if !force, let last = UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date,
           Date().timeIntervalSince(last) < Self.minimumIntervalHours * 3600 {
            return nil
        }
        let result = await run()
        UserDefaults.standard.set(Date(), forKey: Self.lastRunKey)
        return result
    }

    /// Always runs, regardless of last-run timestamp. Tests + a
    /// hypothetical Settings → "Run decay now" button use this.
    func run() async -> PassResult {
        var result = PassResult()
        let descriptor = FetchDescriptor<MemoryChunk>()
        guard let all = try? modelContext.fetch(descriptor) else { return result }

        let cutoff = Date().addingTimeInterval(-Self.evictionDays * 86_400)
        for chunk in all {
            if chunk.pinned || chunk.tier == .longTerm {
                result.pinnedSeen += 1
                continue
            }
            // Eviction first — ephemeral + stale wins over demotion.
            if chunk.tier == .ephemeral, chunk.lastAccessedAt < cutoff {
                await searchEngine.removeFromCache(id: chunk.id)
                await spotlightService.remove(chunkID: chunk.id)
                modelContext.delete(chunk)
                result.evicted += 1
                continue
            }
            // Demotion: working → ephemeral when score has fallen off.
            if chunk.tier == .working, chunk.decayMultiplier < Self.demotionThreshold {
                chunk.tier = .ephemeral
                result.demoted += 1
                continue
            }
            result.skipped += 1
        }
        try? modelContext.save()

        auditLogger?.recordSuccess(
            actor: .memory,
            action: "decay_pass",
            dataAccessed: "demoted=\(result.demoted) evicted=\(result.evicted) skipped=\(result.skipped) pinned=\(result.pinnedSeen)"
        )
        return result
    }

    // MARK: - User-driven memory controls
    //
    // Pin / forget / correct / promote are routed through here so the
    // audit log captures user intent (Phase 7 will surface this).

    func pin(_ chunk: MemoryChunk) {
        chunk.pinned = true
        chunk.tier = .longTerm
        chunk.lastAccessedAt = Date()
        try? modelContext.save()
        auditLogger?.recordSuccess(actor: .memory, action: "pin", dataAccessed: chunk.sourceID)
    }

    func unpin(_ chunk: MemoryChunk) {
        chunk.pinned = false
        chunk.tier = .working
        try? modelContext.save()
        auditLogger?.recordSuccess(actor: .memory, action: "unpin", dataAccessed: chunk.sourceID)
    }

    /// User-initiated forget. Removes the chunk from SwiftData, the
    /// search cache, and Spotlight. The original source data
    /// (photo, contact, calendar event) is untouched — only Sage's
    /// memory of it goes.
    func forget(_ chunk: MemoryChunk) async {
        let id  = chunk.id
        let src = chunk.sourceID
        await searchEngine.removeFromCache(id: id)
        await spotlightService.remove(chunkID: id)
        modelContext.delete(chunk)
        try? modelContext.save()
        auditLogger?.recordSuccess(actor: .memory, action: "forget", dataAccessed: src)
    }

    /// User-corrected content. Sets confidence to 1.0 (user-confirmed)
    /// and re-stamps `updatedAt` so retrieval freshness reflects the
    /// edit. Re-embedding is the indexing service's job — a
    /// follow-up pass picks the new content up.
    func correct(_ chunk: MemoryChunk, newContent: String) {
        chunk.content        = newContent
        chunk.confidence     = 1.0
        chunk.updatedAt      = Date()
        chunk.lastAccessedAt = Date()
        try? modelContext.save()
        auditLogger?.recordSuccess(actor: .memory, action: "correct", dataAccessed: chunk.sourceID)
    }

    /// Bump access time on chunks injected into a response. Drives
    /// the decay clock so things you actually use don't fade out.
    func touch(chunkSourceIDs: [String]) {
        guard !chunkSourceIDs.isEmpty else { return }
        let set = Set(chunkSourceIDs)
        let descriptor = FetchDescriptor<MemoryChunk>(
            predicate: #Predicate { set.contains($0.sourceID) }
        )
        guard let chunks = try? modelContext.fetch(descriptor) else { return }
        let now = Date()
        for chunk in chunks { chunk.lastAccessedAt = now }
        try? modelContext.save()
    }
}
