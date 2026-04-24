import Foundation

struct CatalogModel: Identifiable, Hashable {
    let id: String                  // HuggingFace repo ID
    let displayName: String
    let family: String
    let description: String
    let parameterCount: String
    let sizeGB: Double
    let contextLength: Int
    let quantization: String
    let tags: [Tag]
    let minimumRAMGB: Int
    let isVisionCapable: Bool
    /// When true this model is a dedicated photo-analysis model (e.g. SmolVLM 256M).
    /// It runs at index time to generate stored photo descriptions — enabling any
    /// text-only chat model to search photos by content. Guarded separately in
    /// IndexingService so the main chat LLM is never used for batch captioning.
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

    /// Models over 3 GB are flagged — warn users before download on space-constrained devices.
    var isLargeModel: Bool { sizeGB >= 3.0 }
}

enum ModelCatalog {
    /// All models in one list. Models over 3 GB have been removed to keep the total
    /// device footprint within 2–3 GB. isPhotoAnalysisModel distinguishes dedicated
    /// index-time vision models from interactive chat models.
    static let all: [CatalogModel] = [

        // MARK: Fast / Compact (< 2 GB)
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
            isVisionCapable: false
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
            isVisionCapable: false
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

        // MARK: Multilingual
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

        // MARK: Vision chat models (≤ 3 GB)
        CatalogModel(
            id: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
            displayName: "Qwen2-VL · 2B",
            family: "Qwen",
            description: "Vision-language model. Understands photos and can describe scenes, people, and objects during chat.",
            parameterCount: "2B",
            sizeGB: 2.0,
            contextLength: 32768,
            quantization: "4-bit",
            tags: [.recommended, .vision],
            minimumRAMGB: 6,
            isVisionCapable: true
        ),
        CatalogModel(
            id: "mlx-community/gemma-3-4b-it-qat-4bit",
            displayName: "Gemma 3 · 4B Vision",
            family: "Gemma",
            description: "Google's Gemma 3 with full vision support. Understands photos, charts, and documents. Best vision quality on device.",
            parameterCount: "4B",
            sizeGB: 3.0,
            contextLength: 131072,
            quantization: "4-bit QAT",
            tags: [.recommended, .vision],
            minimumRAMGB: 6,
            isVisionCapable: true
        ),

        // MARK: Photo Analysis (index-time only, not for interactive chat)
        CatalogModel(
            id: "mlx-community/SmolVLM-256M-Instruct-bf16",
            displayName: "SmolVLM · 256M",
            family: "SmolVLM",
            description: "Tiny vision model by HuggingFace (256 M params, ~0.5 GB). Downloads once and runs at index time to generate rich photo descriptions — enabling any text-only model to search your photos by content.",
            parameterCount: "256M",
            sizeGB: 0.5,
            contextLength: 4096,
            quantization: "bf16",
            tags: [.compact, .fast, .vision],
            minimumRAMGB: 4,
            isVisionCapable: true,
            isPhotoAnalysisModel: true
        ),
    ]

    /// Convenience: photo-analysis models only.
    static var photoAnalysis: [CatalogModel] {
        all.filter { $0.isPhotoAnalysisModel }
    }

    static func model(for id: String) -> CatalogModel? {
        all.first { $0.id == id }
    }

    static func isVisionCapable(for catalogID: String) -> Bool {
        all.first { $0.id == catalogID }?.isVisionCapable ?? false
    }

    static func isPhotoAnalysisModel(for catalogID: String) -> Bool {
        all.first { $0.id == catalogID }?.isPhotoAnalysisModel ?? false
    }
}
