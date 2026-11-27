//
//  IntelSandboxPrompt.swift
//  osaurus
//
//  Intel fork: the sandbox prompt sections (W-seatbelt-sandbox stage 3).
//  Upstream's `SystemPromptTemplates` sandbox blocks describe the Linux VM
//  or the unified `file_*`/`shell_run` vocabulary; Intel's tools are the
//  `sandbox_*` family running under Seatbelt on the Mac, so the wording is
//  Intel's own. Sections: environment (with the tool dispatch), state
//  (stored secret names; upstream's `sandboxState`), unavailable (upstream's
//  `sandboxUnavailable`), secret handling, and SOUL (upstream's `soul`).
//  `selfImprovement` and `pluginCreator` come with sandbox plugins (stage 4).
//

import Foundation

enum IntelSandboxPrompt {
    static let heading = "## macOS sandbox environment"

    /// Static framing. Every input is session-constant, so it lives in the
    /// cached prefix. `network` says whether THIS agent may use the network.
    static func environment(home: String, network: Bool, toolNames: Set<String>) -> String {
        let networkLine =
            network
            ? "Network access is ON for this agent: fetch live data with `curl`, Python `requests` or Node `fetch`."
            : "Network access is OFF: commands cannot reach the internet, so do not try to download or call APIs. If the task needs the network, tell the user they can turn it on in this agent's sandbox settings."
        var guide: [String] = []
        if toolNames.contains(BuiltinSandboxTools.readFile) {
            guide.append("- Read: `sandbox_read_file` (`start_line`/`line_count`/`tail_lines` for large files).")
        }
        if toolNames.contains(BuiltinSandboxTools.writeFile) {
            guide.append(
                "- Write/edit: `sandbox_write_file` (`content` for a whole file, or `old_string`+`new_string` to edit one match). Writes ask the user for approval unless they set it to Auto."
            )
        }
        if toolNames.contains(BuiltinSandboxTools.searchFiles) {
            guide.append(
                "- Search: `sandbox_search_files` with `target=\"content\"` (regex) or `target=\"files\"` (names).")
        }
        if toolNames.contains(BuiltinSandboxTools.exec) {
            guide.append(
                "- Shell: `sandbox_exec` for a single command line; it asks the user for approval unless they set it to Auto. Multi-line scripts: `sandbox_write_file` the script, then run it (e.g. `python3 script.py`); never embed multi-line code in `python3 -c` / `node -e`."
            )
        }
        if toolNames.contains(BuiltinSandboxTools.process) {
            guide.append(
                "- Background: `sandbox_exec` with `background:true` returns a `pid` and `log_file`; `sandbox_process` polls, waits or kills it. Background processes stay inside the sandbox and are stopped automatically when this run ends, so collect their results before you finish."
            )
        }
        return """

            \(heading)

            You have a sandboxed command environment: processes run on this Mac but are confined by a sandbox profile. Your home directory is `\(home)` (also `~` / `$HOME`); commands run there by default, so you do not need `cwd` unless you want a different directory. You can read system tools and write only inside the sandbox workspace (your home and `/workspace/shared`). Files persist across messages. You cannot see the user's other folders or files.

            \(networkLine)

            This is macOS, not Linux: BSD userland, plus `bash`, `python3`, `git`, `curl`, `sqlite3` where installed (check others with `command -v`). There is no `apk`, `sudo` or package installer tool.

            Tool dispatch:
            \(guide.joined(separator: "\n"))
            - Run independent calls in parallel; chain dependent shell steps with `&&`.
            """
    }

    /// Plugin authoring (upstream's `pluginCreator`, trimmed to what the host
    /// backend supports: no `dependencies`, `daemon` or `events`).
    static let pluginCreator = """

        ## Sandbox plugins

        You can package a reusable tool as a sandbox plugin. Write `plugins/<plugin_id>/plugin.json` (and any script files next to it) in your home, then call `sandbox_plugin_register` with the plugin id. `plugin.json` fields: `name`, `description`, optional `setup` (one shell command run once in the plugin folder, e.g. `pip install --target libs requests`; it needs network access, which may be off), optional `secrets` (names the user must add first), and `tools`: a list of `{ "id", "description", "parameters": { "<name>": { "type", "description", "default", "enum" } }, "run" }`. A tool's `run` is a shell command in the plugin folder; each parameter arrives as `$PARAM_<NAME>`. Tools are named `<plugin_id>_<tool id>`. Do not use `dependencies` (apk), `daemon` or `events`: they are not supported here. Plugin tools run in the same sandbox as `sandbox_exec`, with the same limits, and ask the user for approval.
        """

    /// Mid-session state: the names of the secrets stored for this agent.
    /// Empty when there are none so the composer drops the section.
    static func state(secretNames: [String]) -> String {
        guard !secretNames.isEmpty else { return "" }
        let list = secretNames.sorted().map { "- `\($0)`" }.joined(separator: "\n")
        return """

            ## Sandbox state

            Configured secrets (available to `sandbox_exec` as environment variables):
            \(list)
            Access via `$NAME` in shell, `os.environ["NAME"]` in Python, or `process.env.NAME` in Node. Their values are redacted from command output.
            """
    }

    /// Shown instead of the tools when the agent opted in but this Mac
    /// cannot run the sandbox.
    static let unavailable = """

        ## Sandbox unavailable

        This agent has the sandbox turned on, but this Mac cannot run it (`sandbox-exec` is missing), so no sandbox tools are offered. Do not pretend to run commands; say so if the user asks for something that needs a shell.
        """

    /// Secret-handling discipline (upstream Classic's `secretHandlingGuidance`;
    /// Intel offers no `value` argument, so the prompt is the only way in).
    static let secretHandling = """

        ## Secret handling

        - Never ask the user to paste a secret (API key, token, password, connection string) into chat: chat is persisted to the transcript.
        - To collect a secret, call `sandbox_secret_set` with `key`, `description` and `instructions` (what to paste and where to find it). The app asks the user in a secure dialog; the value never enters the conversation, and there is no `value` argument. If the user cancels, nothing is stored: do not ask again unprompted.
        - Call `sandbox_secret_check` first and skip collection if the secret exists.
        - Stored secrets reach `sandbox_exec` as environment variables named by their key: read them from the environment, never inline them in scripts or files. No tool returns a secret value, by design.
        - Never echo a secret value, write it to a file in plaintext, pass it as a tool argument, or record it in SOUL.md or notes.
        """

    /// SOUL.md (the agent's own notes). Upstream's `soulSection` renders it;
    /// the read is capped like upstream's.
    static let soulMaxBytes = 8 * 1024

    static func soul(agentName: String, workspace: URL = OsaurusPaths.containerWorkspace()) -> String {
        guard
            let data = readConfined(
                workspace: workspace, agentName: agentName, file: "SOUL.md", maxBytes: soulMaxBytes + 1),
            !data.isEmpty
        else { return "" }
        var text = String(decoding: data.prefix(soulMaxBytes), as: UTF8.self)
        if data.count > soulMaxBytes, let cut = text.lastIndex(of: "\n") {
            text = String(text[..<cut])
        }
        let section = SystemPromptTemplates.soulSection(text)
        return section.isEmpty ? "" : "\n\n" + section
    }

    /// App-side read of a file in the agent's home, which the sandbox can write
    /// to: so the file may be a symlink, or sit behind a symlinked folder. The
    /// final component is opened with `O_NOFOLLOW`; the opened descriptor must
    /// be a regular file whose real path is exactly
    /// `<real workspace>/agents/<name>/<file>`, so a link anywhere on the path
    /// that leads elsewhere is refused. At most `maxBytes` are read.
    static func readConfined(workspace: URL, agentName: String, file: String, maxBytes: Int) -> Data? {
        guard !agentName.isEmpty, !agentName.contains("/"), agentName != ".", agentName != "..",
            !file.contains("/"), file != "..", file != "."
        else { return nil }
        guard let realWorkspace = realPath(workspace.path) else { return nil }
        let expected = "\(realWorkspace)/agents/\(agentName)/\(file)"
        let path = workspace.appendingPathComponent("agents/\(agentName)/\(file)").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0, String(cString: buffer) == expected else { return nil }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < maxBytes {
            let n = read(fd, &chunk, min(chunk.count, maxBytes - data.count))
            if n <= 0 { break }
            data.append(chunk, count: n)
        }
        return data
    }

    private static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }
}
