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
            settingsCommand
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
