//
//  IntelControlRendering.swift
//  osaurus
//
//  Keeps AppKit's hosting window in step with SwiftUI's active theme on the
//  Intel build.  Ventura otherwise keeps the launch appearance for native
//  controls, which can leave switches, bordered buttons, hover tracking, and
//  the field-editor caret visually stale until their first interaction.
//

@preconcurrency import AppKit
import SwiftUI

/// Ventura can leave AppKit's standard window buttons logically present but
/// paint them underneath a full-size SwiftUI hosting view. This strip owns the
/// visible controls instead, while preserving the native close/minimize/zoom
/// actions and the expected muted-grey inactive state.
@MainActor
final class IntelTrafficLightStripView: NSView {
    static let viewIdentifier = NSUserInterfaceItemIdentifier("IntelTrafficLightStrip")

    private enum Kind: CaseIterable {
        case close, minimize, zoom

        var activeColor: NSColor {
            switch self {
            case .close: return .systemRed
            case .minimize: return .systemYellow
            case .zoom: return .systemGreen
            }
        }

        var help: String {
            switch self {
            case .close: return "Close"
            case .minimize: return "Minimize"
            case .zoom: return "Zoom"
            }
        }
    }

    private var buttons: [(Kind, NSButton)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.viewIdentifier
        wantsLayer = true

        for kind in Kind.allCases {
            let button = NSButton(frame: .zero)
            button.isBordered = false
            button.title = ""
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.borderWidth = 0.5
            button.toolTip = kind.help
            button.setAccessibilityLabel(kind.help)
            button.target = self
            switch kind {
            case .close: button.action = #selector(closeWindow)
            case .minimize: button.action = #selector(minimizeWindow)
            case .zoom: button.action = #selector(zoomWindow)
            }
            addSubview(button)
            buttons.append((kind, button))
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowKeyStateChanged(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowKeyStateChanged(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        for (index, entry) in buttons.enumerated() {
            entry.1.frame = NSRect(x: CGFloat(index) * 20, y: 3, width: 12, height: 12)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearance()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateAppearance() {
        let isActive = window?.isKeyWindow == true
        for (kind, button) in buttons {
            let color = isActive ? kind.activeColor : NSColor(calibratedWhite: 0.72, alpha: 1)
            button.layer?.backgroundColor = color.cgColor
            button.layer?.borderColor = (isActive
                ? NSColor.black.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.12)).cgColor
            button.needsDisplay = true
        }
    }

    @objc private func windowKeyStateChanged(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        updateAppearance()
    }

    @objc private func closeWindow() { window?.performClose(nil) }
    @objc private func minimizeWindow() { window?.miniaturize(nil) }
    @objc private func zoomWindow() { window?.performZoom(nil) }
}

/// Retained by `AppDelegate` for the lifetime of the Settings window.
/// `NSToolbar.delegate` is weak, and Ventura collapses a nominally-present
/// toolbar that has no delegate-backed custom item.  Chat already follows
/// this contract; Settings must do the same for its native traffic lights to
/// occupy a real titlebar region.
@MainActor
final class IntelManagementToolbarDelegate: NSObject, NSToolbarDelegate {
    static let chromeAnchor = NSToolbarItem.Identifier("IntelManagementToolbar.chromeAnchor")

    private static let identifiers: [NSToolbarItem.Identifier] = [
        chromeAnchor, .flexibleSpace,
    ]

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.identifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.identifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.chromeAnchor else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        // A clear, fixed-height anchor gives AppKit a genuine toolbar item
        // without adding duplicate Settings controls. The existing sidebar
        // affordance remains in the SwiftUI shell.
        let anchor = NSHostingView(rootView: Color.clear.frame(width: 1, height: 28))
        anchor.sizingOptions = [.intrinsicContentSize]
        anchor.frame = NSRect(origin: .zero, size: anchor.fittingSize)
        item.view = anchor
        return item
    }
}

/// Retained owner for the Settings window's post-presentation titlebar repair.
///
/// The native close button's superview is an AppKit implementation detail. On
/// Ventura, attaching the SwiftUI hosting controller, materializing the unified
/// toolbar, and making the window key can replace that view after the initial
/// strip was installed. Chat's hierarchy happens to remain stable; Settings
/// needs an explicit lifecycle reconciliation instead of another coordinate
/// special case in the shared renderer.
@MainActor
final class IntelManagementWindowLifecycle: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private var repairScheduled = false

    init(window: NSWindow) {
        self.window = window
        super.init()
        window.delegate = self
        repairNow(reason: "attach")
    }

    /// Repair immediately after order-front and once more after AppKit has had
    /// another main-loop turn to finalize the titlebar hierarchy.
    func repairAfterPresentation(reason: String) {
        repairNow(reason: reason)
        scheduleSettledRepair(reason: reason)
    }

    /// Internal so the focused regression test can prove recovery after the
    /// initial strip is deliberately removed.
    func repairNow(reason: String) {
        guard let window else { return }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        IntelNativeWindowRendering.restoreManagementTitlebarControls(in: window)
        NSLog(
            "[Osaurus Intel][SettingsChrome] %@ %@",
            reason,
            IntelNativeWindowRendering.titlebarDiagnosticSummary(in: window)
        )
    }

    private func scheduleSettledRepair(reason: String) {
        guard !repairScheduled else { return }
        repairScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.repairScheduled = false
            self.repairNow(reason: "\(reason)-settled")
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        repairAfterPresentation(reason: "did-become-key")
    }

    func windowDidResize(_ notification: Notification) {
        scheduleSettledRepair(reason: "did-resize")
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        repairAfterPresentation(reason: "did-end-live-resize")
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard window?.occlusionState.contains(.visible) == true else { return }
        scheduleSettledRepair(reason: "did-become-visible")
    }
}

/// A small hosting-view bridge for settings-style windows.
///
/// The AppDelegate creates the Management window before SwiftUI has rendered
/// its active theme.  Native AppKit controls inherit that early appearance,
/// while SwiftUI redraws with the current one.  Reapplying the appearance as
/// the theme changes keeps both systems in agreement and gives Ventura a
/// correctly coloured text field editor from the first focus.
private struct IntelControlRenderingBridge: NSViewRepresentable {
    let isDark: Bool
    let backgroundColor: NSColor
    let cursorColor: NSColor
    let accentColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isDark: isDark,
            backgroundColor: backgroundColor,
            cursorColor: cursorColor,
            accentColor: accentColor
        )
    }

    func makeNSView(context: Context) -> HostingProbeView {
        let view = HostingProbeView()
        view.onWindowChanged = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.apply(to: view)
        }
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: HostingProbeView, context: Context) {
        context.coordinator.update(
            isDark: isDark,
            backgroundColor: backgroundColor,
            cursorColor: cursorColor,
            accentColor: accentColor
        )
        context.coordinator.apply(to: nsView)
    }

    @MainActor
    final class Coordinator {
        private var isDark: Bool
        private var backgroundColor: NSColor
        private var cursorColor: NSColor
        private var accentColor: NSColor
        private weak var hostView: HostingProbeView?

        init(
            isDark: Bool,
            backgroundColor: NSColor,
            cursorColor: NSColor,
            accentColor: NSColor
        ) {
            self.isDark = isDark
            self.backgroundColor = backgroundColor
            self.cursorColor = cursorColor
            self.accentColor = accentColor
        }

        func install(on hostView: HostingProbeView) {
            self.hostView = hostView
            hostView.cursorColor = cursorColor
            NotificationCenter.default.addObserver(
                hostView,
                selector: #selector(HostingProbeView.textDidBeginEditing(_:)),
                name: NSText.didBeginEditingNotification,
                object: nil
            )
        }

        func update(
            isDark: Bool,
            backgroundColor: NSColor,
            cursorColor: NSColor,
            accentColor: NSColor
        ) {
            self.isDark = isDark
            self.backgroundColor = backgroundColor
            self.cursorColor = cursorColor
            self.accentColor = accentColor
            hostView?.cursorColor = cursorColor
        }

        func apply(to hostView: HostingProbeView) {
            guard let window = hostView.window else { return }

            // Keep native controls in the same appearance family as SwiftUI.
            window.appearance = IntelNativeWindowRendering.appearance(
                declaredDark: isDark,
                backgroundColor: backgroundColor
            )
            window.backgroundColor = backgroundColor
            // `onHover` depends on mouse-move delivery in manually-created
            // settings windows.  Chat windows already set this themselves.
            window.acceptsMouseMovedEvents = true

            applyFieldEditor(in: window)
            applyAccent(to: window.contentView)
            IntelNativeWindowRendering.restoreManagementTitlebarControls(in: window)
            window.contentView?.needsDisplay = true

            // SwiftUI can materialize AppKit-backed controls after this bridge
            // updates. Reapply on the next main-loop turn so untouched toggles
            // and bordered buttons are coloured before their first click.
            DispatchQueue.main.async { [weak self, weak hostView] in
                guard let self, let hostView, hostView.window === window else { return }
                self.applyFieldEditor(in: window)
                self.applyAccent(to: hostView.window?.contentView)
                IntelNativeWindowRendering.restoreManagementTitlebarControls(in: window)
                hostView.window?.contentView?.needsDisplay = true
            }
        }

        private func applyFieldEditor(in window: NSWindow) {
            guard let editor = window.fieldEditor(false, for: nil) as? NSTextView else { return }
            editor.insertionPointColor = cursorColor
            editor.textColor = .labelColor
            editor.needsDisplay = true
        }

        private func applyAccent(to view: NSView?) {
            guard let view else { return }
            // `contentTintColor` lives on the concrete AppKit controls that
            // render template content, not on NSControl itself. Keep the walk
            // deliberately narrow so text fields retain their own foreground
            // colours while buttons, switches, and image-backed controls pick
            // up the active agent accent before first interaction.
            if let button = view as? NSButton {
                // Do not force an accent tint onto text-bearing AppKit controls.
                // On Ventura that tint is also applied to switch labels, menu
                // titles, and disabled button text; the result is white glyphs
                // on the Settings paper background until the control is used.
                // SwiftUI's explicit button/toggle styles own accent colour.
                button.contentTintColor = nil
                button.needsDisplay = true
            } else if let imageView = view as? NSImageView {
                imageView.contentTintColor = accentColor
                imageView.needsDisplay = true
            }
            for child in view.subviews {
                applyAccent(to: child)
            }
        }
    }

    final class HostingProbeView: NSView {
        var onWindowChanged: (() -> Void)?
        var cursorColor: NSColor = .textColor

        @objc func textDidBeginEditing(_ notification: Notification) {
            guard
                let editor = notification.object as? NSTextView,
                editor.window === window
            else { return }
            editor.insertionPointColor = cursorColor
            editor.textColor = .labelColor
            editor.needsDisplay = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?()
        }
    }
}

/// Shared AppKit repairs for manually-created Intel windows. Ventura can defer
/// titlebar-button installation until after a toolbar/content view is attached,
/// while native controls can retain the launch appearance after SwiftUI repaints.
@MainActor
enum IntelNativeWindowRendering {
    static func appearance(declaredDark _: Bool, backgroundColor _: NSColor) -> NSAppearance? {
        // The Intel Settings shell uses the upstream light paper palette even
        // when an agent's chat theme is dark. Tying native controls to the
        // active agent made Ventura produce dark (white) glyphs on this light
        // surface. Keep Settings AppKit controls in Aqua; chat windows retain
        // their independent per-agent appearance path.
        NSAppearance(named: .aqua)
    }

    static func restoreTitlebarControls(in window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        // The native buttons remain the semantic source of the window's style
        // mask, but their Ventura rendering is unreliable below full-size
        // SwiftUI content. Hide only their drawing and install one shared,
        // topmost strip for Settings and chat.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.isHidden = true
        }

        guard
            let nativeClose = window.standardWindowButton(.closeButton),
            let titlebarView = nativeClose.superview
        else { return }

        let strip: IntelTrafficLightStripView
        if let existing = titlebarView.subviews.first(where: {
            $0.identifier == IntelTrafficLightStripView.viewIdentifier
        }) as? IntelTrafficLightStripView {
            strip = existing
        } else {
            // `NSTitlebarAccessoryViewController.layoutAttribute = .left`
            // participates in toolbar layout; on Ventura that placed the
            // strip below and far to the right of the native button cluster,
            // and Settings did not display it at all. The standard close
            // button's superview is the actual titlebar layer. Install our
            // strip there and use the native close frame as the coordinate
            // source, so both Settings and chat land at the normal location.
            strip = IntelTrafficLightStripView(frame: .zero)
            strip.autoresizingMask = [.maxXMargin, .minYMargin]
            titlebarView.addSubview(strip, positioned: .above, relativeTo: nil)
        }
        strip.frame = NSRect(
            x: nativeClose.frame.minX,
            y: nativeClose.frame.midY - 9,
            width: 52,
            height: 18
        )
        titlebarView.addSubview(strip, positioned: .above, relativeTo: nil)
        strip.updateAppearance()
    }

    /// Settings-specific installation plane.
    ///
    /// Rosy's lifecycle diagnostics proved that a strip attached beside the
    /// native close button can be present, correctly framed, and owned by a
    /// visible immediate parent while still producing no pixels. The native
    /// button container therefore sits below a later-composited Settings layer
    /// on Ventura. Install Settings' strip directly in the persistent window
    /// frame root instead. That root owns both the titlebar and content layers;
    /// adding the strip last places it above both without changing chat's
    /// already-correct native-titlebar installation.
    static func restoreManagementTitlebarControls(in window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }

        guard
            let nativeClose = window.standardWindowButton(.closeButton),
            let nativeParent = nativeClose.superview,
            let frameRoot = window.contentView?.superview
        else { return }

        // Remove the now-known-invisible installation from the native button
        // plane. There must be exactly one replacement strip per window.
        for stale in nativeParent.subviews where
            stale.identifier == IntelTrafficLightStripView.viewIdentifier
        {
            stale.removeFromSuperview()
        }

        let strip: IntelTrafficLightStripView
        if let existing = frameRoot.subviews.first(where: {
            $0.identifier == IntelTrafficLightStripView.viewIdentifier
        }) as? IntelTrafficLightStripView {
            strip = existing
        } else {
            strip = IntelTrafficLightStripView(frame: .zero)
            strip.autoresizingMask = [.maxXMargin, .minYMargin]
        }

        // Convert the native close button's canonical position through window
        // coordinates into the frame root's coordinate space. This preserves
        // the exact system placement without sharing the native parent's
        // invisible composition plane.
        let closeInWindow = nativeClose.convert(nativeClose.bounds, to: nil)
        let closeInFrame = frameRoot.convert(closeInWindow, from: nil)
        strip.frame = NSRect(
            x: closeInFrame.minX,
            y: closeInFrame.midY - 9,
            width: 52,
            height: 18
        )
        frameRoot.addSubview(strip, positioned: .above, relativeTo: nil)
        strip.updateAppearance()
    }

    static func managementTrafficLightStrip(in window: NSWindow) -> IntelTrafficLightStripView? {
        window.contentView?.superview?.subviews.first {
            $0.identifier == IntelTrafficLightStripView.viewIdentifier
        } as? IntelTrafficLightStripView
    }

    static func titlebarDiagnosticSummary(in window: NSWindow) -> String {
        let nativeClose = window.standardWindowButton(.closeButton)
        let parent = nativeClose?.superview
        let frameRoot = window.contentView?.superview
        let strip = managementTrafficLightStrip(in: window)
        let parentIdentity = parent.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
        let frameIdentity = frameRoot.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
        let closeFrame = nativeClose.map { NSStringFromRect($0.frame) } ?? "nil"
        let stripFrame = strip.map { NSStringFromRect($0.frame) } ?? "nil"
        let closeHidden = nativeClose.map { String($0.isHidden) } ?? "nil"
        let parentVisible = parent.map { String(!$0.isHidden) } ?? "nil"
        return "key=\(window.isKeyWindow) visible=\(window.isVisible) "
            + "closeHidden=\(closeHidden) "
            + "closeFrame=\(closeFrame) nativeParent=\(parentIdentity) "
            + "frameRoot=\(frameIdentity) "
            + "parentVisible=\(parentVisible) "
            + "stripInFrameRoot=\((strip?.superview === frameRoot).description) "
            + "stripFrame=\(stripFrame)"
    }

    /// Installs the same native chrome contract used by chat: full-size
    /// content under a transparent titlebar, anchored by a real unified
    /// toolbar so Ventura owns and paints the traffic-light region.
    static func configureUnifiedTitlebar(
        in window: NSWindow,
        toolbarIdentifier: String,
        delegate: IntelManagementToolbarDelegate
    ) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: toolbarIdentifier)
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            toolbar.displayMode = .iconOnly
            toolbar.showsBaselineSeparator = false
            toolbar.delegate = delegate
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
        restoreManagementTitlebarControls(in: window)
    }
}

extension View {
    /// Synchronize AppKit controls embedded by SwiftUI with the active theme.
    /// This is intentionally attached to ManagementView, where the manually
    /// constructed Settings window owns the affected controls.
    func intelControlRendering(theme: ThemeProtocol) -> some View {
        background(
            IntelControlRenderingBridge(
                isDark: theme.isDark,
                backgroundColor: NSColor(theme.primaryBackground),
                cursorColor: NSColor(theme.cursorColor),
                accentColor: NSColor(theme.accentColor)
            )
            .frame(width: 0, height: 0)
        )
    }
}
