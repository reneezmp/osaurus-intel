//
//  RemoteProviderManagerProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on RemoteProviderManager.
//

import Foundation

protocol RemoteProviderManagerProtocol: AnyObject {
    var configuration: RemoteProviderConfigInfoProtocol { get }
    func isEphemeral(id: UUID) -> Bool
    func updateProvider(_ provider: any RemoteProviderInfoProtocol, apiKey: String?)
    func connect(providerId: UUID) async throws
    func addProvider(_ provider: any RemoteProviderInfoProtocol, apiKey: String?, isEphemeral: Bool)
}

protocol RemoteProviderConfigInfoProtocol {
    var providers: [any RemoteProviderInfoProtocol] { get }
}

protocol RemoteProviderInfoProtocol: Identifiable, Sendable {
    var id: UUID { get }
    var name: String { get }
    var host: String { get set }
    var providerProtocol: RemoteProviderProtocolKind { get set }
    var port: Int? { get set }
    var enabled: Bool { get set }
    var providerType: Any? { get }
    var remoteAgentId: UUID? { get }
}

enum RemoteProviderProtocolKind: Sendable { case http, https }
