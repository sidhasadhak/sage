import Foundation

struct CatalogModel: Identifiable, Hashable {
    let id: String                  // HuggingFace repo ID, e.g. "mlx-community/Llama-3.2-3B-Instruct-4bit"
    let displayName: String
    let family: String              // "Llama", "Phi", "Gemma", etc.
    let description: String
    let parameterCount: String      // "1B", "3B", "7B"
    let sizeGB: Double
    let contextLength: Int
    let quantization: String        // "4-bit"
    let tags: [Tag]
    let minimumRAMGB: Int
    let isVisionCapable: Bool
    /// When true this model is shown in the Photo Analysis section, not the main chat list.
    /// It runs at index-time only to generate stored photo descriptions any chat model can then read.
    let isPhotoAnalysisModel: Bool

    enum Tag: String {
        case recommended = "Recommended"
        case fast = "Fast"
        case capable = "Capable"
        case multilingual = "Multilingual"
        case compact = "Compact"
        case reasoning = "Reasoning"
        case vision = "Vision"
    }

    init(
        id: String, displayName: String, family: String, description: String,
        parameterCount: String, sizeGB: Double, contextLength: Int,
        quantization: String, tags: [Tag], minimumRAMGB: Int,
        isVisionCapable: Bool, isPhotoAnalysisModel: Bool = false
    ) {
        self.id = id; self.displayName = displayName; self.family = family
        self.description = description; self.parameterCount = parameterCount
        self.sizeGB = sizeGB; self.contextLength = contextLength
        self.quantization = quantization; self.tags = tags
        self.minimumRAMGB = minimumRAMGB; self.isVisionCapable = isVisionCapable
        self.isPhotoAnalysisModel = isPhotoAnalysisModel
    }

    var localDirectoryName: String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    var isLargeModel: Bool { sizeGB >= 3.5 }
}

enum ModelCatalog {
    static let all: [CatalogModel] = [
        CatalogModel(
            id: "mlx-community/gemma-4-e2b-4bit",
            displayName: "Gemma 4 · E2B",
            family: "Gemma",
            description: "Google's newest Gemma 4 Efficient 2B. Extremely compact and fast while retaining strong instruction-following quality.",
            parameterCount: "2B",
            sizeGB: 1.3,
            contextLength: 32768,
            quantization: "4-bit",
            tags: [.fast, .compact, .recommended],
            minimumRAMGB: 4,
            isVisionCapable: false,
        ),
        CatalogModel(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            displayName: "Llama 3.2 · 1B",
            family: "Llama",
            description: "Meta's smallest Llama model. Extremely fast, great for quick Q&A and simple tasks.",
            parameterCount: "1B",
            sizeGB: 0.7,
            contextLength: 8192,
            quantization: "4-bit",
            tags: [.fast, .compact],
            minimumRAMGB: 4,
            isVisionCapable: false,
        ),
        CatalogModel(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 · 3B",
            family: "Llama",
            description: "The sweet spot — fast responses with strong reasoning. Best overall choice for most uses.",
            parameterCount: "3B",
            sizeGB: 1.8,
            contextLength: 8192,
            quantization: "4-bit",
            tags: [.recommended, .fast],
            minimumRAMGB: 6,
            isVisionCapable: false
        ),
        CatalogModel(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            displayName: "Qwen 2.5 · 3B",
            family: "Qwen",
            description: "Alibaba's model with strong multilingual support. Excellent for non-English languages.",
            parameterCount: "3B",
            sizeGB: 1.9,
            contextLength: 32768,
            quantization: "4-bit",
            tags: [.multilingual],
            minimumRAMGB: 6,
            isVisionCapable: false
        ),
        CatalogModel(
            id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
            displayName: "Mistral 7B",
            family: "Mistral",
            description: "Highly capable 7B model. Slower but noticeably smarter for complex tasks. Requires 8GB RAM.",
            parameterCount: "7B",
            sizeGB: 4.1,
            contextLength: 32768,
            quantization: "4-bit",
            tags: [.capable],
            minimumRAMGB: 8,
            isVisionCapable: false
        ),
        CatalogModel(
            id: "mlx-community/Llama-3.1-8B-Instruct-4bit",
            displayName: "Llama 3.1 · 8B",
            family: "Llama",
            description: "Meta's most capable mobile-class model. Best reasoning quality. Requires 8GB+ RAM.",
            parameterCount: "8B",
            sizeGB: 4.7,
            contextLength: 131072,
            quantization: "4-bit",
            tags: [.capable, .reasoning],
            minimumRAMGB: 8,
            isVisionCapable: false,
        ),
        CatalogModel(
            id: "mlx-community/gemma-3-4b-it-qat-4bit",
            displayName: "Gemma 3 · 4B Vision",
            family: "Gemma",
            description: "Google's Gemma 3 with full vision support. Understands photos, charts, and documents. Great balance of speed and quality.",
            parameterCount: "4B",
            sizeGB: 3.0,
            contextLength: 131072,
            quantization: "4-bit QAT",
            tags: [.recommended, .vision],
            minimumRAMGB: 6,
            isVisionCapable: true,
        ),
        CatalogModel(
            id: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
            displayName: "Qwen2-VL · 2B",
            family: "Qwen",
            description: "Vision-language model. Understands photos and can describe scenes, people, and objects.",
            parameterCount: "2B",
            sizeGB: 2.0,
            contextLength: 32768,
            quantization: "4-bit",
            tags: [.recommended, .vision],
            minimumRAMGB: 6,
            isVisionCapable: true,
        ),
    ]

    /// Dedicated photo-analysis models — downloaded separately, used only at index time.
    /// Produces stored text descriptions that any chat model can then read at query time.
    static let photoAnalysis: [CatalogModel] = [
        CatalogModel(
            id: "mlx-community/SmolVLM-256M-Instruct-bf16",
            displayName: "SmolVLM · 256M",
            family: "SmolVLM",
            description: "Tiny vision model (256 M params, ~0.5 GB). Downloads once and runs at index time to generate rich photo descriptions stored alongside each photo — enabling any text-only model to search your photos by content.",
            parameterCount: "256M",
            sizeGB: 0.5,
            contextLength: 4096,
            quantization: "bf16",
            tags: [.compact, .vision],
            minimumRAMGB: 4,
            isVisionCapable: true,
            isPhotoAnalysisModel: true
        ),
    ]

    static func model(for id: String) -> CatalogModel? {
        (all + photoAnalysis).first { $0.id == id }
    }

    static func isVisionCapable(for catalogID: String) -> Bool {
        (all + photoAnalysis).first { $0.id == catalogID }?.isVisionCapable ?? false
    }

    static func isPhotoAnalysisModel(for catalogID: String) -> Bool {
        photoAnalysis.first { $0.id == catalogID } != nil
    }
}
