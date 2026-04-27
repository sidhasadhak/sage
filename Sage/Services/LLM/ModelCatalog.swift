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
// `sage-slim` ships with exactly one model: Gemma 2 2B-Instruct.
// SmolVLM and the entire photo/vision stack are gone — the goal is
// to nail the agent + retrieval + action loop on a single, well-
// tested writer before adding modalities back.
//
// Why Gemma 2 2B-Instruct-4bit:
//   • Text-only, mlx-lm compatible — drops cleanly into
//     LLMService.loadModel via LLMModelFactory (Google's Gemma 3+ /
//     Gemma 4 are unified multimodal, which would force us to
//     resurrect MLXVLM and undo the slim work).
//   • 2B params at 4-bit quantization is ~1.3 GB on disk and runs
//     at >30 tok/s on A17 Pro — the smallest text-only Gemma we
//     can ship.
//   • Mature MLX port and well-understood EOS handling
//     (LLMService injects `<end_of_turn>` for the Gemma family).
//   • Permissive license; very strong instruction-following for size.
//
// Trade-off vs the prior Qwen 3 4B: smaller model, more reliant on
// LiveContextProvider's pre-loaded date / events / reminders to stay
// grounded. The grounding work shipped in the same commit is exactly
// what makes the 2 B size class viable.

enum ModelCatalog {

    static let chatModel = CatalogModel(
        id: "mlx-community/gemma-2-2b-it-4bit",
        displayName: "Gemma 2 · 2B",
        family: "Gemma",
        description: "Google's Gemma 2 2B-Instruct — fast, solid instruction following, text-only. Sage's primary brain, paired with live ground-truth grounding.",
        parameterCount: "2B",
        sizeGB: 1.3,
        contextLength: 8_192,
        quantization: "4-bit",
        tags: [.recommended, .fast, .compact],
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
