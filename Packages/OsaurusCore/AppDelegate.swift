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
    private var managementWindow: NSWindow?
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

            showChatWindow()

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
    private func showChatWindow() {
        NSApp.unhide(nil)
        _ = NSRunningApplication.current.activate(options: .activateAllWindows)
        _ = ChatWindowManager.shared.createWindow()
    }

    // MARK: - Reopen

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            showChatWindow()
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

    @MainActor
    public func showManagementWindow(
        initialTab: ManagementTab? = nil,
        deeplinkAgentId: UUID? = nil
    ) {
        NSApp.unhide(nil)
        _ = NSRunningApplication.current.activate(options: .activateAllWindows)

        // Re-use the existing window if we already opened one this
        // session — Cmd+, on a window that's already open should bring
        // it forward, not spawn a duplicate.
        if let existing = managementWindow {
            if let tab = initialTab {
                ManagementStateManager.shared.selectedTab = tab
            }
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let root = ManagementView(
            initialTab: initialTab,
            deeplinkAgentId: deeplinkAgentId
        )
        .environmentObject(updater)

        // Mirror the upstream `WindowManager.createWindow` construction
        // order: build the window with an explicit `contentRect` first,
        // attach the hosting controller second, then call
        // `layoutSubtreeIfNeeded` + a final `setContentSize` so the
        // SwiftUI tree doesn't render against a 0x0 frame on first show
        // (which produced an empty black window in Phase 11.0's first
        // launch). See `Packages/OsaurusCore/Managers/WindowManager.swift`
        // L257-326 for the upstream reference (excluded on Intel but
        // readable on disk).
        let defaultSize = NSSize(width: 1000, height: 700)
        let host = NSHostingController(rootView: root)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Osaurus Settings"
        window.minSize = NSSize(width: 900, height: 640)
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        // Phase 11.0-ter: mirror the appearance + opacity + background
        // contract that `ChatWindowManager.createChatPanel` sets on the
        // chat window (which renders correctly on Intel). Without
        // these three lines the Settings window was painting solid
        // black: SwiftUI's semantic colors (`.foregroundStyle(.tertiary)`
        // in `AppleSiliconOnlyTab`, `theme.primaryBackground` etc.)
        // were resolving against an indeterminate appearance, and the
        // window's default transparent background showed through to
        // nothing. Pinning the appearance to the current theme's
        // light/dark mode forces SwiftUI to pick the right colors.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.appearance = NSAppearance(
            named: ThemeManager.shared.currentTheme.isDark ? .darkAqua : .aqua
        )

        window.contentViewController = host

        // Pre-layout to avoid jank + force-set the size again so the
        // first paint uses the intended dimensions.
        host.view.layoutSubtreeIfNeeded()
        window.setContentSize(defaultSize)

        window.center()
        window.makeKeyAndOrderFront(nil)
        managementWindow = window
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
