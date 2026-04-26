import Foundation
import Combine
import SwiftData

@MainActor
final class AppContainer: ObservableObject {
    /// Set by the voice recorder when the classifier decides the user is
    /// asking Sage a question. ChatListView consumes this on appear and
    /// opens a new chat pre-populated with the transcription.
    @Published var pendingVoiceChatQuery: String?

    let modelContainer: ModelContainer
    let permissions: PermissionCoordinator
    let searchEngine: SemanticSearchEngine
    let spotlightService: SpotlightService
    let indexingService: IndexingService
    let contextBuilder: ContextBuilder
    let llmService: LLMService
    let modelManager: ModelManager
    let reminderService: ReminderCreationService
    let calendarEventService: CalendarEventCreationService
    let toolRegistry: ToolRegistry
    let agentLoop: AgentLoop

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let context = modelContainer.mainContext

        self.permissions = PermissionCoordinator()

        let search = SemanticSearchEngine()
        self.searchEngine = search

        let spotlight = SpotlightService()
        self.spotlightService = spotlight

        self.llmService   = LLMService()
        let manager       = ModelManager(modelContext: context)
        self.modelManager = manager

        self.indexingService = IndexingService(
            modelContext: context,
            searchEngine: search,
            spotlightService: spotlight,
            llmService: self.llmService,
            modelManager: manager
        )

        let builder = ContextBuilder(searchEngine: search)
        self.contextBuilder = builder

        self.reminderService      = ReminderCreationService()
        self.calendarEventService = CalendarEventCreationService()

        let registry = ToolRegistry(searchEngine: search)
        self.toolRegistry = registry
        self.agentLoop = AgentLoop(llmService: self.llmService, registry: registry)
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        await indexingService.loadSearchCache()
    }

    /// Loads the chat model if it is downloaded and not yet in memory.
    func loadChatModelIfNeeded() async {
        guard !llmService.isReady,
              let chatLocalModel = modelManager.chatModel else { return }
        await llmService.loadModel(from: chatLocalModel)
    }

    // Keep old name as an alias so call-sites compile without change.
    func loadActiveModelIfNeeded() async {
        await loadChatModelIfNeeded()
    }
}
