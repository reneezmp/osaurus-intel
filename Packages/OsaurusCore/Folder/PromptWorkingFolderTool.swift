//
//  PromptWorkingFolderTool.swift
//  osaurus
//
//  `prompt_working_folder` (upstream #2918, adapted for Intel). When a chat
//  has no working folder the file/shell tools are not registered, so the
//  model could only ask for a folder in prose. This tool opens the same
//  folder picker as the chat's Folder button (as a sheet on the chat window,
//  with the model's reason as the panel message) and attaches the pick to
//  the chat. The chat then ends the run and continues on its own with the
//  folder bound, so the file tools become callable without the user typing.
//
//  Intel differences from upstream:
//   - Offered only by an attended chat window with no folder, for custom
//     agents (`ChatSession.canPromptForWorkingFolder`); the session passes
//     itself through `ChatExecutionContext.currentChatSessionBox` for that
//     run only. Background dispatches, delegated children (which get no
//     tools) and HTTP never see it.
//   - The pick is attached to THIS chat only. Intel's per-agent default
//     folder stays an explicit choice (Folder chip › "Use as Default for …"),
//     and there is no sandbox to switch off.
//

import AppKit
import Foundation

/// Outcome of an in-turn folder prompt, distinct per terminal reason so the
/// tool envelope never claims the user declined a picker they never saw.
enum WorkingFolderPromptOutcome: Sendable, Equatable {
    /// A folder was attached to the chat.
    case attached(path: String)
    /// The user dismissed the picker without choosing.
    case cancelled
    /// The pick could not be applied (session gone, bookmark failure, …).
    case failed(String)
}

/// Weak handle to the chat that is running a tool call, so the picker can
/// attach to it without the tool keeping the session alive.
final class WeakChatSessionBox: @unchecked Sendable {
    weak var session: ChatSession?
    init(_ session: ChatSession) { self.session = session }
}

final class PromptWorkingFolderTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "prompt_working_folder"
    let name = PromptWorkingFolderTool.toolName
    let description =
        "Ask the user to pick a working folder when the task needs to read, write, search or run "
        + "files and this chat has no working folder attached. "
        + "Use it instead of asking in prose when file_read, file_write, file_edit, file_search or "
        + "shell_run are missing from your tools. It opens the folder picker; once the user "
        + "chooses, the folder is attached to this chat, the file tools become available, and "
        + "your run continues automatically. Pass a short `reason` the user will see in the "
        + "picker. If the user cancels, deliver the content directly in your answer rather than "
        + "asking again."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "reason": .object([
                "type": .string("string"),
                "description": .string(
                    "One short sentence shown to the user in the picker explaining what you need "
                        + "the folder for (e.g. \"Save the generated report as report.md\")."
                ),
            ])
        ]),
        "required": .array([.string("reason")]),
    ])

    /// Names the model regains once a folder is attached.
    static let unlockedToolNames: [String] = [
        "file_read", "file_search", "file_write", "file_edit", "shell_run",
    ]

    /// Shared recovery clause for "no working folder" messages.
    static let attachFolderSteer =
        "Call `prompt_working_folder` to open a folder picker for the user; if that tool is not "
        + "in your tools, ask the user to choose a folder with the Folder button in the chat bar."

    /// Test seam: replaces the AppKit picker. Receives the reason and returns
    /// the folder to attach (nil = the user cancelled). Task-local so suites
    /// that do not bind it keep the headless refusal below.
    typealias TestPicker = @Sendable (_ reason: String) async -> URL?

    @TaskLocal
    static var pickerOverrideForTests: TestPicker?

    /// A real pick blocks on an `NSOpenPanel` only a click resolves; refusing
    /// is the deterministic answer in a test process without the override.
    private static var isHeadlessTestProcess: Bool {
        RuntimeEnvironment.isUnderTests && pickerOverrideForTests == nil
    }

    init() {}

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let reasonReq = requireString(
            args,
            "reason",
            expected: "one short sentence naming what the folder is needed for",
            tool: name
        )
        guard case .value(let rawReason) = reasonReq else { return reasonReq.failureEnvelope ?? "" }
        let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`reason` must be a non-empty sentence the user will see in the picker.",
                field: "reason",
                expected: "non-empty reason string",
                tool: name
            )
        }

        // Only an attended chat binds the box (see ChatSession); background
        // runs, HTTP and anything else have nobody to click a picker.
        guard let box = ChatExecutionContext.currentChatSessionBox else {
            return Self.unavailableEnvelope(
                "prompt_working_folder only works in an attended Osaurus chat window; this run has "
                    + "no user present to pick a folder. Continue without file tools and say why."
            )
        }
        if Self.isHeadlessTestProcess {
            return Self.unavailableEnvelope(
                "prompt_working_folder cannot present a folder picker in a headless process."
            )
        }
        let outcome = await Self.runOnSession(box: box, reason: reason, testPicker: Self.pickerOverrideForTests)
        return Self.envelope(for: outcome, reason: reason)
    }

    @MainActor
    private static func runOnSession(
        box: WeakChatSessionBox,
        reason: String,
        testPicker: TestPicker?
    ) async -> WorkingFolderPromptOutcome {
        guard let session = box.session else {
            return .failed("the chat session that started this run is gone")
        }
        return await session.promptWorkingFolderFromTool(reason: reason, testPicker: testPicker)
    }

    // MARK: - Envelopes

    private static func unavailableEnvelope(_ message: String) -> String {
        ToolEnvelope.failure(kind: .unavailable, message: message, tool: toolName, retryable: false)
    }

    static func envelope(for outcome: WorkingFolderPromptOutcome, reason: String) -> String {
        switch outcome {
        case .attached(let path):
            return ToolEnvelope.success(
                tool: toolName,
                result: [
                    "text":
                        "Working folder attached: \(path). The file tools ("
                        + unlockedToolNames.joined(separator: ", ")
                        + ") are now available and your run continues with this folder as the root. "
                        + "Use paths relative to it.",
                    "path": path,
                    "tools": unlockedToolNames,
                    "reason": reason,
                ]
            )
        case .cancelled:
            // Shown to the user and kept for the model's next turn: word it
            // for both readers.
            return ToolEnvelope.failure(
                kind: .userDenied,
                message:
                    "The folder picker was dismissed, so no working folder was attached and nothing "
                    + "was written. To save files, choose a folder with the Folder button or ask again; "
                    + "otherwise the content can be given directly in the chat.",
                tool: toolName,
                retryable: false
            )
        case .failed(let message):
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "The folder could not be attached: \(message). Ask the user to choose a folder with "
                    + "the Folder button, or give the content directly in the chat.",
                tool: toolName,
                retryable: false
            )
        }
    }
}

// MARK: - ChatSession seam

extension ChatSession {
    /// Whether this session may offer `prompt_working_folder` this turn: an
    /// attended chat window (not a background dispatch), a custom agent (the
    /// Orchestrator never writes files), tools on, and no folder yet.
    var canPromptForWorkingFolder: Bool {
        guard windowState != nil, dispatchTaskId == nil else { return false }
        switch source {
        case .chat, .imported: break
        default: return false
        }
        let agent = agentId ?? Agent.defaultId
        guard agent != Agent.defaultId else { return false }
        return !folderState.hasActiveFolder
    }

    /// Run the Folder button's pick from a tool call: present the picker as a
    /// sheet on this chat's window and attach the choice to the chat.
    func promptWorkingFolderFromTool(
        reason: String,
        testPicker: PromptWorkingFolderTool.TestPicker?
    ) async -> WorkingFolderPromptOutcome {
        if folderState.hasActiveFolder, let path = folderState.persistedPath {
            return .failed(
                "this chat already has a working folder (\(path)); the file tools are available "
                    + "on the next turn"
            )
        }
        let picked: FolderContext?
        if let testPicker {
            guard let url = await testPicker(reason) else { return .cancelled }
            picked = await folderState.setFolder(url)
            if picked == nil { return .failed("the chosen folder could not be opened") }
        } else {
            let window = windowState.flatMap { ChatWindowManager.shared.getNSWindow(id: $0.windowId) }
            picked = await folderState.selectFolder(from: window, message: reason)
            // nil covers both a cancel and a failed bookmark; neither left a
            // folder behind to roll back.
            guard picked != nil else { return .cancelled }
        }
        let path = folderState.persistedPath ?? picked?.rootPath.standardizedFileURL.path ?? ""
        return .attached(path: path)
    }
}
