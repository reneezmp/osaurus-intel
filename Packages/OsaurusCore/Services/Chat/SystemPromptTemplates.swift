//
//  SystemPromptTemplates.swift
//  osaurus
//
//  Centralized repository of all system prompt text. Every instruction
//  string sent to the model should be defined here so the full prompt
//  surface can be viewed, compared, and tuned in a single file.
//

import Foundation

public enum SystemPromptTemplates {

    // MARK: - Identity

    /// Platform framing — emitted unconditionally as a stable, non-customizable
    /// section ahead of the user's persona. Tells the model where it's
    /// running so a custom persona doesn't accidentally erase that context.
    /// Names no tools (see `defaultPersona` for why).
    public static let platformIdentity =
        "You are an Osaurus chat agent running locally on the user's Mac."

    /// Default persona used when the user has not configured a custom one.
    /// Frames the agent as tool-driven so models don't reflexively say
    /// "I cannot do that" when they actually can. Behavior-only — platform
    /// framing lives separately in `platformIdentity`.
    ///
    /// **Tool names are deliberately NOT mentioned here.** Naming `todo` /
    /// `complete` / `share_artifact` / `clarify` / `capabilities_discover`
    /// in the unconditional persona caused MiniMax M2.7 Small JANGTQ
    /// (and other low-bit MoE models) to fall into a recitation loop on
    /// any chat where those tools weren't actually in the request's
    /// `tools[]` array — the model saw the names in the system prompt,
    /// expected the schema to back them, found a mismatch, and degenerated
    /// into emitting tool-spec text from its training distribution
    /// (live-confirmed 2026-04-25).
    ///
    /// Each chat-layer-intercepted tool's how-to lives in the gated
    /// `agentLoopGuidance` / `capabilityDiscoveryNudge` blocks below,
    /// which fire ONLY when the corresponding tool is actually resolved
    /// into the schema. Sandbox-/folder-tool hints are similarly gated
    /// at their composer call-sites.
    public static let defaultPersona = """
        Use the tools available in this conversation when they raise \
        correctness or ground a claim in real data; do not narrate intent \
        before acting. If no tools are listed, answer directly from your \
        own knowledge.
        """

    /// Returns the effective persona, falling back to `defaultPersona`
    /// when the user has not configured one.
    public static func effectivePersona(_ basePrompt: String) -> String {
        let trimmed = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultPersona : trimmed
    }

    // MARK: - Agent Loop

    /// Cheat-sheet for the four chat-layer-intercepted tools (`todo`,
    /// `complete`, `clarify`, `share_artifact`). Injected when any of
    /// those names is in the resolved schema. Tool descriptions carry
    /// the detail; this is the one-line "when to call which" reminder.
    public static let agentLoopGuidance = """
        ## Agent loop

        - `todo(markdown)` — write or replace the user-visible task list. Use it when the request has 3+ obvious steps; skip for trivial work. Each call replaces the whole list, so to mark items done re-send the full list with the new boxes.
        - `complete(summary)` — call once at the very end (never alongside other tools) with WHAT you did + HOW you verified it. Vague placeholders ("done", "looks good") are rejected; partial work should be reported honestly.
        - `clarify(question)` — pause and ask exactly one concrete question only when guessing wrong would change the result. For minor preferences pick a sensible default and proceed.
        - `share_artifact(...)` — the only way the user sees a generated image, chart, report, code blob, or any file. **The file MUST exist before this call.** Sandbox: save under your home dir (default cwd) — files in `/tmp` won't be findable. If unsure where you wrote it, verify with `sandbox_search_files(target="files", pattern="<name>")` first. For inline text/markdown, use `content`+`filename` mode and skip the file write entirely.
        """

    // MARK: - Grounding

    /// Anti-fabrication directive injected whenever tools are present
    /// (gated on `!effectiveToolsOff` + a non-empty schema in the
    /// composer). Both conditions are session-constant → KV-cache safe.
    /// Deliberately tool-name-free: this section can be emitted when
    /// `capabilities_discover` is NOT in the schema (e.g. manual mode), and
    /// naming a tool that isn't in the request is the recitation-loop trap
    /// `defaultPersona` documents. The capability-discovery nudge (when
    /// present) supplies the "how to find a tool" half; this supplies the
    /// "don't fabricate when none fits" half.
    public static let groundingDirective = """
        ## Grounding

        - Ground factual and live-data claims — weather, prices, web content, file contents, command output, current state — in a tool result rather than answering from memory.
        - You can almost always get there: a shell or network tool fetches live/external data, and `capabilities_discover` finds tools you don't have yet. Attempt that before deciding you can't — the absence of a purpose-built tool is not a dead end. Say what you can't do only after genuinely trying, and never invent a tool name or fabricate a value to fill a gap.
        - A claim about your own capabilities is a factual claim. "I don't have a tool for X" or "I can't do X" must be backed by either the Enabled-capabilities manifest or a `capabilities_discover` call that came back empty. Never by X being absent from your current tool schema. Your loaded tools are a fixed subset, not the full enabled set.
        - When the user asks whether you have a tool, whether you can do something, or what you can do: check the manifest first, then `capabilities_discover` if the manifest does not settle it, then answer.
        """

    // MARK: - Capability Discovery Nudge

    /// Static guidance appended to the system prompt when `capabilities_discover`
    /// / `capabilities_load` are in the active tool set (auto-selection mode).
    /// Tells the model how to recover when its current tool kit is missing
    /// something instead of inventing tool names — works hand-in-hand with
    /// the `toolNotFound` self-heal envelope returned by `ToolRegistry`.
    public static let capabilityDiscoveryNudge = """
        ## Discovering more tools

        Your current tool list is a fixed starting set, not an exhaustive \
        one. The Enabled-capabilities list below names more you can pull in on \
        demand and shows exactly how to load by id with capabilities_load. \
        When a capability seems missing and is NOT named there, \
        `capabilities_discover({"query": "<what you need>"})` searches beyond \
        the listed set and returns IDs like `tool/sandbox_exec` or \
        `skill/plot-data` that you load the same way.

        Do not invent tool names — use IDs from the list or from discovery. \
        Only after a `capabilities_discover` call comes back empty may you \
        work around the gap or tell the user the capability is unavailable.
        """

    // MARK: - Enabled Capabilities Manifest

    /// One tool or skill row in the enabled-capabilities manifest. Carries
    /// only the surface name + one-line description the model needs to
    /// answer "do you have X" — the full `Tool` spec / skill body is
    /// resolved on demand by `capabilities_load`.
    public struct ManifestCapability: Sendable, Equatable {
        public let name: String
        public let description: String
        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    /// All enabled-but-unloaded capabilities that belong to one plugin /
    /// provider. Grouped to match the user's mental model and the settings
    /// layout. `skills` render before `tools` so the "Skills that govern
    /// tool groups" rule has a visible anchor.
    public struct ManifestPluginGroup: Sendable, Equatable {
        public let pluginDisplay: String
        public let skills: [ManifestCapability]
        public let tools: [ManifestCapability]
        public init(
            pluginDisplay: String,
            skills: [ManifestCapability],
            tools: [ManifestCapability]
        ) {
            self.pluginDisplay = pluginDisplay
            self.skills = skills
            self.tools = tools
        }
    }

    /// Cap on total tool lines rendered with descriptions before
    /// low-priority plugins collapse to a name + count pointer. A full
    /// enabled set can run to 150+ tools, which would crowd the user's
    /// turn on a small-context model and blow the token budget. The
    /// composer pre-sorts groups so this-turn-relevant plugins come first;
    /// the cap keeps those fully described and collapses the long tail.
    /// **Adjust against your context budget.**
    public static let enabledManifestToolCap = 70

    /// Render the `## Enabled capabilities` manifest from a pre-grouped,
    /// pre-sorted list. Returns `nil` when there is nothing to surface so the
    /// caller can skip an empty section.
    ///
    /// The manifest is the grounded answer to "do you have X" — it lets a
    /// model confirm an enabled capability with zero tool calls. Every line
    /// begins with its loadable id (`tool/<name>` or `skill/<name>`) so the
    /// model can pass it straight to `capabilities_load` without a discover.
    /// Tools past `enabledManifestToolCap` collapse to a per-plugin `+N more`
    /// pointer the model can expand with `capabilities_discover`. `compact`
    /// (small-/tiny-context models) drops per-tool descriptions but keeps the
    /// ids, since naming the capability is what stops the model from denying
    /// it.
    public static func enabledCapabilitiesManifest(
        groups: [ManifestPluginGroup],
        compact: Bool = false
    ) -> String? {
        guard !groups.isEmpty else { return nil }

        var blocks: [String] = []
        var renderedToolLines = 0

        for group in groups {
            let skillLines = group.skills.map { skill -> String in
                let desc = skill.description.isEmpty ? "Plugin skill." : skill.description
                return compact
                    ? "  skill/\(skill.name)"
                    : "  skill/\(skill.name) — \(desc)"
            }

            let remaining = max(enabledManifestToolCap - renderedToolLines, 0)
            // Cap reached: collapse this plugin's tools to a pointer line so
            // the model still knows more exists without paying the tokens.
            if remaining == 0, !group.tools.isEmpty {
                var collapsed = ["<plugin: \(group.pluginDisplay)>"]
                collapsed.append(contentsOf: skillLines)
                collapsed.append(
                    "  +\(group.tools.count) more tool(s) — call capabilities_discover to list them."
                )
                blocks.append(collapsed.joined(separator: "\n"))
                continue
            }

            let toolsToShow = Array(group.tools.prefix(remaining))
            let overflow = group.tools.count - toolsToShow.count
            renderedToolLines += toolsToShow.count

            let toolLines = toolsToShow.map { tool -> String in
                let desc = tool.description.isEmpty ? "(no description)" : tool.description
                return compact ? "  tool/\(tool.name)" : "  tool/\(tool.name) — \(desc)"
            }

            var lines = ["<plugin: \(group.pluginDisplay)>"]
            lines.append(contentsOf: skillLines)
            lines.append(contentsOf: toolLines)
            if overflow > 0 {
                lines.append(
                    "  +\(overflow) more tool(s) — call capabilities_discover to list them."
                )
            }
            blocks.append(lines.joined(separator: "\n"))
        }

        let intro = """
            ## Enabled capabilities

            These capabilities are enabled for this session. Each line begins \
            with its loadable id. Some may already be in your current tool \
            schema; others must be loaded before use. To load one, call \
            capabilities_load with its id exactly as shown \
            (e.g. `capabilities_load({"ids": ["tool/<name>"]})`). They are real \
            — do not deny having a capability that appears here.

            Worked example — User: "You have a list_messages tool." You: check \
            this manifest. If tool/list_messages is listed, confirm it and call \
            capabilities_load with that id before using it. Only if it is absent \
            from both this manifest and an empty capabilities_discover result do \
            you say it is unavailable.
            """

        return intro + "\n\n" + blocks.joined(separator: "\n")
    }

    /// General rule that replaces the per-plugin "Plugin Companions"
    /// enumeration. The manifest lists a plugin's skill alongside its tools;
    /// this rule tells the model to load the skill first because a
    /// name+description manifest can't convey the skill-first ordering a
    /// tool-group skill (e.g. `Osaurus Browser`) teaches.
    public static let skillsGovernToolGroups = """
        ## Skills that govern tool groups

        Some enabled capabilities are skills that teach you how to use a group \
        of related tools. When the manifest shows a skill alongside tools from \
        the same plugin, load the skill first with capabilities_load; it \
        explains when each tool in that group applies. Loading the skill also \
        loads that plugin's whole tool group in the same call, so you can call \
        the tools directly afterward without a separate capabilities_load per \
        tool.
        """

    // MARK: - Cross-cutting Engineering Discipline

    /// General code-style discipline. Injected when a file-authoring tool
    /// (`sandbox_write_file` / `file_write` / `file_edit`, see
    /// `SystemPromptComposer.codeEditToolNames`) is in the resolved schema —
    /// not for shell-/install-only chats, which don't edit code. Not
    /// sandbox-specific — folder-mode agents doing real edits get the same
    /// guardrails.
    public static let codeStyleGuidance = """
        ## Code style

        - Limit changes to what was requested — a bug fix does not warrant adjacent refactoring or style cleanup.
        - Do not add defensive error handling, fallback logic, or input validation for conditions that cannot arise in the current code path.
        - Do not extract helpers or utilities for logic that appears only once.
        - Only add comments when reasoning is genuinely non-obvious — never narrate what the code does.
        - Do not add docstrings, comments, or type annotations to code you did not modify.
        """

    /// Risk-aware action discipline. Fires on the broader
    /// `SystemPromptComposer.mutationToolNames` gate (any tool that can
    /// mutate the filesystem OR run arbitrary code / install deps) — wider
    /// than `codeStyleGuidance` because destructive risk applies to
    /// exec/install, not just file edits.
    public static let riskAwareGuidance = """
        ## Risk-aware actions

        - Default to acting. Local, reversible work — reading, editing a file, running a command or test, installing into the sandbox — just do it; you do not need to ask permission first.
        - Only pause to confirm for genuinely destructive or hard-to-undo actions: deleting the user's files, `rm -rf`, dropping data, force-pushing. The test is reversibility — if it's reversible, proceed.
        - When encountering unexpected state (unfamiliar files, unknown processes), investigate before removing anything.
        """

    // MARK: - Soul

    /// Renders the SOUL section — agent-authored, sandbox-only identity
    /// layer that complements the user-authored persona slot. Frames the
    /// content as the agent's own notes and explicitly tells the model
    /// that earlier sections (i.e. persona) take precedence on conflict.
    ///
    /// Returns `""` when `content` trims to empty so the composer's
    /// existing `PromptSection.isEmpty` filter drops the section without
    /// the caller having to second-guess the gate.
    ///
    /// Size policy (truncate at 8 KB on a line boundary) lives at the
    /// read site in `SystemPromptComposer.resolveSoul` — keeping the
    /// renderer pure means PR2's bootstrap seed and PR3's advert can
    /// reuse `soulSection` without dragging in I/O.
    public static func soulSection(_ content: String) -> String {
        let trimmed = stripLeadingSoulHeading(content.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return "" }
        return """
            ## SOUL

            The agent has recorded the following stable preferences and patterns \
            across prior sessions. These are the agent's own notes; the user's \
            instructions in earlier sections take precedence. Any plugin or tool \
            named in these notes is NOT automatically callable — bring it into \
            your schema with `capabilities_discover` / `capabilities_load` before \
            invoking it.

            \(trimmed)
            """
    }

    /// The seeded `~/SOUL.md` (and many hand-edited ones) begin with their own
    /// `# SOUL` title. Since `soulSection` already emits a `## SOUL` heading,
    /// keeping the file's title would render the heading twice. Strip a single
    /// leading markdown heading whose text is exactly "SOUL" (any `#` depth).
    private static func stripLeadingSoulHeading(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("#") else { return content }
        let headingText = first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        guard headingText.caseInsensitiveCompare("SOUL") == .orderedSame else { return content }
        lines.removeFirst()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sandbox

    /// Static sandbox framing — heading, environment block, tool-dispatch
    /// guide, and runtime hints. Every input is session-constant (the home
    /// path, combined-mode flag, and background flag don't change
    /// mid-session), so this section lives in the cached static prefix.
    ///
    /// Code style + risk-aware actions are NOT included here — they live as
    /// top-level sections gated on file-mutation tools being in the schema,
    /// so folder-mode agents doing real edits get the same discipline.
    ///
    /// The mid-session-mutable bits (installed packages + configured
    /// secrets) are rendered separately by `sandboxState(...)` and injected
    /// as a DYNAMIC section, so a `sandbox_install` or a freshly-added
    /// secret mid-session no longer rewrites the cached prefix.
    public static func sandbox(
        home: String = "",
        hostReadCombined: Bool = false,
        backgroundEnabled: Bool = false
    ) -> String {
        """

        \(sandboxSectionHeading)

        \(sandboxEnvironmentBlock(home: home))

        \(hostReadCombined ? sandboxToolGuideCombined(backgroundEnabled: backgroundEnabled) : sandboxToolGuide(backgroundEnabled: backgroundEnabled))

        \(sandboxRuntimeHints(hostReadCombined: hostReadCombined))
        """
    }

    /// Mid-session-mutable sandbox state: the installed-package summary and
    /// the configured-secret list. Relocated OUT of the static `sandbox`
    /// framing into a DYNAMIC prompt section so a `sandbox_install` or a new
    /// secret mid-session stays fresh without rewriting the cached KV prefix.
    /// Returns `""` when nothing is installed or configured so the composer
    /// drops the section entirely.
    #if !OSAURUS_INTEL
    public static func sandboxState(
        secretNames: [String] = [],
        installedPackages: SandboxPackageManifest.Installed = .init()
    ) -> String {
        var parts: [String] = []
        let installed = installedPackagesPromptBlock(installedPackages)
        if !installed.isEmpty { parts.append(installed) }
        let secrets = secretsPromptBlock(secretNames)
        if !secrets.isEmpty { parts.append(secrets) }
        // Each block is self-contained and trailing-newline terminated; the
        // composer trims the section, so a single `\n` join keeps the two
        // logical blocks on their own lines without a runaway blank run.
        return parts.joined(separator: "\n")
    }
    #endif

    // MARK: - Sandbox Building Blocks

    static let sandboxSectionHeading = "## Linux Sandbox Environment"
    static let sandboxReadFileHint =
        "`sandbox_read_file` with `start_line`/`line_count`/`tail_lines`"

    /// Combined-mode log-read hint: `sandbox_read_file` is hidden in
    /// combined mode (the unified `file_read` reaches `/workspace/...`),
    /// so point the model at `file_read` with `tail_lines` instead of a
    /// tool it can't call.
    static let sandboxReadFileHintCombined =
        "`file_read` with `tail_lines` (works on `/workspace/...` sandbox paths too)"

    /// Environment framing for the sandbox section. When `home` is supplied
    /// (the live composer always passes it), the opening line states the
    /// agent's ABSOLUTE home path and that commands run there by default —
    /// without this, models reliably guess the Linux convention `/root` for
    /// `cwd` on the first turn and eat a rejection. Falls back to the generic
    /// `~` wording when `home` is empty (callers that don't know it).
    private static func sandboxEnvironmentBlock(home: String) -> String {
        let homeLine =
            home.isEmpty
            ? "Your home directory (`~`) is your sandbox home; files persist across messages."
            : "Your home directory is `\(home)` (also `~` / `$HOME`); commands run there by "
                + "default — you don't need to pass `cwd` unless you want a different directory. "
                + "Files persist across messages."
        return """
            You have an isolated Alpine Linux ARM64 sandbox. \(homeLine)

            Internet access is available — fetch live or external data (weather, \
            web pages, APIs) directly with `curl`, `wget`, Python `requests`, or \
            Node `fetch`; you don't need a dedicated tool for it.

            Installed: bash, python3, node, git, curl, wget, jq, rg, sqlite3, \
            build-base, cmake, vim, tree, and standard POSIX utilities.
            """
    }

    /// The Shell-dispatch bullet, shared by both guides. Names
    /// `background:true` + `sandbox_process` only when the agent has opted
    /// into background jobs; otherwise it stays a plain single-line-shell
    /// line so the model isn't pointed at tools it doesn't have.
    private static func sandboxShellBullet(backgroundEnabled: Bool) -> String {
        backgroundEnabled
            ? "- Shell: `sandbox_exec` for single-line shell; use `background:true` for servers and `sandbox_process` to inspect them."
            : "- Shell: `sandbox_exec` for single-line shell."
    }

    private static func sandboxToolGuide(backgroundEnabled: Bool) -> String {
        let shellBullet = sandboxShellBullet(backgroundEnabled: backgroundEnabled)
        return """
            Tool dispatch:
            - Files: `sandbox_read_file` (read/list); `sandbox_write_file` (`content` whole-file, or `old_string`+`new_string` to edit).
            - Search: `sandbox_search_files` with `target="content"` or `target="files"`.
            \(shellBullet)
            - Multi-line code/scripts: `sandbox_write_file` the script, then `sandbox_exec` to run it (e.g. `python3 script.py`). NEVER embed multi-line code in `python3 -c` / `node -e`: the JSON→shell→code escaping breaks.
            - Run independent calls in parallel; chain dependent shell steps with `&&`.
            """
    }

    /// Combined-mode (`.sandbox(hostRead:)`) variant: the host `file_*`
    /// tools are the single, path-routed read family, so reads/lists/searches
    /// are NOT done with `sandbox_read_file` / `sandbox_search_files` (hidden
    /// in this mode). The `## Files` block spells out the path routing.
    private static func sandboxToolGuideCombined(backgroundEnabled: Bool) -> String {
        let shellBullet = sandboxShellBullet(backgroundEnabled: backgroundEnabled)
        return """
            Tool dispatch:
            - Read files / list dirs / search: `file_read` (reads a file or lists a directory — the path decides), `file_search` (they reach both your workspace and `/workspace/...` sandbox paths — see `## Files`).
            - Sandbox writes: `sandbox_write_file` (pass `content` to write the whole file, or `old_string`+`new_string` to edit one match — your workspace is read-only).
            \(shellBullet)
            - Multi-line code/scripts: `sandbox_write_file` the script, then `sandbox_exec` to run it (e.g. `python3 script.py`). NEVER embed multi-line code in `python3 -c` / `node -e`: the JSON→shell→code escaping breaks.
            - Run independent calls in parallel; chain dependent shell steps with `&&`.
            """
    }

    /// Runtime hints block. In combined mode the log-read hint points at
    /// `file_read` (the unified read tool) rather than the hidden
    /// `sandbox_read_file`, so the model is never steered toward a tool
    /// it can't see in this mode.
    private static func sandboxRuntimeHints(hostReadCombined: Bool) -> String {
        let logReadHint = hostReadCombined ? sandboxReadFileHintCombined : sandboxReadFileHint
        return """
            Runtime hints:
            - Install Python, Node, or system deps with `sandbox_install` (`manager`: `pip` / `npm` / `apk`).
            - Use \(logReadHint) to inspect large logs.
            - The sandbox is disposable; experiment freely.
            - Your `SOUL.md` at `~/SOUL.md` records stable preferences across sessions. Edit it with `sandbox_write_file` when you observe a durable pattern; edits apply on the next session.
            """
    }

    /// Per-manager cap on how many package names are listed before
    /// collapsing into a `+N more` tail. Keeps the always-on prefix bounded
    /// even for an agent that has installed dozens of packages.
    static let installedPackagesPromptCap = 12

    /// Compact, capped summary of what's already installed in the sandbox,
    /// grouped by manager. Rendered into the DYNAMIC `sandboxState` section
    /// (via `sandboxState(...)`) so it reflects live manifest state without
    /// busting the cached prefix. Returns `""` when nothing is recorded so
    /// the composer can append unconditionally.
    #if !OSAURUS_INTEL
    static func installedPackagesPromptBlock(_ installed: SandboxPackageManifest.Installed) -> String {
        guard !installed.isEmpty else { return "" }

        func line(_ label: String, _ names: [String]) -> String? {
            guard !names.isEmpty else { return nil }
            let shown = names.prefix(installedPackagesPromptCap)
            var joined = shown.joined(separator: ", ")
            let overflow = names.count - shown.count
            if overflow > 0 { joined += ", +\(overflow) more" }
            return "- \(label): \(joined)"
        }

        let lines = [
            line("System (apk)", installed.apk),
            line("Python (pip)", installed.pip),
            line("Node (npm)", installed.npm),
        ].compactMap { $0 }

        return """
            Already installed (don't reinstall — call directly):
            \(lines.joined(separator: "\n"))

            """
    }
    #endif

    private static func secretsPromptBlock(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let list = names.sorted().map { "- `\($0)`" }.joined(separator: "\n")
        return """
            Configured secrets (available as environment variables):
            \(list)
            Access via `$NAME` in shell, `os.environ["NAME"]` in Python, or `process.env.NAME` in Node.

            """
    }

    // MARK: - Folder Context

    /// Working-directory framing appended to the system prompt when chat
    /// is mounted on a host folder (`ExecutionMode.hostFolder`). Mirrors
    /// the sandbox section's structure: heading + environment metadata +
    /// path rule + tool dispatch + mode-specific framing + optional
    /// project context. Returns `""` when no folder is mounted so the
    /// composer can append unconditionally.
    public static func folderContext(
        from folderContext: FolderContext?,
        toolsAvailable: Bool = true
    ) -> String {
        guard let folder = folderContext else { return "" }

        var lines: [String] = ["## Working Directory"]
        lines.append("**Path:** \(folder.rootPath.path)")
        if folder.projectType != .unknown {
            lines.append("**Project Type:** \(folder.projectType.displayName)")
        }
        let topLevel = buildTopLevelSummary(from: folder.tree)
        if !topLevel.isEmpty {
            lines.append("**Root contents:** \(topLevel)")
        }
        var section = "\n" + lines.joined(separator: "\n") + "\n"

        if let status = folder.gitStatus {
            let trimmed = String(status.prefix(300))
            if !trimmed.isEmpty {
                section += "\n**Git status (uncommitted changes):**\n```\n\(trimmed)\n```\n"
            }
        }

        if toolsAvailable {
            section += """

                \(folderPathRule)

                \(folderToolGuide)

                \(folderArtifactReminder)

                """
        } else {
            section += """

                Folder tools are disabled for this turn. The root summary above is a cached hint, not a live inspection. Do not emit tool-call syntax as text, claim to have read files, or invent file contents. Ask the user to enable the needed tool if a live inspection is required.

                """
        }

        // Project-level guidance file (first-found-wins across AGENTS.md,
        // CLAUDE.md, .hermes.md, .cursorrules). Loaded once at folder-mount
        // time and stamped onto the FolderContext so it lives in the static
        // prefix and doesn't break KV-cache reuse across turns. Capped at
        // 20K chars with head+tail truncation by FolderContextService.
        if let contextFiles = folder.contextFiles, !contextFiles.isEmpty {
            section += """

                ## Project Context

                The following project context file has been loaded and should be followed:

                \(contextFiles)

                """
        }

        return section
    }

    // MARK: - Folder Building Blocks

    /// One-line restatement of the path-arg rule. Each `file_*` tool's
    /// description carries the per-arg detail; this lives in the prompt
    /// so the rule is anchored once at the top of the section instead of
    /// repeated in every dispatch bullet.
    static let folderPathRule =
        "Use paths relative to the working directory; an absolute path is accepted only if it is inside the working directory (paths outside it are rejected)."

    /// Positive dispatch table for the folder-mode tools. Mirror of
    /// `sandboxToolGuide` — discipline ("instead of cat / sed / awk")
    /// lives in each tool's description.
    static let folderToolGuide = """
        Tool dispatch (each tool's description has full detail and the \
        shell pattern it replaces):
        - Read / list: `file_read` to read a file or list a directory — the path decides (optional line range, or `max_depth` for a directory).
        - Search: `file_search` for content (case-insensitive substring), or `target:"files"` to find files by name (case-insensitive substring, e.g. `q4`).
        - Find a file by name: use `file_search` with `target:"files"` and a short distinctive token from the name (not the whole phrase).
        - Edit: `file_edit` for targeted in-place edits, `file_write` for new files or full rewrites.
        - Copy a file: `file_copy` (binary-safe, undoable).
        - Shell: `shell_run` for `mv` / `rm` / `mkdir` (write/exec ops are logged and undoable).
        """

    /// Folder-mode-specific reminder: filesystem changes ARE visible to
    /// the user (unlike sandbox), but only `share_artifact` surfaces an
    /// artifact card in the chat thread.
    static let folderArtifactReminder = """
        **Files land in the working folder, not in chat.** When you create or edit a file with `file_write` / `file_edit`, the user can see it on disk and in the operations log. If the user needs the deliverable to appear in the chat thread (an image, chart, generated text, report, code blob), additionally call `share_artifact` — it's the only thing that surfaces an artifact card.
        """

    // MARK: - Combined Sandbox + Host-Read

    /// Read-only host-workspace framing for combined mode
    /// (`ExecutionMode.sandbox(hostRead: ctx)`). Rendered AFTER the
    /// sandbox section so the agent reads the sandbox framing first,
    /// then learns the host workspace is a separate, read-only
    /// filesystem. Unlike `folderContext` this marks the workspace
    /// read-only, lists only the read tools, and appends the
    /// two-filesystem block. Returns "" when no host-read folder is
    /// attached so the composer can append unconditionally.
    public static func combinedHostRead(
        from folderContext: FolderContext?,
        allowSecretReads: Bool = false
    ) -> String {
        guard let folder = folderContext else { return "" }

        var lines: [String] = ["## Host Workspace (read-only)"]
        lines.append("**Path:** \(folder.rootPath.path)")
        if folder.projectType != .unknown {
            lines.append("**Project Type:** \(folder.projectType.displayName)")
        }
        let topLevel = buildTopLevelSummary(from: folder.tree)
        if !topLevel.isEmpty {
            lines.append("**Root contents:** \(topLevel)")
        }
        var section = "\n" + lines.joined(separator: "\n") + "\n"

        if let status = folder.gitStatus {
            let trimmed = String(status.prefix(300))
            if !trimmed.isEmpty {
                section += "\n**Git status (uncommitted changes):**\n```\n\(trimmed)\n```\n"
            }
        }

        section += """

            \(unifiedFilesBlock(allowSecretReads: allowSecretReads))

            """

        // Same project-context file the folder section surfaces, loaded
        // once at folder-mount time so it lives in the static prefix.
        if let contextFiles = folder.contextFiles, !contextFiles.isEmpty {
            section += """

                ## Project Context

                The following project context file has been loaded and should be followed:

                \(contextFiles)

                """
        }

        return section
    }

    /// The load-bearing mental model for combined mode under the unified,
    /// path-routed file tools: ONE reader (`file_read`, which also lists
    /// directories) and ONE search tool (`file_search`) reach two storage
    /// areas by path — the read-only workspace (default) and the
    /// `/workspace/...` sandbox scratch area; one writer
    /// (`sandbox_write_file`, which also edits) targets the sandbox. This
    /// replaces the older `## Two filesystems` framing that asked the model
    /// to pick between `file_*` and `sandbox_*` read families (the
    /// disambiguation weak models kept getting wrong). The final sentence
    /// reflects the per-agent secret-read setting.
    static func unifiedFilesBlock(allowSecretReads: Bool) -> String {
        let secretLine =
            allowSecretReads
            ? "Workspace secret files (`.env`, keys, credentials) are readable because you enabled secret reads — handle them carefully and never copy them into the sandbox or off-host."
            : "Workspace secret files (`.env`, keys, credentials) are refused."
        return """
            ## Files

            One reader and one search tool reach two storage areas by path:
            - **Workspace** (your read-only host folder) — the default. For "what's in my workspace / on my Desktop", use `file_read` (it reads a file or lists a directory) and `file_search`. Relative paths and `/Users/...` paths are the workspace.
            - **Sandbox** scratch area — pass a `/workspace/...` path to the SAME `file_read` / `file_search`.

            The workspace is read-only: create or change files with `sandbox_write_file` (pass `content` to write the whole file, or `old_string`+`new_string` to edit one match — it writes the sandbox), and run commands with `sandbox_exec` (it runs in the sandbox, which has no copy of the workspace — `file_read` a workspace file and pass its content in if a command needs it). Surface results with `share_artifact`. \(secretLine)
            """
    }

    private static func buildTopLevelSummary(from tree: String) -> String {
        let lines = tree.components(separatedBy: .newlines)
        let topLevel = lines.compactMap { line -> String? in
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            let treeChars = CharacterSet(charactersIn: "│├└─ \u{00A0}")
            let indentPrefix = line.prefix(while: { char in
                char.unicodeScalars.allSatisfy { treeChars.contains($0) }
            })
            guard indentPrefix.count <= 4 else { return nil }
            return stripped.trimmingCharacters(in: treeChars)
        }
        .filter { !$0.isEmpty }

        if topLevel.count <= 8 {
            return topLevel.joined(separator: ", ")
        }
        let shown = topLevel.prefix(6)
        return shown.joined(separator: ", ") + ", and \(topLevel.count - 6) other items"
    }

    // MARK: - Subagent guidance (upstream, docs/SUBAGENTS_INTEL.md)
    //
    // Upstream's text, kept verbatim for the subagent capability registry.
    // Intel does not render these yet; each kind adjusts its wording to
    // Intel facts (cloud models, no local swaps) when it is wired in.


    /// Computer Use grounding. Rendered only when the `computer_use` tool
    /// actually resolves into the schema (custom-agent opt-in via
    /// `computerUseEnabled`), so the prompt never advertises desktop
    /// automation the model can't invoke. Mirrors the tool's own contract:
    /// one whole-task `goal`, AX-first perception, and the read-auto /
    /// edit-confirm autonomy gate — stated plainly, not coerced.
    public static let computerUseGuidance = """
        ## Computer use

        - You can operate macOS apps for the user with `computer_use` — it drives a real app from the on-screen accessibility tree (clicking, typing, reading on-screen text), falling back to a screenshot only when an element can't be resolved.
        - Describe the WHOLE task in a single `goal`. It runs a self-contained subagent that perceives, acts, and verifies each step on its own and returns a summary — do not try to script individual clicks from here.
        - Reads and navigation run automatically; edits and anything consequential pause for the user to approve. Write the goal plainly and let that gate handle confirmation — don't ask the user for permission yourself first.
        - Use it for desktop UI automation (filling a form, navigating an app, extracting on-screen content), NOT for shell, files, or web requests — those have dedicated tools.
        """

    /// Browser Use grounding. Rendered only when the `browser_use` tool
    /// actually resolves into the schema (custom-agent opt-in via
    /// `browserUseEnabled`; the Default agent is hard-off). Mirrors the
    /// tool's contract: one whole-task `goal`, a
    /// persistent per-agent signed-in session, and the read-auto /
    /// edit-confirm autonomy gate — stated plainly, not coerced.
    public static let browserUseGuidance = """
        ## Browser use

        - You can browse the web for the user with `browser_use` — it drives a real, persistent browser session that belongs to this agent (cookies and sign-ins survive across chats), navigating, reading pages, clicking, and filling forms.
        - Describe the WHOLE task in a single `goal`. It runs a self-contained subagent that perceives each page, acts, and verifies on its own and returns a summary — do not try to script individual clicks from here.
        - Reads and ordinary navigation run automatically; typing into pages and anything consequential (submitting, purchasing, sending, deleting, signing in) pause for the user to approve. Write the goal plainly and let that gate handle confirmation.
        - If a site needs the user to sign in, the subagent opens a secure sign-in window — NEVER ask the user for passwords or 2FA codes in chat.
        - Use it for interacting with websites (checking a dashboard, filling a web form, extracting page content behind a login), NOT for simple lookups — `web_search` is faster for those.
        """

    /// Authoritative image directive (generate + edit). Schema-gated on `image`
    /// in the composer, so it only renders when the tool is actually callable;
    /// the composer swaps in the generation-only variant below when no ready
    /// edit model is installed. Counters the persona-led refusal ("I'm
    /// text-only / I can't make images") and keeps the edit-continuation
    /// CONDITIONAL (never a forced "now edit it").
    public static let imageGenerationGuidance = """
        ## Image generation

        - You CAN create and edit images with the `image` tool. To create, call `image` with a `prompt`. To edit an existing image, call `image` with a `prompt` PLUS `source_paths` set to the image path(s) — `source_paths` is what switches it into edit mode.
        - NEVER claim you can't make images or are "text-only", and don't redirect the user to another app or settings — you have this tool, so use it.
        - The result renders inline in the chat automatically; do not call `share_artifact` for it. If the user asked for a follow-up edit of that image, call `image` again with `source_paths` set to the saved result path; otherwise confirm briefly in one sentence.
        - The job runs locally and may briefly swap models; that is expected.
        """

    /// Compact generate + edit directive for small local models: same behavior
    /// at a fraction of the tokens (anti-refusal, edit-mode switch, inline
    /// render / no `share_artifact`, conditional edit-continuation).
    public static let imageGenerationGuidanceCompact = """
        ## Image generation
        - You CAN create/edit images with the `image` tool: call it with a `prompt`; add `source_paths` (existing image path[s]) to edit instead of create.
        - NEVER say you can't make images or are "text-only", and don't redirect to another app or settings — use the tool.
        - The result renders inline automatically; don't call `share_artifact`. For a requested follow-up edit, call `image` again with `source_paths` set to the saved path; otherwise confirm briefly.
        """

    /// Generation-only image directive, selected by the composer when NO ready
    /// edit model is installed (the `image` schema is the edit-free variant
    /// there too). Omits every edit affordance so the prompt never claims an
    /// edit the runtime can't perform, while keeping the anti-refusal rule.
    public static let imageGenerationOnlyGuidance = """
        ## Image generation

        - You CAN create images with the `image` tool: call `image` with a `prompt`. Editing existing images is not available, so do not offer or attempt it.
        - NEVER claim you can't make images or are "text-only", and don't redirect the user to another app or settings — you have this tool, so use it.
        - The result renders inline in the chat automatically; do not call `share_artifact` for it. Confirm briefly in one sentence.
        - The job runs locally and may briefly swap models; that is expected.
        """

    /// Compact generation-only directive for small local models.
    public static let imageGenerationOnlyGuidanceCompact = """
        ## Image generation
        - You CAN create images with the `image` tool: call it with a `prompt`. Editing existing images is not available — don't offer or attempt it.
        - NEVER say you can't make images or are "text-only", and don't redirect to another app or settings — use the tool.
        - The result renders inline automatically; don't call `share_artifact`. Confirm briefly.
        """

    /// AppleScript automation grounding. Rendered only when the `applescript`
    /// tool actually resolves into the schema (per-agent enable + an installed
    /// AppleScript model), so the prompt never advertises automation the model
    /// can't invoke. Mirrors the tool's contract: one whole-task `task`, an
    /// on-device subagent that writes + runs the script, and the user's
    /// execution-mode gate — stated plainly, not coerced.
    public static let appleScriptGuidance = """
        ## Mac automation (AppleScript)

        - Two tools drive this Mac with an on-device AppleScript model (Finder, Safari, Mail, Notes, Music, Calendar, System Events, app + system state). Both write and run the script for you — do NOT write AppleScript yourself from here.
        - Use `mac_query` ONLY when the current user's requested outcome is read-only (e.g. "the front Safari tab URL", "the selected Finder items", "the current track and volume"). It runs read-only, needs no confirmation, and returns the actual `values` plus a per-step transcript. If the current request asks to change anything, NEVER call `mac_query` first as a preflight; call `applescript` directly because that automation validates its live target before editing. Do not invent a Mac-state question merely to acknowledge feedback or conversation.
        - To CHANGE something, call `applescript` with the whole task. Depending on the user's setting each script is shown for approval or auto-run with a warning, so write the task plainly and let that gate handle confirmation — don't ask the user for permission yourself first.
        - When the task must insert EXACT text (a verbatim transcription, quotes, code, or a long note body), pass that text in `applescript`'s `content` argument and keep `task` as the instruction (e.g. task "Set the body of the note 'Quotes' to the provided content", content = the exact text). The subagent inserts it verbatim via a placeholder, so nothing is dropped, reordered, or mis-escaped — never paste large literal text only into `task`.
        - When the task needs SEVERAL exact blocks (a subject and a body, say), pass them in `applescript`'s `contents` argument as a `{name: text}` map (e.g. contents = {"subject": …, "body": …}); the subagent inserts each verbatim via its own placeholder. This is REQUIRED for text replacement even when both strings are short: use `contents={"oldText": old, "newText": replacement}` and phrase `task` as "replace the provided oldText with the provided newText". Never leave replacement strings only inside `task`. Use `content` for a single block and `contents` for several.
        - For an existing open document, name the app or exact path already identified by the request or conversation. Explicit `the file` / `the document` wording is working-app anaphora: call `applescript` with that phrase unchanged so its tracked-frontmost context can resolve it; do not ask for a path first. Never invent a file picker, new file, output file, or save step. An edit does not imply saving.
        - Exact identifiers count as verbatim too: when the task must match an EXISTING thing by its precise name — a note title, file path, mailbox, playlist, contact, or URL — pass that name as a named literal in `contents` alongside any body (e.g. contents = {"target": "Q3 Planning — Notes (v2)", "body": …}) and phrase `task` to use it ("set the body of the provided note to the provided body"). The subagent then references `{{target}}` instead of re-typing the name, so a long or unusual one can't be mistyped into a "not found" error. Names you're only paraphrasing can stay in `task`.
        - Both return a structured result: `status` (succeeded/partial/failed), the returned `values`, and `steps`/`errors` with the real AppleScript error numbers. Read the `values` to confirm the outcome, and use `errors` to retry or to tell the user exactly what to fix (e.g. grant Automation permission).
        - Use these for documents open in Mac apps and other AppleScript / Apple Events automation. Use file tools only for path-addressed files in a selected folder/sandbox; use dedicated tools for shell or web requests.
        """

    /// Compact AppleScript directive for small local models: same behavior at a
    /// fraction of the tokens (the read-vs-change tool split, the structured
    /// result, and the not-for-shell/files/web boundary).
    public static let appleScriptGuidanceCompact = """
        ## Mac automation (AppleScript)
        - Use `mac_query(question)` ONLY when the current user's requested outcome is read-only (Finder, Safari, Mail, Music, System Events, volume, …). If the request asks to change anything, NEVER call it first as a preflight; call `applescript` directly because that automation validates its live target before editing. Never invent a state question just to acknowledge feedback/conversation.
        - To CHANGE something use `applescript(task)`: each script is shown for approval or auto-run per the user's setting. Don't write AppleScript yourself.
        - To insert EXACT/verbatim text (transcription, quote, code, long body) OR an exact existing identifier that must match precisely (a note title, file path, mailbox, or URL), always include the required instruction as `task` and pass the exact value separately: `applescript(task="Set the document to the provided content", content=…)` or `applescript(task="Use the provided named values", contents={name:text})`. `task` is still required when `content`/`contents` is present. Reference the supplied value by placeholder — it is reproduced verbatim instead of re-typed, so an exact name can't be mistyped. For replacement this is required even for short strings: `contents={oldText:old,newText:new}` and a task referring to the provided old/new values. Use `contents` for several blocks.
        - Existing-document edits name the app/path from the request or conversation. Preserve explicit `the file`/`the document` working-app wording in `applescript(task)` so tracked-frontmost resolution can handle it; do not ask for a path first. Never invent a picker/new file/output/save step. Editing does not imply saving.
        - Both return `status` + `values` + `errors` (with AppleScript error numbers) — read `values` to confirm, use `errors` to retry/fix. Use AppleScript for documents open in Mac apps; file tools are only for path-addressed files in a selected folder/sandbox. Not for shell or web.
        """

    /// Intel's AppleScript guidance: upstream's text with its one Apple
    /// Silicon fact replaced. On Intel a helper on a cloud model writes and
    /// runs the script, not an on-device AppleScript model
    /// (docs/SUBAGENTS_INTEL.md, layer 3).
    public static let intelAppleScriptGuidance = appleScriptGuidance.replacingOccurrences(
        of: "Two tools drive this Mac with an on-device AppleScript model",
        with: "Two tools drive this Mac through an AppleScript helper (it runs on this chat's model, or the agent's chosen AppleScript model)"
    )
}
