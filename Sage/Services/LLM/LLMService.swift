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

    /// True only when the active model is a dedicated photo-analysis model (e.g. SmolVLM 256M).
    /// Main chat vision models must NOT be used for batch photo captioning at index time —
    /// they are too heavy to run sequentially on a large photo library without crashing.
    var isPhotoAnalysisModelActive: Bool {
        guard let id = loadedModelID else { return false }
        return ModelCatalog.isPhotoAnalysisModel(for: id)
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

    // Extracts named entities from a memory chunk for the knowledge graph.
    // Returns strings in "type:name" format e.g. ["person:John Smith", "place:Paris"].
    // Does NOT change observable state — safe to call alongside active sessions.
    func extractEntities(from content: String) async -> [String] {
        guard case .ready = state, let container = modelContainer else { return [] }
        do {
            let chatMessages: [Chat.Message] = [
                .system("You are a precise named-entity extractor. Output only valid JSON."),
                .user("""
                Extract named entities from the text below.
                Types: person, place, project, organization, concept.
                Use canonical short names (e.g. "John" not "John said that he…").
                Return ONLY JSON: {"entities": ["person:John Smith", "place:Paris"]}
                Max 5 entities. If none, return {"entities": []}.

                Text: \(content.prefix(600))
                """)
            ]
            let params = GenerateParameters(maxTokens: 120, temperature: 0.1, topP: 0.9)
            let lmInput = try await container.prepare(input: UserInput(chat: chatMessages))
            let stream = try await container.generate(input: lmInput, parameters: params)
            var output = ""
            for await generation in stream {
                if case .chunk(let t) = generation { output += t }
            }
            if let start = output.firstIndex(of: "{"),
               let end = output.lastIndex(of: "}"),
               let data = String(output[start...end]).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = json["entities"] as? [String] {
                let result = raw
                    .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.contains(":") && $0.count < 60 }
                return Array(result.prefix(5))
            }
        } catch {}
        return []
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
