//
//  ToolExecutionSurfaceTests.swift
//  osaurusTests
//
//  Pins the execution-surface answer shown on the approval card
//  (osaurus#2651): the public workspace tools keep one name in
//  every mode and are routed to the VM at execution time, so the surface
//  must be derived from the same state the tool body routes on.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Pure resolution

struct ToolExecutionSurfaceResolutionTests {

    @Test("pure VM mode routes every workspace tool into the sandbox")
    func pureVMModeIsSandbox() {
        for name in ToolExecutionSurface.contextRoutedToolNames {
            #expect(
                ToolExecutionSurface.forContextRoutedTool(
                    name: name,
                    pathArgument: "notes.md",
                    hasSandboxBridge: true,
                    hasFolderRoot: false
                ) == .sandboxVM,
                "\(name) with no host root must serve the VM"
            )
        }
    }

    @Test("no sandbox bridge means the host, whatever the path says")
    func noBridgeIsHost() {
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "file_write",
                pathArgument: "/workspace/out.txt",
                hasSandboxBridge: false,
                hasFolderRoot: false
            ) == .nativeHost
        )
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "shell_run",
                pathArgument: nil,
                hasSandboxBridge: false,
                hasFolderRoot: true
            ) == .nativeHost
        )
    }

    @Test("shell_run with a host root never bridges into the VM")
    func shellRunWithRootIsHost() {
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "shell_run",
                pathArgument: nil,
                hasSandboxBridge: true,
                hasFolderRoot: true
            ) == .nativeHost
        )
    }

    @Test("file tools with a host root route by the /workspace prefix")
    func fileToolsRouteByPathWithRoot() {
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "file_write",
                pathArgument: "/workspace/shared/out.txt",
                hasSandboxBridge: true,
                hasFolderRoot: true
            ) == .sandboxVM
        )
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "file_write",
                pathArgument: "src/main.swift",
                hasSandboxBridge: true,
                hasFolderRoot: true
            ) == .nativeHost
        )
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "file_read",
                pathArgument: nil,
                hasSandboxBridge: true,
                hasFolderRoot: true
            ) == .nativeHost
        )
    }

    @Test("routed path argument is `path`, or `destination` for file_copy")
    func routedPathArgument() {
        #expect(
            ToolExecutionSurface.routedPathArgument(
                toolName: "file_write",
                argumentsJSON: #"{"path":"/workspace/a.txt","content":"x"}"#
            ) == "/workspace/a.txt"
        )
        #expect(
            ToolExecutionSurface.routedPathArgument(
                toolName: "file_copy",
                argumentsJSON: #"{"source":"a.txt","destination":"/workspace/b.txt"}"#
            ) == "/workspace/b.txt"
        )
        #expect(
            ToolExecutionSurface.routedPathArgument(toolName: "shell_run", argumentsJSON: "not json") == nil
        )
    }

    @Test("MCP tools follow the provider's transport and execution host")
    func mcpProviderSurface() {
        #expect(ToolExecutionSurface.forMCPProvider(transport: .http, executionHost: .sandbox) == .remoteServer)
        #expect(ToolExecutionSurface.forMCPProvider(transport: .stdio, executionHost: .sandbox) == .sandboxVM)
        #expect(ToolExecutionSurface.forMCPProvider(transport: .stdio, executionHost: .host) == .nativeHost)
        // Unresolvable provider: the conservative answer for a consent prompt.
        #expect(ToolExecutionSurface.forMCPProvider(transport: nil, executionHost: nil) == .nativeHost)
    }

    @Test("every surface has user-facing copy")
    func presentationIsComplete() {
        for surface in ToolExecutionSurface.allCases {
            #expect(!surface.title.isEmpty)
            #expect(!surface.consentDetail.isEmpty)
            #expect(!surface.symbolName.isEmpty)
        }
    }
}

// MARK: - Intel registry resolution
//
// Intel: upstream's `ToolRegistryExecutionSurfaceTests` and the gate → card
// suite exercise the sandbox VM registry (`BuiltinSandboxTools`,
// `unregisterAllSandboxTools`, `resolvePermissionGate`), which Intel doesn't
// have (`INC-containers`). Intel's resolver: workspace tools are always this
// Mac; MCP tools follow their provider.

@Suite(.serialized)
@MainActor
struct IntelToolExecutionSurfaceTests {
    @Test("workspace and unknown tools resolve to this Mac on Intel")
    func workspaceToolsAreTheHost() async {
        for name in ["shell_run", "file_write", "file_read", "no_such_tool"] {
            #expect(await ToolRegistry.shared.executionSurface(for: name, argumentsJSON: #"{"path":"/workspace/a"}"#)
                == .nativeHost)
        }
    }
}
