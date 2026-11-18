//
//  ConfigIntegrationSections.swift
//  osaurus
//
//  Wave 3c: slash commands and knowledge collections of the declarative
//  document. Upstream also has channel routing here; Intel defers channels
//  (W-channels), so that part is not ported.
//

import Foundation

// MARK: - Slash commands

/// One user-defined template slash command (`~/.osaurus/slash-commands/`).
/// Built-in action commands (/clear, /model, ...), skill-derived entries,
/// and plugin-imported commands are not manageable here.
public struct CommandEntry: Codable, Equatable, Sendable {
    /// Invoke as /name. Match key (case-insensitive).
    public var name: String
    public var description: String?
    /// SF Symbol name shown in the popup.
    public var icon: String?
    /// The prompt text inserted by the command. Required to create.
    public var template: String?

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case name, description, icon, template
    }
}

// MARK: - Knowledge collections

/// One knowledge collection registration (`~/.osaurus/knowledge/collections/`).
/// The registry entry is configuration; the documents inside `folder_path`
/// are content and are never written by apply. Git-cloned collections are
/// created in Settings (interactive clone).
public struct KnowledgeCollectionEntry: Codable, Equatable, Sendable {
    /// Match key (case-insensitive).
    public var name: String
    public var summary: String?
    /// Existing directory holding the collection's documents; ~ expands.
    /// Immutable after create (recreate to move a collection).
    public var folderPath: String?
    public var enabled: Bool?
    /// Glob filters over files inside the folder. Replaces the lists.
    public var includeGlobs: [String]?
    public var excludeGlobs: [String]?

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case name, summary
        case folderPath = "folder_path"
        case enabled
        case includeGlobs = "include_globs"
        case excludeGlobs = "exclude_globs"
    }
}

// MARK: - Channels

