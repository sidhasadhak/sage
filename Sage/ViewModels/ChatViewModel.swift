import Foundation
import SwiftData

@Observable
@MainActor
final class ChatViewModel {
    private(set) var messages: [Message] = []
    private(set) var streamingText = ""
    var error: String?

    /// Surfaces the current pending action preview to the View. When
    /// non-nil, `ChatView` presents `ActionPreviewSheet`. The `id`
    /// makes it usable with SwiftUI's `.sheet(item:)` flow.
    struct ActionPreview: Identifiable, Equatable {
        let id = UUID()
        let diff: ActionDiff
        let displayName: String
    }

    /// Phase-1 replacement for the old `pendingAction: ChatAction`
    /// regex-driven banner. The view now shows a typed, validated
    /// preview sheet whose only commit path goes through the runner.
    private(set) var pendingActionPreview: ActionPreview?

    /// True while `actionRunner.confirm()` is mid-flight. Drives the
    /// preview sheet's button into a "Working…" state and prevents
    /// double-taps.
    private(set) var isExecutingAction: Bool = false

    /// Holds the last assistant message we emitted, so we can rewrite
    /// it from a "preview pending" placeholder to a "✓ done" line
    /// once the action commits.
    private var pendingAssistantMessage: Message?

    private(set) var photoAssetIDs: [String] = []

    private let llmService: LLMService
    private let contextBuilder: ContextBuilder
    private let indexingService: IndexingService
    private let agentLoop: AgentLoop?
    private var conversation: Conversation?
    private var conversationPersisted = false   // false until first message is sent
    private let modelContext: ModelContext

    // ── Phase 1 dependencies ──────────────────────────────────────
    // The router classifies the user input, the registry constructs
    // a typed Action from the router's intent, and the runner
    // orchestrates dry-run → preview → execute → audit.
    private let intentRouter: any IntentRouter
    private let actionRegistry: ActionRegistry
    private let actionRunner: ActionRunner
    private let auditLogger: AuditLogger

    /// Phase-2: bumps lastAccessedAt on cited chunks so the decay
    /// pass doesn't evict things the user actively engages with.
    private let memoryDecay: MemoryDecay?

    /// Status text shown during agent-loop planning ("Thinking…",
    /// "Searching your photos…"). Cleared when the final answer arrives.
    private(set) var agentStatus: String? = nil

    var isGenerating: Bool { llmService.isGenerating }
    var llmState: LLMService.State { llmService.state }

    /// Whether agent-loop mode is active. Persisted in UserDefaults so the
    /// user's preference survives restarts. Default off — single-shot path
    /// is faster for simple queries.
    // Note: @AppStorage can't be used inside @Observable; read/write directly.
    var agentLoopEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "agent_loop_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "agent_loop_enabled") }
    }

    init(
        llmService: LLMService,
        contextBuilder: ContextBuilder,
        indexingService: IndexingService,
        modelContext: ModelContext,
        intentRouter: any IntentRouter,
        actionRegistry: ActionRegistry,
        actionRunner: ActionRunner,
        auditLogger: AuditLogger,
        memoryDecay: MemoryDecay? = nil,
        agentLoop: AgentLoop? = nil
    ) {
        self.llmService      = llmService
        self.contextBuilder  = contextBuilder
        self.indexingService = indexingService
        self.modelContext    = modelContext
        self.intentRouter    = intentRouter
        self.actionRegistry  = actionRegistry
        self.actionRunner    = actionRunner
        self.auditLogger     = auditLogger
        self.memoryDecay     = memoryDecay
        self.agentLoop       = agentLoop
    }

    func loadOrCreateConversation(_ conversation: Conversation?) {
        if let conversation {
            self.conversation = conversation
            self.conversationPersisted = true
            self.messages = conversation.messages.sorted { $0.createdAt < $1.createdAt }
        } else {
            // Prepare an unsaved placeholder — only written to SwiftData on first send.
            // This means opening a blank chat and backing out leaves zero ghost records.
            prepareNewConversation()
        }
    }

    func prepareNewConversation() {
        conversation = Conversation()   // not inserted into SwiftData yet
        conversationPersisted = false
        messages = []
        streamingText = ""
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let conversation else { return }
        // Prevent re-entrant generation — double-tap guard.
        guard !llmService.isGenerating else { return }

        // Persist the conversation on the very first message send.
        if !conversationPersisted {
            modelContext.insert(conversation)
            try? modelContext.save()
            conversationPersisted = true
        }

        pendingActionPreview = nil
        pendingAssistantMessage = nil
        photoAssetIDs = []

        let userMessage = Message(role: .user, content: trimmed)
        conversation.messages.append(userMessage)
        messages.append(userMessage)
        conversation.updatedAt = Date()

        let assistantMessage = Message(role: .assistant, content: "")
        conversation.messages.append(assistantMessage)
        messages.append(assistantMessage)
        streamingText = ""
        error = nil

        // ── Phase 1: route the input first ──────────────────────────────
        // The router decides whether this is an action, retrieval, free
        // generation, or a clarification request. Action and askUser
        // short-circuit the chat-generation path entirely; retrieve and
        // generate fall through to the existing flow.
        let routerHistory = messages.dropLast().suffix(6).map {
            ($0.role == .user ? "user: " : "assistant: ") + $0.content
        }
        let decision: RouterDecision = await classify(trimmed, history: Array(routerHistory))

        switch decision {

        case .action(let plan):
            // Try to construct a typed action. If the registry doesn't
            // recognise the intent or required params are missing, fall
            // through to the chat path so the user still gets *some*
            // answer rather than a dead-end error.
            if actionRegistry.canHandle(plan.intent),
               let action = try? actionRegistry.make(intent: plan.intent, parameters: plan.parameters) {
                let outcome = await actionRunner.prepare(action)
                switch outcome {
                case .success(let diff):
                    pendingActionPreview = ActionPreview(diff: diff, displayName: action.displayName)
                    pendingAssistantMessage = assistantMessage
                    assistantMessage.content = "Here's what I'll do — review and confirm:\n\n\(diff.summary)"
                    try? modelContext.save()
                    return
                case .failure(let err):
                    // Dry-run failed (permission, lookup, etc.). Show the
                    // user the error and fall through to chat as a fallback.
                    assistantMessage.content = "I couldn't prepare that action: \(err.localizedDescription)"
                    try? modelContext.save()
                    return
                }
            }
            // Unknown intent or missing params → fall through to chat.
            await runChatPath(
                trimmed: trimmed,
                conversation: conversation,
                assistantMessage: assistantMessage
            )

        case .askUser(let question):
            assistantMessage.content = question
            try? modelContext.save()

        case .retrieve, .generate, .unknown:
            await runChatPath(
                trimmed: trimmed,
                conversation: conversation,
                assistantMessage: assistantMessage
            )
        }
    }

    /// Defensive wrapper around the router so any throw surfaces as
    /// `.unknown` and the chat path takes over. We never block the
    /// user on a router hiccup.
    private func classify(_ text: String, history: [String]) async -> RouterDecision {
        do {
            let decision = try await intentRouter.classify(text, history: history)
            auditLogger.recordSuccess(
                actor: .router,
                action: "classify",
                dataAccessed: "kind=\(label(decision))",
                metadata: ["impl": intentRouter.implementationName]
            )
            return decision
        } catch {
            auditLogger.recordFailure(actor: .router, action: "classify", error: error)
            return .unknown(reason: error.localizedDescription)
        }
    }

    private func label(_ d: RouterDecision) -> String {
        switch d {
        case .action:   return "action"
        case .retrieve: return "retrieve"
        case .generate: return "generate"
        case .askUser:  return "askUser"
        case .unknown:  return "unknown"
        }
    }

    /// The pre-Phase-1 chat path. Kept verbatim so existing behaviour
    /// is preserved when the router decides this isn't an action.
    private func runChatPath(
        trimmed: String,
        conversation: Conversation,
        assistantMessage: Message
    ) async {
        do {
            let history = messages.dropLast(2).map { $0 }
            let context = await contextBuilder.buildContext(for: trimmed, history: Array(history))
            let chatMessages = await contextBuilder.buildMessages(history: Array(history), newUserMessage: trimmed)

            let photoIDs = context.chunks
                .filter { $0.sourceType == .photo }
                .map { $0.sourceID }
            if !photoIDs.isEmpty { photoAssetIDs = photoIDs }

            let response: String

            if agentLoopEnabled, let loop = agentLoop {
                // Agent-loop path: plan → tool calls → final answer.
                response = try await loop.run(
                    basePrompt: context.instructions,
                    history: chatMessages.dropLast().map { $0 },
                    userMessage: trimmed,
                    onStatus: { [weak self] status in
                        Task { @MainActor [weak self] in
                            self?.agentStatus = status
                        }
                    },
                    onFinalToken: { [weak self] chunk in
                        Task { @MainActor [weak self] in
                            self?.streamingText += chunk
                        }
                    }
                )
                agentStatus = nil
            } else {
                response = try await llmService.generate(
                    systemPrompt: context.instructions,
                    messages: chatMessages
                ) { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.streamingText += chunk
                    }
                }
            }

            assistantMessage.content = response
            streamingText = ""

            // ── Phase-2: extract citations from the response ────────
            // Map [c1]..[cN] markers back to the chunk source IDs the
            // ContextBuilder injected, then store on the message so
            // the bubble UI can render a Sources strip.
            let citedSourceIDs = CitationRenderer.extract(
                from: response,
                mapping: context.citationSourceIDs
            )
            assistantMessage.injectedChunkIDs = citedSourceIDs
            // Bump access time on cited chunks — user clearly cares
            // about these; let the decay pass leave them alone.
            memoryDecay?.touch(chunkSourceIDs: citedSourceIDs)

            auditLogger.recordSuccess(
                actor: .writer,
                action: "generate",
                dataAccessed: "chunks=\(context.chunks.count) cited=\(citedSourceIDs.count)"
            )

            let turnContent = "User asked: \(trimmed)\nSage replied: \(response.prefix(300))"
            let chunk = MemoryChunk(
                sourceType: .conversation,
                sourceID: assistantMessage.id.uuidString,
                content: turnContent,
                keywords: trimmed.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 3 }
            )
            modelContext.insert(chunk)

            if conversation.title == "New Conversation" {
                conversation.title = String(trimmed.prefix(50))
            }
            try? modelContext.save()

        } catch {
            assistantMessage.content = "Something went wrong. Please try again."
            self.error = error.localizedDescription
            auditLogger.recordFailure(actor: .writer, action: "generate", error: error)
        }
    }

    // MARK: - Action approval

    /// User tapped Approve in the preview sheet. Drives the runner
    /// to commit and rewrites the placeholder assistant message into
    /// a confirmation receipt line.
    func confirmPendingAction() async {
        guard pendingActionPreview != nil else { return }
        isExecutingAction = true
        defer { isExecutingAction = false }

        let result = await actionRunner.confirm()
        switch result {
        case .success(let receipt):
            if let msg = pendingAssistantMessage {
                msg.content = "✓ \(receipt.summary)"
            }
        case .failure(let err):
            self.error = err.localizedDescription
            if let msg = pendingAssistantMessage {
                msg.content = "✗ Couldn't complete: \(err.localizedDescription)"
            }
        }
        try? modelContext.save()
        pendingActionPreview = nil
        pendingAssistantMessage = nil
        actionRunner.reset()
    }

    /// User dismissed the preview without approving. Leaves the
    /// placeholder message in place so the chat history reflects the
    /// abandoned step.
    func cancelPendingAction() {
        actionRunner.cancel()
        pendingActionPreview = nil
        if let msg = pendingAssistantMessage {
            msg.content = "(action cancelled)"
            try? modelContext.save()
        }
        pendingAssistantMessage = nil
    }

    // MARK: - Other UI helpers

    func stopGeneration() { streamingText = "" }

    func deleteMessage(_ message: Message) {
        modelContext.delete(message)
        messages.removeAll { $0.id == message.id }
        try? modelContext.save()
    }
}
