import Foundation

struct InjectedContext {
    let instructions: String
    let chunks: [MemoryChunk]
}

@MainActor
final class ContextBuilder {

    private let searchEngine: SemanticSearchEngine
    // ~1500 tokens budget for retrieved context (4 chars ≈ 1 token)
    private let maxContextChars = 6000

    init(searchEngine: SemanticSearchEngine) {
        self.searchEngine = searchEngine
    }

    func buildContext(for query: String, history: [Message]) async -> InjectedContext {
        let topChunks = await searchEngine.search(query: query, topK: 25)
        let fitted = fitToCharBudget(topChunks)
        let instructions = buildSystemPrompt(chunks: fitted, history: history)
        return InjectedContext(instructions: instructions, chunks: fitted)
    }

    // Converts history + context into the (role, content) pairs for the chat API
    func buildMessages(
        history: [Message],
        newUserMessage: String
    ) -> [(role: String, content: String)] {
        var messages: [(role: String, content: String)] = []

        // Include last 8 turns of history (oldest first)
        for msg in history.suffix(8) {
            messages.append((role: msg.role == .user ? "user" : "assistant", content: msg.content))
        }
        messages.append((role: "user", content: newUserMessage))
        return messages
    }

    // MARK: - Private

    private func fitToCharBudget(_ chunks: [MemoryChunk]) -> [MemoryChunk] {
        var total = 0
        var result: [MemoryChunk] = []
        for chunk in chunks {
            let size = chunk.content.count + 30
            if total + size > maxContextChars { break }
            result.append(chunk)
            total += size
        }
        return result
    }

    private func buildSystemPrompt(chunks: [MemoryChunk], history: [Message]) -> String {
        var parts: [String] = []

        parts.append("""
        You are Sage, a private AI assistant that lives entirely on this device.
        You have been given access to the user's personal data stored locally.
        All data is private and stays on-device — never mention cloud or external services.
        Be warm, concise, and specific. Reference personal context naturally when relevant.
        """)

        if !chunks.isEmpty {
            let memText = chunks.map { "[\($0.typeLabel.uppercased())] \($0.content)" }.joined(separator: "\n")
            parts.append("## Personal Context\n\(memText)")
        }

        return parts.joined(separator: "\n\n")
    }
}
