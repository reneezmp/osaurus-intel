//
//  SkillManager+Import.swift
//  osaurus
//
//  Intel fork: upstream Classic's skill import / export surface
//  (`W-skills-plugins-import`) on Intel's own `SkillManager` (declared in
//  `Models/Chat/IntelConformers/IntelDataConformers.swift`, which holds the
//  stored batching state). Bodies are Classic's, minus the
//  `SkillSearchService` indexing calls (Intel doesn't compile that service).
//  Covers `SkillFileError`, .zip import/export through `SkillImportPolicy`
//  (#1477, #1840), overwrite-aware markdown / zip / directory installs,
//  plugin-skill helpers and `batchUpdates`.
//

import Foundation

public enum SkillFileError: Error, LocalizedError, Sendable {
    case cannotModifyBuiltIn
    case cannotModifyPluginSkill
    case skillNotFound
    case exportFailed
    case invalidSkillArchive
    case archiveTooLarge(limitBytes: Int64)
    case archiveEntryTooLarge(path: String, limitBytes: Int64)
    case archiveEntryLimitExceeded(limit: Int)
    case archiveEntryTooDeep(path: String, limit: Int)
    case archiveEntryEscapes(path: String)
    case archiveEntryUnsupported(path: String)
    case archiveListingFailed(String)
    case skillAlreadyExists(name: String)
    case skillImportCopyFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .cannotModifyBuiltIn: return L("Cannot modify built-in skills")
        case .cannotModifyPluginSkill: return L("Cannot modify plugin-provided skills")
        case .skillNotFound: return L("Skill not found")
        case .exportFailed: return L("Failed to export skill")
        case .invalidSkillArchive: return L("Invalid skill archive - SKILL.md not found")
        case .archiveTooLarge(let limitBytes):
            return L("Skill archive is larger than the \(Self.formatBytes(limitBytes)) limit")
        case .archiveEntryTooLarge(let path, let limitBytes):
            return L("Skill archive entry \"\(path)\" is larger than the \(Self.formatBytes(limitBytes)) limit")
        case .archiveEntryLimitExceeded(let limit):
            return L("Skill archive contains more than \(limit) entries")
        case .archiveEntryTooDeep(let path, let limit):
            return L("Skill archive entry \"\(path)\" is deeper than the \(limit)-level limit")
        case .archiveEntryEscapes(let path):
            return L("Skill archive entry \"\(path)\" escapes the archive root")
        case .archiveEntryUnsupported(let path):
            return L("Skill archive entry \"\(path)\" is not a regular file or directory")
        case .archiveListingFailed(let details):
            let suffix = details.isEmpty ? "" : ": \(details)"
            return L("Could not inspect skill archive\(suffix)")
        case .skillAlreadyExists(let name):
            return L("A skill named \"\(name)\" already exists")
        case .skillImportCopyFailed(let path, let reason):
            return L("Could not import skill file \"\(path)\": \(reason)")
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes / (1024 * 1024)) MB"
    }
}

extension SkillManager {
    // MARK: - Batch Updates

    var isBatching: Bool { batchDepth > 0 }

    /// Run `body` as a bulk mutation: per-operation refreshes are suppressed
    /// and `skills` is reloaded once when the outermost batch finishes. The
    /// Claude plugin installer otherwise saves 170+ skills one-by-one, making
    /// the Skills view flash as it re-renders the list on every save.
    @discardableResult
    public func batchUpdates<T>(_ body: () async -> T) async -> T {
        batchDepth += 1
        let result = await body()
        batchDepth -= 1
        if batchDepth == 0 {
            batchStagedSkills.removeAll()
            await refresh()
        }
        return result
    }

    /// `refresh()` unless a bulk batch is in flight (see `batchUpdates`).
    func refreshUnlessBatching() async {
        guard !isBatching else { return }
        await refresh()
    }

    // MARK: - Plugin skill lookup

    /// Returns all skills belonging to a specific plugin
    public func pluginSkills(for pluginId: String) -> [Skill] {
        skills.filter { $0.pluginId == pluginId }
    }

    // MARK: - Import/Export

    @discardableResult
    public func importSkill(from data: Data) async throws -> Skill {
        var skill = try Skill.importFromJSON(data)
        // Fresh id / non-built-in flags on import, but KEEP the author's
        // `keywords` — they are the discovery signal `SkillSearchService`
        // indexes, and dropping them here silently degraded
        // `capabilities_discover` recall for every imported skill.
        skill = Skill(
            name: skill.name,
            description: skill.description,
            version: skill.version,
            author: skill.author,
            category: skill.category,
            keywords: skill.keywords,
            instructions: skill.instructions
        )
        await SkillStore.save(skill)
        await refresh()
        return skill
    }

    @discardableResult
    public func importSkillFromMarkdown(_ content: String) async throws -> Skill {
        try await importSkillFromMarkdown(content, overwriteExisting: false)
    }

    @discardableResult
    public func importSkillFromMarkdown(_ content: String, overwriteExisting: Bool) async throws -> Skill {
        var skill = try Skill.parseAnyFormat(from: content)
        // Keep frontmatter `keywords` — see `importSkill(from:)`.
        skill = Skill(
            name: skill.name,
            description: skill.description,
            version: skill.version,
            author: skill.author,
            category: skill.category,
            keywords: skill.keywords,
            instructions: skill.instructions
        )
        try Self.installImportedSkill(skill, from: nil, overwriteExisting: overwriteExisting)
        await refresh()
        return skill
    }

    /// Import multiple skills at once (batch import from GitHub)
    @discardableResult
    public func importSkillsFromMarkdown(_ skills: [Skill]) async -> [Skill] {
        var imported: [Skill] = []
        for parsedSkill in skills {
            // Keep frontmatter `keywords` — see `importSkill(from:)`.
            let skill = Skill(
                name: parsedSkill.name,
                description: parsedSkill.description,
                version: parsedSkill.version,
                author: parsedSkill.author,
                category: parsedSkill.category,
                keywords: parsedSkill.keywords,
                instructions: parsedSkill.instructions
            )
            await SkillStore.save(skill)
            imported.append(skill)
        }
        if !imported.isEmpty {
            await refresh()
        }
        return imported
    }

    /// Import skills that came from a plugin and preserve their `pluginId` so
    /// they can be grouped, re-registered on update, and uninstalled in bulk
    /// via `unregisterPluginSkills(pluginId:)`.
    ///
    /// Unlike `importSkillsFromMarkdown(_:)` this path:
    /// - Keeps `pluginId` (required for grouping/uninstall).
    /// - Keeps `category` and `keywords`.
    /// - Reuses the existing skill id when re-importing the same plugin skill.
    @discardableResult
    public func importSkillsPreservingPluginId(_ skills: [Skill]) async -> [Skill] {
        var imported: [Skill] = []
        for parsedSkill in skills {
            let existing = self.skills.first(where: {
                $0.pluginId == parsedSkill.pluginId && $0.name == parsedSkill.name
            })

            let skill = Skill(
                id: existing?.id ?? UUID(),
                name: parsedSkill.name,
                description: parsedSkill.description,
                version: parsedSkill.version,
                author: parsedSkill.author,
                category: parsedSkill.category,
                keywords: parsedSkill.keywords,
                instructions: parsedSkill.instructions,
                isBuiltIn: false,
                createdAt: existing?.createdAt ?? Date(),
                updatedAt: Date(),
                pluginId: parsedSkill.pluginId
            )
            await SkillStore.save(skill)
            if isBatching { batchStagedSkills[skill.id] = skill }
            imported.append(skill)
        }
        if !imported.isEmpty {
            await refreshUnlessBatching()
        }
        return imported
    }

    public func exportSkill(_ skill: Skill) throws -> Data {
        try skill.exportToJSON()
    }

    public func exportSkillAsAgentSkills(_ skill: Skill) -> String {
        skill.toAgentSkillsFormat()
    }

    // MARK: - File Management

    public func addReference(to skillId: UUID, name: String, content: Data) async throws {
        guard let skill = skill(for: skillId), !skill.isBuiltIn else {
            throw SkillFileError.cannotModifyBuiltIn
        }
        try await SkillStore.addReference(to: skill, name: name, content: content)
        await refreshUnlessBatching()

    }

    public func addAsset(to skillId: UUID, name: String, content: Data) async throws {
        guard let skill = skill(for: skillId), !skill.isBuiltIn else {
            throw SkillFileError.cannotModifyBuiltIn
        }
        try await SkillStore.addAsset(to: skill, name: name, content: content)
        await refreshUnlessBatching()

    }

    public func removeFile(from skillId: UUID, relativePath: String) async throws {
        guard let skill = skill(for: skillId), !skill.isBuiltIn else {
            throw SkillFileError.cannotModifyBuiltIn
        }
        try await SkillStore.removeFile(from: skill, relativePath: relativePath)
        await refresh()

    }

    public func readFile(from skillId: UUID, relativePath: String) async throws -> Data {
        guard let skill = skill(for: skillId) else {
            throw SkillFileError.skillNotFound
        }
        return try await SkillStore.readFile(from: skill, relativePath: relativePath)
    }

    public func skillDirectory(for skillId: UUID) -> URL? {
        guard let skill = skill(for: skillId) else { return nil }
        return SkillStore.skillDirectory(for: skill)
    }

    // MARK: - ZIP Export/Import

    public func exportSkillAsZip(_ skill: Skill) async throws -> URL {
        try Task.checkCancellation()
        let skillDir = SkillStore.skillDirectory(for: skill)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(skill.xplaceholder_agentSkillsNamex).zip"
        )
        try? FileManager.default.removeItem(at: zipURL)
        do {
            try await FileManager.default.zipItem(at: skillDir, to: zipURL)
            try Task.checkCancellation()
        } catch {
            if (error as? SkillArchiveProcessRunnerError) != .processTerminationIncomplete {
                try? FileManager.default.removeItem(at: zipURL)
            }
            throw error
        }
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw SkillFileError.exportFailed
        }
        return zipURL
    }

    @discardableResult
    public func importSkillFromZip(_ zipURL: URL) async throws -> Skill {
        let result = try await importSkillFromZip(zipURL, overwriteExisting: false)
        return result.skill
    }

    @discardableResult
    public func importSkillFromZip(
        _ zipURL: URL,
        overwriteExisting: Bool,
        policy: SkillImportPolicy = .default
    ) async throws -> SkillImportResult {
        let result = try await Self.performZipImport(
            zipURL,
            overwriteExisting: overwriteExisting,
            policy: policy
        )

        await refresh()
        return result
    }

    /// Installs an unpacked skill folder (`SKILL.md` plus optional
    /// `references/` and `assets/`) the same way a zip import lays it out.
    /// Passing `replacing` overwrites that skill in place and keeps its id,
    /// so search entries and anything holding the id stay attached.
    @discardableResult
    public func installSkill(fromDirectory directory: URL, replacing existing: Skill? = nil) async throws -> Skill {
        if let existing, existing.isBuiltIn { throw SkillFileError.cannotModifyBuiltIn }
        if let existing, existing.isFromPlugin { throw SkillFileError.cannotModifyPluginSkill }
        let skill = try await Self.performDirectoryInstall(directory, replacing: existing)
        await refresh()
        return skill
    }

    nonisolated private static func performDirectoryInstall(
        _ directory: URL, replacing existing: Skill?
    ) async throws -> Skill {
        let markdown = directory.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: markdown.path) else { throw SkillFileError.invalidSkillArchive }
        let content = try String(contentsOf: markdown, encoding: .utf8)
        let parsed = try Skill.parseAnyFormat(from: content)
        let skill = Skill(
            id: existing?.id ?? UUID(),
            name: parsed.name,
            description: parsed.description,
            version: parsed.version,
            author: parsed.author,
            category: parsed.category,
            instructions: parsed.instructions,
            createdAt: existing?.createdAt ?? Date(),
            directoryName: existing?.directoryName ?? parsed.xplaceholder_agentSkillsNamex
        )
        try installImportedSkill(skill, from: directory, overwriteExisting: existing != nil)
        return skill
    }

    /// Nonisolated async work runs off the main actor while preserving the
    /// caller task's cancellation state through validation and extraction.
    nonisolated private static func performZipImport(
        _ zipURL: URL,
        overwriteExisting: Bool,
        policy: SkillImportPolicy
    ) async throws -> SkillImportResult {
        try Task.checkCancellation()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        var cleanupTransferredToReaper = false
        defer {
            if !cleanupTransferredToReaper {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        try policy.validateArchiveBeforeExtraction(zipURL)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        do {
            try await FileManager.default.unzipItem(at: zipURL, to: tempDir)
        } catch {
            if (error as? SkillArchiveProcessRunnerError) == .processTerminationIncomplete {
                cleanupTransferredToReaper = true
            }
            throw error
        }

        try Task.checkCancellation()
        let importPlan = try policy.scanExtractedTree(at: tempDir)
        let content = try String(contentsOf: importPlan.skillMarkdownURL, encoding: .utf8)
        let parsed = try Skill.parseAnyFormat(from: content)
        try Task.checkCancellation()

        let skill = Skill(
            name: parsed.name,
            description: parsed.description,
            version: parsed.version,
            author: parsed.author,
            category: parsed.category,
            instructions: parsed.instructions,
            directoryName: parsed.xplaceholder_agentSkillsNamex
        )

        try Self.installImportedSkill(
            skill,
            from: importPlan.skillRootURL,
            overwriteExisting: overwriteExisting,
            stagingBase: tempDir
        )

        let notes: [String]
        if importPlan.ignoredSkillMarkdownPaths.isEmpty {
            notes = []
        } else {
            let ignored = importPlan.ignoredSkillMarkdownPaths.joined(separator: ", ")
            notes = [
                L("Imported \(importPlan.selectedSkillMarkdownPath); ignored additional SKILL.md files: \(ignored)")
            ]
        }
        return SkillImportResult(skill: skill, notes: notes)
    }

    nonisolated private static func installImportedSkill(
        _ skill: Skill,
        from sourceSkillRoot: URL?,
        overwriteExisting: Bool,
        stagingBase: URL = FileManager.default.temporaryDirectory
    ) throws {
        let fileManager = FileManager.default
        let destination = SkillStore.skillDirectory(for: skill)
        let stage = stagingBase.appendingPathComponent("skill-import-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stage) }

        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        try skill.toAgentSkillsFormatWithId().write(
            to: stage.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        if let sourceSkillRoot {
            for subdirectory in ["references", "assets"] {
                let source = sourceSkillRoot.appendingPathComponent(subdirectory, isDirectory: true)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) {
                    guard isDirectory.boolValue else {
                        throw SkillFileError.skillImportCopyFailed(
                            path: subdirectory,
                            reason: L("Expected directory")
                        )
                    }
                    try copyImportedSubdirectory(
                        named: subdirectory,
                        from: source,
                        to: stage.appendingPathComponent(subdirectory, isDirectory: true)
                    )
                }
            }
        }

        try installStagedSkillDirectory(
            stage,
            to: destination,
            skillName: skill.name,
            overwriteExisting: overwriteExisting
        )
    }

    nonisolated private static func copyImportedSubdirectory(
        named name: String,
        from source: URL,
        to destination: URL
    ) throws {
        let fileManager = FileManager.default
        let sourceRoot = source.standardizedFileURL
        let destinationRoot = destination.standardizedFileURL
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        guard
            let enumerator = fileManager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        else {
            throw SkillFileError.skillImportCopyFailed(path: name, reason: L("Could not inspect directory"))
        }

        for case let entry as URL in enumerator {
            let relativePath = try relativePath(for: entry, in: sourceRoot)
            let importPath = "\(name)/\(relativePath)"
            do {
                let values = try entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isSymbolicLink != true else {
                    throw SkillFileError.archiveEntryUnsupported(path: importPath)
                }

                let target = destinationRoot.appendingPathComponent(relativePath)
                try ensureContained(target, in: destinationRoot)

                if values.isDirectory == true {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } else if values.isRegularFile == true {
                    try fileManager.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: entry, to: target)
                } else {
                    throw SkillFileError.archiveEntryUnsupported(path: importPath)
                }
            } catch let error as SkillFileError {
                throw error
            } catch {
                throw SkillFileError.skillImportCopyFailed(path: importPath, reason: error.localizedDescription)
            }
        }
    }

    nonisolated private static func installStagedSkillDirectory(
        _ stage: URL,
        to destination: URL,
        skillName: String,
        overwriteExisting: Bool
    ) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if exists {
            guard isDirectory.boolValue else {
                throw SkillFileError.skillImportCopyFailed(
                    path: destination.lastPathComponent,
                    reason: L("Destination exists and is not a directory")
                )
            }
            guard overwriteExisting else {
                throw SkillFileError.skillAlreadyExists(name: skillName)
            }
        }

        if !exists {
            try fileManager.moveItem(at: stage, to: destination)
            return
        }

        let backup = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).import-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: stage, to: destination)
            try? fileManager.removeItem(at: backup)
        } catch {
            try? fileManager.removeItem(at: destination)
            try? fileManager.moveItem(at: backup, to: destination)
            throw SkillFileError.skillImportCopyFailed(
                path: destination.lastPathComponent,
                reason: error.localizedDescription
            )
        }
    }

    nonisolated private static func relativePath(for fileURL: URL, in baseDirectory: URL) throws -> String {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        guard fileComponents.count > baseComponents.count,
            Array(fileComponents.prefix(baseComponents.count)) == baseComponents
        else {
            throw SkillFileError.archiveEntryEscapes(path: fileURL.path)
        }
        return fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    nonisolated private static func ensureContained(_ fileURL: URL, in baseDirectory: URL) throws {
        let fileComponents = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count >= baseComponents.count,
            Array(fileComponents.prefix(baseComponents.count)) == baseComponents
        else {
            throw SkillFileError.archiveEntryEscapes(path: fileURL.path)
        }
    }
}

// MARK: - FileManager ZIP Extension

extension FileManager {
    func unzipItem(
        at sourceURL: URL,
        to destinationURL: URL,
        configuration: SkillArchiveProcessConfiguration = .default
    ) async throws {
        try Task.checkCancellation()
        let result = try SkillArchiveProcessRunner.run(
            executablePath: "/usr/bin/unzip",
            arguments: ["-o", "-q", "-d", destinationURL.path, "--", sourceURL.path],
            timeoutSeconds: 60,
            configuration: configuration.withDeferredCleanupURL(destinationURL)
        )
        try Task.checkCancellation()

        if result.timedOut {
            throw NSError(
                domain: "FileManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unzip timed out after 60 seconds"]
            )
        }

        if result.terminationStatus != 0 {
            throw NSError(
                domain: "FileManager",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Unzip failed: \(result.output)"]
            )
        }
    }

    func zipItem(
        at sourceURL: URL,
        to destinationURL: URL,
        configuration: SkillArchiveProcessConfiguration = .default
    ) async throws {
        try Task.checkCancellation()
        let result = try SkillArchiveProcessRunner.run(
            executablePath: "/usr/bin/zip",
            arguments: ["-r", "-q", "-nw", destinationURL.path, "--", sourceURL.lastPathComponent],
            currentDirectoryURL: sourceURL.deletingLastPathComponent(),
            timeoutSeconds: 120,
            configuration: configuration.withDeferredCleanupURL(destinationURL)
        )
        try Task.checkCancellation()

        if result.timedOut {
            throw NSError(
                domain: "FileManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Zip timed out after 120 seconds"]
            )
        }

        if result.terminationStatus != 0 {
            throw NSError(
                domain: "FileManager",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Zip failed: \(result.output)"]
            )
        }
    }
}
