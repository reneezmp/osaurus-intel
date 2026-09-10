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
            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            window.backgroundColor = backgroundColor
            // `onHover` depends on mouse-move delivery in manually-created
            // settings windows.  Chat windows already set this themselves.
            window.acceptsMouseMovedEvents = true

            if let editor = window.fieldEditor(false, for: nil) as? NSTextView {
                editor.insertionPointColor = cursorColor
            }
            applyAccent(to: window.contentView)
            window.contentView?.needsDisplay = true

            // SwiftUI can materialize AppKit-backed controls after this bridge
            // updates. Reapply on the next main-loop turn so untouched toggles
            // and bordered buttons are coloured before their first click.
            DispatchQueue.main.async { [weak self, weak hostView] in
                guard let self, let hostView, hostView.window === window else { return }
                self.applyAccent(to: hostView.window?.contentView)
                hostView.window?.contentView?.needsDisplay = true
            }
        }

        private func applyAccent(to view: NSView?) {
            guard let view else { return }
            // `contentTintColor` lives on the concrete AppKit controls that
            // render template content, not on NSControl itself. Keep the walk
            // deliberately narrow so text fields retain their own foreground
            // colours while buttons, switches, and image-backed controls pick
            // up the active agent accent before first interaction.
            if let button = view as? NSButton {
                button.contentTintColor = accentColor
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
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?()
        }
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
