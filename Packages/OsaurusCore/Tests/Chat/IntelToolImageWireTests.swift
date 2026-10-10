//
//  IntelToolImageWireTests.swift
//  osaurusTests
//
//  Tool-result images on Intel's wire dicts (W-agent-loop-tools,
//  2026-10-10): upstream's ToolResultMediaBridge rules applied to the
//  engine's running conversation. Blobs land in the test root.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelToolImageWireTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])

    private func imageEnvelope(hash: String) -> String {
        ToolEnvelope.success(
            tool: "file_read",
            result: ["kind": "image", "path": "pic.png", "text": "Image pic.png is attached",
                     "image_ref": ["hash": hash, "byte_count": Self.png.count]] as [String: Any])
    }

    @Test func stagedImagesRideWithTheToolResultOnlyWhenEnabled() throws {
        let hash = try AttachmentBlobStore.write(Self.png)
        defer { AttachmentBlobStore.delete(hash) }
        let envelope = imageEnvelope(hash: hash)

        let plain = IntelToolImageWire.toolMessage(
            callId: "c1", toolName: "file_read", result: envelope, imagesEnabled: false)
        #expect(plain["content"] as? String == envelope)

        let withImage = IntelToolImageWire.toolMessage(
            callId: "c1", toolName: "file_read", result: envelope, imagesEnabled: true)
        let parts = try #require(withImage["content"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == envelope)
        let url = (parts.last?["image_url"] as? [String: Any])?["url"] as? String
        #expect(url?.hasPrefix("data:image/png;base64,") == true)

        // A non-image tool is never touched.
        let other = IntelToolImageWire.toolMessage(
            callId: "c2", toolName: "shell_run", result: envelope, imagesEnabled: true)
        #expect(other["content"] is String)
    }

    private func toolImage(_ id: String) -> [String: Any] {
        ["role": "tool", "tool_call_id": id, "content": [
            ["type": "text", "text": "result \(id)"],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(id)"]],
        ]]
    }

    @Test func onlyTheNewestImagesStayLive() {
        let messages: [[String: Any]] = [toolImage("a"), ["role": "assistant", "content": "x"], toolImage("b"),
                                         ["role": "assistant", "content": "y"], toolImage("c")]
        let out = IntelToolImageWire.preparedForSend(messages, keepsImagesInToolResults: true)
        #expect((out[0]["content"] as? String)?.contains(ToolResultMediaBridge.collapsedImageNote) == true)
        #expect(out[2]["content"] is [[String: Any]])
        #expect(out[4]["content"] is [[String: Any]])
    }

    @Test func textOnlyToolWiresGetTheImagesHoisted() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "look at both"],
            ["role": "assistant", "content": "", "tool_calls": []],
            toolImage("a"),
            toolImage("b"),
        ]
        let out = IntelToolImageWire.preparedForSend(messages, keepsImagesInToolResults: false)
        #expect(out.count == 5)
        #expect(out[2]["content"] as? String == "result a")
        #expect(out[3]["content"] as? String == "result b")
        let hoisted = try #require(out[4]["content"] as? [[String: Any]])
        #expect(out[4]["role"] as? String == "user")
        #expect(hoisted.first?["text"] as? String == ToolResultMediaBridge.hoistedImageIntro)
        #expect(hoisted.filter { $0["type"] as? String == "image_url" }.count == 2)

        // Anthropic keeps them inside the tool results.
        let kept = IntelToolImageWire.preparedForSend(messages, keepsImagesInToolResults: true)
        #expect(kept.count == 4)
        #expect(kept[3]["content"] is [[String: Any]])
    }
}
