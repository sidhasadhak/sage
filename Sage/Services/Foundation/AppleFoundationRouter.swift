import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - IntentRouter (the Phase-0 seam)
//
// Phase 0 introduces the controller's first dependency: a router that
// turns a free-form user input into a typed `RouterDecision`. The rest
// of the app (Phase 1 ActionRunner, Phase 3 PEV controller, Phase 4
// truth-mode) consumes RouterDecision — never the underlying model.
//
// We ship two backends:
//
//   • AppleFoundationRouter — uses Apple's on-device foundation model
//     via the FoundationModels framework (iOS 26+, Apple Intelligence
//     enabled). Pays zero RAM from our app's budget; runs on the ANE.
//
//   • LLMServiceRouter      — fallback that drives the existing Llama
//     3.2 3B chat model with a constrained system prompt. Used when
//     FoundationModels is unavailable or disabled.
//
// `IntentRouter.make(...)` returns the right one for the device. The
// caller doesn't (and shouldn't) care which.

/// What Sage decided to do about a user input. All downstream
/// behaviour pivots on this single enum.
enum RouterDecision: Sendable, Equatable {
    /// User wants Sage to do something with side effects (create
    /// reminder, schedule event, draft message). Phase 1 will replace
    /// `ActionPlan` with the concrete typed action registry.
    case action(ActionPlan)

    /// User is asking about their own data — fan out to retrieval
    /// before generating an answer.
    case retrieve(RetrievalQuery)

    /// Open-ended request that doesn't need retrieval (chit-chat,
    /// general knowledge, creative writing).
    case generate(prompt: String)

    /// Sage needs more information before it can help.
    case askUser(question: String)

    /// Router declined to classify with confidence. Fall back to the
    /// safe path (current chat behaviour) and log the reason.
    case unknown(reason: String)
}

/// Phase-0 placeholder. Phase 1 replaces this with `Action` instances
/// from the ActionRegistry, where `intent` becomes the action's
/// `name` and `parameters` are typed `@Generable` structs.
struct ActionPlan: Sendable, Equatable {
    let intent: String                // e.g. "create_reminder"
    let parameters: [String: String]  // raw key/value, validated downstream
    let confidence: Double            // 0–1; gate for auto-execute later
}

/// Phase-0 retrieval query. Phase 4 will add per-source scoping
/// constraints (`only Notes`, `only this folder`, date ranges).
struct RetrievalQuery: Sendable, Equatable {
    let query: String
    let scope: [String]               // source-type names; empty = all
}

protocol IntentRouter: Sendable {
    /// Classify a user input. `history` is the recent conversation
    /// transcript (oldest → newest), used as context for follow-up
    /// disambiguation. Implementations must not mutate it.
    func classify(_ userInput: String, history: [String]) async throws -> RouterDecision

    /// Human-readable label, surfaced in Diagnostics so users can see
    /// which router is running (and therefore what to expect re: latency).
    var implementationName: String { get }
}

enum IntentRouterFactory {
    /// Returns the best available router for the current device,
    /// wrapped in the regex fast-path so obvious action triggers
    /// ("remind me to…", "schedule a meeting…") never depend on the
    /// underlying model answering reliably. The wrapped router still
    /// owns every input that doesn't match a deterministic pattern.
    @MainActor
    static func make(llmService: LLMService) -> any IntentRouter {
        let backend: any IntentRouter
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleFoundationRouter.isSupported {
            backend = AppleFoundationRouter()
        } else {
            backend = LLMServiceRouter(llmService: llmService)
        }
        #else
        backend = LLMServiceRouter(llmService: llmService)
        #endif
        return RegexFastPathRouter(wrapping: backend)
    }
}

// MARK: - Apple FoundationModels backend
//
// Wraps `SystemLanguageModel.default` + `LanguageModelSession` and
// asks for a `@Generable` structured decision. The model never produces
// free-form prose for routing — every output is schema-validated,
// which is exactly the safety property a router needs.

#if canImport(FoundationModels)

@available(iOS 26.0, *)
@Generable
struct FoundationRouterOutput: Equatable {
    @Guide(description: "The category this user input falls into.")
    var kind: Kind

    @Guide(description: "One-sentence summary of what the user wants in their own voice.")
    var summary: String

    @Guide(description: "If kind is action, the snake_case action intent name (e.g. create_reminder, create_event, draft_message). Otherwise empty string.")
    var actionIntent: String

    @Guide(description: "If kind is retrieve, the search query distilled from the user input. Otherwise empty string.")
    var retrievalQuery: String

    @Guide(description: "If kind is askUser, the clarifying question Sage should ask. Otherwise empty string.")
    var clarification: String

    @Guide(description: "Self-rated confidence between 0 and 1.")
    var confidence: Double

    @Generable
    enum Kind: String, Equatable {
        case action, retrieve, generate, askUser, unknown
    }
}

@available(iOS 26.0, *)
final class AppleFoundationRouter: IntentRouter, @unchecked Sendable {

    let implementationName = "Apple FoundationModels (system)"

    /// True when the system model is downloaded, the device is
    /// eligible, and the user has Apple Intelligence enabled.
    static var isSupported: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default:         return false
        }
    }

    /// Long-lived sessions amortise prompt-caching costs across
    /// multiple classifications. We don't carry conversation history
    /// in the session itself — `classify` injects it per-call so the
    /// router stays stateless from the caller's perspective.
    private let session: LanguageModelSession

    init() {
        self.session = LanguageModelSession(
            instructions: """
            You are Sage's intent router. Read the user's latest message \
            and classify it into exactly one category:
              • action   — the user wants Sage to perform a side-effecting \
            task (create reminder, schedule event, draft message, run shortcut).
              • retrieve — the user is asking about their own personal data \
            (notes, photos, calendar, contacts, reminders).
              • generate — open-ended request that needs no personal data.
              • askUser  — the message is too ambiguous; you need a \
            clarifying question.
              • unknown  — none of the above with confidence ≥ 0.4.

            Be conservative. Prefer `askUser` over guessing.
            """
        )
    }

    func classify(_ userInput: String, history: [String]) async throws -> RouterDecision {
        let historyBlock = history.isEmpty
            ? ""
            : "\n\nRecent conversation (oldest first):\n" + history.joined(separator: "\n")

        let prompt = "User message:\n\"\(userInput)\"\(historyBlock)"

        let response = try await session.respond(
            to: prompt,
            generating: FoundationRouterOutput.self
        )
        return Self.translate(response.content)
    }

    static func translate(_ out: FoundationRouterOutput) -> RouterDecision {
        switch out.kind {
        case .action:
            return .action(ActionPlan(
                intent: out.actionIntent,
                parameters: [:],          // Phase 1 fills typed params
                confidence: out.confidence
            ))
        case .retrieve:
            return .retrieve(RetrievalQuery(
                query: out.retrievalQuery.isEmpty ? out.summary : out.retrievalQuery,
                scope: []
            ))
        case .generate:
            return .generate(prompt: out.summary)
        case .askUser:
            return .askUser(question: out.clarification.isEmpty
                ? "Could you give me a bit more detail?"
                : out.clarification)
        case .unknown:
            return .unknown(reason: "router low confidence (\(out.confidence))")
        }
    }
}

#endif

// MARK: - LLMService fallback backend
//
// Devices without Apple Intelligence (older 15 Pro variants, certain
// regions, or users who disabled the system feature) still get a
// router — just slower and using the same Llama 3B as the writer.
// The output is parsed from a constrained JSON response.

@MainActor
final class LLMServiceRouter: IntentRouter {

    /// `nonisolated` so callers from any actor can read it without an
    /// `await`; `let` keeps it trivially thread-safe.
    nonisolated let implementationName = "Llama 3.2 3B (fallback)"

    private let llmService: LLMService

    init(llmService: LLMService) {
        self.llmService = llmService
    }

    nonisolated func classify(_ userInput: String, history: [String]) async throws -> RouterDecision {
        await classifyOnMain(userInput, history: history)
    }

    @MainActor
    private func classifyOnMain(_ userInput: String, history: [String]) async -> RouterDecision {
        // Without Apple FoundationModels we don't get @Generable. We
        // ask the chat model for strict JSON and parse defensively —
        // any malformed output falls back to .unknown rather than
        // hallucinating a routing decision.
        let systemPrompt = """
        You are Sage's intent router. Output ONLY a single JSON object \
        with the keys: kind (one of "action","retrieve","generate","askUser","unknown"), \
        action_intent (string), retrieval_query (string), clarification (string), \
        confidence (number 0–1). No prose, no markdown fences.
        """

        let historyBlock = history.suffix(6).joined(separator: "\n")
        let userPrompt = "Recent conversation:\n\(historyBlock)\n\nClassify: \"\(userInput)\""

        let raw: String
        do {
            raw = try await llmService.generate(
                systemPrompt: systemPrompt,
                messages: [(role: "user", content: userPrompt)],
                onToken: { _ in }
            )
        } catch {
            return .unknown(reason: "fallback router error: \(error.localizedDescription)")
        }

        return Self.parseJSON(raw)
    }

    /// Permissive JSON extractor: pulls the first {...} block out of
    /// whatever the 3B model produced. We only trust fields we can
    /// validate; everything else falls to .unknown.
    static func parseJSON(_ raw: String) -> RouterDecision {
        guard let start = raw.firstIndex(of: "{"),
              let end   = raw.lastIndex(of: "}"),
              start < end,
              let data  = String(raw[start...end]).data(using: .utf8),
              let obj   = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .unknown(reason: "fallback router unparseable output")
        }

        let kind  = (obj["kind"] as? String)?.lowercased() ?? ""
        let conf  = (obj["confidence"] as? Double) ?? 0.0
        let intent = (obj["action_intent"] as? String) ?? ""
        let query  = (obj["retrieval_query"] as? String) ?? ""
        let clar   = (obj["clarification"] as? String) ?? ""

        switch kind {
        case "action":
            return .action(ActionPlan(intent: intent, parameters: [:], confidence: conf))
        case "retrieve":
            return .retrieve(RetrievalQuery(query: query, scope: []))
        case "generate":
            return .generate(prompt: query.isEmpty ? clar : query)
        case "askuser":
            return .askUser(question: clar.isEmpty ? "Could you tell me a bit more?" : clar)
        default:
            return .unknown(reason: "fallback router kind=\(kind) conf=\(conf)")
        }
    }
}
