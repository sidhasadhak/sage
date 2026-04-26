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
    let retrievalEval: RetrievalEval
    let toolRegistry: ToolRegistry
    let agentLoop: AgentLoop
    let sharedContentIndexer: SharedContentIndexer

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

        // Token counter bridges ContextBuilder to the loaded LLM tokenizer.
        // Falls back to chars/3 estimate before any model is in memory.
        let llm = self.llmService
        let counter = TokenCounter { [weak llm] text in
            if let n = await llm?.tokenCount(text) { return n }
            return max(1, text.count / 3)
        }

        // CoreMLReranker loads ms-marco-MiniLM-L6-v2.mlmodelc at first use;
        // falls back to BM25 when the model bundle is absent.
        let reranker = CoreMLReranker()

        let builder = ContextBuilder(
            searchEngine: search,
            tokenCounter: counter,
            reranker: reranker
        )
        self.contextBuilder = builder

        self.reminderService      = ReminderCreationService()
        self.calendarEventService = CalendarEventCreationService()
        self.retrievalEval        = RetrievalEval(searchEngine: search)
        self.sharedContentIndexer = SharedContentIndexer(
            modelContext: context,
            searchEngine: search
        )

        let registry = ToolRegistry(searchEngine: search)
        self.toolRegistry = registry
        self.agentLoop    = AgentLoop(llmService: self.llmService, registry: registry)
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
