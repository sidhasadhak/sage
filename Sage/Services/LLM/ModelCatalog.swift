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
// `sage-slim` ships with exactly one model: Qwen3-4B-Instruct (2507).
// SmolVLM and the entire photo/vision stack have been removed from
// this build — the goal is to nail the agent + retrieval + action
// loop on a single, well-tested writer before adding modalities back.
//
// Why Qwen3-4B-Instruct-2507-4bit:
//   • Newer Qwen3 family — measurably stronger instruction following
//     and tool-call discipline than the 2.5 series at similar size.
//   • Text-only, mlx-lm compatible (NOT mlx-vlm) — drops cleanly into
//     LLMService.loadModel without resurrecting the vision factory.
//   • 256k native context window — the agent loop can hold many more
//     retrieved chunks without our Phase-3 budget caps biting in.
//   • 4-bit quantization, ~2.26 GB on disk. Sustained ~20 tok/s on
//     A17 Pro / M-series GPUs.
//   • Apache 2.0; mature mlx-community port (22k+ monthly downloads).

enum ModelCatalog {

    static let chatModel = CatalogModel(
        id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        displayName: "Qwen 3 · 4B",
        family: "Qwen",
        description: "Alibaba's Qwen 3 4B-Instruct (2507 release) — strong instruction following, 256k context, solid tool calling. Sage's primary brain.",
        parameterCount: "4B",
        sizeGB: 2.3,
        contextLength: 262_144,
        quantization: "4-bit",
        tags: [.recommended, .capable, .reasoning],
        minimumRAMGB: 6
    )

    /// Both-models compatibility shim. `sage-slim` ships only a chat
    /// model — `all` is a single-element array. Code that previously
    /// iterated for storage accounting / download checks still works.
    static var all: [CatalogModel] { [chatModel] }

    static func model(for id: String) -> CatalogModel? {
        all.first { $0.id == id }
    }
}
