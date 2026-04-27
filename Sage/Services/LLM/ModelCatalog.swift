import Foundation

struct CatalogModel: Identifiable, Hashable {
    let id: String                  // HuggingFace repo ID
    let displayName: String
    let family: String              // "Qwen", "Llama", etc.
    let description: String
    let parameterCount: String      // "3B", "1.5B", etc.
    let sizeGB: Double
    let contextLength: Int
    let quantization: String        // "4-bit"
    let tags: [Tag]
    let minimumRAMGB: Int

    enum Tag: String {
        case recommended = "Recommended"
        case fast = "Fast"
        case capable = "Capable"
        case multilingual = "Multilingual"
        case compact = "Compact"
        case reasoning = "Reasoning"
    }

    init(
        id: String, displayName: String, family: String, description: String,
        parameterCount: String, sizeGB: Double, contextLength: Int,
        quantization: String, tags: [Tag], minimumRAMGB: Int
    ) {
        self.id = id; self.displayName = displayName; self.family = family
        self.description = description; self.parameterCount = parameterCount
        self.sizeGB = sizeGB; self.contextLength = contextLength
        self.quantization = quantization; self.tags = tags
        self.minimumRAMGB = minimumRAMGB
    }

    var localDirectoryName: String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    var isLargeModel: Bool { sizeGB >= 3.0 }
}

// MARK: - ModelCatalog
//
// `sage-slim` ships with exactly one model: Qwen2.5-3B-Instruct.
// SmolVLM and the entire photo/vision stack have been removed from
// this build — the goal is to nail the agent + retrieval + action
// loop on a single, well-tested writer before adding modalities back.
//
// Why Qwen2.5-3B-Instruct-4bit:
//   • Same on-disk footprint as Llama 3.2 3B (~1.8 GB).
//   • Markedly better at JSON/structured-output instruction following,
//     which the IntentRouter fallback path relies on.
//   • 32k context window vs Llama's 8k — gives the agent loop more
//     headroom under the new context-budget caps.
//   • Permissively-licensed, mature MLX port, runs at >25 tok/s on
//     A17 Pro / M-series GPUs.

enum ModelCatalog {

    static let chatModel = CatalogModel(
        id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
        displayName: "Qwen 2.5 · 3B",
        family: "Qwen",
        description: "Alibaba's Qwen 2.5 3B-Instruct — strong instruction following, 32k context, runs comfortably on Apple Silicon. Sage's primary brain.",
        parameterCount: "3B",
        sizeGB: 1.8,
        contextLength: 32_768,
        quantization: "4-bit",
        tags: [.recommended, .fast, .capable],
        minimumRAMGB: 4
    )

    /// Both-models compatibility shim. `sage-slim` ships only a chat
    /// model — `all` is a single-element array. Code that previously
    /// iterated for storage accounting / download checks still works.
    static var all: [CatalogModel] { [chatModel] }

    static func model(for id: String) -> CatalogModel? {
        all.first { $0.id == id }
    }
}
