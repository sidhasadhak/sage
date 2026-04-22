import CoreSpotlight
import Foundation

actor SpotlightService {

    func index(chunk: MemoryChunk) async {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = String(chunk.content.prefix(100))
        attributeSet.contentDescription = chunk.content
        attributeSet.keywords = chunk.keywords

        let item = CSSearchableItem(
            uniqueIdentifier: chunk.id.uuidString,
            domainIdentifier: "com.sage.memory.\(chunk.sourceType.rawValue)",
            attributeSet: attributeSet
        )

        try? await CSSearchableIndex.default().indexSearchableItems([item])
    }

    func remove(chunkID: UUID) async {
        try? await CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: [chunkID.uuidString]
        )
    }

    func removeAll() async {
        try? await CSSearchableIndex.default().deleteAllSearchableItems()
    }
}
