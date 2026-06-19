//
//  StaticEmbedder.swift
//  OsaurusCore (Intel fork)
//
//  Pure-Swift model2vec ("potion") static embedder. Embedding a string is:
//  tokenize → gather each token's row from a bundled [vocab × dim] float32
//  matrix → mean-pool → L2-normalize. No MLX, no Metal, no ONNX — microseconds
//  per query on CPU. This is the same math VecturaKit's SwiftEmbedder runs on
//  Apple Silicon, minus the CoreML/Metal plumbing the Intel build can't use.
//

#if OSAURUS_INTEL
import Accelerate
import Foundation

public final class StaticEmbedder: EmbeddingBackend, @unchecked Sendable {
    public let dimension: Int
    public let identifier: String
    private let tokenizer: WordPieceTokenizer
    private let matrix: [Float]  // row-major [vocabCount * dim]
    private let vocabCount: Int
    private let normalize: Bool

    private struct Meta: Decodable {
        let model: String
        let dim: Int
        let vocabCount: Int
        let normalize: Bool
        let lowercase: Bool
        let unkToken: String
    }

    public init(modelDirectory: URL) throws {
        let metaURL = modelDirectory.appendingPathComponent("meta.json")
        let vocabURL = modelDirectory.appendingPathComponent("vocab.txt")
        let matrixURL = modelDirectory.appendingPathComponent("potion.f32")
        let fm = FileManager.default
        guard fm.fileExists(atPath: matrixURL.path), fm.fileExists(atPath: vocabURL.path),
            fm.fileExists(atPath: metaURL.path)
        else {
            throw EmbeddingError.modelMissing(modelDirectory.path)
        }
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaURL))
        self.dimension = meta.dim
        self.vocabCount = meta.vocabCount
        self.normalize = meta.normalize
        self.identifier = "static:\(meta.model):\(meta.dim)"
        self.tokenizer = try WordPieceTokenizer(
            vocabFile: vocabURL, unkToken: meta.unkToken, lowercase: meta.lowercase)

        let data = try Data(contentsOf: matrixURL, options: .mappedIfSafe)
        let expected = meta.vocabCount * meta.dim * MemoryLayout<Float>.size
        guard data.count == expected else {
            throw EmbeddingError.malformedResponse(
                "matrix \(data.count) bytes != expected \(expected)")
        }
        self.matrix = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { embedOne($0) }
    }

    private func embedOne(_ text: String) -> [Float] {
        let ids = tokenizer.tokenize(text)
        var acc = [Float](repeating: 0, count: dimension)
        guard !ids.isEmpty else { return acc }
        let dim = dimension
        matrix.withUnsafeBufferPointer { mp in
            guard let m = mp.baseAddress else { return }
            acc.withUnsafeMutableBufferPointer { ap in
                guard let a = ap.baseAddress else { return }
                for id in ids where id >= 0 && id < vocabCount {
                    vDSP_vadd(a, 1, m + id * dim, 1, a, 1, vDSP_Length(dim))
                }
            }
        }
        var scale = 1.0 / Float(ids.count)
        vDSP_vsmul(acc, 1, &scale, &acc, 1, vDSP_Length(dim))
        if normalize { Self.l2normalize(&acc) }
        return acc
    }

    static func l2normalize(_ v: inout [Float]) {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        if norm > 1e-12 {
            var inv = 1.0 / norm
            vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count))
        }
    }
}
#endif
