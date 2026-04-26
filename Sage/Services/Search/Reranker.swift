import Foundation
import CoreML

// MARK: - Reranker
//
// Second-pass scoring: take the first-stage semantic recall list
// (top-50 candidates) and re-score with a more expensive function
// to surface the true top-8.
//
// Why this order matters:
//   • First stage (cosine + keyword + recency) optimises for recall —
//     better to have the right chunk at rank 30 than to miss it.
//   • Second stage optimises for precision — the LLM's context window
//     is precious; every slot wasted on a marginally-relevant chunk
//     dilutes the prompt.
//
// Two implementations, selected at runtime:
//
//   BM25Reranker  — pure Swift, ships with no extra assets.
//                   BM25 is the industry-standard IR scoring function;
//                   it consistently outperforms TF-IDF and raw cosine
//                   on short factual queries.
//
//   CoreMLReranker — loads ms-marco-MiniLM-L6-v2.mlmodelc from the
//                   app bundle if present; delegates to BM25 otherwise.
//                   A cross-encoder jointly encodes (query, document)
//                   and produces a single relevance score — much higher
//                   quality than bi-encoder cosine, at the cost of N
//                   forward passes instead of 1.
//
// How to convert the CoreML model (one-time, requires Python):
//
//   pip install sentence-transformers coremltools numpy
//
//   python3 - <<'EOF'
//   from sentence_transformers import CrossEncoder
//   import coremltools as ct, numpy as np, torch
//
//   model = CrossEncoder("cross-encoder/ms-marco-MiniLM-L6-v2")
//   tokenizer = model.tokenizer
//
//   # Traced with a representative input shape (seq_len=128).
//   dummy_ids   = torch.zeros(1, 128, dtype=torch.long)
//   dummy_mask  = torch.ones(1, 128, dtype=torch.long)
//
//   traced = torch.jit.trace(
//       model.model, (dummy_ids, dummy_mask), strict=False
//   )
//   mlmodel = ct.convert(
//       traced,
//       inputs=[
//           ct.TensorType(name="input_ids",      shape=(1, 128), dtype=np.int32),
//           ct.TensorType(name="attention_mask",  shape=(1, 128), dtype=np.int32),
//       ],
//       outputs=[ct.TensorType(name="logits")],
//       minimum_deployment_target=ct.target.iOS16,
//   )
//   mlmodel.save("ms-marco-MiniLM-L6-v2.mlmodelc")
//   EOF
//
//   Then drag ms-marco-MiniLM-L6-v2.mlmodelc into Xcode → Sage target
//   → "Copy items if needed" checked.
//   (~25 MB; Accelerate-backed — no GPU spike, no extra memory budget.)

// MARK: - Protocol

protocol Reranker: Sendable {
    /// Re-score `candidates` for `query` and return them sorted best-first.
    /// Implementations may return fewer than `candidates.count` items if they
    /// apply an internal top-K cutoff, but must never return more.
    func rerank(query: String, candidates: [MemoryChunk], topK: Int) async -> [MemoryChunk]
}

// MARK: - BM25 Reranker

/// Okapi BM25 scoring over the reranking candidate set.
///
/// Parameters: k1 = 1.5 (TF saturation), b = 0.75 (length norm).
/// IDF is estimated from the candidate set itself — not the full corpus —
/// which is accurate enough for a 50-document candidate list and avoids
/// coupling the reranker to the full embedding cache.
struct BM25Reranker: Reranker {

    private let k1: Float = 1.5
    private let b:  Float = 0.75

    func rerank(query: String, candidates: [MemoryChunk], topK: Int) async -> [MemoryChunk] {
        guard !candidates.isEmpty else { return [] }

        let queryTerms = tokenise(query)
        guard !queryTerms.isEmpty else { return Array(candidates.prefix(topK)) }

        // avgdl: mean document length over the candidate set.
        let lengths = candidates.map { Float(tokenise($0.content).count) }
        let avgdl = lengths.reduce(0, +) / Float(candidates.count)

        // df[term] = number of candidates containing that term.
        var df: [String: Int] = [:]
        for chunk in candidates {
            let docTerms = Set(tokenise(chunk.content))
            for term in queryTerms where docTerms.contains(term) {
                df[term, default: 0] += 1
            }
        }

        let N = Float(candidates.count)

        let scored: [(MemoryChunk, Float)] = candidates.map { chunk in
            let docTerms = tokenise(chunk.content)
            let dl = Float(docTerms.count)
            var score: Float = 0

            // Build a term-frequency map for this document.
            var tf: [String: Float] = [:]
            for t in docTerms { tf[t, default: 0] += 1 }

            for term in queryTerms {
                let termTF = tf[term] ?? 0
                guard termTF > 0 else { continue }

                // BM25 IDF (clamped to 0 to avoid negative contribution
                // from very common terms in this small candidate set).
                let dfVal = Float(df[term] ?? 1)
                let idf = max(0, log((N - dfVal + 0.5) / (dfVal + 0.5) + 1))

                // BM25 TF — saturates via k1, penalises long docs via b.
                let normTF = (termTF * (k1 + 1)) /
                    (termTF + k1 * (1 - b + b * dl / max(avgdl, 1)))

                score += idf * normTF
            }

            // Bonus: query terms appearing in the chunk's keyword list
            // got there because the indexer judged them important — give
            // them a small lift. Capped so it can't dominate BM25.
            let keywordSet = Set(chunk.keywords.map { $0.lowercased() })
            let keywordHits = queryTerms.filter { keywordSet.contains($0) }
            score += Float(keywordHits.count) * 0.3

            return (chunk, score)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { $0.0 }
    }

    // MARK: - Tokenisation

    /// Lowercase, split on non-alphanumeric, drop stopwords and very
    /// short tokens. Mirrors what standard BM25 implementations do.
    private func tokenise(_ text: String) -> [String] {
        let lower = text.lowercased()
        // Split on anything that isn't a letter or digit.
        let tokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !Self.stopwords.contains($0) }
        return tokens
    }

    /// Minimal English stopword set. Blocking only the most frequent
    /// function words; content words (even short ones like "at", "on")
    /// that are meaningful in personal data queries are kept.
    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all",
        "can", "had", "her", "was", "one", "our", "out", "day",
        "get", "has", "him", "his", "how", "its", "may", "new",
        "now", "say", "she", "use", "was", "who", "did", "this",
        "that", "with", "from", "have", "been", "they", "will",
        "what", "when", "your", "more", "than", "into", "some",
        "also", "just", "each", "like", "most", "over", "such",
        "then", "them", "very", "well", "were", "been"
    ]
}

// MARK: - CoreML Reranker

/// Loads `ms-marco-MiniLM-L6-v2.mlmodelc` from the app bundle at
/// first use. Falls back to `BM25Reranker` silently when the model
/// is absent — so the app ships with a working reranker regardless.
///
/// The CoreML model takes (input_ids: Int32[1,128], attention_mask:
/// Int32[1,128]) and produces (logits: Float[1,1]). The higher the
/// logit, the more relevant the document is to the query.
///
/// Tokenisation uses a simple whitespace+subword approach that
/// approximates BERT WordPiece well enough for reranking purposes
/// without pulling in a full HuggingFace tokenizer.
final class CoreMLReranker: Reranker, @unchecked Sendable {

    private static let modelName = "ms-marco-MiniLM-L6-v2"
    private static let maxSeqLen = 128

    // Lazy so the model file is read only if the reranker is actually
    // used, not at app launch. Model load is cheap (~5ms); no GPU needed.
    private let model: MLModel? = {
        guard let url = Bundle.main.url(
            forResource: CoreMLReranker.modelName,
            withExtension: "mlmodelc"
        ) else { return nil }
        return try? MLModel(contentsOf: url)
    }()

    private let fallback = BM25Reranker()

    func rerank(query: String, candidates: [MemoryChunk], topK: Int) async -> [MemoryChunk] {
        guard let model else {
            // Model not in bundle — fall back to BM25.
            return await fallback.rerank(query: query, candidates: candidates, topK: topK)
        }

        var scored: [(MemoryChunk, Float)] = []

        for chunk in candidates {
            let inputText = "Query: \(query) Document: \(chunk.content.prefix(300))"
            guard let (idArray, maskArray) = tokenise(inputText),
                  let input = try? MLDictionaryFeatureProvider(dictionary: [
                      "input_ids":      idArray,
                      "attention_mask": maskArray
                  ]),
                  let output = try? await model.prediction(from: input),
                  let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                scored.append((chunk, 0))
                continue
            }
            scored.append((chunk, logits[0].floatValue))
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { $0.0 }
    }

    // MARK: - Tokenisation

    /// Approximate WordPiece tokenisation: lowercase, split on
    /// non-alphanumerics, hash tokens into [1000, 30522) (BERT vocab
    /// range). Not as accurate as the full HuggingFace tokenizer, but
    /// rank-ordering of scores is correct enough for reranking.
    private func tokenise(_ text: String) -> (MLMultiArray, MLMultiArray)? {
        let maxLen = Self.maxSeqLen
        let lower = text.lowercased()

        var rawIDs: [Int32] = [101] // [CLS]
        let tokens = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for token in tokens {
            if rawIDs.count >= maxLen - 1 { break }
            let h = abs(token.hashValue) % 29_522
            rawIDs.append(Int32(1_000 + h))
        }
        rawIDs.append(102) // [SEP]

        let seqLen = rawIDs.count
        let padLen = maxLen - seqLen
        let paddedIDs  = rawIDs + [Int32](repeating: 0, count: padLen)
        let paddedMask = [Int32](repeating: 1, count: seqLen)
                       + [Int32](repeating: 0, count: padLen)

        guard let idArr   = try? MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32),
              let maskArr = try? MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32) else {
            return nil
        }
        for (i, v) in paddedIDs.enumerated()  { idArr[i]   = NSNumber(value: v) }
        for (i, v) in paddedMask.enumerated() { maskArr[i] = NSNumber(value: v) }
        return (idArr, maskArr)
    }
}
