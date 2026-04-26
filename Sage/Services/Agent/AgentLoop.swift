import Foundation

// MARK: - AgentLoop
//
// Plan → act → observe loop, capped at 3 iterations. The cap is a
// hard safety net, not a target — most queries resolve in 1–2 turns.
//
// Iteration shape:
//
//   1. Build chat with: system prompt (tools spec + persona) +
//      retrieved memory context + history + user message.
//   2. Generate full response (no streaming; we don't know yet
//      whether it's a tool call or a final answer).
//   3. Parse for <tool_call>{...}</tool_call>. If found:
//        a. Execute the tool.
//        b. Append the assistant's tool-call message + a "tool"
//           role message with the result.
//        c. Loop, unless we've hit the iteration cap.
//      If not found: this is the final answer. We re-stream it
//      to the UI on a final clean generate so the user sees
//      typed-tokens UX rather than a sudden block of text.
//
// Streaming tradeoff: the obvious approach would be to stream from
// iteration 1. But intermediate iterations might be tool-call JSON,
// which would look broken in the UI. The compromise is: silent
// generate during planning, stream the final answer. The UI shows a
// "Thinking…" status during planning via `onStatus`.

@MainActor
final class AgentLoop {

    private let llmService: LLMService
    private let registry: ToolRegistry

    /// Hard cap on planning iterations. Three is the sweet spot:
    /// enough for "look up a fact, then answer" or "check the time,
    /// then search for the right event"; not enough for runaway loops.
    private let maxIterations = 3

    init(llmService: LLMService, registry: ToolRegistry) {
        self.llmService = llmService
        self.registry = registry
    }

    // MARK: - Public

    /// Run a chat turn through the agent loop. Returns the final
    /// assistant response. Status updates ("Thinking…", "Searching
    /// your photos…") flow through `onStatus`; final-answer tokens
    /// flow through `onFinalToken`.
    ///
    /// `basePrompt` is the persona/context system prompt produced by
    /// ContextBuilder.buildSystemPrompt — we prepend the tools spec
    /// to it. `history` is chronological past turns; `userMessage`
    /// is the new message.
    func run(
        basePrompt: String,
        history: [(role: String, content: String)],
        userMessage: String,
        onStatus: @escaping @Sendable (String) -> Void,
        onFinalToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var conversation = history
        conversation.append((role: "user", content: userMessage))

        let systemPrompt = """
        \(registry.systemPromptSection())

        \(basePrompt)
        """

        for iteration in 1...maxIterations {
            // On the last iteration, force a final answer — the
            // model has had its chances; if it tries to call yet
            // another tool we ignore it and treat the message as
            // a final answer attempt.
            let isLast = iteration == maxIterations
            let prompt = isLast
                ? systemPrompt + "\n\nThis is your final turn. Do NOT call any more tools — write the answer for the user now using everything you've learned."
                : systemPrompt

            onStatus(iteration == 1 ? "Thinking…" : "Reasoning (\(iteration)/\(maxIterations))…")

            // Silent generate — no token streaming during planning.
            // We don't know if this is a tool call or a final answer
            // until we see the full text.
            let raw = try await llmService.generate(
                systemPrompt: prompt,
                messages: conversation,
                onToken: { _ in }
            )

            if let call = parseToolCall(in: raw), !isLast {
                onStatus("Running \(call.name)…")
                let resultText: String
                if let tool = registry.tool(named: call.name) {
                    do {
                        resultText = try await tool.execute(arguments: call.arguments)
                    } catch {
                        resultText = "Error executing \(call.name): \(error.localizedDescription)"
                    }
                } else {
                    resultText = "Error: tool '\(call.name)' not found. Available tools: \(registry.tools.map { $0.name }.joined(separator: ", "))."
                }

                // Append the model's tool-call utterance and the
                // result, then loop. We use 'user' role for the
                // tool result rather than a dedicated 'tool' role
                // because the chat template doesn't always handle
                // 'tool' uniformly across model families.
                conversation.append((role: "assistant", content: raw))
                conversation.append((
                    role: "user",
                    content: "<tool_result name=\"\(call.name)\">\n\(resultText)\n</tool_result>"
                ))
                continue
            }

            // No tool call — this is the final answer. Strip any
            // stray tool_call tags (model sometimes emits one then
            // continues with prose) and re-stream cleanly to the UI.
            let cleaned = stripToolCallBlocks(raw)
            return try await restream(text: cleaned, onToken: onFinalToken)
        }

        // Should be unreachable — the loop exits via the no-tool-
        // call branch above. Defensive return.
        return ""
    }

    // MARK: - Parsing

    struct ToolCall {
        let name: String
        let arguments: [String: AnySendable]
    }

    /// Extract a tool call from the model's output, if present.
    /// Tolerant to minor format wobble (extra whitespace, missing
    /// closing tag, leading prose) because 3B models drift.
    private func parseToolCall(in text: String) -> ToolCall? {
        // Primary pattern: <tool_call>{...}</tool_call>
        if let range = text.range(of: "<tool_call>", options: .caseInsensitive) {
            let after = text[range.upperBound...]
            let endRange = after.range(of: "</tool_call>", options: .caseInsensitive)
            let jsonSlice = endRange.map { String(after[..<$0.lowerBound]) } ?? String(after)
            if let parsed = decodeToolCall(jsonSlice) {
                return parsed
            }
        }
        // Fallback: a bare {"name": "...", "arguments": {...}} block.
        if let braceStart = text.firstIndex(of: "{"),
           let braceEnd = text.lastIndex(of: "}") {
            let candidate = String(text[braceStart...braceEnd])
            if let parsed = decodeToolCall(candidate) {
                return parsed
            }
        }
        return nil
    }

    private func decodeToolCall(_ json: String) -> ToolCall? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        struct RawCall: Decodable {
            let name: String
            let arguments: [String: AnySendable]?
            // Some models prefer 'parameters' instead of 'arguments'.
            // Accept both so we don't reject correct intent over a
            // naming nit.
            let parameters: [String: AnySendable]?
        }
        guard let raw = try? JSONDecoder().decode(RawCall.self, from: data) else {
            return nil
        }
        let args = raw.arguments ?? raw.parameters ?? [:]
        return ToolCall(name: raw.name, arguments: args)
    }

    private func stripToolCallBlocks(_ text: String) -> String {
        // Drop any straggling tool_call tags so prose doesn't surface
        // them in the UI. Cheap regex; the format is well-defined.
        var out = text
        while let open = out.range(of: "<tool_call>", options: .caseInsensitive) {
            if let close = out.range(of: "</tool_call>", options: [.caseInsensitive], range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                out.removeSubrange(open.lowerBound..<out.endIndex)
                break
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Restream

    /// Replay an already-generated response through the UI's token
    /// callback so the user sees a typing animation. This avoids the
    /// "block of text suddenly appears" UX after planning.
    private func restream(
        text: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        // Word-grain replay at a gentle rate. Chosen empirically:
        // ~30 ms / word reads naturally without dragging on long
        // answers. We deliberately don't do char-by-char; that's too
        // slow on multi-paragraph responses.
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        for (i, w) in words.enumerated() {
            let chunk = i == 0 ? String(w) : " " + String(w)
            onToken(chunk)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return text
    }
}
