//
//  IntelHTTPEmbeddings.swift
//  osaurus
//
//  `POST /embeddings` (OpenAI) and `POST /embed` (Ollama) on Intel's local
//  embedder (`W-server-api` stage 2d, docs/SERVER_API_INTEL.md). Upstream's
//  contract and errors; the model is Intel's: `potion-base-8M` (256
//  dimensions, the CPU `StaticEmbedder` memory uses) where upstream serves
//  `potion-base-4M` (128) on MLX. A client asking for upstream's id gets
//  upstream's "unsupported model" error rather than vectors of a size it
//  didn't expect. Like upstream, the model downloads on first use.
//

import Foundation
import NIOCore
import NIOHTTP1

enum IntelAPIEmbedder {
    /// The served model id (`StaticEmbeddingModel.modelId` without its org).
    static var modelName: String { String(StaticEmbeddingModel.modelId.split(separator: "/").last ?? "") }

    enum APIModelError: LocalizedError {
        case unsupportedModel(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedModel(let requested):
                return "Embedding model '\(requested)' is not supported by this endpoint. "
                    + "Use '\(IntelAPIEmbedder.modelName)' or '\(StaticEmbeddingModel.modelId)'. "
                    + "No embeddings were generated."
            }
        }
    }

    /// Upstream `EmbeddingService.validateAPIModel`, with Intel's model.
    static func validateAPIModel(_ requested: String) throws {
        guard requested == modelName || requested == StaticEmbeddingModel.modelId else {
            throw APIModelError.unsupportedModel(requested)
        }
    }

    private static let cached = NSLockedValue<StaticEmbedder?>(nil)

    static func embed(texts: [String]) async throws -> [[Float]] {
        if let embedder = cached.withLock({ $0 }) { return try await embedder.embed(texts) }
        let directory = try await StaticEmbeddingModel.ensureAvailable()
        let embedder = try StaticEmbedder(modelDirectory: directory)
        cached.withLock { $0 = embedder }
        return try await embedder.embed(texts)
    }
}

extension HTTPHandler {
    func serveEmbeddings(context: ChannelHandlerContext, head: HTTPRequestHead, ollamaFormat: Bool) {
        let logPath = ollamaFormat ? "/embed" : "/embeddings"
        let data = requestBodyData()
        let requestBodyString = String(decoding: data, as: UTF8.self)
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")

        guard let request = try? JSONDecoder().decode(EmbeddingRequest.self, from: data) else {
            let errorBody =
                ollamaFormat
                ? #"{"error":"invalid request body"}"#
                : #"{"error":{"message":"Invalid request body","type":"invalid_request_error","code":"invalid_body"}}"#
            sendResponse(context: context, status: .badRequest, headers: jsonHeaders(), body: errorBody)
            return
        }
        do {
            try IntelAPIEmbedder.validateAPIModel(request.model)
        } catch {
            let message = error.localizedDescription
            let payload: [String: Any] =
                ollamaFormat
                ? ["error": message]
                : [
                    "error": [
                        "message": message, "type": "invalid_request_error",
                        "param": "model", "code": "unsupported_embedding_model",
                    ]
                ]
            let json = (try? JSONSerialization.data(withJSONObject: payload)).map { String(decoding: $0, as: UTF8.self) }
                ?? #"{"error":"Unsupported embedding model"}"#
            sendResponse(context: context, status: .badRequest, headers: jsonHeaders(), body: json)
            return
        }

        stateRef.value.routeLogsItself = true
        let texts = request.input.texts
        let eventLoop = context.eventLoop
        runRequestTask {
            do {
                let embeddings = try await IntelAPIEmbedder.embed(texts: texts)
                let model = IntelAPIEmbedder.modelName
                let json: String
                if ollamaFormat {
                    let response = OllamaEmbedResponse(model: model, embeddings: embeddings)
                    json = (try? JSONEncoder.osaurusCanonical().encode(response)).map {
                        String(decoding: $0, as: UTF8.self)
                    } ?? "{}"
                } else {
                    let objects = embeddings.enumerated().map { OpenAIEmbeddingObject(embedding: $1, index: $0) }
                    let tokenCount = texts.reduce(0) { $0 + $1.split(separator: " ").count }
                    let response = OpenAIEmbeddingResponse(
                        data: objects, model: model,
                        usage: OpenAIEmbeddingUsage(prompt_tokens: tokenCount, total_tokens: tokenCount))
                    json = (try? JSONEncoder.osaurusCanonical().encode(response)).map {
                        String(decoding: $0, as: UTF8.self)
                    } ?? "{}"
                }
                self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
                self.logRequest(
                    method: "POST", path: logPath, userAgent: userAgent, requestBody: requestBodyString,
                    responseBody: json, responseStatus: 200, startTime: startTime, model: model,
                    details: Self.embeddingActivityDetails(texts: texts, dimensions: embeddings.first?.count))
            } catch {
                let message = Self.escapeJSONString(error.localizedDescription)
                let errorJson =
                    ollamaFormat
                    ? #"{"error":"\#(message)"}"#
                    : #"{"error":{"message":"\#(message)","type":"server_error","code":"embedding_failed"}}"#
                self.respondOnLoop(eventLoop, status: .internalServerError, headers: self.jsonHeaders(), body: errorJson)
                self.logRequest(
                    method: "POST", path: logPath, userAgent: userAgent, requestBody: requestBodyString,
                    responseBody: errorJson, responseStatus: 500, startTime: startTime,
                    model: IntelAPIEmbedder.modelName, errorMessage: error.localizedDescription,
                    details: Self.embeddingActivityDetails(texts: texts, dimensions: nil))
            }
        }
    }
}
