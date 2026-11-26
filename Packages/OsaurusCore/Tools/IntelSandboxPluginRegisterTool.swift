//
//  IntelSandboxPluginRegisterTool.swift
//  osaurus
//
//  Intel fork (W-seatbelt-sandbox stage 4): `sandbox_plugin_register`, the
//  host-backend counterpart of upstream's tool of the same name (the upstream
//  file and `SandboxPluginRegistration` are the VM stack and stay excluded).
//
//  The agent writes `plugins/<plugin_id>/plugin.json` (plus script files) in
//  its sandbox home, then calls this tool. What differs from upstream:
//
//  - the plugin folder is read by a confined command (`base64`, regular files
//    only, no symlinks, no hidden files), never by an app-side read of a path
//    the sandbox could have swapped for a symlink to a file outside it;
//  - the tool asks for approval like `sandbox_exec` and is offered only to
//    agents whose own `pluginCreate` switch is on;
//  - agent-created plugins get upstream's restricted defaults (network
//    `none`, no inference), and system `dependencies` are refused;
//  - the install runs `setup` under the agent's own network switch, so a
//    plugin can never reach the network the agent itself cannot.
//

import Foundation

struct SandboxPluginRegisterTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name = BuiltinSandboxTools.pluginRegister
    let description =
        "Register a sandbox plugin you created. Reads `plugin.json` from your "
        + "`plugins/{plugin_id}/` directory, seeds its files, runs its `setup` command inside the sandbox, "
        + "and makes its tools available (immediately when possible, otherwise on your next message). "
        + "The plugin must already be written to disk before this call. Plugin tools run in the same "
        + "sandbox as `sandbox_exec`, with the same limits, and ask the user for approval."

    var requirements: [String] { [] }
    /// Installing runs a setup script: the user is asked unless they set Auto.
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }
    var bypassRegistryTimeout: Bool { true }

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "plugin_id": .object([
                    "type": .string("string"),
                    "description": .string("Plugin directory name under `plugins/` (e.g. `notion`)."),
                ])
            ]),
            "required": .array([.string("plugin_id")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let context: SandboxToolContext
        switch await SandboxToolContext.resolve(tool: name) {
        case .failure(let refusal): return refusal.envelope
        case .success(let value): context = value
        }
        guard context.config.pluginCreate else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Plugin creation is off for this agent. The user can turn it on in the agent's sandbox settings.",
                tool: name, retryable: false)
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let idReq = requireString(
            args, "plugin_id", expected: "plugin directory name under `plugins/`", tool: name)
        guard case .value(let pluginId) = idReq else { return idReq.failureEnvelope ?? "" }
        guard SandboxPluginManager.isSafeIdentifier(pluginId) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`plugin_id` must use only letters, digits, `-` and `_`. Got `\(pluginId)`.",
                field: "plugin_id", expected: "plugin directory name", tool: name)
        }
        if let notReady = await context.ensureReady(tool: name) { return notReady }

        let loaded = await Self.loadPlugin(pluginId: pluginId, context: context, tool: name)
        switch loaded {
        case .envelope(let envelope):
            return envelope
        case .plugin(let plugin):
            return await register(plugin: plugin, context: context)
        }
    }

    // MARK: - Registration

    private func register(plugin: SandboxPlugin, context: SandboxToolContext) async -> String {
        var staged = plugin
        let errors = SandboxPluginManager.validate(staged)
        guard errors.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: errors.joined(separator: "; "), tool: name, retryable: false)
        }
        // Declared secrets must exist before registration (upstream).
        if let names = staged.secrets, !names.isEmpty {
            let env = AgentSecretsKeychain.mergedSecretsEnvironment(agentId: context.agentId, pluginId: staged.id)
            let missing = names.filter { (env[$0] ?? "").isEmpty }
            if !missing.isEmpty {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Missing secrets for plugin: \(missing.joined(separator: ", ")). Ask the user to add "
                        + "each in this agent's settings, then register again.",
                    tool: name, retryable: false)
            }
        }
        SandboxPluginDefaults.applyRestrictedDefaults(&staged)
        if staged.metadata == nil { staged.metadata = [:] }
        staged.metadata?["created_by"] = .string("agent")
        staged.metadata?["created_via"] = .string("agent_tool")

        let secrets = SandboxExecSecrets.values(for: context.agentId)
        do {
            try await SandboxPluginManager.current.install(
                plugin: staged,
                for: context.agentId.uuidString,
                networkEnabled: context.config.sandboxNetworkEnabled,
                secrets: secrets)
        } catch {
            // Do not leave a failed registration behind.
            try? await SandboxPluginManager.current.uninstall(
                pluginId: staged.id, from: context.agentId.uuidString)
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Plugin installation failed: \(SecretScrubber.scrub(error.localizedDescription, secrets: secrets))",
                tool: name, retryable: true)
        }
        let toolNames = (staged.tools ?? []).map { "\(staged.id)_\($0.id)" }
        // Offer the new tools to the running turn where the engine can take
        // them; otherwise they appear on the next message.
        await CapabilityLoadBuffer.current?.add(toolNames)
        return ToolEnvelope.success(
            tool: name,
            result: [
                "plugin_id": staged.id,
                "plugin_name": staged.name,
                "tools": (staged.tools ?? []).map {
                    ["name": "\(staged.id)_\($0.id)", "description": $0.description]
                },
                "note":
                    "Plugin tools ask the user for approval like `sandbox_exec`. They are available now if listed in your tools, otherwise from the next message.",
            ])
    }

    // MARK: - Loading (confined)

    private enum LoadResult {
        case plugin(SandboxPlugin)
        case envelope(String)
    }

    /// Cap on the bytes one confined read may print (the plugin limit is
    /// 256 KB of text, which is about 350 KB as base64).
    private static let maxListingBytes = 400_000

    private static func loadPlugin(
        pluginId: String, context: SandboxToolContext, tool: String
    ) async -> LoadResult {
        func fail(_ kind: ToolEnvelope.Kind, _ message: String) -> LoadResult {
            .envelope(ToolEnvelope.failure(kind: kind, message: message, tool: tool, retryable: false))
        }
        let dir = "\(context.home)/plugins/\(pluginId)"
        let quoted = sandboxShellEscape(dir)
        // 1. plugin.json: a regular file (not a symlink), printed as base64.
        guard
            let manifest = try? await context.run(
                "cd '\(quoted)' 2>/dev/null && [ -f plugin.json ] && [ ! -L plugin.json ] && /usr/bin/base64 < plugin.json",
                timeout: 20),
            manifest.succeeded,
            let manifestData = Data(
                base64Encoded: manifest.stdout.filter { !$0.isWhitespace })
        else {
            return fail(.executionError, "plugin.json not found at plugins/\(pluginId)/plugin.json")
        }
        let plugin: SandboxPlugin
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            plugin = try decoder.decode(SandboxPlugin.self, from: manifestData)
        } catch {
            return fail(.invalidArgs, "Invalid plugin.json: \(decodeFailureDetail(error))")
        }
        // 2. Every other regular file (no symlinks, no hidden files).
        let listing =
            "cd '\(quoted)' && find . -type f ! -name plugin.json ! -path '*/.*' | head -n \(SandboxPluginManager.maxFiles + 1) | "
            + "while IFS= read -r f; do printf '%s\\t' \"${f#./}\"; /usr/bin/base64 < \"$f\" | tr -d '\\n'; printf '\\n'; done | head -c \(maxListingBytes + 1)"
        guard let result = try? await context.run(listing, timeout: 30), result.succeeded else {
            return fail(.executionError, "Could not read the plugin folder `plugins/\(pluginId)/`.")
        }
        if result.stdout.utf8.count > maxListingBytes {
            return fail(
                .invalidArgs,
                "Plugin files are too large (limit \(SandboxPluginManager.maxTotalFileBytes) bytes of text).")
        }
        var text: [String: String] = [:]
        var binary: [String] = []
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            let path = String(parts[0])
            if let data = Data(base64Encoded: String(parts[1])), let content = String(data: data, encoding: .utf8) {
                text[path] = content
            } else if !parts[1].isEmpty {
                binary.append(path)
            } else {
                text[path] = ""
            }
        }
        if !binary.isEmpty {
            return fail(
                .invalidArgs,
                "Binary files in `plugins/\(pluginId)/` cannot be packaged into a sandbox plugin "
                    + "(`plugin.files` is text-only). Remove them or regenerate them in `setup`. "
                    + "Offending files: \(binary.sorted().joined(separator: ", ")).")
        }
        var merged = plugin.files ?? [:]
        // Authored entries in plugin.json win over auto-discovered files.
        for (path, content) in text where merged[path] == nil { merged[path] = content }
        var packaged = plugin
        packaged.files = merged.isEmpty ? nil : merged
        return .plugin(packaged)
    }

    /// Actionable text for a `plugin.json` decode failure (upstream's wording).
    static func decodeFailureDetail(_ error: Error) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let joined = codingPath.map { key in
                key.intValue.map { "[\($0)]" } ?? key.stringValue
            }.joined(separator: ".")
            return joined.isEmpty ? "(root)" : joined
        }
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "missing required key `\(key.stringValue)` at \(path(context.codingPath))."
        case let DecodingError.typeMismatch(type, context):
            return "wrong type at \(path(context.codingPath)) — expected \(type)."
        case let DecodingError.valueNotFound(type, context):
            return "null/missing value at \(path(context.codingPath)) — expected \(type)."
        case let DecodingError.dataCorrupted(context):
            let underlying = (context.underlyingError as NSError?)?
                .userInfo[NSDebugDescriptionErrorKey] as? String
            let detail = underlying ?? context.debugDescription
            return "malformed JSON — \(detail) Check for unescaped quotes/newlines in string values."
        default:
            let ns = error as NSError
            return (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
        }
    }
}
