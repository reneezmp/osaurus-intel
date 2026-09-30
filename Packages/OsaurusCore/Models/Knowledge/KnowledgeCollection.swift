import Foundation

/// Knowledge paths live beside the existing storage roots. Keeping the path
/// declaration with the Intel Knowledge core lets the feature compile before
/// the broader upstream path reconciliation lands.
public extension OsaurusPaths {
    static func knowledge() -> URL {
        root().appendingPathComponent("knowledge", isDirectory: true)
    }

    /// Where a collection cloned from git lives (upstream path). Removed with
    /// the collection; user-chosen folders are never touched.
    static func knowledgeManagedContentDirectory(for id: UUID) -> URL {
        knowledge()
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("content", isDirectory: true)
    }
}

/// A user-owned folder of reference material. The folder is the source of
/// truth; the database and vectors are derived and can always be rebuilt.
public struct KnowledgeCollection: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var folderPath: String
    public var isEnabled: Bool
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    /// Git remote this collection syncs with (upstream; `nil` for plain
    /// local folders). Detected from an existing repo's `origin`. Sync is
    /// always user-triggered; there is no background poll.
    public var gitRemoteURL: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, summary: String = "", folderPath: String,
                isEnabled: Bool = true, includeGlobs: [String] = [], excludeGlobs: [String] = [],
                gitRemoteURL: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.gitRemoteURL = gitRemoteURL
        self.id = id
        self.name = name
        self.summary = summary
        self.folderPath = folderPath
        self.isEnabled = isEnabled
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        folderPath = try c.decode(String.self, forKey: .folderPath)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        includeGlobs = try c.decodeIfPresent([String].self, forKey: .includeGlobs) ?? []
        excludeGlobs = try c.decodeIfPresent([String].self, forKey: .excludeGlobs) ?? []
        gitRemoteURL = try c.decodeIfPresent(String.self, forKey: .gitRemoteURL)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    public var folderURL: URL {
        URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    public var folderExists: Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &directory) && directory.boolValue
    }

    /// Whether the collection folder is a git repository (a `.git` entry).
    public var isGitRepository: Bool {
        FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(".git").path)
    }

    /// Upstream's cached variant for view bodies. Intel's collection folders
    /// are local; the probe is one `stat`, so it reads through.
    public var isGitRepositoryCached: Bool { isGitRepository }

    public func indexPathAllowed(_ relPath: String) -> Bool {
        KnowledgeGlob.matches(relPath, include: includeGlobs, exclude: excludeGlobs)
    }
}

/// The small prompt-facing representation of a granted collection.
public struct KnowledgeGrantDescriptor: Sendable, Equatable {
    public let name: String
    public let summary: String

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

public extension KnowledgeCollection {
    var grantDescriptor: KnowledgeGrantDescriptor { .init(name: name, summary: summary) }
}
