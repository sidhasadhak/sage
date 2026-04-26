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
            _ = try? await embedding.requestAssets()
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
    //
    // Vectors are persisted as int8-quantized blobs to cut SwiftData/SQLite
    // storage and memory pressure by ~4× (512 dims: 2048B Float32 → 520B
    // quantized) with negligible cosine-similarity loss for L2-normalized
    // sentence embeddings.
    //
    // Format: [magic 4B = 'Q','8',0,1][scale Float32 4B][int8 × N]
    //
    // Legacy Float32 blobs (no magic prefix) are still readable — `unpack`
    // auto-detects format. Re-saving a chunk migrates it to the new format
    // transparently. The first byte of any L2-normalized Float32 vector is
    // never 0x51, so the magic header cannot collide with legacy data.

    private static let magic: [UInt8] = [0x51, 0x38, 0x00, 0x01]    // "Q8\0\1"
    private static let headerSize = 8                                // magic(4) + scale(4)

    /// Packs a vector for SwiftData persistence. Always writes the new
    /// int8-quantized format. Reading is backward-compatible.
    static func pack(_ vector: [Float]) -> Data {
        guard !vector.isEmpty else { return Data() }

        // Find max abs value for the per-vector scale. Normalized embeddings
        // sit in [-1, 1] so this is typically ≈1.0; storing the scale per
        // vector lets us also handle un-normalized inputs safely.
        var maxAbs: Float = 0
        vDSP_maxmgv(vector, 1, &maxAbs, vDSP_Length(vector.count))
        let scale: Float = maxAbs > 0 ? maxAbs / 127.0 : 1.0
        let invScale: Float = scale > 0 ? 1.0 / scale : 1.0

        var data = Data(capacity: headerSize + vector.count)
        data.append(contentsOf: magic)
        withUnsafeBytes(of: scale) { data.append(contentsOf: $0) }

        // Quantize: round(value / scale) → clamp to int8 range.
        for v in vector {
            let q = (v * invScale).rounded()
            let clamped = max(-127, min(127, q))
            data.append(UInt8(bitPattern: Int8(clamped)))
        }
        return data
    }

    /// Unpacks a vector from SwiftData. Auto-detects quantized vs legacy
    /// Float32 format. Returned vectors are NOT re-normalized — caller
    /// uses cosine similarity which is scale-invariant.
    static func unpack(_ data: Data) -> [Float] {
        guard data.count >= 4 else { return [] }

        // Detect quantized format by magic header.
        let isQuantized = data.prefix(4).elementsEqual(magic)

        if isQuantized {
            guard data.count > headerSize else { return [] }
            let scale: Float = data.withUnsafeBytes { raw in
                raw.load(fromByteOffset: 4, as: Float.self)
            }
            let count = data.count - headerSize
            var out = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { raw in
                let base = raw.baseAddress!.advanced(by: headerSize)
                for i in 0..<count {
                    let q = base.load(fromByteOffset: i, as: Int8.self)
                    out[i] = Float(q) * scale
                }
            }
            return out
        }

        // Legacy: raw Float32 array, no header.
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// True if `data` is in the new quantized format. Used by the one-shot
    /// migration pass in IndexingService to skip already-compact rows.
    static func isQuantized(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual(magic)
    }
}

enum EmbeddingError: Error {
    case emptyInput, noVector, modelUnavailable
}
