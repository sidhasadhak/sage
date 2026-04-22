import Foundation
import SwiftData

@Observable
@MainActor
final class MemoryViewModel {
    private(set) var searchResults: [MemoryChunk] = []
    var searchQuery = ""
    var selectedSourceType: MemoryChunk.SourceType? = nil
    private(set) var isSearching = false

    private let searchEngine: SemanticSearchEngine
    private let modelContext: ModelContext

    init(searchEngine: SemanticSearchEngine, modelContext: ModelContext) {
        self.searchEngine = searchEngine
        self.modelContext = modelContext
    }

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        var results = await searchEngine.search(query: query, topK: 50)

        if let filter = selectedSourceType {
            results = results.filter { $0.sourceType == filter }
        }

        searchResults = results
    }

    func allChunks() throws -> [MemoryChunk] {
        var descriptor = FetchDescriptor<MemoryChunk>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        if let filter = selectedSourceType {
            descriptor.predicate = #Predicate { $0.sourceType == filter }
        }
        return try modelContext.fetch(descriptor)
    }

    func deleteChunk(_ chunk: MemoryChunk) {
        Task { await searchEngine.removeFromCache(id: chunk.id) }
        modelContext.delete(chunk)
        searchResults.removeAll { $0.id == chunk.id }
        try? modelContext.save()
    }
}
