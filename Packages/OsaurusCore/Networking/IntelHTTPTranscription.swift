//
//  IntelHTTPTranscription.swift
//  osaurus
//
//  `POST /audio/transcriptions` (OpenAI Whisper API shape) on Intel's
//  `SpeechService` (`W-server-api` stage 2d, docs/SERVER_API_INTEL.md).
//  Upstream's multipart parsing, response formats and Insights details;
//  Intel transcribes with Apple Speech where upstream uses Parakeet on
//  Apple silicon. Two Intel changes: the multipart parser no longer traps
//  on a body without boundaries (upstream's `0 ..< (ranges.count - 1)`
//  crashes on an empty range list), and the temporary file keeps the
//  upload's extension so Apple Speech reads non-WAV audio.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    struct MultipartParseResult {
        var file: Data?
        var filename: String?
        var fields: [String: String] = [:]
    }

    static func extractBoundary(from contentType: String) -> String? {
        for part in contentType.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var boundary = String(trimmed.dropFirst("boundary=".count))
                if boundary.hasPrefix("\""), boundary.hasSuffix("\"") {
                    boundary = String(boundary.dropFirst().dropLast())
                }
                return boundary
            }
        }
        return nil
    }

    static func parseMultipartFormData(data: Data, boundary: String) -> MultipartParseResult {
        var result = MultipartParseResult()
        guard !boundary.isEmpty else { return result }
        let boundaryData = Data(("--" + boundary).utf8)
        let crlfData = Data("\r\n".utf8)
        let doubleCrlfData = Data("\r\n\r\n".utf8)

        var ranges: [Range<Data.Index>] = []
        var searchStart = data.startIndex
        while let range = data.range(of: boundaryData, in: searchStart ..< data.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        // Intel: upstream iterated `0 ..< (ranges.count - 1)`, which traps
        // when no boundary was found.
        guard ranges.count >= 2 else { return result }

        for i in 0 ..< (ranges.count - 1) {
            let partStart = ranges[i].upperBound
            let partEnd = ranges[i + 1].lowerBound
            var contentStart = partStart
            if data[contentStart ..< min(contentStart + 2, partEnd)] == crlfData {
                contentStart += 2
            }
            guard let headerEnd = data.range(of: doubleCrlfData, in: contentStart ..< partEnd) else { continue }
            let headerData = data[contentStart ..< headerEnd.lowerBound]
            let bodyStart = headerEnd.upperBound
            var bodyEnd = partEnd
            if bodyEnd - bodyStart >= 2, data[bodyEnd - 2 ..< bodyEnd] == crlfData {
                bodyEnd -= 2
            }
            let bodyData = data[bodyStart ..< bodyEnd]
            guard let headerString = String(data: headerData, encoding: .utf8) else { continue }

            var fieldName: String?
            var fileName: String?
            for line in headerString.split(separator: "\r\n") {
                let lineStr = String(line)
                guard lineStr.lowercased().hasPrefix("content-disposition:") else { continue }
                if let nameRange = lineStr.range(of: "name=\""),
                    let nameEnd = lineStr.range(of: "\"", range: nameRange.upperBound ..< lineStr.endIndex)
                {
                    fieldName = String(lineStr[nameRange.upperBound ..< nameEnd.lowerBound])
                }
                if let fnRange = lineStr.range(of: "filename=\""),
                    let fnEnd = lineStr.range(of: "\"", range: fnRange.upperBound ..< lineStr.endIndex)
                {
                    fileName = String(lineStr[fnRange.upperBound ..< fnEnd.lowerBound])
                }
            }
            guard let name = fieldName else { continue }
            if fileName != nil {
                result.file = Data(bodyData)
                result.filename = fileName
            } else if let value = String(data: bodyData, encoding: .utf8) {
                result.fields[name] = value
            }
        }
        return result
    }

    func serveAudioTranscription(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let data = requestBodyData()
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")
        let path = "/audio/transcriptions"

        guard let contentType = head.headers.first(name: "Content-Type"),
            contentType.contains("multipart/form-data"),
            let boundary = Self.extractBoundary(from: contentType)
        else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":{"message":"Invalid content type. Expected multipart/form-data","type":"invalid_request_error"}}"#)
            return
        }
        let parsed = Self.parseMultipartFormData(data: data, boundary: boundary)
        guard let audioData = parsed.file else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":{"message":"Missing audio file in request","type":"invalid_request_error"}}"#)
            return
        }

        stateRef.value.routeLogsItself = true
        let modelParam = parsed.fields["model"]
        let responseFormat = parsed.fields["response_format"] ?? "json"
        let suffix = parsed.filename.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "wav"
        let eventLoop = context.eventLoop
        runRequestTask {
            let audioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus_transcription_\(UUID().uuidString).\(suffix)")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            do {
                try audioData.write(to: audioURL)
                let service = await MainActor.run { SpeechService.shared }
                let result = try await service.transcribe(audioURL: audioURL)
                let loadedModel = await MainActor.run { service.loadedModelId }
                var details: [String: String] = [
                    "mode": "file",
                    "audio_bytes": String(audioData.count),
                    "transcript_chars": String(result.text.count),
                ]
                if let seconds = result.durationSeconds, seconds > 0 {
                    details["audio_seconds"] = String(format: "%.1f", seconds)
                }
                let body: String
                if responseFormat == "text" {
                    body = result.text
                } else if responseFormat == "verbose_json" {
                    var response: [String: Any] = ["text": result.text, "task": "transcribe"]
                    if let duration = result.durationSeconds { response["duration"] = duration }
                    body = String(
                        decoding: try JSONSerialization.data(withJSONObject: response, options: .osaurusCanonical),
                        as: UTF8.self)
                } else {
                    body = String(
                        decoding: try JSONEncoder.osaurusCanonical().encode(["text": result.text]), as: UTF8.self)
                }
                let headers = responseFormat == "text" ? self.textHeaders() : self.jsonHeaders()
                self.respondOnLoop(eventLoop, status: .ok, headers: headers, body: body)
                self.logRequest(
                    method: "POST", path: path, userAgent: userAgent, requestBody: nil, responseBody: body,
                    responseStatus: 200, startTime: startTime, model: loadedModel ?? modelParam, details: details)
            } catch {
                let body = Self.errorBody(.openai(type: "api_error"), message: error.localizedDescription)
                self.respondOnLoop(eventLoop, status: .internalServerError, headers: self.jsonHeaders(), body: body)
                self.logRequest(
                    method: "POST", path: path, userAgent: userAgent, requestBody: nil, responseBody: body,
                    responseStatus: 500, startTime: startTime, model: modelParam,
                    errorMessage: error.localizedDescription,
                    details: ["mode": "file", "audio_bytes": String(audioData.count)])
            }
        }
    }
}
