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
        Settings {
            EmptyView()
        }
        .commands {
            aboutCommand
        }
    }
}

// MARK: - Menu Commands

private extension osaurusApp {

    var aboutCommand: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "Osaurus",
                    .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                        ?? "1.0",
                    .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
                ])
            } label: {
                Text(verbatim: "About Osaurus (Intel)")
            }
        }
    }
}
