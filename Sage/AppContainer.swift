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

    // ── v1.2 Phase-0 plumbing ────────────────────────────────────────
    // ResourceBudget is consumed from Phase 8 (thermal degradation);
    // it's instantiated now so the View layer can already bind to its
    // `@Published` quality state today.
    let resourceBudget: ResourceBudget
    let auditLogger: AuditLogger
    let intentRouter: any IntentRouter

    // ── v1.2 Phase-1 action layer ────────────────────────────────────
    // The registry catalogues every typed Action; the runner
    // orchestrates dry-run → preview → execute → audit. The chat
    // view model consumes both. Phase 6 (Shortcuts as actuator) will
    // expand the registry; Phase 7 will use the runner from the
    // audit-screen "Undo" path.
    let actionRegistry: ActionRegistry
    let actionRunner: ActionRunner

    // ── v1.2 Phase-2 memory tier + decay ─────────────────────────────
    // Owns pin/forget/correct + the daily decay sweep. Memory views
    // and ChatViewModel both consume it.
    let memoryDecay: MemoryDecay

    // ── v1.2 Phase-3 closed-loop controller ──────────────────────────
    // Verifies action receipts and emits user-facing summaries with
    // Undo affordances. Phase 3.5 will extend this with multi-step
    // structured Plan execution.
    let pevController: PEVController

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

        // ── v1.2 Phase-0 plumbing initialisation ─────────────────────
        // Order matters: ResourceBudget has no deps; AuditLogger needs
        // the model context; IntentRouterFactory chooses the right
        // backend based on FoundationModels availability.
        self.resourceBudget = ResourceBudget()
        let logger = AuditLogger(modelContext: context)
        self.auditLogger    = logger
        self.intentRouter   = IntentRouterFactory.make(llmService: self.llmService)

        // ── v1.2 Phase-1 action layer initialisation ─────────────────
        // ActionRegistry takes the existing reminder/calendar services
        // and wraps them in typed Actions. ActionRunner uses the
        // logger so every dry-run / execute / cancel hits the audit
        // trail with no per-call boilerplate at the call sites.
        self.actionRegistry = ActionRegistry(
            reminderService: self.reminderService,
            calendarService: self.calendarEventService
        )
        self.actionRunner   = ActionRunner(auditLogger: logger)

        // ── v1.2 Phase-2 memory decay initialisation ─────────────────
        let decay = MemoryDecay(
            modelContext: context,
            searchEngine: search,
            spotlightService: spotlight,
            auditLogger: logger
        )
        self.memoryDecay = decay
        // Wire the decay pass into the next indexAll wake-up so
        // garbage-collection runs alongside fresh-data ingestion
        // without spinning a separate background task.
        self.indexingService.memoryDecay = decay

        // ── v1.2 Phase-3 PEV controller initialisation ───────────────
        self.pevController = PEVController(auditLogger: logger)

        // Tiny breadcrumb so the very first audit row shows boot order.
        // Phase 7's audit screen will render these chronologically.
        logger.recordSuccess(
            actor: .privacy,
            action: "boot",
            metadata: [
                "router": self.intentRouter.implementationName,
                "actions": self.actionRegistry.registeredIntents.joined(separator: ",")
            ]
        )
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
