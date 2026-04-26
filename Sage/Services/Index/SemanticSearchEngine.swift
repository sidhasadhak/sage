import Foundation
import Accelerate
import SwiftData

actor SemanticSearchEngine {

    struct CacheEntry {
        let id: UUID
        let vector: [Float]
        let chunk: MemoryChunk
        let updatedAt: Date
    }

    // Flat array kept for keyword + recency re-scoring after ANN recall.
    private var cache: [CacheEntry] = []
    private var cacheLoaded = false

    // HNSW (or flat-scan fallback) index for fast cosine first-stage recall.
    // Populated in parallel with `cache` via loadCache / addToCache.
    private let hnswIndex = HNSWVectorIndex()

    private let embeddingService = EmbeddingService.shared

    // MARK: - Search

    func search(query: String, topK: Int) async -> [MemoryChunk] {
        guard !cache.isEmpty else {
            return keywordSearch(query: query, topK: topK)
        }

        let queryVector: [Float]
        do {
            queryVector = try await embeddingService.embed(text: query)
        } catch {
            return keywordSearch(query: query, topK: topK)
        }

        // First stage: HNSW (or flat-scan) returns cosine-nearest candidates.
        // Fetch 2× topK so the re-scoring step has enough headroom.
        let candidates = await hnswIndex.search(query: queryVector, topK: topK * 2)

        // Second stage: re-score candidates with keyword + recency signals.
        let scored = candidates.map { entry -> (MemoryChunk, Float) in
            let cosine = cosineSimilarity(queryVector, entry.vector)
            let keyword = Float(keywordScore(query: query, chunk: entry.chunk))
            let recency = recencyScore(date: entry.updatedAt)
            let combined = 0.65 * cosine + 0.20 * keyword + 0.15 * recency
            return (entry.chunk, combined)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { $0.0 }
    }

    // MARK: - Cache Management

    func loadCache(chunks: [MemoryChunk]) {
        // Time-sensitive sources (photos, events) are evicted from RAM after 90 days.
        // Durable sources (contacts, notes, reminders) are always kept hot.
        let hotThreshold = Date(timeIntervalSinceNow: -(90 * 86400))
        cache = chunks.compactMap { chunk in
            let isTimeSensitive = chunk.sourceType == .photo || chunk.sourceType == .event
            if isTimeSensitive && chunk.updatedAt < hotThreshold { return nil }
            guard let data = chunk.embeddingData else { return nil }
            let vector = EmbeddingService.unpack(data)
            guard !vector.isEmpty else { return nil }
            return CacheEntry(id: chunk.id, vector: vector, chunk: chunk, updatedAt: chunk.updatedAt)
        }
        cacheLoaded = true

        // Build HNSW index from the loaded entries.
        let entries = cache
        Task { await hnswIndex.build(from: entries) }
    }

    func addToCache(chunk: MemoryChunk) async {
        guard let data = chunk.embeddingData else { return }
        let vector = EmbeddingService.unpack(data)
        guard !vector.isEmpty else { return }
        let entry = CacheEntry(id: chunk.id, vector: vector, chunk: chunk, updatedAt: chunk.updatedAt)
        cache.removeAll { $0.id == chunk.id }
        cache.append(entry)
        await hnswIndex.add(entry: entry)
    }

    func removeFromCache(id: UUID) {
        cache.removeAll { $0.id == id }
        Task { await hnswIndex.remove(id: id) }
    }

    func invalidateCache() {
        cache = []
        cacheLoaded = false
        Task { await hnswIndex.build(from: []) }
    }

    // MARK: - Helpers

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(count))

        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    private func keywordSearch(query: String, topK: Int) -> [MemoryChunk] {
        let queryWords = query.lowercased().components(separatedBy: .whitespacesAndNewlines)
        let scored = cache.map { entry -> (MemoryChunk, Float) in
            let score = Float(keywordScore(query: query, chunk: entry.chunk, queryWords: queryWords))
            return (entry.chunk, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(topK).map { $0.0 }
    }

    private func keywordScore(query: String, chunk: MemoryChunk, queryWords: [String]? = nil) -> Double {
        let words = queryWords ?? query.lowercased().components(separatedBy: .whitespacesAndNewlines)
        let content = chunk.content.lowercased()
        let keywords = chunk.keywords.map { $0.lowercased() }

        var score = 0.0
        for word in words where word.count > 2 {
            if content.contains(word) { score += 1.0 }
            if keywords.contains(where: { $0.contains(word) }) { score += 0.5 }
        }
        return min(score / max(Double(words.count), 1), 1.0)
    }

    private func recencyScore(date: Date) -> Float {
        let daysSince = Date().timeIntervalSince(date) / 86400
        return Float(exp(-daysSince / 30))
    }
}
