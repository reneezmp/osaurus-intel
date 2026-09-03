//
//  ProjectManager.swift
//  osaurus
//
//  Manages project lifecycle - loading, creating, updating, deleting
//

import Combine
import Foundation

extension Notification.Name {
    /// Posted after a project is created, updated, or deleted.
    /// `userInfo["projectId"]` is the affected project's UUID.
    static let projectsChanged = Notification.Name("projectsChanged")
    /// Posted after a chat session's `projectId` changes (moved into a
    /// project, moved out, or its project was deleted). `userInfo["sessionId"]`
    /// + `userInfo["projectId"]` (Any, may be nil) on a move, or
    /// `userInfo["clearedProjectId"]` when a whole project was deleted — lets
    /// an already-open `ChatWindowState`/`ChatSession` for that chat drop its
    /// stale project reference instead of continuing to inject dead
    /// instructions on the next compose.
    static let chatSessionProjectDidChange = Notification.Name("chatSessionProjectDidChange")
}

/// Manages all projects. Sessions reference projects by `projectId`;
/// membership itself lives on `ChatSessionData` (see `ChatSessionsManager`).
@MainActor
public final class ProjectManager: ObservableObject {
    public static let shared = ProjectManager()

    @Published public private(set) var projects: [Project] = []

    /// One-shot request to reveal the sidebar's Projects tab — set by the
    /// "What's New" projects CTA. `ChatSessionSidebar` observes this, switches
    /// its lens to Projects, and resets it to false.
    @Published public var pendingRevealProjectsTab: Bool = false

    private init() {
        projects = ProjectStore.loadAll()
    }

    public func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    @discardableResult
    public func create(name: String) -> Project {
        let project = Project(name: name)
        ProjectStore.save(project)
        projects = ProjectStore.loadAll()
        notify(project.id)
        return project
    }

    public func update(_ project: Project) {
        var updated = project
        updated.updatedAt = Date()
        ProjectStore.save(updated)
        projects = ProjectStore.loadAll()
        notify(project.id)
    }

    /// Deletes the project record. Callers should go through
    /// `ChatSessionsManager.shared.deleteProject(id:)` instead so member
    /// sessions get their `projectId` cleared first.
    public func delete(id: UUID) {
        guard ProjectStore.delete(id: id) else { return }
        projects = ProjectStore.loadAll()
        notify(id)
    }

    private func notify(_ id: UUID) {
        NotificationCenter.default.post(
            name: .projectsChanged, object: nil, userInfo: ["projectId": id])
    }
}
