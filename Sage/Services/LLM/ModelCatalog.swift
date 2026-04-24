import Foundation

struct CatalogModel: Identifiable, Hashable {
    let id: String                  // HuggingFace repo ID, e.g. "mlx-community/Llama-3.2-3B-Instruct-4bit"
    let displayName: String
    let family: String              // "Llama", "SmolVLM", etc.
    let description: String
    let parameterCount: String      // "1B", "3B", etc.
    let sizeGB: Double
    let contextLength: Int
    let quantization: String        // "4-bit", "bf16"
    let tags: [Tag]
    let minimumRAMGB: Int
    let isVisionCapable: Bool
    let isPhotoAnalysisModel: Bool  // true only for the dedicated photo-captioning model

    enum Tag: String {
        case recommended = "Recommended"
        case fast = "Fast"
        case capable = "Capable"
        case multilingual = "Multilingual"
        case compact = "Compact"
        case reasoning = "Reasoning"
        case vision = "Vision"
        case photoAnalysis = "Photo Analysis"
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

    var isLargeModel: Bool { sizeGB >= 3.0 }
}

// MARK: - ModelCatalog

/// Sage uses exactly two hard-coded models:
///  • chatModel          — Llama 3.2 3B  (general-purpose Q&A and reasoning)
///  • photoAnalysisModel — SmolVLM 256M  (lightweight vision; used only during photo indexing)
enum ModelCatalog {

    // MARK: - Fixed models

    static let chatModel = CatalogModel(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        displayName: "Llama 3.2 · 3B",
        family: "Llama",
        description: "Meta's Llama 3.2 3B — fast, capable, and great for everyday Q&A, summaries, and reasoning. The primary Sage brain.",
        parameterCount: "3B",
        sizeGB: 1.8,
        contextLength: 8192,
        quantization: "4-bit",
        tags: [.recommended, .fast],
        minimumRAMGB: 4,
        isVisionCapable: false,
        isPhotoAnalysisModel: false
    )

    static let photoAnalysisModel = CatalogModel(
        id: "mlx-community/SmolVLM-256M-Instruct-bf16",
        displayName: "SmolVLM · 256M",
        family: "SmolVLM",
        description: "HuggingFace's tiny 256M vision model. Used exclusively to caption your photos so they become searchable. Runs only during background indexing.",
        parameterCount: "256M",
        sizeGB: 0.5,
        contextLength: 16384,
        quantization: "bf16",
        tags: [.compact, .vision, .photoAnalysis],
        minimumRAMGB: 4,
        isVisionCapable: true,
        isPhotoAnalysisModel: true
    )

    // MARK: - Convenience

    /// Both models together — used for storage accounting and download checks.
    static var all: [CatalogModel] { [chatModel, photoAnalysisModel] }

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
