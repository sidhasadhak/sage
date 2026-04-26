import Foundation
import SwiftData

// MARK: - SharedContentIndexer
//
// Reads items queued in the App Group container by the SageShare extension
// and turns them into MemoryChunks that feed the semantic search engine.
//
// Call site: SageApp body, inside `.onChange(of: scenePhase)` when the
// app moves to `.active`, so pickup runs every time the user returns to
// Sage after sharing something.
//
// App Group ID must match SageShare/SharedItemStore.swift → appGroupID.
// Enable "App Groups" capability on BOTH the Sage and SageShare targets in
// Xcode → Signing & Capabilities using the same group identifier string.

private let sharedAppGroupID = "group.sage.app"   // ← keep in sync with SageShare

@MainActor
final class SharedContentIndexer {

    // MARK: - Shared item model
    //
    // Mirrors SageShare/SharedItemStore.SharedItem — deliberately duplicated
    // so the main app has no compile-time dependency on the extension module.

    private enum ItemType: String, Codable {
        case url, text, image
    }

    private struct PendingItem: Codable, Identifiable {
        let id: UUID
        let type: ItemType
        let content: String
        let note: String
        let sourceApp: String
        let date: Date
    }

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let searchEngine: SemanticSearchEngine
    private let embeddingService = EmbeddingService.shared

    init(modelContext: ModelContext, searchEngine: SemanticSearchEngine) {
        self.modelContext  = modelContext
        self.searchEngine  = searchEngine
    }

    // MARK: - Entry point

    /// Read all pending shared items, index them, then clear the queue.
    /// Safe to call repeatedly — idempotent when nothing is pending.
    func indexPendingShares() async {
        let items = drainPendingItems()
        guard !items.isEmpty else { return }

        for item in items {
            await index(item)
        }
        try? modelContext.save()
    }

    // MARK: - Private

    private func index(_ item: PendingItem) async {
        let sourceID = "share-\(item.id.uuidString)"

        // Idempotency: skip if already indexed.
        var descriptor = FetchDescriptor<MemoryChunk>(
            predicate: #Predicate { $0.sourceID == sourceID }
        )
        descriptor.fetchLimit = 1
        if (try? modelContext.fetch(descriptor))?.isEmpty == false { return }

        // Build the text content we'll embed and store.
        let (content, keywords) = buildContent(for: item)
        guard !content.isEmpty else { return }

        let chunk = MemoryChunk(
            sourceType: .note,
            sourceID: sourceID,
            content: content,
            keywords: keywords,
            sourceDate: item.date
        )
        modelContext.insert(chunk)

        // Generate embedding and attach it so the chunk is searchable.
        if let vector = try? await embeddingService.embed(text: content, quality: .contextual) {
            chunk.embeddingData = EmbeddingService.pack(vector)
            await searchEngine.addToCache(chunk: chunk)
        }

        // Clean up saved image files after capturing their metadata.
        if item.type == .image {
            deleteImage(filename: item.content)
        }
    }

    /// Returns (content string, keywords) for the given item type.
    private func buildContent(for item: PendingItem) -> (String, [String]) {
        switch item.type {

        case .url:
            var parts = ["Saved link: \(item.content)"]
            if !item.note.isEmpty   { parts.append(item.note) }
            if !item.sourceApp.isEmpty { parts.append("Shared from \(item.sourceApp)") }
            let text = parts.joined(separator: ". ")
            let kw   = extractKeywords(from: item.content + " " + item.note)
                     + ["link", "url", "website"]
            return (text, kw)

        case .text:
            var parts = [item.content]
            if !item.note.isEmpty { parts.append(item.note) }
            let text = parts.joined(separator: "\n\n")
            return (text, extractKeywords(from: text))

        case .image:
            var parts = ["Saved image"]
            if !item.note.isEmpty      { parts.append(item.note) }
            if !item.sourceApp.isEmpty { parts.append("from \(item.sourceApp)") }
            let text = parts.joined(separator: " — ")
            let kw   = extractKeywords(from: item.note) + ["image", "photo", "picture"]
            return (text, kw)
        }
    }

    // MARK: - App Group I/O

    private var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: sharedAppGroupID)
    }

    private var pendingURL: URL? {
        containerURL?.appendingPathComponent("pending_shares.json")
    }

    private var imagesURL: URL? {
        containerURL?.appendingPathComponent("SharedImages")
    }

    private func drainPendingItems() -> [PendingItem] {
        guard let url = pendingURL,
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([PendingItem].self, from: data),
              !items.isEmpty else {
            return []
        }
        // Clear atomically — a crash during indexing will skip re-indexing
        // (each item has a unique sourceID, so it won't be re-created anyway).
        try? JSONEncoder().encode([PendingItem]()).write(to: url, options: .atomic)
        return items
    }

    private func deleteImage(filename: String) {
        guard !filename.isEmpty, let dir = imagesURL else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(filename))
    }

    // MARK: - Keyword extraction

    private func extractKeywords(from text: String) -> [String] {
        let stop: Set<String> = [
            "the","and","for","are","but","not","you","all","can","had",
            "was","one","our","out","get","has","him","his","how","its",
            "may","she","use","who","did","this","that","with","from",
            "have","been","they","will","what","when","your","more",
            "than","into","some","just","also","link","http","https"
        ]
        return Array(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !stop.contains($0) }
                .uniqued()
                .prefix(20)
        )
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
