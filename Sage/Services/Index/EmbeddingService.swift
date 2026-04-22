import Foundation
import NaturalLanguage
import Accelerate

actor EmbeddingService {
    static let shared = EmbeddingService()
    private var sentenceEmbedding: NLEmbedding?

    enum Quality {
        case fast, contextual
    }

    func embed(text: String, quality: Quality = .fast) async throws -> [Float] {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { throw EmbeddingError.emptyInput }

        switch quality {
        case .fast:
            return try fastEmbed(text: cleanText)
        case .contextual:
            return try await contextualEmbed(text: cleanText)
        }
    }

    private func fastEmbed(text: String) throws -> [Float] {
        let embedding = try loadSentenceEmbedding()

        if let vector = embedding.vector(for: text) {
            return vector.map { Float($0) }
        }

        // Fall back to averaging sentence-piece vectors
        let sentences = text.components(separatedBy: ". ")
        var sum = [Double](repeating: 0, count: 512)
        var count = 0

        for sentence in sentences where !sentence.isEmpty {
            if let vec = embedding.vector(for: sentence) {
                for (i, v) in vec.enumerated() where i < sum.count {
                    sum[i] += v
                }
                count += 1
            }
        }

        guard count > 0 else { throw EmbeddingError.noVector }
        let averaged = sum.map { Float($0 / Double(count)) }
        return l2Normalize(averaged)
    }

    private func contextualEmbed(text: String) async throws -> [Float] {
        guard let embedding = NLContextualEmbedding(language: .english) else {
            return try fastEmbed(text: text)
        }
        if !embedding.hasAvailableAssets {
            try? await embedding.requestAssets()
        }
        try embedding.load()

        guard let result = try? embedding.embeddingResult(for: text, language: nil) else {
            return try fastEmbed(text: text)
        }

        var sum = [Float](repeating: 0, count: Int(embedding.dimension))
        var count = 0

        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for (i, v) in vector.enumerated() where i < sum.count {
                sum[i] += Float(v)
            }
            count += 1
            return true
        }

        guard count > 0 else { throw EmbeddingError.noVector }
        let averaged = sum.map { $0 / Float(count) }
        return l2Normalize(averaged)
    }

    private func loadSentenceEmbedding() throws -> NLEmbedding {
        if let e = sentenceEmbedding { return e }
        guard let e = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbeddingError.modelUnavailable
        }
        sentenceEmbedding = e
        return e
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        let magnitude = sqrt(norm)
        guard magnitude > 0 else { return v }
        return v.map { $0 / magnitude }
    }

    // MARK: - Serialization

    static func pack(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpack(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

enum EmbeddingError: Error {
    case emptyInput, noVector, modelUnavailable
}
