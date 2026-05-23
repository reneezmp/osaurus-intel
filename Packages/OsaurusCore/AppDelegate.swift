//
//  AppDelegate.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//  Intel fork — minimal launch shell. M2 milestone.
//

import AppKit
import Combine
import SwiftUI
import os.log

private let log = Logger(subsystem: "ai.osaurus", category: "AppDelegate")

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    public static weak var shared: AppDelegate?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    let updater = UpdaterViewModel()

    private static let swiftUISettingsPlaceholderID = "com_apple_SwiftUI_Settings_window"
    private static let swiftUISettingsPlaceholderNotifications: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification,
        NSWindow.didChangeOcclusionStateNotification,
    ]

    // MARK: - Launch

    public func applicationWillFinishLaunching(_ notification: Notification) {
        UncaughtExceptionLogger.install()
        AppDelegate.shared = self

        ProcessInfo.processInfo.disableAutomaticTermination(
            "Osaurus Intel — long-running"
        )

        if #available(macOS 26.0, *) {
            let hideDockIcon = ServerConfigurationStore.load()?.hideDockIcon ?? false
            NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
            suppressSwiftUISettingsPlaceholder()
            disableAppKitStateRestoration()
        }
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if #unavailable(macOS 26.0) {
            let hideDockIcon = ServerConfigurationStore.load()?.hideDockIcon ?? false
            NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
        }

        DocumentAdaptersBootstrap.registerBuiltIns()

        Task.detached(priority: .background) {
            await StorageMaintenance.shared.start()
        }

        let launchedByCLI = ProcessInfo.processInfo.arguments.contains("--launched-by-cli")
        if !launchedByCLI {
            LoginItemService.shared.applyStartAtLogin(
                ServerConfigurationStore.load()?.startAtLogin ?? false
            )
        }

        installStatusItem()

        #if DEBUG
            MainThreadWatchdog.shared.start()
        #endif

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)

            if #available(macOS 26.0, *) {
                sweepSwiftUISettingsPlaceholder()
            }

            showMinimalWindow()

            if #available(macOS 26.0, *) {
                for name in Self.swiftUISettingsPlaceholderNotifications {
                    NotificationCenter.default.removeObserver(self, name: name, object: nil)
                }
            }
        }
    }

    // MARK: - Settings Placeholder Suppression

    private func disableAppKitStateRestoration() {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    private func suppressSwiftUISettingsPlaceholder() {
        sweepSwiftUISettingsPlaceholder()
        for name in Self.swiftUISettingsPlaceholderNotifications {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSwiftUIPlaceholderEvent(_:)),
                name: name,
                object: nil
            )
        }
    }

    private func sweepSwiftUISettingsPlaceholder() {
        for window in NSApp.windows
        where window.identifier?.rawValue == Self.swiftUISettingsPlaceholderID {
            hidePlaceholder(window)
        }
    }

    @objc private func handleSwiftUIPlaceholderEvent(_ note: Notification) {
        guard
            let window = note.object as? NSWindow,
            window.identifier?.rawValue == Self.swiftUISettingsPlaceholderID
        else { return }
        hidePlaceholder(window)
    }

    private func hidePlaceholder(_ window: NSWindow) {
        window.orderOut(nil)
        window.setIsVisible(false)
    }

    // MARK: - Window

    @MainActor
    private func showMinimalWindow() {
        NSApp.unhide(nil)
        _ = NSRunningApplication.current.activate(options: .activateAllWindows)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Osaurus (Intel)"
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Reopen

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            showMinimalWindow()
        }
        return true
    }

    // MARK: - Dock Menu

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About Osaurus", action: #selector(dockAbout), keyEquivalent: ""))
        return menu
    }

    @objc private func dockAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Osaurus",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
        ])
    }

    // MARK: - Terminate

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSApp.reply(toApplicationShouldTerminate: true)
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        NSLog("Osaurus (Intel) terminating")
        SharedConfigurationService.shared.remove()
    }

    // MARK: - Status Item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(named: "osaurus") {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Osaurus"
            }
            button.toolTip = "Osaurus (Intel)"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        showPopover()
    }

    public func showPopover() {
        guard let statusButton = statusItem?.button else { return }
        if let popover, popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let content = VStack(alignment: .leading, spacing: 8) {
            Text("Osaurus (Intel)")
                .font(.headline)
            Divider()
            Text("Intel fork — cloud-only, MCP-rich")
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            Button("Quit Osaurus") {
                NSApp.terminate(nil)
            }
        }
        .padding()

        popover.contentViewController = NSHostingController(rootView: content)
        self.popover = popover
        popover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        log.debug("Popover closed")
    }
}
