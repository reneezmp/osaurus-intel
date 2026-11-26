//
//  IntelClaudeCodeTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing
@testable import OsaurusCore

@Suite("Intel Claude Code integration")
struct IntelClaudeCodeTests {
    /// The picker rows are gone (Claude Code is a harness runtime), but the
    /// ids still parse: the launch migration turns them into aliases.
    @Test func legacyPickerIdsStillParseForTheMigration() {
        for model in ClaudeCodeModel.allCases {
            #expect(ClaudeCodeModel.fromPickerId(model.pickerId) == model)
        }
        #expect(ClaudeCodeModel.fromPickerId("default") == nil)
        #expect(ClaudeCodeModel.fromPickerId("claude-code/unknown") == nil)
    }

    @Test func textOnlyArgumentsDisableToolsAndPreserveStreaming() throws {
        let args = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .textOnly,
            allowedTools: ["Read", "Bash"],
            systemPrompt: "Be concise."
        )
        let toolsIndex = try #require(args.firstIndex(of: "--tools"))
        #expect(args[toolsIndex + 1].isEmpty)
        #expect(!args.contains("--allowedTools"))
        #expect(!args.contains("--permission-mode"))
        #expect(args.contains("--include-partial-messages"))
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--append-system-prompt"))
    }

    @Test func folderAgentArgumentsAllowAuthorizedWorkspaceToolsWithoutBypass() throws {
        let tools = ClaudeCodeConfiguration.allowedTools(allowWrites: true, allowShell: true)
        let args = ClaudeCodeConfiguration.arguments(
            model: .haiku,
            mode: .agent,
            allowedTools: tools,
            systemPrompt: "Stay in the selected folder."
        )
        let permissionIndex = try #require(args.firstIndex(of: "--permission-mode"))
        let toolsIndex = try #require(args.firstIndex(of: "--allowedTools"))
        #expect(args[permissionIndex + 1] == "dontAsk")
        #expect(Set(args[toolsIndex + 1].split(separator: ",").map(String.init)) == Set([
            "Read", "Grep", "Glob", "Edit", "Write", "NotebookEdit", "Bash", "Monitor",
        ]))
        #expect(!args.contains("--dangerously-skip-permissions"))
        #expect(!args.contains("--allow-dangerously-skip-permissions"))
    }

    // MARK: - Hidden tools (upstream #3293)

    @Test func toolsWithoutATogglesAreHiddenNotJustRefused() {
        let none = ClaudeCodeConfiguration.hiddenBuiltinTools(allowWrites: false, allowShell: false)
        for tool in ["Bash", "Monitor", "CronCreate", "LSP", "RemoteTrigger", "Workflow", "Edit", "Write",
            "NotebookEdit", "WebFetch", "WebSearch"]
        {
            #expect(none.contains(tool), "\(tool) must be hidden")
        }
        let all = ClaudeCodeConfiguration.hiddenBuiltinTools(allowWrites: true, allowShell: true)
        #expect(Set(all) == Set(["WebFetch", "WebSearch"]))
        // A deny beats an allow, so nothing granted may be hidden.
        let granted = Set(ClaudeCodeConfiguration.allowedTools(allowWrites: false, allowShell: true))
        let hidden = Set(ClaudeCodeConfiguration.hiddenBuiltinTools(allowWrites: false, allowShell: true))
        #expect(granted.isDisjoint(with: hidden))
        #expect(hidden.contains("Edit") && !hidden.contains("Bash") && !hidden.contains("Monitor"))
    }

    @Test func agentArgumentsPassDisallowedTools() throws {
        let args = ClaudeCodeConfiguration.arguments(
            model: .haiku,
            mode: .agent,
            allowedTools: ["Read"],
            systemPrompt: nil,
            disallowedTools: ["Bash", "Monitor"]
        )
        let index = try #require(args.firstIndex(of: "--disallowedTools"))
        #expect(args[index + 1] == "Bash,Monitor")
        let textOnly = ClaudeCodeConfiguration.arguments(
            model: .haiku, mode: .textOnly, allowedTools: [], systemPrompt: nil, disallowedTools: ["Bash"])
        #expect(!textOnly.contains("--disallowedTools"))
    }

    @Test func effortAndThinkingSummariesAreRequested() throws {
        for mode in [ClaudeCodeMode.agent, .textOnly] {
            let args = ClaudeCodeConfiguration.arguments(
                model: .fable, mode: mode, allowedTools: [], systemPrompt: nil, effort: .xhigh)
            let effort = try #require(args.firstIndex(of: "--effort"))
            #expect(args[effort + 1] == "xhigh")
            let display = try #require(args.firstIndex(of: "--thinking-display"))
            #expect(args[display + 1] == "summarized")
        }
        let plain = ClaudeCodeConfiguration.arguments(
            model: .sonnet, mode: .agent, allowedTools: [], systemPrompt: nil)
        #expect(!plain.contains("--effort"))
        #expect(ClaudeCodeModel.fromPickerId("claude-code/fable") == .fable)
    }

    @Test func effortSurvivesAgentRoundTripAndOldAgentsDecode() throws {
        let config = ClaudeCodeAgentConfig(effort: " Max ")
        let decoded = try JSONDecoder().decode(ClaudeCodeAgentConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.resolvedEffort == .max)
        let legacy = try JSONDecoder().decode(ClaudeCodeAgentConfig.self, from: Data(#"{"allowShell":true}"#.utf8))
        #expect(legacy.resolvedEffort == nil)
        #expect(ClaudeCodeAgentConfig(effort: "turbo").resolvedEffort == nil)
    }

    @Test func refusalMessagesNameTheSettingToChange() {
        #expect(ClaudeCodeConfiguration.permissionDeniedMessage(tool: "Monitor").contains("Allow shell commands"))
        #expect(ClaudeCodeConfiguration.permissionDeniedMessage(tool: "Write").contains("Allow file changes"))
    }

    @Test func authStatusShapesDecodeWithoutCredentialAccess() throws {
        let signedIn = try #require(ClaudeCodeConfiguration.decodeAuthStatus(Data(
            #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","newField":1}"#.utf8
        )))
        #expect(signedIn.loggedIn)
        #expect(signedIn.displayPlan == "Max")
        #expect(signedIn.usesSubscription)

        let signedOut = try #require(ClaudeCodeConfiguration.decodeAuthStatus(Data(
            #"{"loggedIn":false}"#.utf8
        )))
        #expect(!signedOut.loggedIn)
    }

    @Test func executableSearchIncludesOfficialInstallerLocation() {
        let entries = ExecutableLocator.searchPath(env: ["PATH": "/usr/bin"])
            .split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(entries.contains("\(home)/.local/bin"))
        #expect(entries.contains("/usr/local/bin"))
    }

    @Test func subprocessEnvironmentExcludesCredentialAndRoutingOverrides() {
        let environment = ClaudeCodeConfiguration.subprocessEnvironment(source: [
            "PATH": "/fixture/bin",
            "HOME": "/fixture/home",
            "USER": "fixture-user",
            "LANG": "en_US.UTF-8",
            "ANTHROPIC_API_KEY": "secret",
            "ANTHROPIC_AUTH_TOKEN": "secret",
            "ANTHROPIC_BASE_URL": "https://redirect.invalid",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "AWS_SECRET_ACCESS_KEY": "secret",
            "HTTPS_PROXY": "https://proxy.invalid",
        ])
        #expect(environment["HOME"] == "/fixture/home")
        #expect(environment["USER"] == "fixture-user")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["PATH"]?.contains("/fixture/bin") == true)
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(environment["ANTHROPIC_BASE_URL"] == nil)
        #expect(environment["CLAUDE_CODE_USE_BEDROCK"] == nil)
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(environment["HTTPS_PROXY"] == nil)
    }
}
