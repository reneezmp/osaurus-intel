//
//  IntelConfigExportRoundTripTests.swift
//  OsaurusCoreTests
//
//  Intel's slice of the declarative configuration model (W-declarative-config
//  stage 1): the exporter's document survives YAML and JSON round trips,
//  never carries a secret value, and the strict decoder rejects the upstream
//  sections Intel does not have (channels, harness runtimes, local models).
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct IntelConfigExportRoundTripTests {

    @Test
    func exportedDocument_roundTripsThroughYAMLAndJSON() throws {
        let document = ConfigExporter.export(sections: nil)
        #expect(document.version == ConfigManifest.version)

        let yaml = try ConfigYAML.encode(document)
        let fromYAML = try ConfigYAML.decode(yaml)
        #expect(fromYAML == document)

        let json = try ConfigJSON.encode(document)
        let fromJSON = try ConfigYAML.decode(json)
        #expect(fromJSON == document)
    }

    @Test
    func exportedYAML_neverContainsSecretValues() throws {
        let yaml = try ConfigYAML.encode(ConfigExporter.export(sections: nil)).lowercased()
        for forbidden in ["api_key:", "access_token", "refresh_token", "password", "bearer "] {
            #expect(!yaml.contains(forbidden), "exported YAML contains `\(forbidden)`")
        }
    }

    @Test
    func sectionFilter_exportsOnlyTheAskedSection() {
        let document = ConfigExporter.export(sections: [.memory])
        #expect(document.declaredSections == [.memory])
    }

    @Test(arguments: ["channels", "harness_runtimes", "models"])
    func sectionsIntelLacks_areRejectedWithAnActionableError(section: String) {
        let yaml = "version: 1\n\(section): []\n"
        do {
            _ = try ConfigYAML.decode(yaml)
            Issue.record("`\(section)` should not decode on Intel")
        } catch let error as ConfigYAMLError {
            #expect(error.messages.contains { $0.contains(section) })
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func providerSecrets_travelOnlyAsReferences() throws {
        let yaml = """
            version: 1
            providers:
              - name: Anthropic
                provider: anthropic
                api_key_ref: env:ANTHROPIC_API_KEY
            """
        let document = try ConfigYAML.decode(yaml)
        let entry = try #require(document.providers?.first)
        #expect(entry.apiKeyRef == "env:ANTHROPIC_API_KEY")
        let again = try ConfigYAML.encode(document)
        #expect(again.contains("env:ANTHROPIC_API_KEY"))
    }
}
