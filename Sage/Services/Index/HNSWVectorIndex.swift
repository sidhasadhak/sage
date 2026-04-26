import Foundation
import Accelerate

// MARK: - HNSWVectorIndex
//
// Approximate nearest-neighbour index for the 512-d sentence embeddings
// produced by EmbeddingService.
//
// Two implementations, selected at compile time:
//
//   USearch (preferred) — O(log N) ANN queries via the Hierarchical
//     Navigable Small World graph. Add the package once in Xcode and the
//     fast path activates automatically with no code changes.
//
//     Package URL: https://github.com/unum-cloud/usearch
//     Version:     Up To Next Major from 2.0.0
//     Product:     USearch
//
//   FlatScan (fallback) — O(N) exhaustive cosine scan, identical in
//     quality but slower on large collections (>5 k chunks). Ships with
//     no extra dependencies so the app always builds.
//
// How to add USearch via Xcode:
//   File → Add Package Dependencies…
//   URL: https://github.com/unum-cloud/usearch
//   Dependency Rule: Up To Next Major Version, 2.0.0
//   Add to target: Sage
//
// Once the package is linked the `#if canImport(USearch)` block below
// compiles in and all subsequent index operations run via HNSW.

#if canImport(USearch)
import USearch

// MARK: USearch-backed implementation

/// An actor that maintains a live HNSW graph over the in-RAM embedding
/// cache and answers top-K cosine queries in O(log N) time.
actor HNSWVectorIndex {

    // USearch key type alias for clarity.
    typealias Key = USearchKey   // UInt64

    // MARK: State

    private var index: USearchIndex?
    private var dimension: UInt32 = 0

    // Bidirectional map: stable UInt64 key ↔ chunk UUID.
    private var keyToID: [Key: UUID] = [:]
    private var idToKey: [UUID: Key] = [:]
    private var nextKey: Key = 1

    // Full entry lookup (needed to return MemoryChunk after ANN).
    private var entries: [UUID: SemanticSearchEngine.CacheEntry] = [:]

    // MARK: Build

    /// Replace the entire index with `newEntries`.
    /// Called once when the search cache is loaded from SwiftData.
    func build(from newEntries: [SemanticSearchEngine.CacheEntry]) {
        keyToID = [:]
        idToKey = [:]
        nextKey  = 1
        entries  = [:]
        index    = nil

        guard !newEntries.isEmpty else { return }

        let dim = UInt32(newEntries[0].vector.count)
        guard dim > 0 else { return }
        dimension = dim

        guard let idx = try? USearchIndex.make(
            metric: .cos,
            dimensions: dim,
            connectivity: 16,       // M: 16 is the standard default
            quantization: .f32
        ) else { return }

        try? idx.reserve(UInt32(newEntries.count + 64))

        for entry in newEntries {
            let key = nextKey; nextKey += 1
            keyToID[key] = entry.id
            idToKey[entry.id] = key
            entries[entry.id] = entry
            try? idx.add(key: key, vector: entry.vector)
        }

        index = idx
    }

    // MARK: Incremental updates

    func add(entry: SemanticSearchEngine.CacheEntry) {
        guard !entry.vector.isEmpty else { return }

        // First entry — initialise the index on the spot.
        if index == nil {
            let dim = UInt32(entry.vector.count)
            dimension = dim
            index = try? USearchIndex.make(
                metric: .cos,
                dimensions: dim,
                connectivity: 16,
                quantization: .f32
            )
        }

        guard let idx = index,
              UInt32(entry.vector.count) == dimension else { return }

        // Remove stale entry for the same UUID if re-indexing.
        if let oldKey = idToKey[entry.id] {
            try? idx.remove(key: oldKey)
            keyToID.removeValue(forKey: oldKey)
        }

        let key = nextKey; nextKey += 1
        keyToID[key] = entry.id
        idToKey[entry.id] = key
        entries[entry.id] = entry
        try? idx.add(key: key, vector: entry.vector)
    }

    func remove(id: UUID) {
        guard let key = idToKey[id] else { return }
        try? index?.remove(key: key)
        keyToID.removeValue(forKey: key)
        idToKey.removeValue(forKey: id)
        entries.removeValue(forKey: id)
    }

    // MARK: Query

    /// Return up to `topK` entries ordered by cosine similarity to `query`.
    /// Falls back to flat scan if the index has not been built yet.
    func search(query: [Float], topK: Int) -> [SemanticSearchEngine.CacheEntry] {
        guard !entries.isEmpty else { return [] }
        guard let idx = index, query.count == Int(dimension) else {
            return flatScan(query: query, topK: topK)
        }

        // ANN: fetch 2× topK so post-filter (stale keys) doesn't starve results.
        let fetchK = UInt32(min(topK * 2, entries.count))
        guard let (keys, _) = try? idx.search(vector: query, count: fetchK) else {
            return flatScan(query: query, topK: topK)
        }

        let result = keys.compactMap { keyToID[$0].flatMap { entries[$0] } }
        return Array(result.prefix(topK))
    }

    // MARK: Flat-scan fallback (used when ANN index isn't ready)

    private func flatScan(query: [Float], topK: Int) -> [SemanticSearchEngine.CacheEntry] {
        let scored = entries.values.map { entry -> (SemanticSearchEngine.CacheEntry, Float) in
            (entry, cosine(query, entry.vector))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(topK).map { $0.0 }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(n))
        vDSP_svesq(a, 1, &na, vDSP_Length(n))
        vDSP_svesq(b, 1, &nb, vDSP_Length(n))
        let d = sqrt(na) * sqrt(nb)
        return d > 0 ? dot / d : 0
    }
}

#else

// MARK: - Flat-scan fallback (no USearch package)
//
// Identical API surface so SemanticSearchEngine compiles either way.
// Performance characteristics: O(N) per query — fine up to ~10 k chunks.

actor HNSWVectorIndex {

    private var entries: [UUID: SemanticSearchEngine.CacheEntry] = [:]

    func build(from newEntries: [SemanticSearchEngine.CacheEntry]) {
        entries = Dictionary(uniqueKeysWithValues: newEntries.map { ($0.id, $0) })
    }

    func add(entry: SemanticSearchEngine.CacheEntry) {
        entries[entry.id] = entry
    }

    func remove(id: UUID) {
        entries.removeValue(forKey: id)
    }

    func search(query: [Float], topK: Int) -> [SemanticSearchEngine.CacheEntry] {
        guard !entries.isEmpty else { return [] }
        let scored = entries.values.map { entry -> (SemanticSearchEngine.CacheEntry, Float) in
            (entry, cosine(query, entry.vector))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(topK).map { $0.0 }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(n))
        vDSP_svesq(a, 1, &na, vDSP_Length(n))
        vDSP_svesq(b, 1, &nb, vDSP_Length(n))
        let d = sqrt(na) * sqrt(nb)
        return d > 0 ? dot / d : 0
    }
}

#endif
