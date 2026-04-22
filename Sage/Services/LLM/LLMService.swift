import Foundation
import UIKit
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon

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

        state = .loading(localModel.displayName)
        modelContainer = nil
        loadedModelID = nil

        let displayName = localModel.displayName
        let localURL = localModel.localURL

        do {
            let isVision = ModelCatalog.isVisionCapable(for: localModel.catalogID)
            let catalogModel = ModelCatalog.model(for: localModel.catalogID)

            // Gemma 3 requires <end_of_turn> as an extra stop token
            let extraEOS: Set<String> = catalogModel?.family == "Gemma" ? ["<end_of_turn>"] : []
            let config = ModelConfiguration(directory: localURL, extraEOSTokens: extraEOS)

            // GPU cache + weight loading run off the main actor so the UI stays responsive
            let loaded = try await Task.detached(priority: .userInitiated) {
                // Cap GPU memory at 70% of device RAM to leave headroom for the OS and app.
                // Without this, MLX can grow unbounded and iOS kills the process.
                let deviceRAM = ProcessInfo.processInfo.physicalMemory
                MLX.GPU.set(memoryLimit: Int(Double(deviceRAM) * 0.70))
                MLX.GPU.set(cacheLimit: 512 * 1024 * 1024) // 512 MB free-block cache
                // Vision-language models (Gemma 3, Qwen2-VL) must use VLMModelFactory;
                // LLMModelFactory doesn't register their architectures and will crash.
                if isVision {
                    return try await VLMModelFactory.shared.loadContainer(
                        hub: defaultHubApi,
                        configuration: config
                    ) { _ in }
                } else {
                    return try await LLMModelFactory.shared.loadContainer(
                        hub: defaultHubApi,
                        configuration: config
                    ) { _ in }
                }
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

        let result = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let stream = try MLXLMCommon.generate(
                input: lmInput,
                parameters: generateParams,
                context: context
            )
            var output = ""
            for await generation in stream {
                if let chunk = generation.chunk {
                    output += chunk
                    let text = chunk
                    Task { @MainActor in onToken(text) }
                }
            }
            return output
        }

        return result
    }

    func complete(prompt: String) async throws -> String {
        try await generate(
            systemPrompt: "You are a helpful assistant.",
            messages: [("user", prompt)],
            onToken: { _ in }
        )
    }

    func generateCaption(for image: UIImage) async throws -> String {
        #if targetEnvironment(simulator)
        return "Photo captured on device"
        #else
        guard let container = modelContainer else { throw ModelError.noModelSelected }
        guard isVisionCapable else { throw ModelError.loadFailed("Active model does not support vision") }
        guard let ciImage = CIImage(image: image) else { throw ModelError.loadFailed("Could not process image") }
        let userInput = UserInput(chat: [
            .user(
                "Describe what you see in this photo. Include the scene, objects, people, colours, location, activities, and mood. Be concise but specific.",
                images: [.ciImage(ciImage)]
            )
        ])
        let params = GenerateParameters(maxTokens: 200, temperature: 0.3, topP: 0.9)
        return try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let stream = try MLXLMCommon.generate(input: lmInput, parameters: params, context: context)
            var output = ""
            for await generation in stream {
                if let chunk = generation.chunk { output += chunk }
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
    }
}
