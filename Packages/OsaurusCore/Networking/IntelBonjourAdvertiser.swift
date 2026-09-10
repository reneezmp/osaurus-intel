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
            let expectedName = "\(agent.name)@\(agent.id.uuidString)"
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
            name: "\(agent.name)@\(agent.id.uuidString)",
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
