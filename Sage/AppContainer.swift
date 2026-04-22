import Foundation
import Combine
import SwiftData

@MainActor
final class AppContainer: ObservableObject {
    let modelContainer: ModelContainer
    let permissions: PermissionCoordinator
    let searchEngine: SemanticSearchEngine
    let spotlightService: SpotlightService
    let indexingService: IndexingService
    let contextBuilder: ContextBuilder
    let llmService: LLMService
    let modelManager: ModelManager

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let context = modelContainer.mainContext

        self.permissions = PermissionCoordinator()

        let search = SemanticSearchEngine()
        self.searchEngine = search

        let spotlight = SpotlightService()
        self.spotlightService = spotlight

        self.indexingService = IndexingService(
            modelContext: context,
            searchEngine: search,
            spotlightService: spotlight
        )

        let builder = ContextBuilder(searchEngine: search)
        self.contextBuilder = builder

        self.llmService = LLMService()
        self.modelManager = ModelManager(modelContext: context)
    }

    func bootstrap() async {
        await indexingService.loadSearchCache()
        if let active = modelManager.activeModel {
            // Fire model loading without blocking bootstrap — UI is usable immediately
            Task { await llmService.loadModel(from: active) }
        }
    }
}
