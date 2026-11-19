//
//  IntelHTTPConfigAdminTemplateTests.swift
//  OsaurusCoreTests
//
//  W-agent-templates stage 2: `template` on `/admin/config/plan|apply` names a
//  whole-config YAML template saved in `~/.osaurus/templates`. It only supplies
//  the document: the same validation, planning and user approval apply, and a
//  template can neither be read from outside the folder nor mixed with `yaml`.
//

import Foundation
import NIOHTTP1
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelHTTPConfigAdminTemplateTests {

    private func request(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test func aSavedTemplatePlansWithoutChangingAnything() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let name = "admin-template-\(UUID().uuidString.prefix(8))"
        guard case .success(let url) = ConfigTemplateStore.save(yaml: "version: 1\ndelegation:\n  budget_max_tokens: 2048\n", name: name)
        else {
            Issue.record("could not save the template")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let before = await MainActor.run { ConfigExporter.export().delegation?.budgetMaxTokens }
        let response = await ConfigAdminEndpoint.handle(
            operation: .plan, uri: "/admin/config/plan", requestBody: request(["template": name]))
        #expect(response.status == .ok, "\(response.body)")
        #expect(await MainActor.run { ConfigExporter.export().delegation?.budgetMaxTokens } == before)
    }

    @Test func aTemplateApplyStillWaitsForTheUser() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let name = "admin-template-\(UUID().uuidString.prefix(8))"
        let before = await MainActor.run { ConfigExporter.export().delegation?.budgetMaxTokens }
        let target = before == 4096 ? 2048 : 4096
        guard case .success(let url) = ConfigTemplateStore.save(yaml: "version: 1\ndelegation:\n  budget_max_tokens: \(target)\n", name: name)
        else {
            Issue.record("could not save the template")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let response = await ConfigAdminEndpoint.handle(
            operation: .apply, uri: "/admin/config/apply", requestBody: request(["template": name, "confirm_high_risk": true]),
            approve: { _, _ in .denied })
        #expect(response.status == .forbidden, "\(response.body)")
        #expect(await MainActor.run { ConfigExporter.export().delegation?.budgetMaxTokens } == before)
    }

    @Test func yamlAndTemplateTogetherAreRefused_andTraversalNames() async throws {
        let both = await ConfigAdminEndpoint.handle(
            operation: .plan, uri: "/admin/config/plan",
            requestBody: request(["yaml": "version: 1\n", "template": "x"]))
        #expect(both.status == .badRequest)
        for hostile in ["../outside", "/etc/passwd", "a/b"] {
            let response = await ConfigAdminEndpoint.handle(
                operation: .plan, uri: "/admin/config/plan", requestBody: request(["template": hostile]))
            #expect(response.status == .badRequest, "\(hostile)")
        }
    }
}
