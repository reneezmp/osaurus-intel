//
//  ComposerWalletViews.swift
//  osaurus
//
//  Upstream's composer credits chip and wallet panel (`FloatingCreditsChip`,
//  `WalletPopover`, from `Views/Chat/FloatingInputCard.swift`, #2947),
//  verbatim apart from the Intel notes marked below (Ventura: no
//  `.symbolEffect(.replace)` icon transition, which needs macOS 14). Intel's composer is its
//  own file, so the two views live here. W-model-picker-2947, 2026-10-11.
//

import AppKit
import SwiftUI


/// The composer wallet panel, presented in the same arrowless, themed card
/// as the model picker, aligned to the trailing edge of its credits chip.
/// Opens from the credits chip as a hover preview or a pinned click-through
/// panel: balance hero, per-session router spend, recent account activity
/// (model requests + ledger transactions), and Add credits / View all actions.
/// This is the surface agent-initiated credit transactions will land in — new
/// ledger `entry_type`s render here via `WalletActivityProjector` without UI
/// rework.
private struct WalletPopover: View {
    /// This session's router spend; nil outside router-billed sessions.
    let sessionSpend: String?
    /// "N cached · P%" for the session's router prompt-cache hits. Shown under
    /// the spend row so users can see the discount they got; nil hides it.
    let sessionCachedInputLabel: String?
    /// True when a low/empty balance should tint amber (router-billed sessions
    /// only — a $0 wallet doesn't block a local-model chat).
    let isAttention: Bool
    let onAddCredits: () -> Void
    let onViewAll: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @ObservedObject private var accountService = OsaurusRouterAccountService.shared
    @Environment(\.theme) private var theme
    @Environment(\.anchoredCardMetrics) private var cardMetrics

    private var subduedTextColor: Color { theme.isDark ? theme.tertiaryText : theme.secondaryText }

    /// Shared so each row doesn't allocate a formatter; relative labels like
    /// "3h ago" only need minute resolution.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var rows: [WalletActivityRow] {
        WalletActivityProjector().rows(
            usageItems: accountService.usage,
            transactions: accountService.transactions,
            webUsageItems: accountService.webUsage
        )
    }

    var body: some View {
        ScrollView {
            walletContent
                .padding(PickerCardMetrics.padding)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    ceil(geometry.size.height)
                } action: { height in
                    onHeightChange(height)
                }
        }
        .intelScrollBounceBasedOnSize()  // Intel: macOS 13.3+ only
        .frame(
            width: cardMetrics?.visibleSize.width ?? PickerCardMetrics.infoCardWidth,
            height: cardMetrics?.visibleSize.height
        )
        .pickerCardSurface()
        .task {
            await accountService.refreshBalance()
            await accountService.refreshUsage(reset: true)
            await accountService.refreshTransactions(reset: true)
            await accountService.refreshWebUsage(reset: true)
            await accountService.refreshWebSettings()
        }
        // A billed turn settled while the popover is open: refetch the
        // activity rows. Only fires while this view is mounted, so a closed
        // wallet costs nothing per turn.
        .onChange(of: accountService.usageRevision) { _ in  // Intel: Ventura onChange
            Task { await accountService.refreshUsage(reset: true) }
        }
    }

    private var walletContent: some View {
        let searchGrant = accountService.webSettings?.grants?.search
        let showsSearchCredits = (searchGrant?.includedTotal ?? 0) > 0
        return VStack(alignment: .leading, spacing: 8) {
            PickerCardHeading(title: L("Credits")) {
                if accountService.isFrozen {
                    Text("Paused", bundle: .module)
                        .font(theme.font(size: theme.pickerCardBodySize, weight: .medium))
                        .foregroundStyle(theme.warningColor)
                }
            }

            VStack(alignment: .leading, spacing: PickerCardMetrics.infoSectionSpacing) {
                header

                if sessionSpend != nil || showsSearchCredits {
                    VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
                        if let sessionSpend {
                            sessionSpendRow(sessionSpend, cachedLabel: sessionCachedInputLabel)
                        }
                        if let searchGrant, showsSearchCredits {
                            webSearchCreditsRow(searchGrant)
                        }
                    }
                }

                if accountService.webSearchNeedsTopUp {
                    webSearchFallbackNotice
                }

                activitySection
                footerActions
            }
        }
    }

    // MARK: Sections

    /// Hero balance at the top of the wallet.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Hero figure only; "credits" rides along as a caption so large
            // balances don't truncate the oversized figure.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: accountService.formattedBalanceValue)
                    .font(theme.font(size: theme.pickerCardHeroSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(
                        (isAttention || accountService.isFrozen)
                            ? theme.warningColor : theme.primaryText
                    )
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("credits available", bundle: .module)
                    .font(theme.font(size: theme.pickerCardBodySize))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            if accountService.isFrozen {
                Text("Account paused - add credits to resume.", bundle: .module)
                    .font(theme.font(size: theme.pickerCardCaptionSize))
                    .foregroundStyle(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PickerCardMetrics.rowInset)
    }

    /// Read-only label/value row in the picker's row geometry.
    private func valueRow(
        icon: String,
        iconColor: Color? = nil,
        label: LocalizedStringKey,
        value: String,
        valueColor: Color? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(iconColor ?? theme.tertiaryText)
                .frame(width: 16)
            Text(label, bundle: .module)
                .font(theme.font(size: theme.pickerCardBodySize))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(verbatim: value)
                .font(theme.font(size: theme.pickerCardBodySize))
                .monospacedDigit()
                .foregroundStyle(valueColor ?? theme.primaryText)
                .contentTransition(.numericText())
        }
        .pickerCardRowChrome(highlighted: false, minHeight: PickerCardMetrics.valueRowHeight)
    }

    @ViewBuilder
    private func sessionSpendRow(_ spend: String, cachedLabel: String?) -> some View {
        valueRow(icon: "chart.bar.fill", label: "This session", value: spend)
        // Prompt-cache hits: input the router billed at the cached rate.
        // Only rendered when the router echoed a non-zero split.
        if let cachedLabel {
            valueRow(
                icon: "bolt.fill",
                label: "Prompt cache",
                value: cachedLabel,
                valueColor: theme.secondaryText
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text("Prompt cache: \(cachedLabel) input tokens served from cache", bundle: .module)
            )
        }
    }

    /// The account's search credit balance, mirrored from the Credits tab so
    /// the balance the user actually spends on web search is visible where
    /// they check their wallet. Reads like the dollar balance above it — a
    /// single remaining count, amber once spent (searches then bill the
    /// shared balance or fall back to the built-in sources).
    private func webSearchCreditsRow(_ grant: OsaurusRouterWebAllowance) -> some View {
        let exhausted = grant.remainingTotal <= 0
        return valueRow(
            icon: "magnifyingglass",
            iconColor: exhausted ? theme.warningColor : nil,
            label: "Search credits",
            value: "\(grant.remainingTotal)",
            valueColor: exhausted ? theme.warningColor : nil
        )
    }

    /// Premium web search ran out of credits and is quietly using the
    /// built-in sources — the graceful-fallback state made visible where the
    /// user checks their wallet, per spec: billing outcomes reach the UI even
    /// when the search itself succeeded via fallback.
    private var webSearchFallbackNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.warningColor)
                .frame(width: 16)
            Text("Premium search is paused - add credits to resume.", bundle: .module)
                .font(theme.font(size: theme.pickerCardCaptionSize))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PickerCardMetrics.rowInset)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickerCardSectionTitle(L("Recent activity"))

            if rows.isEmpty {
                PickerCardFootnote(text: L("No activity yet"), color: subduedTextColor)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
                    ForEach(rows) { row in
                        activityRow(row)
                    }
                }
            }
        }
    }

    private func activityRow(_ row: WalletActivityRow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: iconName(for: row))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(badgeTint(for: row))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                // Transaction and web-usage titles are the projector's fixed
                // vocabulary ("Credits added", "Web search", ...) and localize
                // via key lookup. Model-usage titles are model/provider ids
                // and must render verbatim — LocalizedStringKey would treat
                // underscores in ids as markdown emphasis.
                Group {
                    if row.kind == .usage {
                        Text(verbatim: Self.modelName(row.title))
                            .help(Text(verbatim: row.title))
                    } else {
                        Text(LocalizedStringKey(row.title), bundle: .module)
                    }
                }
                .font(theme.font(size: theme.pickerCardBodySize))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                if let timeLabel = timeLabel(for: row) {
                    Text(verbatim: timeLabel)
                        .font(theme.font(size: theme.pickerCardCaptionSize))
                        .foregroundStyle(subduedTextColor)
                }
            }

            Spacer(minLength: 8)

            Text(verbatim: row.amountLabel)
                .font(theme.font(size: theme.pickerCardBodySize))
                .monospacedDigit()
                .foregroundStyle(row.isCredit ? theme.successColor : theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 4)
        .pickerCardRowChrome(highlighted: false)
    }

    /// Two quiet actions side by side: the primary one tinted, the
    /// navigation one neutral.
    private var footerActions: some View {
        HStack(spacing: 0) {
            PickerCardTextLink(
                title: L("Add credits"),
                icon: "plus",
                tint: theme.accentColor,
                fillsWidth: false,
                action: onAddCredits
            )
            Spacer(minLength: 8)
            PickerCardTextLink(title: L("View all"), icon: "arrow.forward", fillsWidth: false, action: onViewAll)
                .localizedHelp("Open the Credits tab for full usage and transaction history.")
        }
    }

    /// `provider/model` → `model`; the full id stays in the row's tooltip.
    private static func modelName(_ identifier: String) -> String {
        identifier.split(separator: "/", maxSplits: 1).last.map(String.init) ?? identifier
    }

    // MARK: Row styling

    private func iconName(for row: WalletActivityRow) -> String {
        switch row.kind {
        case .transaction:
            return row.isCredit ? "arrow.down.left" : "arrow.up.right"
        case .usage:
            return "sparkles"
        case .webUsage:
            return "magnifyingglass"
        }
    }

    /// Badge + icon tint. Money-in reads green; spends stay neutral unless the
    /// request itself needs attention (stopped/error states from the ledger).
    /// Hosted web searches render in the premium (accent) family — a touch
    /// stronger when the request used a search credit.
    private func badgeTint(for row: WalletActivityRow) -> Color {
        if row.isCredit { return theme.successColor }
        switch row.stateKind {
        case .warning: return theme.warningColor
        case .error: return theme.errorColor
        case .success, .secondary:
            if row.kind == .webUsage {
                return row.isIncludedWebRequest
                    ? theme.accentColor : theme.accentColor.opacity(0.7)
            }
            return theme.secondaryText
        }
    }

    private func timeLabel(for row: WalletActivityRow) -> String? {
        guard let date = row.date else { return nil }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}


/// account-service updates re-render only this chip, never the whole card.
/// Hovering previews the wallet panel; clicking pins it so its actions
/// (Add credits → top-up sheet, View all → Credits tab) are reachable.
/// Quiet plain text normally, escalating to an amber pill / "Add credits"
/// CTA as the balance runs low or hits zero — router-billed sessions only.
struct FloatingCreditsChip: View {
    let isRouterBilledSession: Bool
    /// Total micro-USD spent on the Osaurus Router this session (popover row).
    let sessionSpendMicro: Int
    /// Session prompt-cache hit label for the popover's spend row; nil hides it.
    let sessionCachedInputLabel: String?
    let metaCompact: Bool
    let metaUltraCompact: Bool
    let onAddCredits: (() -> Void)?

    @ObservedObject private var accountService = OsaurusRouterAccountService.shared
    @Environment(\.theme) private var theme

    /// Wallet panel presentation. Hovering the chip opens it as a passive
    /// preview (dismissed on hover exit); clicking pins it so its actions
    /// (Add credits, View all) are reachable.
    @State private var showWalletPanel = false
    /// True when the wallet panel was opened by click; hover exit no longer
    /// dismisses it, only outside-click / an action does.
    @State private var walletPanelPinned = false
    @State private var walletHover = HoverPreviewPresence()
    /// Measured before the first presentation, then updated as activity loads.
    @State private var walletPanelHeight: CGFloat = 0
    @State private var balanceHoverTask: Task<Void, Never>?
    /// Delayed dismiss for the hover-opened wallet panel. Gives the cursor a
    /// grace period to travel from the chip into the panel (which lives in its
    /// own window, so hovering it doesn't keep the chip "hovered"); the panel's
    /// own hover cancels it so its buttons stay clickable.
    @State private var walletDismissTask: Task<Void, Never>?

    /// Urgency tiers for the balance indicator. Healthy stays quiet (plain muted
    /// text that blends into the meta cluster); low and empty escalate to an
    /// amber pill so a top-up is easy to notice. Empty/frozen reads as an "Add
    /// credits" call to action — deliberately amber, never error-red, so it
    /// invites action instead of looking like a failure. The escalation only
    /// applies to router-billed sessions; see `creditsStyle(for:)`.
    private enum BalanceLevel {
        case healthy
        case low
        case empty
    }

    private var balanceLevel: BalanceLevel {
        let micro = accountService.balanceMicroValue
        if micro <= 0 || accountService.isFrozen {
            return .empty
        }
        if micro < 1_000_000 {  // < 10,000 credits ($1.00)
            return .low
        }
        return .healthy
    }

    /// Resolved visual tokens for one `BalanceLevel` so the body can render
    /// declaratively instead of re-deriving each property from the level inline.
    private struct CreditsChipStyle {
        let iconName: String
        let iconColor: Color
        let textColor: Color
        let weight: Font.Weight
        /// Pill fill/stroke; `nil` keeps the chip chrome-free (healthy state).
        let pill: (fill: Color, stroke: Color)?
        let glow: Color
        /// When false, the chip shows the "Add credits" CTA instead of an amount.
        let showsAmount: Bool
    }

    private func creditsStyle(for level: BalanceLevel) -> CreditsChipStyle {
        let amber = theme.warningColor
        // Outside router-billed sessions the chip never escalates: the balance
        // doesn't block the current session, so a $0/unknown wallet reads as
        // quiet muted "Add credits" text instead of an amber call to action.
        guard isRouterBilledSession else {
            return CreditsChipStyle(
                iconName: "cloud",
                iconColor: theme.tertiaryText,
                textColor: theme.secondaryText,
                weight: .medium,
                pill: nil,
                glow: .clear,
                showsAmount: level != .empty
            )
        }
        switch level {
        case .healthy:
            return CreditsChipStyle(
                iconName: "cloud",
                iconColor: theme.tertiaryText,
                textColor: theme.secondaryText,
                weight: .medium,
                pill: nil,
                glow: .clear,
                showsAmount: true
            )
        case .low:
            // The chip shows the router balance, so a low balance escalates the
            // chip itself to amber text (no pill) — a gentle nudge that stops
            // short of the empty-state "Add credits" call to action.
            return CreditsChipStyle(
                iconName: "cloud",
                iconColor: amber,
                textColor: amber,
                weight: .semibold,
                pill: nil,
                glow: .clear,
                showsAmount: true
            )
        case .empty:
            return CreditsChipStyle(
                iconName: "plus.circle.fill",
                iconColor: amber,
                textColor: amber,
                weight: .semibold,
                pill: (amber.opacity(0.22), amber.opacity(0.5)),
                glow: amber.opacity(0.25),
                showsAmount: false
            )
        }
    }

    /// This session's Router spend, formatted for the hover popover. The chip
    /// surfaces the account balance; spend is shown only in the popover.
    private var sessionSpendDisplay: String {
        OsaurusRouter.formatMicroAsCredits(String(sessionSpendMicro))
    }

    /// Accessibility text for the credits chip. Describes the router balance the
    /// chip shows and the tap action; session spend lives in the wallet panel.
    private var creditsHelpText: Text {
        if accountService.isFrozen {
            return Text("Account paused - add credits to resume.", bundle: .module)
        }
        return Text("\(accountService.formattedBalance) router balance. Click to open the wallet.", bundle: .module)
    }

    var body: some View {
        let level = balanceLevel
        let style = creditsStyle(for: level)
        let caption = CGFloat(theme.captionSize)
        // Hide the icon in compact mode to save width, except the empty-state
        // plus glyph, which signals the chip is actionable. In the ultra-compact
        // tier we always keep the icon, since it becomes the whole chip.
        let showIcon = !metaCompact || level == .empty || metaUltraCompact
        // At the tightest width the chip is icon-only (glyph carries the state,
        // hover/tap opens the wallet) so the row's toggle chips aren't clipped.
        let showLabel = !metaUltraCompact

        Group {
            if style.pill == nil {
                // Balance states: the same pill chrome as the model selector
                // chip (`SelectorChip`) so the meta cluster's interactive
                // chips read as one family.
                SelectorChip(isActive: showWalletPanel && walletPanelPinned) {
                    handleChipTap(level: level)
                } content: {
                    chipLabel(style: style, caption: caption, showIcon: showIcon, showLabel: showLabel)
                }
            } else {
                // Empty state keeps its own amber "Add credits" CTA pill.
                Button {
                    handleChipTap(level: level)
                } label: {
                    chipLabel(style: style, caption: caption, showIcon: showIcon, showLabel: showLabel)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            if let pill = style.pill {
                                Capsule()
                                    .fill(pill.fill)
                                    .overlay(Capsule().strokeBorder(pill.stroke, lineWidth: 1))
                            }
                        }
                        // Soft glow on the empty CTA draws the eye without a
                        // repeating animation.
                        .shadow(color: style.glow, radius: 5, x: 0, y: 1)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .accessibilityLabel(creditsHelpText)
        .onHover { hovering in
            walletHover.isOverTrigger = hovering
            balanceHoverTask?.cancel()
            // Empty state: the chip is a direct "Add credits" CTA (click opens
            // the top-up sheet), so no hover preview — surfacing the wallet
            // panel there just re-offers the same action with an extra hop.
            guard level != .empty || onAddCredits == nil else {
                if !hovering, !walletPanelPinned { scheduleWalletDismiss() }
                return
            }
            if hovering {
                walletDismissTask?.cancel()
                balanceHoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    showWalletPanel = true
                }
            } else if !walletPanelPinned {
                scheduleWalletDismiss()
            }
        }
        .anchoredCard(
            isPresented: $showWalletPanel,
            size: CGSize(width: PickerCardMetrics.infoCardWidth, height: walletPanelHeight),
            alignment: .trailing,
            constrainToWindow: true,
            takesFocus: walletPanelPinned,
            accessibilityLabel: L("Credits")
        ) {
            WalletPopover(
                sessionSpend: isRouterBilledSession ? sessionSpendDisplay : nil,
                sessionCachedInputLabel: isRouterBilledSession ? sessionCachedInputLabel : nil,
                isAttention: isRouterBilledSession && balanceLevel != .healthy,
                onAddCredits: {
                    closeWalletPanel()
                    onAddCredits?()
                },
                onViewAll: {
                    closeWalletPanel()
                    AppDelegate.shared?.showManagementWindow(initialTab: .credits)
                },
                onHeightChange: { walletPanelHeight = $0 }
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                walletHover.isOverPanel = hovering
                if hovering {
                    walletDismissTask?.cancel()
                } else if !walletPanelPinned {
                    scheduleWalletDismiss()
                }
            }
        }
        .onChange(of: showWalletPanel) { isShown in  // Intel: Ventura onChange
            // Outside-click dismissal flips the binding directly; unpin so the
            // next hover preview behaves normally.
            if !isShown {
                walletHover.isOverPanel = false
                walletPanelPinned = false
                walletPanelHeight = 0
                balanceHoverTask?.cancel()
                walletDismissTask?.cancel()
            }
        }
        .onDisappear {
            balanceHoverTask?.cancel()
            walletDismissTask?.cancel()
        }
    }

    /// The chip's icon + amount/CTA line, shared by the `SelectorChip`
    /// (balance states) and the amber CTA pill (empty state).
    @ViewBuilder
    private func chipLabel(
        style: CreditsChipStyle,
        caption: CGFloat,
        showIcon: Bool,
        showLabel: Bool
    ) -> some View {
        HStack(spacing: 4) {
            if showIcon {
                Image(systemName: style.iconName)
                    .font(.system(size: caption - 2))
                    .foregroundColor(style.iconColor)
            }

            if showLabel {
                if style.showsAmount {
                    // Composer shows the overall router balance; this session's
                    // spend is surfaced only in the hover popover. Abbreviated
                    // ("212.1K credits") so six-figure balances don't crowd
                    // the meta cluster.
                    Text(verbatim: accountService.compactFormattedBalance)
                        .font(.system(size: caption - 1, weight: style.weight, design: .monospaced))
                        .foregroundColor(style.textColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text("Add credits", bundle: .module)
                        .font(theme.font(size: caption - 1, weight: style.weight))
                        .foregroundColor(style.textColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private func handleChipTap(level: BalanceLevel) {
        balanceHoverTask?.cancel()
        walletDismissTask?.cancel()
        // Empty state: the chip IS the "Add credits" call to action, so a
        // click opens the top-up sheet directly — routing it through the
        // wallet panel just to click a second "Add credits" there was an
        // extra hop with no information gain.
        if level == .empty, let onAddCredits {
            showWalletPanel = false
            walletPanelPinned = false
            onAddCredits()
            return
        }
        // Otherwise click pins the wallet panel (rather than jumping straight
        // to the top-up sheet) so its actions stay reachable; a second click
        // while pinned closes it.
        if showWalletPanel && walletPanelPinned {
            showWalletPanel = false
            walletPanelPinned = false
        } else {
            walletPanelPinned = true
            showWalletPanel = true
        }
    }

    /// Dismiss the hover-opened wallet panel after a grace period, giving the
    /// cursor time to cross the gap into the panel window.
    private func scheduleWalletDismiss() {
        balanceHoverTask?.cancel()
        walletDismissTask?.cancel()
        guard walletHover.shouldDismiss(isPinned: walletPanelPinned) else { return }
        walletDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                walletHover.shouldDismiss(isPinned: walletPanelPinned)
            else { return }
            showWalletPanel = false
        }
    }

    private func closeWalletPanel() {
        walletDismissTask?.cancel()
        balanceHoverTask?.cancel()
        showWalletPanel = false
        walletPanelPinned = false
    }
}
