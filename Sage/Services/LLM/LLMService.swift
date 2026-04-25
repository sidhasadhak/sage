import Foundation
import UIKit
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import Tokenizers

// MARK: - Tokenizer bridge (swift-transformers → MLXLMCommon)

private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(upstream)
    }
}

private struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let msgs     = messages.map { $0.mapValues { $0 as Any } }
        let toolSpecs = tools?.map { $0.mapValues { $0 as Any } }
        let ctx      = additionalContext?.mapValues { $0 as Any }
        do {
            return try upstream.applyChatTemplate(messages: msgs, tools: toolSpecs, additionalContext: ctx)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

// Models are always local — this downloader is never actually called.
private struct NoOpDownloader: MLXLMCommon.Downloader {
    func download(
        id: String, revision: String?, matching: [String],
        useLatest: Bool, progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        throw URLError(.fileDoesNotExist)
    }
}

// MARK: - LLMService

@Observable
@MainActor
final class LLMService {

    enum State: Equatable {
        case noModelSelected
        case loading(String)
        case ready(String)
        case generating
        case error(String)
    }

    private(set) var state: State = .noModelSelected
    private(set) var loadedModelID: String?

    private var modelContainer: ModelContainer?

    /// Serialises background MLX calls (labels, captions, entities) so they
    /// never overlap with an active `generate()` or with each other.
    private(set) var isBackgroundProcessing = false

    init() {
        // Only evict GPU cache when fully idle — never during active computation.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isGenerating,
                      !self.isBackgroundProcessing else { return }
                MLX.Memory.cacheLimit = 0
            }
        }
    }

    var temperature: Float  = 0.7
    var topP: Float         = 0.9
    var maxNewTokens: Int   = 1024

    // MARK: - Model lifecycle

    func loadModel(from localModel: LocalModel) async {
        #if targetEnvironment(simulator)
        state = .error("LLM models require a physical device — no Metal GPU in Simulator.")
        return
        #else
        guard loadedModelID != localModel.catalogID else { return }
        // Never swap the model while the GPU is busy.
        guard !isGenerating, !isBackgroundProcessing else { return }

        let catalogModel = ModelCatalog.model(for: localModel.catalogID)

        if let required = catalogModel?.minimumRAMGB {
            let deviceGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
            if deviceGB < Double(required) {
                state = .error(
                    "\(localModel.displayName) requires \(required) GB RAM; this device has \(Int(deviceGB)) GB."
                )
                return
            }
        }

        state = .loading(localModel.displayName)
        modelContainer = nil
        loadedModelID  = nil

        let displayName = localModel.displayName
        let localURL    = localModel.localURL

        do {
            let extraEOS: Set<String> = catalogModel?.family == "Gemma" ? ["<end_of_turn>"] : []
            let config       = ModelConfiguration(directory: localURL, extraEOSTokens: extraEOS)
            let useVLMFactory = ModelCatalog.isVisionCapable(for: localModel.catalogID)

            let loaded = try await Task.detached(priority: .userInitiated) {
                MLX.Memory.cacheLimit = 0

                let tokenizerLoader = LocalTokenizerLoader()
                let container: ModelContainer
                if useVLMFactory {
                    container = try await VLMModelFactory.shared.loadContainer(
                        from: NoOpDownloader(), using: tokenizerLoader, configuration: config)
                } else {
                    container = try await LLMModelFactory.shared.loadContainer(
                        from: NoOpDownloader(), using: tokenizerLoader, configuration: config)
                }

                MLX.Memory.cacheLimit = 256 * 1024 * 1024
                return container
            }.value

            modelContainer = loaded
            loadedModelID  = localModel.catalogID
            state = .ready(displayName)
        } catch {
            state = .error("Failed to load \(displayName): \(error.localizedDescription)")
        }
        #endif
    }

    func unloadModel() {
        guard !isGenerating, !isBackgroundProcessing else { return }
        modelContainer = nil
        loadedModelID  = nil
        MLX.Memory.cacheLimit = 0
        state = .noModelSelected
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var isGenerating: Bool { state == .generating }

    var isVisionCapable: Bool {
        guard let id = loadedModelID else { return false }
        return ModelCatalog.isVisionCapable(for: id)
    }

    /// True when the photo-analysis (SmolVLM) model is currently loaded.
    var isPhotoAnalysisModelActive: Bool {
        guard let id = loadedModelID else { return false }
        return ModelCatalog.isPhotoAnalysisModel(for: id)
    }

    // MARK: - Generation (chat)

    func generate(
        systemPrompt: String,
        messages: [(role: String, content: String)],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard case .ready = state else { throw ModelError.noModelSelected }
        guard let container = modelContainer else { throw ModelError.noModelSelected }

        // Wait for any background processing to drain (max 3 s) then proceed.
        if isBackgroundProcessing {
            var waited = 0
            while isBackgroundProcessing && waited < 30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            isBackgroundProcessing = false
        }

        // Re-check after suspension
        guard case .ready = state, modelContainer != nil else { throw ModelError.noModelSelected }

        state = .generating
        defer {
            if case .generating = state {
                if let id = loadedModelID,
                   let name = ModelCatalog.model(for: id)?.displayName {
                    state = .ready(name)
                } else {
                    state = .noModelSelected
                }
            }
        }

        MLXRandom.seed(UInt64(Date.now.timeIntervalSince1970))

        var chatMessages: [Chat.Message] = [.system(systemPrompt)]
        chatMessages += messages.map { msg in
            switch msg.role {
            case "assistant": return .assistant(msg.content)
            default:          return .user(msg.content)
            }
        }

        let userInput      = UserInput(chat: chatMessages)
        let generateParams = GenerateParameters(
            maxTokens: maxNewTokens,
            temperature: temperature,
            topP: topP
        )

        let lmInput = try await container.prepare(input: userInput)

        // Re-check after suspend — another caller may have changed state.
        guard case .generating = state else { return "" }

        let stream = try await container.generate(input: lmInput, parameters: generateParams)

        var output = ""
        for await generation in stream {
            if case .chunk(let text) = generation {
                output += text
                Task { @MainActor in onToken(text) }
            }
        }
        return output
    }

    func complete(prompt: String) async throws -> String {
        try await generate(
            systemPrompt: "You are a helpful assistant.",
            messages: [("user", prompt)],
            onToken: { _ in }
        )
    }

    // MARK: - Background helpers (serialised via isBackgroundProcessing)

    /// Extracts up to 10 structured entities from text using the loaded model.
    /// Returns strings in "type:name" format, e.g. ["person:John Smith", "place:Paris"].
    /// Safe to call while the chat session is idle — re-checks state after every suspension.
    func extractEntities(from text: String) async -> [String] {
        guard case .ready = state, !isBackgroundProcessing,
              let container = modelContainer else { return [] }

        isBackgroundProcessing = true
        defer { isBackgroundProcessing = false }

        do {
            let chatMessages: [Chat.Message] = [
                .system("You are a precise entity extractor. Return only valid JSON arrays."),
                .user("""
                Extract named entities from the text below.
                Return a JSON array of strings in "type:name" format.
                Types: person, place, organisation, project, product, event, date.
                Return at most 10 entries. No explanation — only the JSON array.

                Text: \(text.prefix(600))
                """)
            ]

            let params  = GenerateParameters(maxTokens: 120, temperature: 0.1, topP: 0.9)
            let lmInput = try await container.prepare(input: UserInput(chat: chatMessages))

            // Re-check after suspension — user may have sent a message.
            guard case .ready = state else { return [] }

            let stream = try await container.generate(input: lmInput, parameters: params)
            var output = ""
            for await generation in stream {
                if case .chunk(let t) = generation { output += t }
            }

            // Parse JSON array
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]") {
                let jsonSlice = String(trimmed[start...end])
                if let data = jsonSlice.data(using: .utf8),
                   let array = try? JSONDecoder().decode([String].self, from: data) {
                    return Array(array
                        .filter { $0.contains(":") && $0.count < 60 }
                        .prefix(10))
                }
            }
        } catch {}
        return []
    }

    /// Extracts up to 10 context-aware labels from text. Safe for background use.
    func generateLabels(for text: String) async -> [String] {
        guard case .ready = state, !isBackgroundProcessing,
              let container = modelContainer else { return [] }

        isBackgroundProcessing = true
        defer { isBackgroundProcessing = false }

        do {
            let chatMessages: [Chat.Message] = [
                .system("You are a concise label extractor. You only return comma-separated labels."),
                .user("""
                Extract up to 10 short, specific labels from the text below. \
                Labels should capture key topics, people, places, actions, and dates. \
                Return ONLY a comma-separated list — no explanation, no numbering.

                Text: \(text.prefix(800))
                """)
            ]
            let params  = GenerateParameters(maxTokens: 80, temperature: 0.2, topP: 0.9)
            let lmInput = try await container.prepare(input: UserInput(chat: chatMessages))

            guard case .ready = state else { return [] }

            let stream = try await container.generate(input: lmInput, parameters: params)
            var output = ""
            for await generation in stream {
                if case .chunk(let t) = generation { output += t }
            }
            return output
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty && $0.count < 40 }
                .prefix(10)
                .map { $0 }
        } catch {
            return []
        }
    }

    // MARK: - Voice intent classification

    /// Classifies a voice transcription into a `VoiceIntent`. Uses the chat
    /// model when ready; otherwise falls back to keyword-based heuristics so
    /// the UX is consistent regardless of whether the model has been loaded
    /// yet (the chat model is lazy-loaded on first Chat-tab visit).
    ///
    /// Always returns *something* — never throws. Caller renders the result
    /// in a preview UI for the user to confirm.
    func analyzeVoiceIntent(transcription: String) async -> VoiceIntent {
        let cleaned = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return VoiceIntent(kind: .note, title: "Voice Note",
                               transcription: cleaned, summary: "Saved as a note")
        }

        // Fall back to heuristics if the model isn't ready.
        guard case .ready = state, !isBackgroundProcessing,
              let container = modelContainer else {
            return Self.heuristicIntent(for: cleaned)
        }

        isBackgroundProcessing = true
        defer { isBackgroundProcessing = false }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let nowISO = isoFormatter.string(from: Date())

        let userPrompt = """
        Today is \(nowISO).

        Read this voice transcription and classify what the user wants. Reply with ONLY a single JSON object — no prose, no code fences.

        Schema:
        {
          "intent": "note" | "checklist" | "reminder" | "calendar_event" | "chat",
          "title": "short title (max 60 chars)",
          "items": ["only for checklist intent — list each item"],
          "due_iso": "ISO 8601 datetime, only for reminder intent, null if no time",
          "start_iso": "ISO 8601 datetime, only for calendar_event intent, null if no time",
          "summary": "one short sentence telling the user what you will do"
        }

        Rules for picking the intent:
        - "checklist": ANY list of things (shopping, groceries, packing, to-dos, tasks, items to buy/get/bring/pack).
        - "reminder": "remind me", "don't forget", "remember to", or an explicit future task with no meeting context.
        - "calendar_event": meetings, appointments, events at a specific time with other people.
        - "chat": questions, requests for information, anything that wants Sage to answer.
        - "note": general thoughts, observations, journal entries — the default if nothing else fits.

        Examples:
        Transcription: "Create a shopping list with milk, eggs, and bread"
        → {"intent":"checklist","title":"Shopping List","items":["Milk","Eggs","Bread"],"summary":"I'll create a shopping list with 3 items."}

        Transcription: "Remind me to call mom tomorrow at 5pm"
        → {"intent":"reminder","title":"Call mom","due_iso":"<tomorrow 17:00 ISO>","summary":"I'll set a reminder for tomorrow at 5 PM."}

        Transcription: "Schedule a meeting with the design team Friday at 2"
        → {"intent":"calendar_event","title":"Meeting with design team","start_iso":"<Friday 14:00 ISO>","summary":"I'll add this to your calendar."}

        Transcription: "What did I do last weekend?"
        → {"intent":"chat","title":"What did I do last weekend?","summary":"I'll look this up for you in Sage."}

        Transcription: "Had lunch with Sarah at the park, weather was great"
        → {"intent":"note","title":"Lunch with Sarah","summary":"I'll save this as a note."}

        Transcription: "\(cleaned.prefix(500))"
        """

        do {
            let chatMessages: [Chat.Message] = [
                .system("You classify voice transcriptions and return ONLY valid JSON. No commentary."),
                .user(userPrompt)
            ]
            let params  = GenerateParameters(maxTokens: 220, temperature: 0.1, topP: 0.9)
            let lmInput = try await container.prepare(input: UserInput(chat: chatMessages))

            guard case .ready = state else { return Self.heuristicIntent(for: cleaned) }

            let stream = try await container.generate(input: lmInput, parameters: params)
            var output = ""
            for await generation in stream {
                if case .chunk(let t) = generation { output += t }
            }

            if let parsed = Self.parseIntentJSON(output, transcription: cleaned) {
                return parsed
            }
        } catch {
            // fall through
        }
        return Self.heuristicIntent(for: cleaned)
    }

    /// Extract first JSON object from `raw` and decode into a `VoiceIntent`.
    private static func parseIntentJSON(_ raw: String, transcription: String) -> VoiceIntent? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end   = trimmed.lastIndex(of: "}"),
              start < end else { return nil }

        let jsonStr = String(trimmed[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let intent  = (obj["intent"] as? String ?? "note").lowercased()
        let title   = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                      ?? heuristicTitle(from: transcription)
        let summary = (obj["summary"] as? String) ?? "Saved"

        let isoParser = ISO8601DateFormatter()
        isoParser.formatOptions = [.withInternetDateTime]
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func parseDate(_ key: String) -> Date? {
            guard let s = obj[key] as? String, !s.isEmpty, s.lowercased() != "null" else { return nil }
            return isoParser.date(from: s) ?? isoFractional.date(from: s)
        }

        let kind: VoiceIntent.Kind
        switch intent {
        case "checklist":
            let items = (obj["items"] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? []
            kind = .checklist(items: items.isEmpty ? [transcription] : items)
        case "reminder":
            kind = .reminder(dueDate: parseDate("due_iso"))
        case "calendar_event", "calendarevent", "event":
            kind = .calendarEvent(startDate: parseDate("start_iso"))
        case "chat":
            kind = .chat
        default:
            kind = .note
        }

        return VoiceIntent(kind: kind, title: String(title.prefix(80)),
                           transcription: transcription, summary: summary)
    }

    /// Pure-Swift fallback used when the chat model isn't loaded yet, or the
    /// model returns unparsable output. Mirrors the LLM rules with simple
    /// keyword matching plus `NSDataDetector` for date extraction.
    private static func heuristicIntent(for text: String) -> VoiceIntent {
        let lower = text.lowercased()

        // Date detection (shared by reminder + calendar paths).
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range    = NSRange(text.startIndex..., in: text)
        let date     = detector?.matches(in: text, options: [], range: range).first?.date

        // Calendar event triggers
        let eventKeywords = ["schedule a meeting", "schedule meeting", "set up a meeting",
                             "book a meeting", "create an event", "add to calendar",
                             "schedule an event", "book appointment", "create appointment",
                             "set up a call", "book a call"]
        if eventKeywords.contains(where: { lower.contains($0) }) {
            return VoiceIntent(
                kind: .calendarEvent(startDate: date),
                title: heuristicTitle(from: text),
                transcription: text,
                summary: "I'll add this to your calendar."
            )
        }

        // Reminder triggers
        let reminderKeywords = ["remind me", "reminder to", "don't forget", "remember to",
                                "add reminder", "set reminder", "set a reminder"]
        if reminderKeywords.contains(where: { lower.contains($0) }) {
            return VoiceIntent(
                kind: .reminder(dueDate: date),
                title: heuristicTitle(from: text),
                transcription: text,
                summary: date == nil ? "I'll set a reminder." : "I'll set a reminder for that time."
            )
        }

        // Checklist triggers
        let checklistKeywords = ["shopping list", "grocery list", "to-do list", "todo list",
                                 "to do list", "checklist", "packing list",
                                 "make a list", "create a list", "list of"]
        if checklistKeywords.contains(where: { lower.contains($0) }) {
            return VoiceIntent(
                kind: .checklist(items: extractListItems(from: text)),
                title: heuristicTitle(from: text),
                transcription: text,
                summary: "I'll create a checklist."
            )
        }

        // Question → chat
        if text.contains("?") || lower.hasPrefix("what ") || lower.hasPrefix("when ")
            || lower.hasPrefix("where ") || lower.hasPrefix("who ") || lower.hasPrefix("why ")
            || lower.hasPrefix("how ") {
            return VoiceIntent(
                kind: .chat,
                title: String(text.prefix(60)),
                transcription: text,
                summary: "I'll ask Sage about this."
            )
        }

        return VoiceIntent(
            kind: .note,
            title: heuristicTitle(from: text),
            transcription: text,
            summary: "I'll save this as a note."
        )
    }

    private static func extractListItems(from text: String) -> [String] {
        // Split on commas, "and", newlines.
        let separators = CharacterSet(charactersIn: ",\n;")
        let cleaned = text
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: ":", with: ",")
        let pieces = cleaned.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count < 80 }

        // Drop any piece that contains a list-trigger phrase (likely the prefix).
        let stripPhrases = ["shopping list", "grocery list", "to-do list", "todo list",
                            "to do list", "checklist", "packing list", "make a list",
                            "create a list", "list of"]
        let items = pieces.filter { piece in
            let lower = piece.lowercased()
            return !stripPhrases.contains(where: { lower.contains($0) })
        }
        return items.isEmpty ? pieces : items
    }

    private static func heuristicTitle(from text: String) -> String {
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .prefix(8)
            .joined(separator: " ")
        return words.isEmpty ? "Voice Note" : String(words.prefix(60))
    }

    func generateCaption(for image: UIImage) async throws -> String {
        #if targetEnvironment(simulator)
        return "Photo captured on device"
        #else
        guard case .ready = state, !isBackgroundProcessing,
              let container = modelContainer else { throw ModelError.noModelSelected }
        guard isVisionCapable else {
            throw ModelError.loadFailed("Active model does not support vision")
        }
        guard let ciImage = CIImage(image: image) else {
            throw ModelError.loadFailed("Could not process image")
        }

        isBackgroundProcessing = true
        defer { isBackgroundProcessing = false }

        let userInput = UserInput(chat: [
            .user(
                """
                Describe this photo for search. In ONE compact paragraph (≤80 words), list:
                • Scene / setting (indoor or outdoor, type of place).
                • Objects, animals, vehicles, food visible.
                • People (count, approximate ages, what they are doing) — never invent names.
                • Any visible text, signs, license plates, numbers, brands.
                • Colours, lighting, weather, time of day if obvious.
                • Activity or event happening.
                Be specific and factual. No opinions, no metaphors, no "I see".
                """,
                images: [.ciImage(ciImage)]
            )
        ])
        let params  = GenerateParameters(maxTokens: 200, temperature: 0.3, topP: 0.9)
        let lmInput = try await container.prepare(input: userInput)

        guard case .ready = state else { return "Photo" }

        let stream = try await container.generate(input: lmInput, parameters: params)
        var output = ""
        for await generation in stream {
            if case .chunk(let text) = generation { output += text }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }
}
