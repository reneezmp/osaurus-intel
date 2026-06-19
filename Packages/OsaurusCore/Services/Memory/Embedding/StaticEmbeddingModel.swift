//
//  StaticEmbeddingModel.swift
//  OsaurusCore (Intel fork)
//
//  Downloads + caches the static model2vec model on first use rather than
//  bundling it — matching upstream (which fetches it from HuggingFace via
//  VecturaKit), keeping the app slim. The HF `model.safetensors` is parsed to a
//  flat little-endian float32 `.f32` (+ `vocab.txt` + `meta.json`) under
//  `~/.osaurus/embeddings/potion-base-8M/`; later runs load straight from cache.
//

#if OSAURUS_INTEL
import Foundation

public enum StaticEmbeddingModel {
    public static let modelId = "minishlab/potion-base-8M"
    public static let dimension = 256
    private static let folderName = "potion-base-8M"
    private static let base = "https://huggingface.co/minishlab/potion-base-8M/resolve/main"

    public static var cacheDirectory: URL {
        OsaurusPaths.embeddings().appendingPathComponent(folderName, isDirectory: true)
    }

    /// True when the converted cache is present (matrix + vocab + meta).
    public static var isAvailable: Bool {
        let d = cacheDirectory
        let fm = FileManager.default
        return fm.fileExists(atPath: d.appendingPathComponent("potion.f32").path)
            && fm.fileExists(atPath: d.appendingPathComponent("vocab.txt").path)
            && fm.fileExists(atPath: d.appendingPathComponent("meta.json").path)
    }

    /// Ensure the model is downloaded + converted; returns the cache directory.
    /// Idempotent. Callers should serialize (the `EmbeddingClient` actor does) so
    /// a first-run download happens once.
    public static func ensureAvailable() async throws -> URL {
        let dir = cacheDirectory
        if isAvailable { return dir }
        MemoryLogger.config.info("Downloading static embedding model \(modelId)…")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let session = GlobalProxySettings.makeSession()
        let vocabData = try await download(session, "\(base)/vocab.txt")
        let safetensors = try await download(session, "\(base)/model.safetensors")

        let (matrixData, rows, dim) = try parseEmbeddings(safetensors: safetensors)
        try matrixData.write(to: dir.appendingPathComponent("potion.f32"), options: .atomic)
        try vocabData.write(to: dir.appendingPathComponent("vocab.txt"), options: .atomic)
        let meta: [String: Any] = [
            "model": modelId, "dim": dim, "vocabCount": rows,
            "normalize": true, "lowercase": true, "unkToken": "[UNK]",
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
        try metaData.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        MemoryLogger.config.info("Static embedding model ready (\(rows)x\(dim)).")
        return dir
    }

    private static func download(_ session: URLSession, _ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw EmbeddingError.notConfigured("bad model URL: \(urlString)")
        }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw EmbeddingError.httpError(status: status, message: "downloading \(urlString)")
        }
        return data
    }

    /// Parse a safetensors blob and return the `embeddings` tensor as raw
    /// little-endian float32 `Data`, plus its `[rows, dim]`. Only F32 is
    /// supported (potion-base-8M is F32). Layout:
    /// `[u64 LE header length][JSON header][raw tensor bytes]`.
    static func parseEmbeddings(safetensors data: Data) throws -> (Data, Int, Int) {
        guard data.count > 8 else { throw EmbeddingError.malformedResponse("safetensors too small") }
        let headerLen = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self) })
        let headerStart = 8
        let headerEnd = headerStart + headerLen
        guard headerLen > 0, data.count >= headerEnd else {
            throw EmbeddingError.malformedResponse("truncated safetensors header")
        }
        let headerData = data.subdata(in: headerStart..<headerEnd)
        guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
            let emb = header["embeddings"] as? [String: Any],
            let dtype = emb["dtype"] as? String,
            let shape = emb["shape"] as? [Int], shape.count == 2,
            let offsets = emb["data_offsets"] as? [Int], offsets.count == 2
        else {
            throw EmbeddingError.malformedResponse("missing/!valid `embeddings` tensor")
        }
        guard dtype == "F32" else {
            throw EmbeddingError.malformedResponse("unsupported dtype \(dtype), expected F32")
        }
        let tensorStart = headerEnd + offsets[0]
        let tensorEnd = headerEnd + offsets[1]
        guard tensorEnd >= tensorStart, data.count >= tensorEnd else {
            throw EmbeddingError.malformedResponse("truncated tensor data")
        }
        return (data.subdata(in: tensorStart..<tensorEnd), shape[0], shape[1])
    }
}
#endif
