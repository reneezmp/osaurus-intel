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

// `OsaurusRouterWorkspacePerson` is upstream's (OsaurusRouterWorkspaceTypes.swift,
// ported 2026-10-10 with W-credits-ui-sync).

/// Intel stub: no workspaces yet (`W-workspaces-identity-mobile`). A Router
/// summary billed to a workspace pool can't happen without one, so upstream's
/// "refresh that pool's ledger" hook has nothing to do.
@MainActor
final class WorkspacesService {
    static let shared = WorkspacesService()
    func noteWorkspaceBilled(workspaceId: String) {}
}

/// Intel stub: upstream's KPI telemetry is not ported
/// (`W-diagnostics-telemetry`: upstream sends to its own Aptabase keys).
enum FeatureTelemetry {
    static func balanceTopUpInitiated() {}
    static func balanceTopUpSucceeded() {}
}

/// Intel stub: only upstream's `normalized(_:)` (verbatim), which the ported
/// workspace invite type decodes through. The rest of
/// `WorkspacesDeepLinkRouter` (the `osaurus://workspaces/...` handler) comes
/// with `W-workspaces-identity-mobile`; drop this stub then.
enum WorkspacesDeepLinkRouter {
    nonisolated static let host = "workspaces"
    nonisolated static let legacyHost = "teams"

    /// Rewrites a legacy `osaurus://teams/...` link to the current host so
    /// links the router still mints under the old name are displayed and
    /// copied in the new form. Anything else is returned untouched.
    nonisolated static func normalized(_ link: String) -> String {
        let prefix = "osaurus://\(legacyHost)/"
        guard link.lowercased().hasPrefix(prefix) else { return link }
        return "osaurus://\(host)/" + link.dropFirst(prefix.count)
    }
}
