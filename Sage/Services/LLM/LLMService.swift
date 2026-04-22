import Foundation
import MLX
import MLXLLM
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
            let config = ModelConfiguration(directory: localURL)
            // GPU cache + weight loading run off the main actor so the UI stays responsive
            let loaded = try await Task.detached(priority: .userInitiated) {
                MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
                return try await LLMModelFactory.shared.loadContainer(
                    hub: defaultHubApi,
                    configuration: config
                ) { _ in }
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
        var result = ""
        _ = try await generate(
            systemPrompt: "You are a helpful assistant.",
            messages: [("user", prompt)]
        ) { result += $0 }
        return result
    }
}
