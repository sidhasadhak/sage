import Foundation

struct InjectedContext {
    let instructions: String
    let chunks: [MemoryChunk]
    /// Phase-2: parallel array to `chunks` carrying their `sourceID`s
    /// in citation order. ChatViewModel uses this to map `[cN]`
    /// markers back to the originating chunks for the Sources strip
    /// under each assistant bubble.
    let citationSourceIDs: [String]
}

/// Pluggable token counter — wired to the loaded LLM tokenizer in
/// production, swappable for tests / pre-load fallback. The fallback
/// implementation uses a chars/3 estimate which intentionally
/// over-counts slightly, so we never overshoot the real token budget
/// when the model isn't loaded yet.
///
/// Why a struct + closure rather than a protocol with LLMService
/// conformance: the only callers are `ContextBuilder`'s budget loops,
/// and a closure keeps the seam testable without dragging
/// `LLMService` into unit tests of context fitting.
struct TokenCounter: Sendable {
    let count: @Sendable (String) async -> Int

    /// Conservative chars/3 estimate. Used when no tokenizer is loaded
    /// (cold start, before the chat model is in memory). English text
    /// averages ~3.5 chars/token; we use 3.0 to err on the side of
    /// fitting fewer chunks rather than blowing the window.
    static let estimating = TokenCounter { text in
        max(1, text.count / 3)
    }
}

@MainActor
final class ContextBuilder {

    private let searchEngine: SemanticSearchEngine
    private let tokenCounter: TokenCounter
    private let reranker: (any Reranker)?

    // Token budgets sized for Llama 3.2 3B's 8k window.
    private let memoryTokenBudget  = 1_500
    private let historyTokenBudget = 2_000

    /// Wide first-stage recall so the reranker has a meaningful pool.
    private let firstStageK  = 50
    /// Chunks kept after reranking before the token-budget pass.
    private let rerankerTopK = 8

    init(
        searchEngine: SemanticSearchEngine,
        tokenCounter: TokenCounter = .estimating,
        reranker: (any Reranker)? = nil
    ) {
        self.searchEngine = searchEngine
        self.tokenCounter = tokenCounter
        self.reranker     = reranker
    }

    func buildContext(for query: String, history: [Message]) async -> InjectedContext {
        // Stage 1: broad semantic recall (top-50).
        let candidates = await searchEngine.search(query: query, topK: firstStageK)

        // Stage 2: rerank for precision, then fit to token budget.
        let reranked: [MemoryChunk]
        if let reranker {
            reranked = await reranker.rerank(query: query, candidates: candidates, topK: rerankerTopK)
        } else {
            reranked = Array(candidates.prefix(rerankerTopK))
        }

        let fitted = await fitToTokenBudget(reranked)
        let (instructions, sourceIDs) = buildSystemPrompt(chunks: fitted, history: history)
        return InjectedContext(
            instructions: instructions,
            chunks: fitted,
            citationSourceIDs: sourceIDs
        )
    }

    /// Builds (role, content) pairs for the chat API, walking history
    /// newest → oldest so we always keep the most recent turns even
    /// when older history is verbose. Reversed at the end so the API
    /// receives chronological order.
    func buildMessages(
        history: [Message],
        newUserMessage: String
    ) async -> [(role: String, content: String)] {
        var picked: [(role: String, content: String)] = []
        var used = 0

        for msg in history.reversed() {
            // +4 covers per-message chat-template overhead (role
            // markers / separators). Cheap rounding since the actual
            // overhead varies by model family.
            let cost = await tokenCounter.count(msg.content) + 4
            if used + cost > historyTokenBudget { break }
            used += cost
            picked.append((role: msg.role == .user ? "user" : "assistant", content: msg.content))
        }
        picked.reverse()
        picked.append((role: "user", content: newUserMessage))
        return picked
    }

    // MARK: - Private

    /// Fits chunks into the memory token budget in ranked order. Stops
    /// at the first chunk that would overflow — we don't try to pack a
    /// smaller later chunk in, because retrieval order *is* relevance
    /// order and skipping breaks that contract.
    private func fitToTokenBudget(_ chunks: [MemoryChunk]) async -> [MemoryChunk] {
        var total = 0
        var result: [MemoryChunk] = []
        for chunk in chunks {
            // +8 covers the "[TYPE] " prefix and the trailing newline.
            let cost = await tokenCounter.count(chunk.content) + 8
            if total + cost > memoryTokenBudget { break }
            result.append(chunk)
            total += cost
        }
        return result
    }

    /// Returns the system prompt and the parallel array of citation
    /// source IDs in the order they appear (so `[c1]` ↔ sourceIDs[0]).
    private func buildSystemPrompt(
        chunks: [MemoryChunk],
        history: [Message]
    ) -> (prompt: String, sourceIDs: [String]) {
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

        // ── Anti-hallucination access guard ────────────────────────
        // Small writers (Llama 3.2 3B fallback path) sometimes default
        // to "I don't have access to your calendar / photos" even when
        // the chunks are right there in context. Tell them explicitly:
        // the data is already loaded; if a specific item isn't in the
        // chunks, the correct response is "I don't have that on file",
        // never "I can't access that".
        let presentSources = Set(chunks.map { $0.sourceType })
        if !presentSources.isEmpty {
            let humanReadable: [(MemoryChunk.SourceType, String)] = [
                (.event,    "calendar events"),
                (.reminder, "reminders"),
                (.contact,  "contacts"),
                (.photo,    "photos"),
                (.note,     "notes"),
                (.email,    "emails")
            ]
            let names = humanReadable.compactMap { presentSources.contains($0.0) ? $0.1 : nil }
            if !names.isEmpty {
                parts.append("""
                Access reminder: the user's \(names.joined(separator: ", ")) are ALREADY loaded for this turn — they appear below as numbered chunks. Do NOT reply that you "don't have access" or "can't see" the user's calendar/photos/contacts/etc.; you can. If a specific item isn't present in the chunks, say "I don't have that on file" instead. Never invent dates, titles, names, or other facts that aren't in the chunks.
                """)
            }
        }

        // ── Phase-2: numbered chunks + citation discipline ─────────
        let (numbered, sourceIDs) = CitationRenderer.numbered(chunks)
        if !numbered.isEmpty {
            parts.append("## Personal Context\n\(numbered)")
        }
        parts.append(CitationRenderer.systemPromptAddendum(chunkCount: chunks.count))

        return (parts.joined(separator: "\n\n"), sourceIDs)
    }
}
