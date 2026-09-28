//
//  AgentBundleService.swift
//  osaurus
//
//  Per-agent encrypted export/import bundle (spec §11.1), Intel port of
//  upstream's AgentBundleService (docs/AGENT_DATABASE_INTEL_PLAN.md, Phase 3).
//  The bundle is a tar archive (`.osaurus-agent`) containing:
//
//   - `manifest.json`     — bundle metadata + key-wrapping ciphertext.
//   - `agent.json`        — the agent's JSON body.
//   - `db.sqlite`         — the agent's SQLCipher database, re-encrypted with
//                           a bundle-local key on export.
//   - `schema.sql`        — human-readable schema dump.
//   - `views/<name>.sql`  — saved-view definitions.
//   - `migrations/*.sql`  — migration files.
//   - `runs/`             — JSON run traces (best effort; skipped if absent).
//
//  Key wrapping (unchanged from upstream, so bundles move between Intel and
//  Apple Silicon builds): a fresh 256-bit bundle key encrypts `db.sqlite`; the
//  bundle key is sealed with AES-GCM under a PBKDF2-SHA256 key (600k
//  iterations, 16-byte salt) derived from the user's passphrase.
//
//  Intel adaptations:
//   - Databases are always SQLCipher with the shared storage key, so the
//     copy is made with `sqlcipher_export` (the StorageMigrator pattern)
//     instead of upstream's StorageFormatConverter/StorageEncryptionPolicy.
//     The live file is only read.
//   - Agents are loaded and saved through the Intel `AgentManager`.
//   - Intel agents carry no device scope, so an imported address is kept
//     unless another local agent already owns that address or index; then
//     it is cleared (assign a new one in Identity — no surprise auth prompt).
//   - Import refuses symlinks and anything that isn't a plain file or
//     folder in the unpacked bundle: a crafted archive must not be able to
//     plant a link that later redirects the agent's database writes.
//   - The review preview names the local agent it would replace and the
//     riskier abilities the bundled agent arrives with.
//

import CommonCrypto
import CryptoKit
import Foundation
import OsaurusSQLCipher

public enum AgentBundleError: Error, LocalizedError {
    case agentNotFound
    case readFailed(String)
    case writeFailed(String)
    case archiveFailed(String)
    case passphraseTooShort
    case decryptFailed(String)
    case manifestInvalid(String)
    case rekeyFailed(String)
    case unsafeBundle(String)

    public var errorDescription: String? {
        switch self {
        case .agentNotFound: return "Agent not found."
        case .readFailed(let m): return "Bundle read failed: \(m)"
        case .writeFailed(let m): return "Bundle write failed: \(m)"
        case .archiveFailed(let m): return "Bundle archive failed: \(m)"
        case .passphraseTooShort: return "Passphrase must be at least 8 characters."
        case .decryptFailed(let m): return "Could not unlock the bundle: \(m)"
        case .manifestInvalid(let m): return "Bundle manifest is invalid: \(m)"
        case .rekeyFailed(let m): return "Could not re-encrypt the database: \(m)"
        case .unsafeBundle(let m): return "This bundle was refused: \(m)"
        }
    }
}

/// Format-tag stamped into the manifest. Bump when the on-disk shape changes
/// so old/new versions can refuse incompatible bundles.
public enum AgentBundleFormat {
    public static let currentVersion: Int = 1
}

/// Manifest shape, byte-compatible with upstream so bundles are portable.
public struct AgentBundleManifest: Codable, Sendable {
    public var formatVersion: Int
    public var exportedAt: Date
    public var agentId: UUID
    public var agentName: String
    public var agentDescription: String
    public var schemaTables: Int
    public var savedViews: Int
    /// PBKDF2 salt, base64-encoded.
    public var kdfSalt: String
    /// PBKDF2 iteration count.
    public var kdfIterations: Int
    /// AES-GCM nonce that sealed the bundle key, base64-encoded.
    public var keyNonce: String
    /// AES-GCM ciphertext of the bundle key, base64-encoded.
    public var keyCiphertext: String
    /// AES-GCM auth tag, base64-encoded.
    public var keyTag: String
}

public actor AgentBundleService {
    public static let shared = AgentBundleService()

    /// Default PBKDF2 cost (matches upstream).
    public static let kdfIterations = 600_000
    /// Refuse absurd iteration counts from a crafted manifest (CPU burn).
    static let maxKdfIterations = 10_000_000

    /// Top-level entries activation moves into place; anything else in a
    /// bundle is ignored.
    static let knownEntries: Set<String> = [
        "manifest.json", "agent.json", "db.sqlite", "schema.sql", "views", "migrations", "runs",
    ]

    private init() {}

    // MARK: - Export

    public struct ExportResult: Sendable {
        public var bundleURL: URL
        public var manifest: AgentBundleManifest
    }

    /// Build a `.osaurus-agent` bundle for `agentId`, sealed with
    /// `passphrase`, into `destinationDirectory` as `<agent-name>.osaurus-agent`.
    public func exportBundle(
        agentId: UUID,
        passphrase: String,
        destinationDirectory: URL
    ) async throws -> ExportResult {
        guard passphrase.count >= 8 else { throw AgentBundleError.passphraseTooShort }
        let agent: Agent = try await MainActor.run {
            guard let agent = AgentManager.shared.agent(for: agentId), !agent.isBuiltIn else {
                throw AgentBundleError.agentNotFound
            }
            return agent
        }

        let scratch = try makeScratchDirectory(prefix: "osaurus-agent-export-")
        defer { try? FileManager.default.removeItem(at: scratch) }

        try writeJSON(agent, to: scratch.appendingPathComponent("agent.json"))

        let bundleKey = SymmetricKey(size: .bits256)
        try exportAgentDatabase(
            agentId: agentId,
            to: scratch.appendingPathComponent("db.sqlite"),
            bundleKey: bundleKey
        )

        let agentDir = OsaurusPaths.agentDirectory(for: agentId)
        try copyIfExists(
            from: agentDir.appendingPathComponent("schema.sql"),
            to: scratch.appendingPathComponent("schema.sql"))
        try copyDirIfExists(
            from: OsaurusPaths.agentViewsDirectory(for: agentId),
            to: scratch.appendingPathComponent("views"))
        try copyDirIfExists(
            from: OsaurusPaths.agentMigrationsDirectory(for: agentId),
            to: scratch.appendingPathComponent("migrations"))
        try copyDirIfExists(
            from: OsaurusPaths.agentRunsDirectory(for: agentId),
            to: scratch.appendingPathComponent("runs"))

        let (tables, views) =
            (try? readBundleStats(
                dbPath: scratch.appendingPathComponent("db.sqlite").path, key: bundleKey)) ?? (0, 0)

        let (salt, kekData) = try deriveKEK(passphrase: passphrase)
        let sealed = try AES.GCM.seal(
            bundleKey.withUnsafeBytes { Data($0) }, using: SymmetricKey(data: kekData))
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        guard !nonce.isEmpty else { throw AgentBundleError.archiveFailed("nonce missing") }

        let manifest = AgentBundleManifest(
            formatVersion: AgentBundleFormat.currentVersion,
            exportedAt: Date(),
            agentId: agent.id,
            agentName: agent.displayName,
            agentDescription: agent.description,
            schemaTables: tables,
            savedViews: views,
            kdfSalt: salt.base64EncodedString(),
            kdfIterations: Self.kdfIterations,
            keyNonce: nonce.base64EncodedString(),
            keyCiphertext: sealed.ciphertext.base64EncodedString(),
            keyTag: sealed.tag.base64EncodedString()
        )
        try writeJSON(manifest, to: scratch.appendingPathComponent("manifest.json"))

        let slug = sanitizeFilename(agent.displayName.isEmpty ? agent.id.uuidString : agent.displayName)
        let bundleURL = destinationDirectory.appendingPathComponent("\(slug).osaurus-agent")
        try await tarDirectory(scratch, into: bundleURL)
        return ExportResult(bundleURL: bundleURL, manifest: manifest)
    }

    // MARK: - Import (review-before-activate)

    /// What activation does to the imported agent's cryptographic address.
    public enum IdentityNote: Equatable, Sendable {
        /// Another local agent already owns this address or index; the
        /// imported copy arrives without one.
        case collidesWithLocalAgent(name: String)
    }

    public struct ImportPreview: Sendable {
        /// Unpacked, validated staging directory. Lives until `activate` or
        /// `discard`.
        public var stagingDirectory: URL
        public var manifest: AgentBundleManifest
        public var identityNote: IdentityNote?
        /// Name of the local agent with the same id that activation replaces.
        public var replacesAgentName: String?
        /// Abilities the bundled agent arrives with that deserve a look
        /// (shell, file writes, web search, database, config writes).
        public var capabilityNotes: [String]
        /// Unwrapped with the passphrase; memory only.
        let bundleKey: SymmetricKey
    }

    /// Pure identity rule. Same-UUID re-imports are overwrites, so the
    /// record with the agent's own id never counts as a collision.
    static func resolveImportIdentity(
        agent: Agent,
        localAgents: [Agent]
    ) -> (agent: Agent, note: IdentityNote?) {
        guard !agent.isBuiltIn, agent.agentAddress != nil || agent.agentIndex != nil else {
            return (agent, nil)
        }
        let addressLower = agent.agentAddress?.lowercased()
        let collision = localAgents.first { existing in
            guard !existing.isBuiltIn, existing.id != agent.id else { return false }
            if let index = agent.agentIndex, existing.agentIndex == index { return true }
            if let addressLower, existing.agentAddress?.lowercased() == addressLower { return true }
            return false
        }
        guard let collision else { return (agent, nil) }
        var cleared = agent
        cleared.agentIndex = nil
        cleared.agentAddress = nil
        return (cleared, .collidesWithLocalAgent(name: collision.name))
    }

    /// Abilities worth surfacing before activating someone else's agent.
    static func capabilityNotes(for agent: Agent) -> [String] {
        var notes: [String] = []
        if let claude = agent.claudeCode {
            if claude.allowShell { notes.append(L("Claude Code may run shell commands")) }
            if claude.allowWrites { notes.append(L("Claude Code may write files")) }
            if claude.allowOsaurusConfigWrites { notes.append(L("May change Osaurus settings")) }
        }
        if agent.settings.webSearchEnabled { notes.append(L("Web Search is on")) }
        if agent.settings.dbEnabled { notes.append(L("Database is on")) }
        return notes
    }

    /// Unpack, validate and unlock a bundle without touching `~/.osaurus`.
    public func openBundleForReview(url: URL, passphrase: String) async throws -> ImportPreview {
        guard passphrase.count >= 8 else { throw AgentBundleError.passphraseTooShort }

        let staging = try makeScratchDirectory(prefix: "osaurus-agent-import-")
        func fail(_ error: Error) -> Error {
            try? FileManager.default.removeItem(at: staging)
            return error
        }
        do {
            try await untar(url, into: staging)
            try Self.validateStagingTree(staging)
        } catch {
            throw fail(error)
        }

        let manifestURL = staging.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw fail(AgentBundleError.manifestInvalid("no manifest.json in bundle"))
        }
        let manifest: AgentBundleManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(AgentBundleManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw fail(AgentBundleError.manifestInvalid(error.localizedDescription))
        }
        guard manifest.formatVersion == AgentBundleFormat.currentVersion else {
            throw fail(
                AgentBundleError.manifestInvalid(
                    "format version \(manifest.formatVersion) not supported by this build"))
        }
        guard (1 ... Self.maxKdfIterations).contains(manifest.kdfIterations) else {
            throw fail(AgentBundleError.manifestInvalid("unsupported key-derivation cost"))
        }

        guard let salt = Data(base64Encoded: manifest.kdfSalt),
            let nonceBytes = Data(base64Encoded: manifest.keyNonce),
            let ciphertext = Data(base64Encoded: manifest.keyCiphertext),
            let tag = Data(base64Encoded: manifest.keyTag)
        else {
            throw fail(AgentBundleError.manifestInvalid("manifest base64 fields malformed"))
        }
        let bundleKeyData: Data
        do {
            let kek = SymmetricKey(
                data: try Self.pbkdf2(
                    passphrase: passphrase, salt: salt, iterations: manifest.kdfIterations, keyLength: 32))
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonceBytes), ciphertext: ciphertext, tag: tag)
            bundleKeyData = try AES.GCM.open(box, using: kek)
        } catch {
            throw fail(AgentBundleError.decryptFailed("wrong passphrase or corrupted bundle"))
        }

        let staged: Agent
        do {
            staged = try Self.decodeAgent(at: staging.appendingPathComponent("agent.json"))
        } catch {
            throw fail(error)
        }
        guard staged.id == manifest.agentId, !staged.isBuiltIn else {
            throw fail(AgentBundleError.manifestInvalid("manifest agentId mismatch"))
        }
        let locals = await MainActor.run { AgentManager.shared.agents }
        let note = Self.resolveImportIdentity(agent: staged, localAgents: locals).note
        let replaces = locals.first { $0.id == staged.id && !$0.isBuiltIn }?.name

        return ImportPreview(
            stagingDirectory: staging,
            manifest: manifest,
            identityNote: note,
            replacesAgentName: replaces,
            capabilityNotes: Self.capabilityNotes(for: staged),
            bundleKey: SymmetricKey(data: bundleKeyData)
        )
    }

    /// Activate a reviewed import: re-encrypt `db.sqlite` from the bundle key
    /// to the local storage key, move the files into
    /// `~/.osaurus/agents/<id>/`, and save the agent.
    @discardableResult
    public func activate(preview: ImportPreview) async throws -> Agent {
        let staging = preview.stagingDirectory
        defer { try? FileManager.default.removeItem(at: staging) }
        // The staging tree was validated on open; re-check in case anything
        // changed on disk since.
        try Self.validateStagingTree(staging)

        let bundled = try Self.decodeAgent(at: staging.appendingPathComponent("agent.json"))
        guard bundled.id == preview.manifest.agentId, !bundled.isBuiltIn else {
            throw AgentBundleError.manifestInvalid("manifest agentId mismatch")
        }
        let locals = await MainActor.run { AgentManager.shared.agents }
        let agent = Self.resolveImportIdentity(agent: bundled, localAgents: locals).agent

        let fm = FileManager.default
        let stagedDB = staging.appendingPathComponent("db.sqlite").path
        let convertedDB = staging.appendingPathComponent("db.local.sqlite").path
        if fm.fileExists(atPath: stagedDB) {
            let localKey: SymmetricKey
            do {
                localKey = try StorageKeyManager.shared.currentKey()
            } catch {
                throw AgentBundleError.rekeyFailed("storage key unavailable")
            }
            try Self.reencrypt(from: stagedDB, sourceKey: preview.bundleKey, to: convertedDB, destinationKey: localKey)
        }

        let agentDir = OsaurusPaths.agentDirectory(for: agent.id)
        OsaurusPaths.ensureExistsSilent(agentDir)
        // Drop the live handle (and the bridge's queue) before replacing files.
        AgentDatabaseStore.shared.close(agent.id)
        LocalAgentBridge.shared.forget(agentId: agent.id)
        let liveDB = OsaurusPaths.agentDatabaseFile(for: agent.id).path
        if fm.fileExists(atPath: convertedDB) {
            for sidecar in ["-wal", "-shm"] { try? fm.removeItem(atPath: liveDB + sidecar) }
            try moveOverwriting(from: convertedDB, to: liveDB)
        }
        try moveOverwritingIfExists(
            from: staging.appendingPathComponent("schema.sql").path,
            to: agentDir.appendingPathComponent("schema.sql").path)
        try moveDirOverwritingIfExists(
            from: staging.appendingPathComponent("views").path,
            to: OsaurusPaths.agentViewsDirectory(for: agent.id).path)
        try moveDirOverwritingIfExists(
            from: staging.appendingPathComponent("migrations").path,
            to: OsaurusPaths.agentMigrationsDirectory(for: agent.id).path)
        try moveDirOverwritingIfExists(
            from: staging.appendingPathComponent("runs").path,
            to: OsaurusPaths.agentRunsDirectory(for: agent.id).path)

        await MainActor.run {
            if AgentManager.shared.agent(for: agent.id) != nil {
                AgentManager.shared.update(agent)
            } else {
                AgentManager.shared.add(agent)
            }
            NotificationCenter.default.post(name: .agentUpdated, object: agent.id)
        }
        return agent
    }

    /// Discard a preview without activating. Always safe to call.
    public func discard(preview: ImportPreview) {
        try? FileManager.default.removeItem(at: preview.stagingDirectory)
    }

    // MARK: - Validation

    /// Refuse symlinks and anything that isn't a regular file or directory,
    /// anywhere in the unpacked tree, plus hard-linked files.
    static func validateStagingTree(_ root: URL) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .linkCountKey]
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in false })
        else {
            throw AgentBundleError.readFailed("could not read the unpacked bundle")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values.isSymbolicLink == true {
                throw AgentBundleError.unsafeBundle("it contains a symbolic link (\(name))")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw AgentBundleError.unsafeBundle("it contains a special file (\(name))")
            }
            if (values.linkCount ?? 1) > 1 {
                throw AgentBundleError.unsafeBundle("it contains a hard-linked file (\(name))")
            }
        }
        for required in ["manifest.json", "agent.json"] {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: root.appendingPathComponent(required).path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                throw AgentBundleError.unsafeBundle("\(required) is a folder")
            }
        }
    }

    private static func decodeAgent(at url: URL) throws -> Agent {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentBundleError.manifestInvalid("no agent.json in bundle")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Agent.self, from: Data(contentsOf: url))
        } catch {
            throw AgentBundleError.manifestInvalid("agent.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Database copy (sqlcipher_export)

    /// Export the live agent database (or an empty one) into `destination`
    /// encrypted with `bundleKey`. The live file is only read.
    private func exportAgentDatabase(agentId: UUID, to destination: URL, bundleKey: SymmetricKey) throws {
        let source = OsaurusPaths.agentDatabaseFile(for: agentId).path
        guard FileManager.default.fileExists(atPath: source) else {
            // No database yet: ship an empty encrypted file so bundles are uniform.
            let conn = try EncryptedSQLiteOpener.open(path: destination.path, key: bundleKey)
            sqlite3_close(conn)
            return
        }
        let localKey: SymmetricKey
        do {
            localKey = try StorageKeyManager.shared.currentKey()
        } catch {
            throw AgentBundleError.writeFailed("storage key unavailable")
        }
        try Self.reencrypt(from: source, sourceKey: localKey, to: destination.path, destinationKey: bundleKey)
    }

    /// Copy an encrypted database under a different key with
    /// `sqlcipher_export` (a consistent read snapshot; works in WAL mode and
    /// never modifies the source). Forwards `user_version`.
    static func reencrypt(
        from sourcePath: String,
        sourceKey: SymmetricKey,
        to destinationPath: String,
        destinationKey: SymmetricKey
    ) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: destinationPath)
        for sidecar in ["-wal", "-shm"] { try? fm.removeItem(atPath: destinationPath + sidecar) }

        let source: OpaquePointer
        do {
            source = try EncryptedSQLiteOpener.open(
                path: sourcePath, key: sourceKey, applyPerfPragmas: false, applyForeignKeys: false)
        } catch {
            throw AgentBundleError.rekeyFailed("open source: \(error.localizedDescription)")
        }
        defer { sqlite3_close(source) }

        let hex = destinationKey.withUnsafeBytes { raw in raw.map { String(format: "%02x", $0) }.joined() }
        let escaped = destinationPath.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(source, "ATTACH DATABASE '\(escaped)' AS bundle KEY \"x'\(hex)'\"", nil, nil, nil)
            == SQLITE_OK
        else {
            throw AgentBundleError.rekeyFailed("attach: \(String(cString: sqlite3_errmsg(source)))")
        }
        for pragma in [
            "PRAGMA bundle.cipher_memory_security = OFF",
            "PRAGMA bundle.cipher_page_size = 4096",
            "PRAGMA bundle.kdf_iter = 256000",
        ] {
            _ = sqlite3_exec(source, pragma, nil, nil, nil)
        }
        guard sqlite3_exec(source, "SELECT sqlcipher_export('bundle')", nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(source))
            _ = sqlite3_exec(source, "DETACH DATABASE bundle", nil, nil, nil)
            try? fm.removeItem(atPath: destinationPath)
            throw AgentBundleError.rekeyFailed("export: \(message)")
        }
        var userVersion: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(source, "PRAGMA main.user_version", -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            if sqlite3_step(s) == SQLITE_ROW { userVersion = sqlite3_column_int(s, 0) }
            sqlite3_finalize(s)
        }
        if userVersion > 0 {
            _ = sqlite3_exec(source, "PRAGMA bundle.user_version = \(userVersion)", nil, nil, nil)
        }
        _ = sqlite3_exec(source, "DETACH DATABASE bundle", nil, nil, nil)
    }

    /// Tally user tables and saved views for the manifest. Best effort.
    private func readBundleStats(dbPath: String, key: SymmetricKey) throws -> (Int, Int) {
        let conn = try EncryptedSQLiteOpener.open(path: dbPath, key: key, applyPerfPragmas: false)
        defer { sqlite3_close(conn) }
        func count(_ sql: String) -> Int {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return 0 }
            defer { sqlite3_finalize(s) }
            return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : 0
        }
        let tables = count(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' "
                + "AND name NOT IN ('_tables_meta', '_changelog', '_views')")
        let views = count("SELECT count(*) FROM _views")
        return (tables, views)
    }

    // MARK: - PBKDF2 + key wrap

    private func deriveKEK(passphrase: String) throws -> (salt: Data, key: Data) {
        var saltBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &saltBytes) == errSecSuccess else {
            throw AgentBundleError.archiveFailed("CSPRNG salt")
        }
        let salt = Data(saltBytes)
        return (salt, try Self.pbkdf2(passphrase: passphrase, salt: salt, iterations: Self.kdfIterations, keyLength: 32))
    }

    /// PBKDF2-HMAC-SHA256 via CommonCrypto.
    static func pbkdf2(passphrase: String, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
        var derived = Data(count: keyLength)
        let passphraseBytes = Array(passphrase.utf8)
        let result = derived.withUnsafeMutableBytes { derivedBuffer -> Int32 in
            salt.withUnsafeBytes { saltBuffer -> Int32 in
                guard let derivedBase = derivedBuffer.baseAddress, let saltBase = saltBuffer.baseAddress else {
                    return Int32(kCCParamError)
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphraseBytes,
                    passphraseBytes.count,
                    saltBase.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    derivedBase.assumingMemoryBound(to: UInt8.self),
                    keyLength
                )
            }
        }
        guard result == kCCSuccess else {
            throw AgentBundleError.decryptFailed("PBKDF2 returned \(result)")
        }
        return derived
    }

    // MARK: - Files

    private func makeScratchDirectory(prefix: String) throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        } catch {
            throw AgentBundleError.writeFailed(error.localizedDescription)
        }
        return temp
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(value).write(to: url)
        } catch {
            throw AgentBundleError.writeFailed(error.localizedDescription)
        }
    }

    private func copyIfExists(from src: URL, to dst: URL) throws {
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        do {
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            throw AgentBundleError.writeFailed("copy \(src.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func copyDirIfExists(from src: URL, to dst: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else { return }
        do {
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            throw AgentBundleError.writeFailed("copy dir \(src.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func moveOverwriting(from srcPath: String, to dstPath: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dstPath) { try? fm.removeItem(atPath: dstPath) }
        do {
            try fm.moveItem(atPath: srcPath, toPath: dstPath)
        } catch {
            throw AgentBundleError.writeFailed("move \(srcPath): \(error.localizedDescription)")
        }
    }

    private func moveOverwritingIfExists(from srcPath: String, to dstPath: String) throws {
        guard FileManager.default.fileExists(atPath: srcPath) else { return }
        try moveOverwriting(from: srcPath, to: dstPath)
    }

    private func moveDirOverwritingIfExists(from srcPath: String, to dstPath: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: srcPath, isDirectory: &isDir), isDir.boolValue else { return }
        try moveOverwriting(from: srcPath, to: dstPath)
    }

    private func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let trimmed = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "agent" : trimmed
    }

    // MARK: - Tar (`/usr/bin/tar`)

    /// Uncompressed tar, as upstream; `untar` autodetects compression.
    private func tarDirectory(_ dir: URL, into bundle: URL) async throws {
        try? FileManager.default.removeItem(at: bundle)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", bundle.path, "-C", dir.path, "."]
        try await runProcess(process, errorContext: "tar")
    }

    /// bsdtar refuses absolute paths and `..` components by default (no
    /// `-P`); `validateStagingTree` then rejects links and special files.
    private func untar(_ bundle: URL, into dir: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", bundle.path, "-C", dir.path]
        try await runProcess(process, errorContext: "untar")
    }

    private func runProcess(_ process: Process, errorContext: String) async throws {
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume()
            }
        }
        guard process.processIdentifier != 0 else {
            throw AgentBundleError.archiveFailed("\(errorContext) could not launch")
        }
        guard process.terminationStatus == 0 else {
            let stderr = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
            let message = String(data: stderr, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw AgentBundleError.archiveFailed("\(errorContext): \(message)")
        }
    }
}
