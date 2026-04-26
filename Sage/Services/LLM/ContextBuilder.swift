import Foundation

struct InjectedContext {
    let instructions: String
    let chunks: [MemoryChunk]
}

@MainActor
final class ContextBuilder {

    private let searchEngine: SemanticSearchEngine
    private let reranker: (any Reranker)?

    // Token budgets — sized for Llama 3.2 3B's 8k window.
    // (This branch is on the baseline before medium/14's token-counter
    //  lands; we keep the char fallback so both branches compile cleanly.)
    private let maxContextChars = 6_000

    /// Number of candidates fetched from first-stage retrieval.
    /// Wider than the final context window so the reranker has a
    /// meaningful pool to re-order. Cost: N cosine ops instead of 25.
    private let firstStageK = 50

    /// Maximum chunks kept after reranking. The reranker's job is to
    /// surface the best 8; `fitToCharBudget` may still trim further.
    private let rerankerTopK = 8

    init(searchEngine: SemanticSearchEngine, reranker: (any Reranker)? = nil) {
        self.searchEngine = searchEngine
        self.reranker = reranker
    }

    func buildContext(for query: String, history: [Message]) async -> InjectedContext {
        // First stage: broad semantic recall.
        let candidates = await searchEngine.search(query: query, topK: firstStageK)

        // Second stage: rerank if available, otherwise take top slice.
        let reranked: [MemoryChunk]
        if let reranker {
            reranked = await reranker.rerank(query: query, candidates: candidates, topK: rerankerTopK)
        } else {
            reranked = Array(candidates.prefix(rerankerTopK))
        }

        let fitted = fitToCharBudget(reranked)
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

        let storedName = UserDefaults.standard.string(forKey: "sage_user_name") ?? ""
        let nameClause = storedName.isEmpty
            ? "the user"
            : storedName
        let nameInstruction = storedName.isEmpty
            ? ""
            : "\nThe user's name is \(storedName). Address them by name naturally when it feels warm and appropriate — not in every message."

        parts.append("""
        You are Sage, a private AI assistant that lives entirely on this device.
        You have been given access to \(nameClause)'s personal data stored locally.
        All data is private and stays on-device — never mention cloud or external services.
        Be warm, concise, and specific. Reference personal context naturally when relevant.\(nameInstruction)
        """)

        if !chunks.isEmpty {
            let memText = chunks.map { "[\($0.typeLabel.uppercased())] \($0.content)" }.joined(separator: "\n")
            parts.append("## Personal Context\n\(memText)")
        }

        return parts.joined(separator: "\n\n")
    }
}
