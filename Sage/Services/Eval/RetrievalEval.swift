import Foundation

// MARK: - RetrievalEval
//
// Lightweight regression harness for the retrieval stack. The point is
// not to "score the model" — it's to catch regressions when we change
// embedding format, swap embedding models, add a reranker, or tune the
// hybrid keyword/semantic weights. A pass-rate that drops 30% after a
// PR is a far better signal than vibes.
//
// Design choices:
//
//   • Queries are matched against chunks by *substring + sourceType*,
//     not by ID. We can't ship hand-labelled IDs because every user's
//     index is different. Substring matchers work for any indexed
//     library that contains the seed concepts.
//
//   • Pass criterion: at least one chunk in top-K satisfies BOTH the
//     expected sourceType set AND at least one expected keyword
//     (case-insensitive). Keywords are alternates ("any-of"); types
//     are alternates too.
//
//   • Metrics reported: pass-rate@5, pass-rate@10, mean reciprocal
//     rank of first hit. MRR is the most stable signal across runs
//     because it doesn't snap to integer K boundaries.
//
//   • Seed pack is intentionally generic. Power users can add their
//     own queries by appending to `seedQueries` — there's no JSON
//     loader yet because the seed runs even on an empty index and
//     returns 0/0/0, which is exactly the diagnostic we want.

struct EvalQuery: Sendable {
    /// The natural-language query, as a user would type it.
    let text: String

    /// Source types where a relevant answer could live. Empty set
    /// means "any type" — useful for free-form queries.
    let expectedSourceTypes: Set<MemoryChunk.SourceType>

    /// Lower-cased substrings; ANY one matching the chunk content
    /// counts as a hit. Use the most distinctive nouns/verbs you'd
    /// expect in a relevant chunk.
    let expectedKeywords: [String]
}

struct EvalReport: Sendable {
    let totalQueries: Int
    let passAt5: Int
    let passAt10: Int
    let meanReciprocalRank: Double
    let perQuery: [QueryResult]

    struct QueryResult: Sendable, Identifiable {
        let id = UUID()
        let query: String
        /// Rank (1-based) of the first matching chunk, or nil if no
        /// chunk in the top-25 matched.
        let firstHitRank: Int?
        let topResultsPreview: [String]
    }

    var passRateAt5: Double  { totalQueries == 0 ? 0 : Double(passAt5)  / Double(totalQueries) }
    var passRateAt10: Double { totalQueries == 0 ? 0 : Double(passAt10) / Double(totalQueries) }
}

@MainActor
final class RetrievalEval {

    private let searchEngine: SemanticSearchEngine

    init(searchEngine: SemanticSearchEngine) {
        self.searchEngine = searchEngine
    }

    /// Built-in seed pack. 12 generic queries spanning every source
    /// type Sage indexes. Each is structured so a real user's library
    /// has *some* chance of matching at least a handful — but the
    /// real value is consistency: re-running this after a code change
    /// should produce nearly the same numbers if retrieval is intact.
    static let seedQueries: [EvalQuery] = [
        // Photos
        EvalQuery(text: "photos from the beach",
                  expectedSourceTypes: [.photo],
                  expectedKeywords: ["beach", "ocean", "sand", "shore", "coast"]),
        EvalQuery(text: "pictures of food I took",
                  expectedSourceTypes: [.photo],
                  expectedKeywords: ["food", "meal", "dinner", "lunch", "restaurant", "plate", "dish"]),
        EvalQuery(text: "screenshots from my phone",
                  expectedSourceTypes: [.photo],
                  expectedKeywords: ["screen", "phone", "ui", "app", "notification"]),

        // Contacts
        EvalQuery(text: "who is my doctor",
                  expectedSourceTypes: [.contact],
                  expectedKeywords: ["doctor", "dr.", "md", "physician", "clinic"]),
        EvalQuery(text: "contact info for family",
                  expectedSourceTypes: [.contact],
                  expectedKeywords: ["mom", "dad", "mother", "father", "sister", "brother", "family"]),

        // Calendar / events
        EvalQuery(text: "meetings this week",
                  expectedSourceTypes: [.event],
                  expectedKeywords: ["meeting", "call", "sync", "1:1", "standup"]),
        EvalQuery(text: "upcoming birthdays",
                  expectedSourceTypes: [.event],
                  expectedKeywords: ["birthday", "bday"]),

        // Reminders
        EvalQuery(text: "what do I need to buy",
                  expectedSourceTypes: [.reminder],
                  expectedKeywords: ["buy", "pick up", "get", "groceries", "store"]),
        EvalQuery(text: "tasks for work",
                  expectedSourceTypes: [.reminder],
                  expectedKeywords: ["work", "deadline", "submit", "review", "send"]),

        // Notes
        EvalQuery(text: "ideas I wrote down",
                  expectedSourceTypes: [.note],
                  expectedKeywords: ["idea", "thought", "brainstorm", "concept"]),
        EvalQuery(text: "my travel plans",
                  expectedSourceTypes: [.note, .event, .reminder],
                  expectedKeywords: ["trip", "travel", "flight", "hotel", "vacation", "itinerary"]),

        // Free-form
        EvalQuery(text: "anything about coffee",
                  expectedSourceTypes: [],
                  expectedKeywords: ["coffee", "espresso", "latte", "cafe", "starbucks"])
    ]

    // MARK: - Run

    func run(queries: [EvalQuery] = RetrievalEval.seedQueries) async -> EvalReport {
        var passAt5 = 0
        var passAt10 = 0
        var rrSum = 0.0
        var perQuery: [EvalReport.QueryResult] = []

        for q in queries {
            // Top-25 is the same width ContextBuilder uses, so the
            // rank we measure is the rank that would be seen in
            // production — not an artificially inflated window.
            let results = await searchEngine.search(query: q.text, topK: 25)
            let firstHit = firstHitRank(in: results, for: q)

            if let rank = firstHit {
                if rank <= 5  { passAt5  += 1 }
                if rank <= 10 { passAt10 += 1 }
                rrSum += 1.0 / Double(rank)
            }

            // Truncate previews so the diagnostics UI doesn't render a
            // wall of text. 80 chars covers most chunk gists.
            let preview = results.prefix(3).map {
                let trimmed = $0.content.replacingOccurrences(of: "\n", with: " ")
                return "[\($0.typeLabel)] \(trimmed.prefix(80))"
            }

            perQuery.append(EvalReport.QueryResult(
                query: q.text,
                firstHitRank: firstHit,
                topResultsPreview: preview
            ))
        }

        return EvalReport(
            totalQueries: queries.count,
            passAt5: passAt5,
            passAt10: passAt10,
            meanReciprocalRank: queries.isEmpty ? 0 : rrSum / Double(queries.count),
            perQuery: perQuery
        )
    }

    // MARK: - Private

    /// 1-based rank of the first chunk satisfying the query's type
    /// and keyword constraints. Returns nil if no chunk in the result
    /// list matches — distinct from "rank 0", which would be wrong.
    private func firstHitRank(in chunks: [MemoryChunk], for query: EvalQuery) -> Int? {
        for (i, chunk) in chunks.enumerated() {
            let typeMatches = query.expectedSourceTypes.isEmpty
                || query.expectedSourceTypes.contains(chunk.sourceType)
            guard typeMatches else { continue }

            let lower = chunk.content.lowercased()
            let keywordMatches = query.expectedKeywords.isEmpty
                || query.expectedKeywords.contains { lower.contains($0.lowercased()) }
            if keywordMatches { return i + 1 }
        }
        return nil
    }
}
