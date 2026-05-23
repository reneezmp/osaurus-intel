//
//  AppDelegate.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//  Intel fork — with HTTP server. M3 milestone.
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
    private let server = OsaurusServer()

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

        let serverStartupTask = Task { @MainActor in
            let config = ServerConfigurationStore.load() ?? .default
            let serverConfig = OsaurusServer.Config(
                host: "127.0.0.1",
                port: 1338,
                trustLoopback: true
            )
            do {
                try await server.start(serverConfig, serverConfiguration: config)
                NSLog("[Osaurus Intel] HTTP server started on port \(config.port)")
            } catch {
                NSLog("[Osaurus Intel] Server start failed: \(error)")
            }

            do {
                try await MCPBridge.shared.start()
                NSLog("[Osaurus Intel] MCP server started")
            } catch {
                NSLog("[Osaurus Intel] MCP start failed: \(error)")
            }
        }

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

        let content = VStack(spacing: 20) {
            Image(systemName: "apple.logo")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Osaurus (Intel)")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Cloud-only  ·  MCP-ready  ·  Identity sync")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .frame(width: 280)

            VStack(alignment: .leading, spacing: 10) {
                FeatureRow(icon: "cloud.fill", label: "DeepSeek V4 Pro / Flash", status: "Active", color: .green)
                FeatureRow(icon: "hammer.fill", label: "MCP Server (3 tools)", status: "Active", color: .green)
                FeatureRow(icon: "network", label: "HTTP API · Port 1338", status: "Active", color: .green)
                FeatureRow(icon: "apple.logo", label: "Local Models", status: "Apple Silicon only", color: .orange)
                FeatureRow(icon: "mic.fill", label: "Voice Features", status: "Apple Silicon only", color: .orange)
                FeatureRow(icon: "shippingbox.fill", label: "Sandbox VM", status: "Apple Silicon only", color: .orange)
            }

            Divider()
                .frame(width: 280)

            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("Server running on port 1338")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(36)
        .frame(width: 420)

        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Osaurus (Intel)"
        window.contentViewController = hosting
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
        Task { @MainActor in
            await MCPBridge.shared.stop()
            await server.stop()
        }
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

// MARK: - Intel Status Dashboard

private struct FeatureRow: View {
    let icon: String
    let label: String
    let status: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 13))
            Spacer()
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
