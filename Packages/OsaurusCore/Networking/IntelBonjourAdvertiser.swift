//
//  IntelBonjourAdvertiser.swift
//  OsaurusCore
//
//  The Intel target excludes the upstream BonjourAdvertiser file. Keep the
//  same persisted-agent contract here instead of leaving a label-only stub.
//

#if OSAURUS_INTEL

import Combine
import Foundation

@MainActor
public final class BonjourAdvertiser: NSObject {
    public static let shared = BonjourAdvertiser()
    public static let serviceType = "_osaurus._tcp."
    /// DNS-SD instance names are capped at 63 bytes of UTF-8 (upstream).
    static let maxInstanceNameBytes = 63

    /// Truncate a string to at most `maxBytes` of UTF-8 without splitting a
    /// character (upstream; `MobileConnectAdvertiser` uses it too).
    static func truncateUTF8(_ string: String, maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        var result = ""
        var used = 0
        for char in string {
            let size = String(char).utf8.count
            if used + size > maxBytes { break }
            result.append(char)
            used += size
        }
        return result
    }

    /// `Name@<agent UUID>`, the name cut to fit the 63-byte DNS-SD limit
    /// whole characters at a time, so the UUID browsers key on survives
    /// (upstream). A longer name failed to publish.
    static func instanceName(for agent: Agent) -> String {
        let suffix = "@\(agent.id.uuidString)"
        let budget = maxInstanceNameBytes - suffix.utf8.count
        return truncateUTF8(agent.name, maxBytes: max(0, budget)) + suffix
    }

    private var services: [UUID: NetService] = [:]
    private var currentPort: Int = 0
    private var isAdvertising = false
    private var cancellables: Set<AnyCancellable> = []

    private override init() {
        super.init()
        AgentManager.shared.$agents
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                self?.syncAdvertisements(agents: agents)
            }
            .store(in: &cancellables)
    }

    func startAdvertising(port: Int) {
        currentPort = port
        isAdvertising = true
        syncAdvertisements(agents: AgentManager.shared.agents)
    }

    func stopAdvertising() {
        isAdvertising = false
        for service in services.values {
            service.stop()
        }
        services.removeAll()
    }

    private func syncAdvertisements(agents: [Agent]) {
        guard isAdvertising else { return }

        let enabledIDs = Set(agents.filter(\.bonjourEnabled).map(\.id))
        for id in services.keys where !enabledIDs.contains(id) {
            services[id]?.stop()
            services.removeValue(forKey: id)
        }

        for agent in agents where agent.bonjourEnabled {
            let expectedName = Self.instanceName(for: agent)
            if services[agent.id]?.name != expectedName {
                services[agent.id]?.stop()
                publish(agent: agent)
            }
        }
    }

    private func publish(agent: Agent) {
        let service = NetService(
            domain: "",
            type: Self.serviceType,
            name: Self.instanceName(for: agent),
            port: Int32(currentPort)
        )
        var fields: [String: Data] = [
            "name": Data(agent.name.utf8),
            "id": Data(agent.id.uuidString.utf8)
        ]
        if !agent.description.isEmpty {
            fields["description"] = Data(agent.description.utf8)
        }
        if let address = agent.agentAddress {
            fields["address"] = Data(address.utf8)
        }
        service.setTXTRecord(NetService.data(fromTXTRecord: fields))
        service.delegate = self
        service.publish()
        services[agent.id] = service
    }
}

extension BonjourAdvertiser: NetServiceDelegate {
    public nonisolated func netServiceDidPublish(_ sender: NetService) {
        print("[Bonjour] Advertised agent '\(sender.name)' on port \(sender.port)")
    }

    public nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("[Bonjour] Failed to advertise agent '\(sender.name)': \(errorDict)")
    }
}

#endif
