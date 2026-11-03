//
//  IntelAgentKeyPathTests.swift
//  OsaurusCoreTests
//
//  `W-identity-mobile` stage 7 (docs/IDENTITY_MOBILE_INTEL.md): Intel's
//  `Agent` stores upstream's `agentDeviceScope`. Losing it on a save is
//  exactly the "older build dropped the scope" drift upstream repairs, so
//  the field must survive Intel's JSON round trip, and records written
//  before it existed must keep their v1 path.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelAgentKeyPathTests {

    private func agent(index: UInt32?, scope: String?) -> Agent {
        Agent(
            id: UUID(),
            name: "Scoped",
            isBuiltIn: false,
            agentIndex: index,
            agentAddress: index == nil ? nil : "0x00000000000000000000000000000000000000aa",
            agentDeviceScope: scope,
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
    }

    @Test func deviceScope_survivesTheJSONRoundTrip() throws {
        let original = agent(index: 3, scope: "a1b2c3d4")
        let data = try JSONEncoder().encode(original)
        #expect(String(decoding: data, as: UTF8.self).contains("agentDeviceScope"))
        let decoded = try JSONDecoder().decode(Agent.self, from: data)
        #expect(decoded.agentDeviceScope == "a1b2c3d4")
        #expect(decoded.agentKeyPath == .deviceScoped(index: 3, deviceScope: "a1b2c3d4"))
    }

    @Test func recordsWithoutTheField_keepTheLegacyPath() throws {
        let data = try JSONEncoder().encode(agent(index: 5, scope: nil))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "agentDeviceScope")
        let legacy = try JSONDecoder().decode(Agent.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.agentDeviceScope == nil)
        #expect(legacy.agentKeyPath == .legacy(index: 5))
        #expect(agent(index: nil, scope: nil).agentKeyPath == nil)
    }

    /// The two layouts give different addresses for the same index, and the
    /// v2 address depends on the device: two Macs sharing one master never
    /// mint the same address for their agent #0.
    @Test func layouts_differ_andScopeSeparatesDevices() throws {
        let master = Data(repeating: 0x42, count: 32)
        let v1 = try AgentKey.deriveAddress(masterKey: master, path: .legacy(index: 0))
        let m4 = try AgentKey.deriveAddress(masterKey: master, path: .deviceScoped(index: 0, deviceScope: "m4device"))
        let rosy = try AgentKey.deriveAddress(masterKey: master, path: .deviceScoped(index: 0, deviceScope: "rosy0001"))
        #expect(v1 == (try AgentKey.deriveAddress(masterKey: master, index: 0)))
        #expect(v1 != m4)
        #expect(m4 != rosy)
    }
}
