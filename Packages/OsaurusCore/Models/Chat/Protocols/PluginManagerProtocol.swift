//
//  PluginManagerProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on PluginManager.
//

import Foundation

protocol PluginManagerProtocol: AnyObject {
    func notifyArtifactHandlers(artifact: Any) async
}
