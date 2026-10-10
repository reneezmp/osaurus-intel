//
//  IntelWorkspaceRosterStub.swift
//  OsaurusCore — Intel fork
//
//  Stand-in for upstream's `WorkspaceRosterStore` (Services/Router) and
//  `OsaurusRouterWorkspacePerson.shortWallet`, so upstream's dispatch-target
//  model (`AgentDispatchTarget`, `AgentTargetResolver`) and the trigger
//  editors' `WorkspaceAgentPickerOption` compile verbatim (2026-10-10, with
//  the schedule history port). Intel has no workspaces yet
//  (W-workspaces-identity-mobile): the roster is always empty, so no shared
//  workspace agent is ever offered and every schedule targets a local agent.
//  Replace with upstream's store when workspaces land.
//

import Foundation

@MainActor
final class WorkspaceRosterStore: ObservableObject {
    static let shared = WorkspaceRosterStore()

    enum Presence: Equatable, Sendable {
        case online, offline, unknown
    }

    struct Owner: Equatable, Sendable {
        let friendlyName: String?
    }

    struct RosterAgent: Equatable, Sendable {
        let agentAddress: String
        let displayName: String?
        let description: String?
        let owner: Owner?
    }

    struct Workspace: Equatable, Sendable {
        let name: String
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        let workspace: Workspace
        let agents: [RosterAgent]
    }

    @Published private(set) var rosters: [Entry] = []

    private init() {}

    func isHostedHere(address: String) -> Bool { false }
    func presence(forAddress address: String, workspaceId: String) -> Presence { .unknown }
    func agent(forAddress address: String, workspaceId: String) -> RosterAgent? { nil }
    func lastKnownName(forAddress address: String) -> String? { nil }
    /// Editors call these while open so presence stays fresh (no-ops here).
    func beginObserving() {}
    func endObserving() {}
}

enum OsaurusRouterWorkspacePerson {
    /// Upstream `OsaurusRouterWorkspacePerson.shortWallet`.
    static func shortWallet(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }
}
