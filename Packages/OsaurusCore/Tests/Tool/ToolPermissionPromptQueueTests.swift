//
//  ToolPermissionPromptQueueTests.swift
//  osaurusTests
//
//  Upstream e4734a216, Intel adaptation: approval prompts present one at a
//  time, in request order, so two concurrent requests can never share the
//  single panel/key-monitor slots (one Enter approving both tools).
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ToolPermissionPromptQueueTests {

    @Test func secondRequestWaitsForTheFirstToFinish() async {
        var order: [String] = []
        await ToolPermissionPromptService.acquirePresentationSlot()
        order.append("first-presented")

        let second = Task { @MainActor in
            await ToolPermissionPromptService.acquirePresentationSlot()
            order.append("second-presented")
            ToolPermissionPromptService.releasePresentationSlot()
        }
        // Give the second request every chance to jump the queue.
        for _ in 0..<5 { await Task.yield() }
        #expect(order == ["first-presented"])

        order.append("first-finished")
        ToolPermissionPromptService.releasePresentationSlot()
        await second.value
        #expect(order == ["first-presented", "first-finished", "second-presented"])
    }
}
