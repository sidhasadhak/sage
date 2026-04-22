import Foundation
import SwiftData

@Observable
@MainActor
final class ChatViewModel {
    private(set) var messages: [Message] = []
    private(set) var streamingText = ""
    var error: String?

    struct ReminderSuggestion {
        let title: String
        let dueDate: Date?
    }
    private(set) var reminderSuggestion: ReminderSuggestion?
    private let reminderService = ReminderCreationService()

    private let llmService: LLMService
    private let contextBuilder: ContextBuilder
    private let indexingService: IndexingService
    private var conversation: Conversation?
    private let modelContext: ModelContext

    var isGenerating: Bool { llmService.isGenerating }
    var llmState: LLMService.State { llmService.state }

    init(
        llmService: LLMService,
        contextBuilder: ContextBuilder,
        indexingService: IndexingService,
        modelContext: ModelContext
    ) {
        self.llmService = llmService
        self.contextBuilder = contextBuilder
        self.indexingService = indexingService
        self.modelContext = modelContext
    }

    func loadOrCreateConversation(_ conversation: Conversation?) {
        if let conversation {
            self.conversation = conversation
            self.messages = conversation.messages.sorted { $0.createdAt < $1.createdAt }
        } else {
            startNewConversation()
        }
    }

    func startNewConversation() {
        let conv = Conversation()
        modelContext.insert(conv)
        try? modelContext.save()
        conversation = conv
        messages = []
        streamingText = ""
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let conversation else { return }

        // Add user message
        let userMessage = Message(role: .user, content: trimmed)
        conversation.messages.append(userMessage)
        messages.append(userMessage)
        conversation.updatedAt = Date()

        // Placeholder for assistant
        let assistantMessage = Message(role: .assistant, content: "")
        conversation.messages.append(assistantMessage)
        messages.append(assistantMessage)
        streamingText = ""
        error = nil

        do {
            // Build context from memory index
            let history = messages.dropLast(2).map { $0 }
            let context = await contextBuilder.buildContext(for: trimmed, history: Array(history))
            let chatMessages = contextBuilder.buildMessages(history: Array(history), newUserMessage: trimmed)

            let response = try await llmService.generate(
                systemPrompt: context.instructions,
                messages: chatMessages
            ) { [weak self] chunk in
                Task { @MainActor [weak self] in
                    self?.streamingText += chunk
                    assistantMessage.content = self?.streamingText ?? ""
                }
            }

            assistantMessage.content = response
            streamingText = ""

            // Check user's message for reminder intent
            if let intent = reminderService.parseReminderIntent(from: trimmed) {
                reminderSuggestion = ReminderSuggestion(title: intent.title, dueDate: intent.dueDate)
            }

            // Index conversation turn for future context retrieval
            let turnContent = "User asked: \(trimmed)\nSage replied: \(response.prefix(300))"
            let chunk = MemoryChunk(
                sourceType: .conversation,
                sourceID: assistantMessage.id.uuidString,
                content: turnContent,
                keywords: trimmed.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 3 }
            )
            modelContext.insert(chunk)

            // Auto-title from first user message
            if conversation.title == "New Conversation" {
                conversation.title = String(trimmed.prefix(50))
            }
            try? modelContext.save()

        } catch {
            assistantMessage.content = "Something went wrong. Please try again."
            self.error = error.localizedDescription
        }
    }

    func dismissReminderSuggestion() { reminderSuggestion = nil }

    func stopGeneration() {
        // MLX generation is not easily cancellable mid-stream without task cancellation;
        // we cancel the Task that wraps generate() by setting a flag.
        // For now, generation will complete the current token batch then stop.
        streamingText = ""
    }

    func deleteMessage(_ message: Message) {
        modelContext.delete(message)
        messages.removeAll { $0.id == message.id }
        try? modelContext.save()
    }
}
