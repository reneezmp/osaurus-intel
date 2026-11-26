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

    /// Secret-handling discipline. Intel's version: secrets are added by the
    /// user in the agent's settings (the secure prompt tool is not offered).
    static let secretHandling = """

        ## Secret handling

        - Never ask the user to paste a secret (API key, token, password) into chat: chat is persisted.
        - Call `sandbox_secret_check` to see whether a secret exists. If it is missing, tell the user which secret name you need and that they can add it in this agent's settings, then wait.
        - Stored secrets reach `sandbox_exec` as environment variables named by their key: read them from the environment, never inline them in scripts or files, and never record a value in SOUL.md or notes.
        """

    /// SOUL.md (the agent's own notes). Upstream's `soulSection` renders it;
    /// the read is capped like upstream's.
    static let soulMaxBytes = 8 * 1024

    static func soul(agentName: String) -> String {
        let url = OsaurusPaths.containerAgentDir(agentName).appendingPathComponent("SOUL.md")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        var text = String(decoding: data.prefix(soulMaxBytes), as: UTF8.self)
        if data.count > soulMaxBytes, let cut = text.lastIndex(of: "\n") {
            text = String(text[..<cut])
        }
        let section = SystemPromptTemplates.soulSection(text)
        return section.isEmpty ? "" : "\n\n" + section
    }
}
