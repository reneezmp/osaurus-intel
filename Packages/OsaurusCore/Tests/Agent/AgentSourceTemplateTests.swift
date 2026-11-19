//
//  AgentSourceTemplateTests.swift
//  OsaurusCoreTests
//
//  `sourceTemplateName` is display provenance for agents made from a
//  template. It must survive the agent JSON round trip, load as nil for
//  agents written before the field existed, travel through the declarative
//  document as `source_template`, and follow the agent through Duplicate.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AgentSourceTemplateTests {

    @Test
    func roundTripsThroughAgentJSON_andDefaultsToNil() throws {
        var agent = Agent(id: UUID(), name: "Invoice Bot")
        agent.sourceTemplateName = "Cloud Agent"
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(Agent.self, from: data)
        #expect(decoded.sourceTemplateName == "Cloud Agent")

        // An agent persisted before the field existed decodes with nil.
        var json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        json?["sourceTemplateName"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: json ?? [:])
        #expect(try JSONDecoder().decode(Agent.self, from: legacy).sourceTemplateName == nil)
    }

    // Intel: Duplicate lives in `AgentsView.duplicateAgent` (no `duplicateRecord`
    // seam), which passes `sourceTemplateName` / `sourceTemplateID` through;
    // covered by the manual retest step, not a unit test.

    @Test
    func exporterAndApplierCarryTheOrigin() {
        var agent = Agent(id: UUID(), name: "Invoice Bot")
        agent.sourceTemplateName = "Cloud Agent"
        #expect(ConfigExporter.exportAgent(agent).sourceTemplate == "Cloud Agent")
    }

    @Test
    func declarativeDocument_carriesSourceTemplate() throws {
        let yaml = """
            version: 1
            agents:
              - name: Invoice Bot
                source_template: Cloud Agent
            """
        let document = try ConfigYAML.decode(yaml)
        #expect(document.agents?.first?.sourceTemplate == "Cloud Agent")
        let encoded = try ConfigYAML.encode(document)
        #expect(encoded.contains("source_template: Cloud Agent"))
    }
}
