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

    enum Tag: String {
        case recommended = "Recommended"
        case fast = "Fast"
        case capable = "Capable"
        case multilingual = "Multilingual"
        case compact = "Compact"
        case reasoning = "Reasoning"
        case vision = "Vision"
    }

    var localDirectoryName: String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    var isLargeModel: Bool { sizeGB >= 3.5 }
}

enum ModelCatalog {
    static let all: [CatalogModel] = [
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
            id: "mlx-community/SmolLM2-1.7B-Instruct-4bit",
            displayName: "SmolLM2 · 1.7B",
            family: "SmolLM",
            description: "Hugging Face's ultra-compact model. Surprisingly capable for its tiny size.",
            parameterCount: "1.7B",
            sizeGB: 1.0,
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
        CatalogModel(
            id: "mlx-community/gemma-2-2b-it-4bit",
            displayName: "Gemma 2 · 2B",
            family: "Gemma",
            description: "Google's efficient model. Excellent instruction following and structured output.",
            parameterCount: "2B",
            sizeGB: 1.5,
            contextLength: 8192,
            quantization: "4-bit",
            tags: [.fast],
            minimumRAMGB: 6,
            isVisionCapable: false
        ),
        CatalogModel(
            id: "mlx-community/Phi-3.5-mini-instruct-4bit",
            displayName: "Phi-3.5 Mini",
            family: "Phi",
            description: "Microsoft's efficient model with strong coding and reasoning despite small size.",
            parameterCount: "3.8B",
            sizeGB: 2.3,
            contextLength: 128000,
            quantization: "4-bit",
            tags: [.reasoning],
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
            isVisionCapable: false
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
            isVisionCapable: true
        ),
        CatalogModel(
            id: "mlx-community/Qwen2-VL-7B-Instruct-4bit",
            displayName: "Qwen2-VL · 7B",
            family: "Qwen",
            description: "Powerful vision-language model. Best photo understanding quality. Requires 8GB RAM.",
            parameterCount: "7B",
            sizeGB: 4.5,
            contextLength: 32768,
            quantization: "4-bit",
            tags: [.capable, .vision],
            minimumRAMGB: 8,
            isVisionCapable: true
        ),
    ]

    static func model(for id: String) -> CatalogModel? {
        all.first { $0.id == id }
    }

    static func isVisionCapable(for catalogID: String) -> Bool {
        all.first { $0.id == catalogID }?.isVisionCapable ?? false
    }
}
