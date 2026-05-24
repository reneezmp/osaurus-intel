//
//  RemoteProviderManagerProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on RemoteProviderManager.
//

import Foundation

protocol RemoteProviderManagerProtocol: AnyObject {
    var configuration: RemoteProviderConfigInfoProtocol { get }
    func isEphemeral(id: String) -> Bool
    func updateProvider(_ provider: any RemoteProviderInfoProtocol)
    func connect(providerId: String) async throws
    func addProvider(_ provider: any RemoteProviderInfoProtocol, isEphemeral: Bool)
}

protocol RemoteProviderConfigInfoProtocol {
    var providers: [any RemoteProviderInfoProtocol] { get }
}

protocol RemoteProviderInfoProtocol: Identifiable, Sendable {
    var id: String { get }
    var name: String { get }
    var host: String { get }
}
