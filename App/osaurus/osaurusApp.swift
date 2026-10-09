//
//  osaurusApp.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//  Intel fork — minimal app entry point. M2 milestone.
//

import AppKit
import OsaurusCore
import SwiftUI

@main
struct osaurusApp: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// Chat settings toggle: ⌘N starts a new chat in the frontmost chat
    /// window instead of opening a new window (see `NewChatShortcutSetting`).
    /// Upstream e0eeba12.
    @AppStorage(NewChatShortcutSetting.defaultsKey)
    private var cmdNStartsNewChatInCurrentWindow: Bool = false
    // NOTE: Do not add `@ObservedObject` singletons here. Every `@Published`
    // change on an object observed by the App struct re-evaluates the whole
    // `Commands` tree and rebuilds the main menu on the main thread (upstream
    // #3052, a Sentry-reported hang). Observe state from small, dedicated
    // menu-item views instead (see `ZoomMenuItems`).

    var body: some SwiftUI.Scene {
        // The SwiftUI `Settings { EmptyView() }` scene is kept as a
        // placeholder so SwiftUI doesn't synthesize its own default
        // Settings menu item. The real "Settings…" entry is provided
        // by `settingsCommand` below, which routes Cmd+, into
        // `AppDelegate.showManagementWindow()` — our hand-rolled
        // NSWindow hosting the real `ManagementView`. This was the
        // root cause of M11 Phase 11.0's empty-black-window
        // regression: Cmd+, was firing the SwiftUI Settings scene
        // (an `EmptyView`), and the window's title coincidentally
        // matched the one we set on the hand-rolled window, so we
        // spent three sub-phases "fixing" a window that was never
        // even being shown.
        Settings {
            EmptyView()
        }
        .commands {
            aboutCommand
            fileMenuCommands
            chatShortcutCommands
            viewMenuCommands
            settingsCommand
            helpMenuCommands
        }
    }
}

// MARK: - Menu Commands

private extension osaurusApp {

    var aboutCommand: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button {
                let shortVersion =
                    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                let versionLine =
                    OsaurusBuildInfo.upstreamShortLabel.map { "\(shortVersion) · \($0)" } ?? shortVersion
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "Osaurus (Intel)",
                    .applicationVersion: versionLine,
                    .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
                ])
            } label: {
                Text(verbatim: "About Osaurus (Intel)")
            }
        }
    }

    /// ⌘N: opens a new chat window by default (matching the historical
    /// behavior — there was no File-menu "New Window" command to replace
    /// here before this port). When the Chat setting is on, ⌘N instead
    /// starts a new chat in the frontmost chat window (the sidebar "New
    /// Chat" action), and gains a second ⇧⌘N item for opening a genuinely
    /// new window — matching most chat apps. Upstream e0eeba12.
    var fileMenuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            if cmdNStartsNewChatInCurrentWindow {
                Button {
                    Task { @MainActor in
                        if !ChatWindowManager.shared.startNewChatInLastFocusedWindow() {
                            _ = ChatWindowManager.shared.createWindow()
                        }
                    }
                } label: {
                    Text(verbatim: L("New Chat"))
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            Button {
                Task { @MainActor in
                    _ = ChatWindowManager.shared.createWindow()
                }
            } label: {
                Text(verbatim: L("New Window"))
            }
            .keyboardShortcut(
                "n",
                modifiers: cmdNStartsNewChatInCurrentWindow ? [.command, .shift] : .command
            )
        }
    }

    /// Help ▸ Chat Layout Tour replays the coachmark tour of the chat
    /// window (upstream #2630). Intel adds it after the system Help item
    /// instead of replacing the menu: the rest of upstream's Help menu
    /// (docs, Discord, report an issue…) is not part of this port.
    var helpMenuCommands: some Commands {
        CommandGroup(after: .help) {
            Button {
                Task { @MainActor in ChatLayoutTour.shared.start() }
            } label: {
                Text(verbatim: L("Chat Layout Tour"))
            }
        }
    }

    var chatShortcutCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Button {
                Task { @MainActor in ChatWindowManager.shared.toggleSidebarInFocusedWindow() }
            } label: {
                Text(verbatim: L("Toggle Sidebar"))
            }
            .keyboardShortcut("b", modifiers: .command)

            Button {
                Task { @MainActor in ChatWindowManager.shared.cycleAgentInFocusedWindow() }
            } label: {
                Text(verbatim: L("Next Agent"))
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }

    /// Global UI font zoom, matching browsers' ⌘+/⌘-/⌘0. Upstream 1b955c2b
    /// hangs these off an existing View menu (the "Theme" picker); this
    /// fork has none, so they get their own `CommandMenu`.
    var viewMenuCommands: some Commands {
        CommandMenu(L("View")) {
            ZoomMenuItems()
        }
    }

    var settingsCommand: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                AppDelegate.shared?.showManagementWindow()
            } label: {
                Text(verbatim: "Settings…")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

// MARK: - Zoom Menu Items

/// View-menu font zoom items. Observes `ThemeManager` locally so theme
/// changes only invalidate these items rather than re-evaluating every
/// App-level `Commands` builder. Upstream #3052 `ThemeMenuItems`, minus the
/// Theme submenu this fork's menu bar doesn't have (`W-app-menus`).
private struct ZoomMenuItems: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        Button {
            themeManager.zoomFontIn()
        } label: {
            Text(verbatim: L("Zoom In"))
        }
        // "=" is the unshifted key under "+", matching how ⌘+ zoom is
        // reached without holding Shift in browsers.
        .keyboardShortcut("=", modifiers: .command)
        .disabled(!themeManager.canZoomFontIn)

        Button {
            themeManager.zoomFontOut()
        } label: {
            Text(verbatim: L("Zoom Out"))
        }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(!themeManager.canZoomFontOut)

        Button {
            themeManager.resetFontScale()
        } label: {
            Text(verbatim: L("Actual Size"))
        }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(themeManager.isDefaultFontScale)
    }
}
