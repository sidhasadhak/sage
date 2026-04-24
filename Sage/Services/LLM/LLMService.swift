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
        let msgs = messages.map { $0.mapValues { $0 as Any } }
        let toolSpecs = tools?.map { $0.mapValues { $0 as Any } }
        let ctx = additionalContext?.mapValues { $0 as Any }
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
    private var modelContainer: ModelContainer?
    private var loadedModelID: String?

    init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MLX.Memory.cacheLimit = 0
        }
    }

    var temperature: Float = 0.7
    var topP: Float = 0.9
    var maxNewTokens: Int = 1024

    // MARK: - Model lifecycle

    func loadModel(from localModel: LocalModel) async {
        #if targetEnvironment(simulator)
        state = .error("LLM models require a physical device — no Metal GPU in Simulator.")
        return
        #else
        guard loadedModelID != localModel.catalogID else { return }

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
        loadedModelID = nil

        let displayName = localModel.displayName
        let localURL = localModel.localURL

        do {
            // Gemma 4 (text) lives in MLXLLM but Gemma 3 vision lives in MLXVLM.
            // All Gemma variants need <end_of_turn> as an extra EOS token.
            let extraEOS: Set<String> = catalogModel?.family == "Gemma" ? ["<end_of_turn>"] : []
            let config = ModelConfiguration(directory: localURL, extraEOSTokens: extraEOS)
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
            loadedModelID = localModel.catalogID
            state = .ready(displayName)
        } catch {
            state = .error("Failed to load \(displayName): \(error.localizedDescription)")
        }
        #endif
    }

    func unloadModel() {
        modelContainer = nil
        loadedModelID = nil
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

    // MARK: - Generation

    func generate(
        systemPrompt: String,
        messages: [(role: String, content: String)],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let container = modelContainer else {
            throw ModelError.noModelSelected
        }

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
            default: return .user(msg.content)
            }
        }

        let userInput = UserInput(chat: chatMessages)
        let generateParams = GenerateParameters(
            maxTokens: maxNewTokens,
            temperature: temperature,
            topP: topP
        )

        let lmInput = try await container.prepare(input: userInput)
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

    // Extracts up to 10 context-aware labels from text using the loaded model.
    // Does NOT change observable state — safe to call alongside active chat sessions.
    func generateLabels(for text: String) async -> [String] {
        guard case .ready = state, let container = modelContainer else { return [] }
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
            let params = GenerateParameters(maxTokens: 80, temperature: 0.2, topP: 0.9)
            let lmInput = try await container.prepare(input: UserInput(chat: chatMessages))
            let stream = try await container.generate(input: lmInput, parameters: params)
            var output = ""
            for await generation in stream {
                if case .chunk(let t) = generation { output += t }
            }
            let labels = output
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty && $0.count < 40 }
            return Array(labels.prefix(10))
        } catch {
            return []
        }
    }

    // Analyzes a voice transcription and returns a structured intent.
    // Does NOT change observable state — safe to call alongside active chat sessions.
    func analyzeVoiceIntent(transcription: String) async -> VoiceIntent {
        let fallback = VoiceIntent(
            action: .saveNote(title: "Voice Note", body: transcription),
            labels: [],
            summary: "Saved as a note.",
            transcription: transcription
        )
        guard case .ready = state, let container = modelContainer else { return fallback }

        let today = ISO8601DateFormatter().string(from: Date())
        let prompt = """
        Analyze this voice note and determine the single best action to take. Today is \(today).

        Voice note: "\(transcription)"

        Respond with ONLY a valid JSON object — no explanation, no markdown fences:
        {
          "action": "save_note" | "create_list" | "create_reminder" | "create_event" | "chat",
          "title": "concise title",
          "body": "full note text (save_note only)",
          "items": ["item 1", "item 2"],
          "due_date": "ISO8601 string or null",
          "notes": "extra context (create_reminder only, optional)",
          "start_date": "ISO8601 string or null",
          "location": "place name or null",
          "question": "exact question for chat (chat only)",
          "labels": ["tag1", "tag2"],
          "summary": "One sentence: what Sage will do."
        }
        """

        do {
            let chatMessages: [Chat.Message] = [
                .system("You are a precise JSON-only voice intent parser. Output only valid JSON."),
                .user(prompt)
            ]
            let params = GenerateParameters(maxTokens: 350, temperature: 0.1, topP: 0.9)
            let lmInput = try await container.prepare(input: UserInput(chat: chatMessages))
            let stream = try await container.generate(input: lmInput, parameters: params)
            var output = ""
            for await generation in stream {
                if case .chunk(let t) = generation { output += t }
            }
            if let jsonStr = extractFirstJSON(from: output),
               let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return parseVoiceIntent(json: json, transcription: transcription)
            }
        } catch {}
        return fallback
    }

    private func extractFirstJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        return String(text[start...end])
    }

    private func parseVoiceIntent(json: [String: Any], transcription: String) -> VoiceIntent {
        let actionStr = json["action"]  as? String ?? "save_note"
        let title     = (json["title"]  as? String ?? "Voice Note").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLabels = json["labels"]  as? [String] ?? []
        let labels    = Array(rawLabels.map { $0.lowercased() }.filter { !$0.isEmpty && $0.count < 40 }.prefix(10))
        let summary   = json["summary"] as? String ?? ""
        let iso       = ISO8601DateFormatter()

        let action: VoiceIntent.Action
        switch actionStr {
        case "create_list":
            let items = (json["items"] as? [String] ?? []).filter { !$0.isEmpty }
            action = .createList(title: title, items: items)

        case "create_reminder":
            let dueDate = (json["due_date"] as? String).flatMap { iso.date(from: $0) }
            let notes   = json["notes"] as? String
            action = .createReminder(title: title, dueDate: dueDate, notes: notes)

        case "create_event":
            let startDate = (json["start_date"] as? String).flatMap { iso.date(from: $0) }
            let location  = json["location"] as? String
            action = .createCalendarEvent(title: title, startDate: startDate, location: location)

        case "chat":
            let q = (json["question"] as? String ?? transcription).trimmingCharacters(in: .whitespacesAndNewlines)
            action = .chat(question: q.isEmpty ? transcription : q)

        default:
            let body = (json["body"] as? String ?? transcription).trimmingCharacters(in: .whitespacesAndNewlines)
            action = .saveNote(title: title, body: body.isEmpty ? transcription : body)
        }

        return VoiceIntent(action: action, labels: labels, summary: summary, transcription: transcription)
    }

    func generateCaption(for image: UIImage) async throws -> String {
        #if targetEnvironment(simulator)
        return "Photo captured on device"
        #else
        guard let container = modelContainer else { throw ModelError.noModelSelected }
        guard isVisionCapable else {
            throw ModelError.loadFailed("Active model does not support vision")
        }
        guard let ciImage = CIImage(image: image) else {
            throw ModelError.loadFailed("Could not process image")
        }
        let userInput = UserInput(chat: [
            .user(
                "Describe what you see in this photo. Include the scene, objects, people, colours, location, activities, and mood. Be concise but specific.",
                images: [.ciImage(ciImage)]
            )
        ])
        let params = GenerateParameters(maxTokens: 200, temperature: 0.3, topP: 0.9)
        let lmInput = try await container.prepare(input: userInput)
        let stream = try await container.generate(input: lmInput, parameters: params)
        var output = ""
        for await generation in stream {
            if case .chunk(let text) = generation { output += text }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }
}
