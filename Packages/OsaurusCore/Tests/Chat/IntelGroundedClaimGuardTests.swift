//
//  IntelGroundedClaimGuardTests.swift
//  osaurusTests
//
//  W-agent-loop-tools (2026-10-10): upstream's grounded-claim driver
//  scenarios (`GroundedClaimLoopDriverTests`, `FileClaimLoopDriverTests`,
//  `KnowledgeClaimLoopDriverTests`) against Intel's run state and cloud
//  engine. The engine is exercised against an in-process HTTP fixture, never
//  a real provider.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelGroundedClaimGuardTests {
    private static let failedList = ToolEnvelope.failure(
        kind: .invalidArgs,
        message: "Unknown collection `knowledge`. Granted collections: Obsidian Vault.",
        field: "collection",
        expected: "one of the agent's granted collection names",
        tool: "list_knowledge",
        retryable: true
    )

    // MARK: File side effects

    @Test func narratedWriteWithoutWriteTool_stagesBoundedNotices() {
        var guardState = IntelGroundedClaimGuard()
        guardState.record(
            toolName: "fetch_html", argumentsJSON: "{}", result: ToolEnvelope.success(tool: "fetch_html", text: "x"))
        let narration = "I've appended the summary to the file. Fetching the next page now."
        #expect(guardState.toolTurnNotice(narration: narration) == GroundedFileSideEffectCheck.ungroundedFileClaimNotice)
        #expect(guardState.toolTurnNotice(narration: narration) != nil)
        #expect(guardState.toolTurnNotice(narration: narration) == nil)  // bounded per run
    }

    @Test func successfulWriteGrounds_failedWriteDoesNot() {
        var failed = IntelGroundedClaimGuard()
        failed.record(
            toolName: "file_write", argumentsJSON: "{}",
            result: ToolEnvelope.failure(kind: .rejected, message: "denied", tool: "file_write"))
        #expect(failed.toolTurnNotice(narration: "Saved the report.") != nil)

        var written = IntelGroundedClaimGuard()
        written.record(
            toolName: "file_write", argumentsJSON: "{}", result: ToolEnvelope.success(tool: "file_write", text: "ok"))
        #expect(written.toolTurnNotice(narration: "Saved the report.") == nil)
        #expect(written.finalAnswerNotice(visibleText: "Saved the report.", configToolOffered: false) == nil)
    }

    @Test func futureIntentNeverTrips() {
        var guardState = IntelGroundedClaimGuard()
        #expect(guardState.toolTurnNotice(narration: "I'll append it to the file once the page is fetched.") == nil)
    }

    @Test func finalClaimRetriesAreBounded() {
        var guardState = IntelGroundedClaimGuard()
        let claim = "I created the markdown document with the three sections you asked for."
        #expect(guardState.finalAnswerNotice(visibleText: claim, configToolOffered: false) != nil)
        #expect(guardState.finalAnswerNotice(visibleText: claim, configToolOffered: false) != nil)
        #expect(guardState.finalAnswerNotice(visibleText: claim, configToolOffered: false) == nil)
    }

    // MARK: Knowledge

    @Test func fabricatedSummaryAfterFailedListing_namesTheGrantedCollection() throws {
        var guardState = IntelGroundedClaimGuard()
        guardState.record(toolName: "list_knowledge", argumentsJSON: "{}", result: Self.failedList)
        let staged = guardState.finalAnswerNotice(
            visibleText: "The Obsidian Vault contains 20 documents, all dated 2025.", configToolOffered: false)
        let notice = try #require(staged)
        #expect(notice.contains("`Obsidian Vault`"))
        #expect(notice.contains("`list_knowledge`"))
    }

    @Test func successfulReadOrNoCallOrHonestAnswer_neverTrips() {
        let claim = "There are 312 notes in the vault."
        var none = IntelGroundedClaimGuard()
        #expect(none.finalAnswerNotice(visibleText: claim, configToolOffered: false) == nil)

        var read = IntelGroundedClaimGuard()
        read.record(toolName: "list_knowledge", argumentsJSON: "{}", result: Self.failedList)
        read.record(
            toolName: "list_knowledge", argumentsJSON: "{}",
            result: ToolEnvelope.success(tool: "list_knowledge", text: "Found 3 knowledge document(s):"))
        #expect(read.finalAnswerNotice(visibleText: claim, configToolOffered: false) == nil)

        var honest = IntelGroundedClaimGuard()
        honest.record(toolName: "list_knowledge", argumentsJSON: "{}", result: Self.failedList)
        #expect(
            honest.finalAnswerNotice(
                visibleText: "The knowledge tool failed, so I cannot say how many documents the vault contains.",
                configToolOffered: false) == nil)
    }

    // MARK: Config (scoped to runs offering osaurus_config)

    @Test func configClaimTripsOnlyWhenTheToolIsOffered() {
        let envelope = #"{"ok":true,"result":{"status":"applied"}}"#
        var offered = IntelGroundedClaimGuard()
        #expect(offered.finalAnswerNotice(visibleText: envelope, configToolOffered: true)
            == GroundedConfigClaimCheck.fabricatedEnvelopeNotice)
        var notOffered = IntelGroundedClaimGuard()
        #expect(notOffered.finalAnswerNotice(visibleText: envelope, configToolOffered: false) == nil)
    }

    // MARK: Persistence

    @Test func excludedTurnRoundTrips() throws {
        let turn = ChatTurn(role: .assistant, content: "Saved the report.")
        turn.modelContextExcluded = true
        let data = try JSONEncoder().encode(ChatTurnData(from: turn))
        let back = try JSONDecoder().decode(ChatTurnData.self, from: data)
        #expect(back.modelContextExcluded)
        #expect(ChatTurn(from: back).modelContextExcluded)
        // Ordinary turns don't write the key at all.
        let plain = try JSONEncoder().encode(ChatTurnData(from: ChatTurn(role: .assistant, content: "hi")))
        #expect(!String(decoding: plain, as: UTF8.self).contains("modelContextExcluded"))
    }
}

// MARK: - Engine

@Suite("Intel grounded-claim engine", .serialized)
struct IntelGroundedClaimEngineTests {
    private static func textStream(_ text: String) -> String {
        """
        data: {"choices":[{"index":0,"delta":{"content":"\(text)"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
    }

    private func run(checksEnabled: Bool) async throws -> (deltas: [String], bodies: [String]) {
        GroundedFixtureProtocol.configure(responses: [
            Self.textStream("Saved the report."),
            Self.textStream("I cannot write files in this chat; here is the content."),
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroundedFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: "grounded-fixture.invalid", providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        let request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "Write me a report")])
        let stream = try await ChatExecutionContext.$interactiveChatRun.withValue(checksEnabled) {
            try await engine.streamChat(request: request)
        }
        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }
        return (deltas, GroundedFixtureProtocol.bodies)
    }

    @Test("An ungrounded final is regenerated once, with the notice and without the answer")
    func ungroundedFinalRegenerates() async throws {
        let (deltas, bodies) = try await run(checksEnabled: true)
        #expect(deltas.contains(StreamingGroundedRetryHint.sentinel))
        #expect(deltas.last == "I cannot write files in this chat; here is the content.")
        #expect(bodies.count == 2)
        #expect(bodies[1].contains("[System Notice] Your previous message says a file was written"))
        #expect(!bodies[1].contains("Saved the report."))
    }

    @Test("Surfaces that don't opt in keep the answer as is")
    func surfacesWithoutOptInAreUnaffected() async throws {
        let (deltas, bodies) = try await run(checksEnabled: false)
        #expect(!deltas.contains(StreamingGroundedRetryHint.sentinel))
        #expect(bodies.count == 1)
    }
}

private final class GroundedFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [String] = []
    nonisolated(unsafe) private static var captured: [String] = []
    static var bodies: [String] { lock.lock(); defer { lock.unlock() }; return captured }
    static func configure(responses: [String]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses; captured = []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "grounded-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.captured.append(String(decoding: body, as: UTF8.self))
        let text = Self.queue.isEmpty ? "data: [DONE]\n\n" : Self.queue.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
