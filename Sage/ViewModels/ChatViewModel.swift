import Foundation
import SwiftData

@Observable
@MainActor
final class ChatViewModel {
    private(set) var messages: [Message] = []
    private(set) var streamingText = ""
    var error: String?

    enum ChatAction {
        case createReminder(title: String, dueDate: Date?)
        case scheduleCalendarEvent(title: String, startDate: Date?)
    }

    private(set) var pendingAction: ChatAction?
    private(set) var photoAssetIDs: [String] = []

    private let llmService: LLMService
    private let contextBuilder: ContextBuilder
    private let indexingService: IndexingService
    private let agentLoop: AgentLoop?
    private var conversation: Conversation?
    private var conversationPersisted = false   // false until first message is sent
    private let modelContext: ModelContext

    /// Status text shown during agent-loop planning ("Thinking…",
    /// "Searching your photos…"). Cleared when the final answer arrives.
    private(set) var agentStatus: String? = nil

    var isGenerating: Bool { llmService.isGenerating }
    var llmState: LLMService.State { llmService.state }

    /// Whether agent-loop mode is active. Persisted in UserDefaults so
    /// the user's preference survives restarts. Default is off — the
    /// single-shot path is faster and more predictable for simple queries.
    @AppStorage("agent_loop_enabled") var agentLoopEnabled: Bool = false

    init(
        llmService: LLMService,
        contextBuilder: ContextBuilder,
        indexingService: IndexingService,
        modelContext: ModelContext,
        agentLoop: AgentLoop? = nil
    ) {
        self.llmService = llmService
        self.contextBuilder = contextBuilder
        self.indexingService = indexingService
        self.modelContext = modelContext
        self.agentLoop = agentLoop
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

        pendingAction = nil
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

        do {
            let history = messages.dropLast(2).map { $0 }
            let context = await contextBuilder.buildContext(for: trimmed, history: Array(history))
            let chatMessages = contextBuilder.buildMessages(history: Array(history), newUserMessage: trimmed)

            let photoIDs = context.chunks
                .filter { $0.sourceType == .photo }
                .map { $0.sourceID }
            if !photoIDs.isEmpty { photoAssetIDs = photoIDs }

            let response: String

            if agentLoopEnabled, let loop = agentLoop {
                // Agent-loop path: plan → tool calls → final answer.
                // Status updates (e.g. "Searching your photos…") land
                // in agentStatus so the UI can show a small indicator.
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
                // Standard single-shot path — unchanged from baseline.
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

            pendingAction = Self.parseIntent(from: trimmed)

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
        }
    }

    func dismissAction() { pendingAction = nil }

    func stopGeneration() { streamingText = "" }

    func deleteMessage(_ message: Message) {
        modelContext.delete(message)
        messages.removeAll { $0.id == message.id }
        try? modelContext.save()
    }

    // MARK: - Intent parsing

    private static func parseIntent(from text: String) -> ChatAction? {
        let lower = text.lowercased()
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let date = detector?.matches(in: text, options: [], range: range).first?.date

        let eventPatterns = [
            "schedule a meeting", "set up a meeting", "book a meeting",
            "create an event", "add to calendar", "schedule meeting",
            "book appointment", "create appointment", "set a meeting",
            "schedule an event", "plan a meeting", "arrange a meeting",
            "set up a call", "book a call"
        ]
        for pattern in eventPatterns where lower.contains(pattern) {
            let title = extractTitle(from: text, after: pattern) ?? text
            return .scheduleCalendarEvent(title: String(title.prefix(100)), startDate: date)
        }

        let reminderPatterns = [
            "remind me to", "remind me about", "reminder to",
            "don't forget to", "remember to", "add reminder",
            "set reminder", "set a reminder"
        ]
        for pattern in reminderPatterns where lower.contains(pattern) {
            let title = extractTitle(from: text, after: pattern) ?? text
            return .createReminder(title: String(title.prefix(100)), dueDate: date)
        }

        return nil
    }

    private static func extractTitle(from text: String, after pattern: String) -> String? {
        guard let range = text.lowercased().range(of: pattern) else { return nil }
        let after = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return after.isEmpty ? nil : after
    }
}
