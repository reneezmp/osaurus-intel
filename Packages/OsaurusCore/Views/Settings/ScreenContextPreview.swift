//
//  ScreenContextPreview.swift
//  OsaurusCore — Computer Use
//
//  A self-contained, on-demand preview of the screen-context snapshot a new
//  chat would freeze and share. Shared by the global Computer Use settings card
//  and the per-agent "Share screen context" toggle so the two never drift.
//  Owns its own capture state and reads Accessibility + theme from the shared
//  singletons, so it drops cleanly into either a card or a popover.
//
//  Intel (W-computer-use stage 6): no Privacy Filter note (the filter is not on
//  this build); the preview only ever runs on the user's click (Refresh) or
//  when the user opens it, and only when Accessibility is already granted: it
//  checks, never requests.
//

import SwiftUI

struct ScreenContextPreview: View {
    /// Capture as soon as the view appears instead of waiting for a manual
    /// Refresh. The default suits a popover (the user opened it to look) and the
    /// always-rendered settings card alike.
    var autoCaptureOnAppear: Bool = true
    /// Shown when Accessibility is missing. Phrased for the host by default for
    /// the popover; the settings card overrides it to point "above" at its own
    /// permission row.
    var accessibilityHint: String = "Grant Accessibility to preview what would be shared."
    /// Definite height for the scrolling snapshot area. A `ScrollView` has no
    /// intrinsic height, so inside a self-sizing container (a popover) it
    /// collapses to nothing; pass a height there. `nil` keeps it flexible
    /// (capped at 220) for the settings card, which sits inside an outer
    /// ScrollView that already hands it a definite height.
    var previewHeight: CGFloat? = nil

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared

    @State private var snapshot: ScreenContextSnapshot?
    @State private var isLoading = false
    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var isAccessibilityGranted: Bool {
        permissionService.permissionStates[.accessibility] ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .onAppear {
            if autoCaptureOnAppear, snapshot == nil { refresh() }
        }
    }

    private var header: some View {
        HStack {
            Text(L("Preview"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                Text(L("Refresh"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(roundedSurface(fill: theme.tertiaryBackground, stroke: theme.inputBorder, cornerRadius: 6))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isAccessibilityGranted || isLoading)
    }

    @ViewBuilder
    private var content: some View {
        if !isAccessibilityGranted {
            hint(accessibilityHint)
        } else if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                hint("Reading the screen…")
            }
        } else if let snapshot {
            let text = snapshot.render()
            if text.isEmpty {
                hint("Nothing shareable detected on screen right now.")
            } else {
                snapshotScroll(text)
                privacyNote
            }
        } else {
            hint("Tap Refresh to see what would be shared.")
        }
    }

    @ViewBuilder
    private func snapshotScroll(_ text: String) -> some View {
        let scroll = ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(roundedSurface(fill: theme.inputBackground, stroke: theme.inputBorder, cornerRadius: 8))

        if let previewHeight {
            scroll.frame(height: previewHeight)
        } else {
            scroll.frame(maxHeight: 220)
        }
    }

    /// With the Privacy Filter on, this text rides the first user turn and is
    /// scrubbed with it before a cloud send (`W-privacy-filter` stage 3); with
    /// it off nothing scrubs it: say plainly where it goes.
    @ViewBuilder
    private var privacyNote: some View {
        if PrivacyFilterStore.snapshot().enabled {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundColor(theme.successColor)
                    .padding(.top, 1)
                Text(L("The Privacy Filter scrubs this before it reaches a cloud model."))
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            unscrubbedNote
        }
    }

    private var unscrubbedNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(theme.warningColor)
                .padding(.top, 1)
            Text(
                L(
                    "This text goes to the model you chose for the chat, as shown, when you send the first message. It is not scrubbed. Nothing is shared when the option is off."
                )
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func roundedSurface(fill: Color, stroke: Color, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(stroke, lineWidth: 1)
            )
    }

    private func refresh() {
        guard isAccessibilityGranted else {
            snapshot = nil
            return
        }
        isLoading = true
        Task { @MainActor in
            let captured = await ScreenContextDistiller.captureForChat()
            snapshot = captured
            isLoading = false
        }
    }
}
