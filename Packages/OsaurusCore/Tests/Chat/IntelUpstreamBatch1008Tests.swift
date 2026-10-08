//
//  IntelUpstreamBatch1008Tests.swift
//  osaurusTests
//
//  Intel adaptations from the 2026-10-08 upstream batch
//  (docs/UPSTREAM_AUDIT_2026-10-08.md).
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

struct IntelUpstreamBatch1008Tests {
    // MARK: - #3042 reasoning off, in the form each host reads

    @Test func reasoningOffFormFollowsTheHost() {
        typealias E = ChatEngine
        // Built-in DeepSeek path and DeepSeek hosts keep Intel's thinking flag.
        #expect(E.reasoningOffForm(providerType: nil, host: "api.deepseek.com", isOsaurusRouter: false) == .deepSeekThinking)
        #expect(E.reasoningOffForm(providerType: .openaiLegacy, host: "api.deepseek.com", isOsaurusRouter: false) == .deepSeekThinking)
        // Strict hosted schemas get nothing (they reject unknown fields).
        #expect(E.reasoningOffForm(providerType: .openaiLegacy, host: "api.openai.com", isOsaurusRouter: false) == .none)
        #expect(E.reasoningOffForm(providerType: .openaiLegacy, host: "openrouter.ai", isOsaurusRouter: false) == .none)
        // Self-hosted servers (vLLM, LM Studio, llama.cpp) read template kwargs.
        #expect(E.reasoningOffForm(providerType: .openaiLegacy, host: "127.0.0.1", isOsaurusRouter: false) == .templateKwargs)
        #expect(E.reasoningOffForm(providerType: .openaiLegacy, host: "gpu-box.local", isOsaurusRouter: false) == .templateKwargs)
        // Other API families send nothing; the Router keeps Intel's flag.
        #expect(E.reasoningOffForm(providerType: .anthropic, host: "api.anthropic.com", isOsaurusRouter: false) == .none)
        #expect(E.reasoningOffForm(providerType: .osaurusRouter, host: "router.osaurus.ai", isOsaurusRouter: true) == .deepSeekThinking)
    }

    @Test func compactionRefusesATruncatedSummary() {
        #expect(IntelContextCompaction.isTruncated(finishReason: "length"))
        #expect(IntelContextCompaction.isTruncated(finishReason: "MAX_TOKENS"))
        #expect(!IntelContextCompaction.isTruncated(finishReason: "stop"))
        #expect(!IntelContextCompaction.isTruncated(finishReason: nil))
        #expect(IntelContextCompaction.Failure.truncatedSummary(model: "m").errorDescription?.contains("nothing was replaced") == true)
    }

    // MARK: - #3048 empty new_string deletes (Intel's registry never drops it)

    @Test func fileEditEmptyNewStringDeletesTheMatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intel-file-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("repro.txt")
        try "keep-before\nREMOVE_ME\nkeep-after\n".write(to: url, atomically: true, encoding: .utf8)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"repro.txt","old_string":"REMOVE_ME\n","new_string":""}"#)
        #expect(ToolEnvelope.isSuccess(output), "\(output)")
        #expect(try String(contentsOf: url, encoding: .utf8) == "keep-before\nkeep-after\n")
    }

    // MARK: - #3040 image paste detection (private pasteboard, never .general)

    @MainActor
    @Test func pasteboardImageDetection() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("intel-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        let textOnly = PasteMonitorView.pasteboardHasImage(pasteboard)
        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        let withImage = PasteMonitorView.pasteboardHasImage(pasteboard)
        #expect(!textOnly)
        #expect(withImage)
    }
}
