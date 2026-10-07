//
//  ChatModelPickerProviderTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatModelPickerProviderTests {
    private let providerA = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let providerB = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

    private func remote(_ id: String, providerID: UUID, name: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: id, source: .remote(providerName: name, providerId: providerID))
    }

    private func cloud(_ id: String) -> ModelPickerItem {
        remote(id, providerID: RemoteProviderManager.osaurusRouterProviderId, name: "Osaurus")
    }

    @Test func emptyCacheRetainsOnlyInactiveDiscoveryEntries() {
        let groups = ChatModelPickerProvider.groups(from: [])
        #expect(groups.map(\.kind) == [.local, .osaurusCloud])
        #expect(groups.allSatisfy { !$0.isActive && $0.models.isEmpty && $0.availableModels.isEmpty })
    }

    @Test func activeBuiltInsLeadAndConnectionsKeepTheirIncomingOrder() {
        let groups = ChatModelPickerProvider.groups(from: [
            remote("b/model", providerID: providerB, name: "Provider B"),
            cloud("osaurus/model"),
            remote("a/model", providerID: providerA, name: "Provider A"),
            .foundation(),
        ])
        #expect(groups.map(\.title) == ["Local", "Osaurus Cloud", "Provider B", "Provider A"])
        #expect(groups.allSatisfy { $0.isActive })
    }

    @Test func cloudWithoutLocalLeadsConnectionsAndInactiveLocalMovesLast() {
        let groups = ChatModelPickerProvider.groups(from: [
            remote("a/model", providerID: providerA, name: "Provider A"),
            cloud("osaurus/model"),
        ])
        #expect(groups.map(\.kind) == [.osaurusCloud, .connected, .local])
        #expect(groups.last?.isActive == false)
    }

    @Test func inactiveBuiltInsFollowRealConnectionsInLocalThenCloudOrder() {
        let groups = ChatModelPickerProvider.groups(from: [
            remote("a/model", providerID: providerA, name: "Provider A")
        ])
        #expect(groups.map(\.kind) == [.connected, .local, .osaurusCloud])
        #expect(groups.filter { $0.kind == .connected }.count == 1)
    }

    @Test func cloudUsesProviderIdentityEvenWhenRenamedOrImpersonatedByTitle() {
        let realCloud = remote(
            "renamed/model", providerID: RemoteProviderManager.osaurusRouterProviderId, name: "My Cloud"
        )
        let sameTitle = remote("another/model", providerID: providerA, name: "Osaurus")
        let groups = ChatModelPickerProvider.groups(from: [sameTitle, realCloud])
        #expect(groups.first?.kind == .osaurusCloud)
        #expect(groups.first?.models == [realCloud])
        #expect(groups.first?.title == "Osaurus Cloud")
        #expect(groups.first { $0.kind == .connected }?.models == [sameTitle])
    }

    @Test func explicitCloudShortlistIntersectsAvailableModelsWithoutAddingStaleIDs() {
        let chosen = cloud("osaurus/chosen")
        let hidden = cloud("osaurus/other")
        let otherProvider = remote("osaurus/chosen", providerID: providerA, name: "Separate Route")
        let groups = ChatModelPickerProvider.groups(
            from: [hidden, otherProvider, chosen],
            cloudModelIDs: [chosen.id, "osaurus/no-longer-available"]
        )
        let cloudGroup = groups.first { $0.isOsaurusCloud }
        #expect(cloudGroup?.models == [chosen])
        #expect(cloudGroup?.availableModels == [chosen, hidden])
        #expect(groups.first { $0.kind == .connected }?.models == [otherProvider])
    }

    @Test func nilAndEmptyCloudShortlistsHaveDifferentMeaning() {
        let model = cloud("osaurus/model")
        let all = ChatModelPickerProvider.groups(from: [model])
        let none = ChatModelPickerProvider.groups(from: [model], cloudModelIDs: [])
        #expect(all.first?.models == [model])
        #expect(all.first?.isActive == true)
        #expect(none.map(\.kind) == [.local, .osaurusCloud])
        #expect(none.last?.models.isEmpty == true)
        #expect(none.last?.availableModels == [model])
        #expect(none.last?.isActive == false)
    }

    // Intel: upstream's last two cases cover MLX-format, image-generation and
    // Claude Code sources Intel's picker cache doesn't have. Intel versions:

    @Test func localHoldsFoundationFirstThenSortedLocalModels() {
        let zeta = ModelPickerItem(id: "local/zeta", displayName: "Zeta", source: .local)
        let alpha = ModelPickerItem(id: "local/alpha", displayName: "Alpha", source: .local)
        let groups = ChatModelPickerProvider.groups(from: [zeta, .foundation(), alpha])
        #expect(groups.first?.kind == .local)
        #expect(groups.first?.models.map(\.id) == ["foundation", "local/alpha", "local/zeta"])
    }

    @Test func sameNamedConnectionsStayDistinctByProviderID() {
        let a = remote("x/model", providerID: providerA, name: "Claude Code")
        let b = remote("y/model", providerID: providerB, name: "Claude Code")
        let groups = ChatModelPickerProvider.groups(from: [a, b])
        let connected = groups.filter { $0.kind == .connected }
        #expect(connected.count == 2)
        #expect(connected.map(\.models) == [[a], [b]])
    }
}
