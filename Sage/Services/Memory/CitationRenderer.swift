import Foundation

// MARK: - CitationRenderer
//
// Phase 2 of the v1.2 plan: every claim about the user's life cites
// the supporting chunk. The renderer is two pure functions:
//
//   • `numbered(_:)` injects `[c1] [c2] …` markers into the system
//      prompt so the model has stable citation handles.
//   • `extract(_:)` reads `[cN]` markers out of the assistant's
//      response and returns the matching chunk source IDs in the
//      order they appeared. ChatViewModel writes those IDs onto
//      `Message.injectedChunkIDs` so the bubble UI can render
//      "Sources" chips.
//
// Pure (no model context, no SwiftData) so it's trivial to unit
// test and so callers don't need to thread an actor through.

enum CitationRenderer {

    /// Render a numbered version of the chunk list ready for prompt
    /// injection. Returns the rendered block and the source-ID
    /// mapping (index → sourceID) so the post-parse can resolve a
    /// `[cN]` back to the original chunk.
    ///
    /// Example:
    ///   [c1] [NOTE] Trip plan: leaving Tuesday, returning Sunday.
    ///   [c2] [EVENT] Dentist — Apr 30, 9 AM.
    static func numbered(_ chunks: [MemoryChunk]) -> (block: String, sourceIDs: [String]) {
        var ids: [String] = []
        var lines: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let n = i + 1
            ids.append(chunk.sourceID)
            // Trim very long bodies so the prompt stays bounded.
            let body = chunk.content.count > 280
                ? String(chunk.content.prefix(280)) + "…"
                : chunk.content
            lines.append("[c\(n)] [\(chunk.typeLabel.uppercased())] \(body)")
        }
        return (lines.joined(separator: "\n"), ids)
    }

    /// Citation discipline addendum appended to the system prompt.
    /// Tuned for a 3B model — short, declarative, repeats the magic
    /// markers so the model's instruction-following holds.
    static func systemPromptAddendum(chunkCount: Int) -> String {
        if chunkCount == 0 {
            return """
            You have no personal context for this query. If the user asks \
            about their own data, say "I don't have that on file" rather \
            than guessing.
            """
        }
        return """
        Citation rules — strictly enforced:
          • You have \(chunkCount) numbered chunks of personal context above ([c1]–[c\(chunkCount)]).
          • Every factual claim about the user's own life MUST end with the supporting marker, e.g. "your dentist appointment is at 9 AM [c2]".
          • If no chunk supports a claim, say exactly: "I don't have that on file." Do NOT invent a citation.
          • Do not cite for general-knowledge or chit-chat — citations are only for the user's personal data.
        """
    }

    /// Pull `[cN]` markers out of the assistant's reply and map them
    /// to source IDs (preserving order, deduped). Tolerant to minor
    /// format wobble — a 3B model occasionally produces `[C2]` or
    /// `( c3 )`. We accept those silently.
    static func extract(from response: String, mapping sourceIDs: [String]) -> [String] {
        guard !sourceIDs.isEmpty else { return [] }
        // Permissive regex: optional whitespace inside the brackets,
        // case-insensitive `c`, 1+ digits.
        let pattern = #"\[\s*[cC]\s*(\d+)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(response.startIndex..., in: response)
        let matches = regex.matches(in: response, range: range)

        var ordered: [String] = []
        var seen: Set<String> = []
        for m in matches where m.numberOfRanges == 2 {
            guard let r = Range(m.range(at: 1), in: response),
                  let n = Int(response[r]),
                  n >= 1, n <= sourceIDs.count else { continue }
            let id = sourceIDs[n - 1]
            if seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }
}
