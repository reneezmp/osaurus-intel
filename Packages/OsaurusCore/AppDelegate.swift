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

        let content = IntelChatView()
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Osaurus (Intel) — Chat"
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

// MARK: - Intel Chat View

private struct IntelChatView: View {
    @State private var messages: [ChatBubble] = []
    @State private var inputText = ""
    @State private var isStreaming = false
    @State private var streamingText = ""

    private let serverURL = "http://127.0.0.1:1338/v1/chat/completions"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { msg in
                            ChatBubbleView(bubble: msg)
                        }
                        if isStreaming {
                            ChatBubbleView(bubble: ChatBubble(role: "assistant", content: streamingText))
                                .id("streaming")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: streamingText) { _, _ in
                    withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Type a message...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .disabled(isStreaming)
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isStreaming else { return }

        let userMsg = ChatBubble(role: "user", content: text)
        messages.append(userMsg)
        inputText = ""
        isStreaming = true
        streamingText = ""

        Task {
            await streamChatResponse(userMessage: text)
        }
    }

    private func streamChatResponse(userMessage: String) async {
        let conversationMessages: [[String: String]] = messages.map { ["role": $0.role, "content": $0.content] }

        let body: [String: Any] = [
            "model": "deepseek-v4-pro",
            "messages": conversationMessages,
            "stream": true,
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: serverURL) else {
            isStreaming = false
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300
        urlRequest.httpBody = httpBody

        do {
            let (asyncBytes, _) = try await URLSession.shared.bytes(for: urlRequest)
            var fullResponse = ""

            for try await line in asyncBytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let dataStr = String(line.dropFirst(6))
                if dataStr == "[DONE]" { break }

                if let chunkData = dataStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any] {

                    if let content = delta["content"] as? String, !content.isEmpty {
                        fullResponse += content
                    }
                    // Also capture reasoning_content for DeepSeek thinking
                    if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                        fullResponse += reasoning
                    }
                }

                streamingText = fullResponse
            }

            if !fullResponse.isEmpty {
                messages.append(ChatBubble(role: "assistant", content: fullResponse))
            }
        } catch {
            messages.append(ChatBubble(role: "assistant", content: "Error: \(error.localizedDescription)"))
        }

        isStreaming = false
        streamingText = ""
    }
}

private struct ChatBubble: Identifiable {
    let id = UUID()
    let role: String
    let content: String
}

private struct ChatBubbleView: View {
    let bubble: ChatBubble
    let isUser: Bool

    init(bubble: ChatBubble) {
        self.bubble = bubble
        self.isUser = bubble.role == "user"
    }

    var body: some View {
        HStack {
            if isUser { Spacer() }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(bubble.role == "user" ? "You" : "Osaurus")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(bubble.content)
                    .font(.body)
                    .padding(10)
                    .background(isUser ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxWidth: 320, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer() }
        }
    }
}
