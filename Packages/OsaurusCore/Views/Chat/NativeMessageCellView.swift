//
//  NativeMessageCellView.swift
//  osaurus
//
//  NSTableCellView subclass — pure AppKit rendering for all block types
//  (preflight chips: NativePreflightCapabilitiesView).
//

import AppKit
import SwiftUI
import QuartzCore

// MARK: - Cell Rendering Context

/// Passed to NativeMessageCellView.configure() — bundles all rendering inputs.
struct CellRenderingContext {
    var width: CGFloat
    let agentName: String
    let agentAvatar: String?
    /// Absolute filesystem path to a user-supplied custom avatar image.
    /// When present, takes precedence over `agentAvatar` (mascot id).
    let agentCustomAvatarPath: String?
    let isStreaming: Bool
    let lastAssistantTurnId: UUID?
    let theme: any ThemeProtocol
    /// mutable so `configureCell` can override with coordinator `expandedIds` before `applyBlocks` runs again
    var expandedIds: Set<String>
    let onToggleExpand: (String) -> Void
    /// Called by native views after they've measured their own height.
    /// Coordinator updates heightCache and calls noteHeightOfRows if delta > 2pt.
    var onHeightMeasured: ((CGFloat, String) -> Void)? = nil
    var isTurnHovered: Bool = false
    var editingTurnId: UUID? = nil
    var editText: (() -> String, (String) -> Void)? = nil
    var onConfirmEdit: (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil
    var onCopy: ((UUID) -> Void)? = nil
    var onRegenerate: ((UUID) -> Void)? = nil
    var onEdit: ((UUID) -> Void)? = nil
    var onDelete: ((UUID) -> Void)? = nil
    var onSpeak: ((UUID) -> Void)? = nil
    /// Deletes an assistant response. The confirmation dialog offers an option
    /// to also delete the prompting user message. Distinct from `onDelete`,
    /// which truncates a user turn and everything after it.
    var onDeleteMessage: ((UUID) -> Void)? = nil
    /// Sends a tapped follow-up suggestion as the next message (upstream).
    var onFollowUpTap: ((String) -> Void)? = nil
    /// Has this follow-up row already played its entrance animation in the
    /// current chat? Lets `configureAsFollowUpSuggestions` suppress the
    /// reveal when a recycled cell re-mounts it after scrolling (upstream).
    var hasFollowUpsShown: ((String) -> Bool)? = nil
    var markFollowUpsShown: ((String) -> Void)? = nil
    /// Read at menu-open time so late generation statistics do not leave a
    /// recycled action row showing a stale response's metrics (#2959).
    var responseStatsForTurn: ((UUID) -> String?)? = nil
    /// attachment or shared-artifact id string → full screen preview from ChatView
    var onUserImagePreview: ((String) -> Void)? = nil
    /// Active in-conversation find query (Cmd+F). Empty when the find bar is
    /// closed. Message cells paint every case-insensitive occurrence in
    /// their body text via `NativeMarkdownView.setSearchHighlight`.
    var searchHighlightQuery: String = ""
}

// MARK: - Cell-Isolated ExpandedBlocksStore Proxy

// MARK: - Native Header View

/// Pure AppKit header row: name label + hover-revealed action buttons.
final class NativeHeaderView: NSView {

    private let avatarImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private var isEditing = false
    private var avatarLeadingConstraint: NSLayoutConstraint?
    private var nameLeadingToAvatar: NSLayoutConstraint?
    private var nameLeadingToSelf: NSLayoutConstraint?
    /// User turns have no avatar and their bubble is right-aligned (trailing);
    /// pinning the name label there too (left of the action stack) keeps "You"
    /// visually anchored above its own bubble instead of stranded on the left
    /// edge of the full-width header row.
    private var nameTrailingToActionStack: NSLayoutConstraint?
    /// Default avatar diameter when the theme doesn't provide one. Theme
    /// override comes through `configure(...)` and is clamped to [16, 108]
    /// before being applied via `avatarSizeConstraints`.
    private static let defaultAvatarSize: CGFloat = 24
    static let minAvatarSize: CGFloat = 16
    static let maxAvatarSize: CGFloat = 108
    private var avatarWidthConstraint: NSLayoutConstraint?
    private var avatarHeightConstraint: NSLayoutConstraint?
    private var currentAvatarSize: CGFloat = NativeHeaderView.defaultAvatarSize

    private var turnId: UUID = UUID()
    private var onCopy: ((UUID) -> Void)?
    private var onRegenerate: ((UUID) -> Void)?
    private var onEdit: ((UUID) -> Void)?
    private var onDelete: ((UUID) -> Void)?
    private var storedOnCancelEdit: (() -> Void)?
    private var currentRole: MessageRole = .assistant
    private var currentTheme: (any ThemeProtocol)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.imageScaling = .scaleProportionallyUpOrDown
        avatarImageView.isHidden = true
        avatarImageView.wantsLayer = true
        avatarImageView.layer?.cornerRadius = Self.defaultAvatarSize / 2
        avatarImageView.layer?.masksToBounds = true
        avatarImageView.layer?.borderWidth = 1
        addSubview(avatarImageView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isSelectable = true
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.alignment = .centerY
        // `.fill` stretches subviews on the cross axis to the stack height; that breaks square chips.
        actionStack.distribution = .equalSpacing
        actionStack.alphaValue = 0
        addSubview(actionStack)

        let avatarLeading = avatarImageView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let nameToAvatar = nameLabel.leadingAnchor.constraint(
            equalTo: avatarImageView.trailingAnchor,
            constant: 6
        )
        let nameToSelf = nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor)
        nameToSelf.isActive = true
        avatarLeadingConstraint = avatarLeading
        nameLeadingToAvatar = nameToAvatar
        nameLeadingToSelf = nameToSelf

        let nameToActionStack = nameLabel.trailingAnchor.constraint(
            equalTo: actionStack.leadingAnchor,
            constant: -8
        )
        nameTrailingToActionStack = nameToActionStack

        let avatarW = avatarImageView.widthAnchor.constraint(equalToConstant: Self.defaultAvatarSize)
        let avatarH = avatarImageView.heightAnchor.constraint(equalToConstant: Self.defaultAvatarSize)
        avatarWidthConstraint = avatarW
        avatarHeightConstraint = avatarH

        NSLayoutConstraint.activate([
            avatarLeading,
            avatarImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarW,
            avatarH,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        turnId: UUID,
        role: MessageRole,
        name: String,
        avatar: String?,
        customAvatarPath: String?,
        isEditing: Bool,
        isHovered: Bool,
        theme: any ThemeProtocol,
        onCopy: ((UUID) -> Void)?,
        onRegenerate: ((UUID) -> Void)?,
        onEdit: ((UUID) -> Void)?,
        onDelete: ((UUID) -> Void)?,
        onCancelEdit: (() -> Void)?,
        /// User turns render their action cluster once, per message, anchored
        /// beside the bubble (see `configureAsUserMessage`). The "You" name
        /// header is emitted only when the conversation side FLIPS, so it
        /// covers just the first turn of a run — it must not draw a second,
        /// partial copy of the same buttons. Label-only there.
        showsActions: Bool = true,
        /// False for enveloped user turns (self-scheduled / watcher runs):
        /// hand-editing the stored envelope would replace the dispatch
        /// framing with free text (upstream).
        allowsEdit: Bool = true
    ) {
        self.allowsEdit = allowsEdit
        self.turnId = turnId
        self.isEditing = isEditing
        self.onCopy = onCopy
        self.onRegenerate = onRegenerate
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.storedOnCancelEdit = onCancelEdit
        self.currentRole = role
        self.currentTheme = theme

        // Resolve theme-driven sizing + visibility first so avatar generation
        // matches the actual rendered size. Clamped to a sensible UI range
        // even if a malformed theme JSON lands here.
        let themeSize = CGFloat(
            max(Double(Self.minAvatarSize), min(Double(Self.maxAvatarSize), theme.inlineAvatarSize))
        )
        if currentAvatarSize != themeSize {
            currentAvatarSize = themeSize
            avatarWidthConstraint?.constant = themeSize
            avatarHeightConstraint?.constant = themeSize
            avatarImageView.layer?.cornerRadius = themeSize / 2
        }

        // Assistant messages always show *some* avatar (custom > mascot >
        // monogram) so the chat header is visually consistent regardless of
        // which avatar mode the user picked, unless the theme opts out via
        // `showInlineAvatar`. User messages hide the avatar.
        avatarSource =
            role == .assistant && theme.showInlineAvatar
            ? AvatarSource(
                name: name,
                avatar: avatar,
                customAvatarPath: customAvatarPath,
                tint: NSColor(theme.accentColor),
                background: NSColor(theme.secondaryText).withAlphaComponent(0.12)
            )
            : nil
        let resolved = resolveAvatarImage()
        avatarImageView.image = resolved
        // Every avatar kind is pre-rendered at the view's exact size, so this
        // only matters as a safety net and never scales in practice.
        avatarImageView.imageScaling = .scaleProportionallyUpOrDown
        let showAvatar = resolved != nil
        avatarImageView.isHidden = !showAvatar
        avatarImageView.layer?.borderColor =
            NSColor(theme.secondaryText).withAlphaComponent(0.35).cgColor
        // User bubbles sit flush against the trailing edge; pin "You" there
        // too (left of the action stack) instead of the leading edge used
        // for the assistant's avatar+name so the header reads as attached
        // to its own bubble rather than stranded on the opposite side.
        let alignTrailing = role == .user
        nameLeadingToSelf?.isActive = !alignTrailing && !showAvatar
        nameLeadingToAvatar?.isActive = !alignTrailing && showAvatar
        nameTrailingToActionStack?.isActive = alignTrailing
        nameLabel.alignment = alignTrailing ? .right : .left

        let nameVisible = role == .user || theme.showAgentName
        nameLabel.isHidden = !nameVisible
        nameLabel.stringValue = nameVisible ? name : ""
        let nameSize = CGFloat(max(12.5, min(18, theme.agentNameSize)))
        nameLabel.font = NSFont.systemFont(ofSize: nameSize, weight: .semibold)
        nameLabel.textColor = role == .user ? NSColor(theme.accentColor) : NSColor(theme.secondaryText)

        rebuildActionButtons(
            role: role, theme: theme, onCancelEdit: onCancelEdit, showsActions: showsActions)
        invalidateIntrinsicContentSize()
        setHovered(isHovered, animated: false)
    }

    private struct AvatarSource {
        let name: String
        let avatar: String?
        let customAvatarPath: String?
        let tint: NSColor
        let background: NSColor
    }

    /// Inputs of the current avatar, kept so the bitmap can be re-rendered
    /// when the view moves to a display with a different backing scale.
    private var avatarSource: AvatarSource?
    private var avatarRenderScale: CGFloat = 0

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Custom > mascot > monogram, rendered at `currentAvatarSize` for the
    /// current backing scale. Nil when the row shows no avatar.
    private func resolveAvatarImage() -> NSImage? {
        guard let source = avatarSource else { return nil }
        let scale = backingScale
        avatarRenderScale = scale
        let renderer = AvatarBitmapRenderer.shared
        if let path = source.customAvatarPath, !path.isEmpty,
            let img = renderer.image(
                customURL: URL(fileURLWithPath: path),
                pointSize: currentAvatarSize,
                scale: scale
            )
        {
            return img
        }
        if let mascot = source.avatar.flatMap(AgentMascot.init(rawValue:)),
            let img = renderer.image(mascot: mascot, pointSize: currentAvatarSize, scale: scale)
        {
            return img
        }
        return Self.monogramImage(
            name: source.name,
            tint: source.tint,
            background: source.background,
            size: currentAvatarSize
        )
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshAvatarForBackingScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAvatarForBackingScale()
    }

    private func refreshAvatarForBackingScale() {
        guard avatarSource != nil, window != nil, backingScale != avatarRenderScale else { return }
        avatarImageView.image = resolveAvatarImage()
    }

    /// Renders a monogram avatar (initial-on-tinted-circle) into a cached
    /// NSImage so the inline header has something to show when no mascot or
    /// custom image is configured. Cached by (initial, tint, size) — themes
    /// share the same key once stringified.
    private static var monogramCache: [String: NSImage] = [:]
    private static let monogramCacheLock = NSLock()
    private static func monogramImage(
        name: String,
        tint: NSColor,
        background: NSColor,
        size: CGFloat
    ) -> NSImage {
        let initial: String = {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first else { return "?" }
            return String(first).uppercased()
        }()
        let key = "\(initial)|\(tint.hashValue)|\(background.hashValue)|\(Int(size))"
        monogramCacheLock.lock()
        if let hit = monogramCache[key] {
            monogramCacheLock.unlock()
            return hit
        }
        monogramCacheLock.unlock()

        let pixelSize = NSSize(width: size, height: size)
        let image = NSImage(size: pixelSize, flipped: false) { rect in
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            background.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.5, weight: .bold),
                .foregroundColor: tint,
            ]
            let str = NSAttributedString(string: initial, attributes: attrs)
            let strSize = str.size()
            let pt = NSPoint(
                x: rect.midX - strSize.width / 2,
                y: rect.midY - strSize.height / 2
            )
            str.draw(at: pt)
            ctx?.restoreGState()
            return true
        }
        monogramCacheLock.lock()
        monogramCache[key] = image
        monogramCacheLock.unlock()
        return image
    }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(actionStack.arrangedSubviews.count)
        guard count > 0 else { return NSSize(width: NSView.noIntrinsicMetric, height: 28) }
        let stackW = count * Self.actionButtonSize + max(0, count - 1) * actionStack.spacing
        let labelW = nameLabel.intrinsicContentSize.width
        let avatarW: CGFloat = avatarImageView.isHidden ? 0 : (currentAvatarSize + 6)
        let total = stackW + avatarW + (labelW > 0 ? labelW + 8 : 0)
        return NSSize(width: total, height: 28)
    }

    func setHovered(_ hovered: Bool, animated: Bool = true) {
        let alpha: CGFloat = (hovered || isEditing) ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                actionStack.animator().alphaValue = alpha
            }
        } else {
            actionStack.alphaValue = alpha
        }
    }

    private var allowsEdit = true

    private func rebuildActionButtons(
        role: MessageRole, theme: any ThemeProtocol, onCancelEdit: (() -> Void)?,
        showsActions: Bool = true
    ) {
        for v in actionStack.arrangedSubviews {
            actionStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        // Assistant actions (copy, regenerate) are rendered in a dedicated footer row
        // under every completed assistant turn, so the header only carries actions for
        // user messages now. This lets the table coordinator skip hover reconfigures
        // for assistant rows entirely.
        guard showsActions, role == .user else { return }

        addBtn(icon: "doc.on.doc", help: L("Copy"), theme: theme, tint: nil) { [weak self] in
            guard let self else { return }
            self.onCopy?(self.turnId)
        }
        if allowsEdit {
            addBtn(icon: "pencil", help: L("Edit"), theme: theme, tint: nil) { [weak self] in
                guard let self else { return }
                self.onEdit?(self.turnId)
            }
        }
        addBtn(icon: "trash", help: L("Delete"), theme: theme, tint: nil) { [weak self] in
            guard let self else { return }
            self.onDelete?(self.turnId)
        }

        if isEditing, let onCancelEdit {
            addBtn(icon: "xmark", help: L("Cancel edit"), theme: theme, tint: nil, action: onCancelEdit)
        }
    }

    private static let actionButtonSize: CGFloat = 28

    private func addBtn(
        icon: String,
        help: String,
        theme: any ThemeProtocol,
        tint: NSColor?,
        action: @escaping () -> Void
    ) {
        let control = HeaderCircleActionControl(action: action)
        let pointSize = CGFloat(theme.captionSize) - 1
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        control.setSymbol(
            SymbolImageCache.image(icon, accessibilityDescription: help)?.withSymbolConfiguration(cfg),
            toolTip: help,
            theme: theme,
            iconTint: tint
        )
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            control.widthAnchor.constraint(equalToConstant: Self.actionButtonSize),
            control.heightAnchor.constraint(equalToConstant: Self.actionButtonSize),
        ])
        actionStack.addArrangedSubview(control)
    }
}

// MARK: - Circular header action buttons (matches SwiftUI `HeaderBlockContent` / `ActionButton`)

/// `NSButton`’s cell/layer often disagree with `bounds`, producing non-circular backgrounds; draw the
/// chrome on a plain `NSView` and keep a borderless `NSButton` for hit-testing and keyboard focus.
final class HeaderCircleActionControl: NSView {
    private let button: NSButton
    private var block: () -> Void
    private var fillBase: NSColor = .clear
    private var fillHover: NSColor = .clear
    private var tracking: NSTrackingArea?

    init(action: @escaping () -> Void) {
        self.block = action
        let btn = NSButton(frame: .zero)
        self.button = btn
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.target = self
        btn.action = #selector(fire)
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.focusRingType = .none
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyDown
        btn.wantsLayer = false
        addSubview(btn)
        NSLayoutConstraint.activate([
            btn.leadingAnchor.constraint(equalTo: leadingAnchor),
            btn.trailingAnchor.constraint(equalTo: trailingAnchor),
            btn.topAnchor.constraint(equalTo: topAnchor),
            btn.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ image: NSImage?, toolTip: String, theme: any ThemeProtocol, iconTint: NSColor?) {
        button.image = image
        button.toolTip = toolTip
        button.contentTintColor = iconTint ?? NSColor(theme.tertiaryText)
        let secondary = NSColor(theme.secondaryBackground)
        fillBase = secondary.withAlphaComponent(0.8)
        fillHover = secondary.withAlphaComponent(0.95)
        layer?.backgroundColor = fillBase.cgColor
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        layer?.cornerRadius = side > 0 ? side / 2 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        tracking = ta
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        layer?.backgroundColor = fillHover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        layer?.backgroundColor = fillBase.cgColor
    }

    @objc private func fire() { block() }

    func setAction(_ newAction: @escaping () -> Void) {
        block = newAction
    }
}

// MARK: - Native Assistant Actions View

/// Copy + Regenerate pinned under every completed assistant turn.
/// Always visible (no hover), so the table coordinator can skip hover
/// reconfigures for assistant rows entirely.
final class NativeAssistantActionsView: NSView {

    private let copyButton: HeaderCircleActionControl
    private let regenerateButton: HeaderCircleActionControl
    let speakButton: HeaderCircleActionControl
    private let overflowButton: HeaderCircleActionControl
    /// "3 files changed · View changes" — the end-of-turn entry point into
    /// the File Changes panel. Hidden until the journal reports this turn
    /// recorded something; refreshed when history changes (e.g. a revert).
    /// Upstream #2907 part A.
    // `NSButton(title:target:action:)` hung the main thread (upstream #2977).
    private let fileChangesButton = NSButton(frame: .zero)
    private var fileChangesSummary: FileChangeTurnSummary?
    private var fileChangesLookupTurnId: UUID?
    nonisolated(unsafe) private var fileChangesObservation: NSObjectProtocol?
    /// Intel: this view hugs its last control exactly (see the overflow
    /// constraint), so the trailing pin moves to the link while it shows.
    private var overflowTrailingConstraint: NSLayoutConstraint?
    private var fileChangesTrailingConstraint: NSLayoutConstraint?

    private var turnId: UUID = UUID()
    private var onCopy: ((UUID) -> Void)?
    private var onRegenerate: ((UUID) -> Void)?
    var onSpeak: ((UUID) -> Void)?
    private var onDeleteMessage: ((UUID) -> Void)?
    private var responseStatsForTurn: ((UUID) -> String?)?

    nonisolated(unsafe) private var ttsObservation: NSObjectProtocol?
    nonisolated(unsafe) private var ttsConfigObservation: NSObjectProtocol?
    private var currentTheme: (any ThemeProtocol)?
    private var speakWidthConstraint: NSLayoutConstraint?
    private var speakLeadingConstraint: NSLayoutConstraint?

    override init(frame: NSRect) {
        let copyControl = HeaderCircleActionControl(action: {})
        let regenControl = HeaderCircleActionControl(action: {})
        let speakControl = HeaderCircleActionControl(action: {})
        let overflowControl = HeaderCircleActionControl(action: {})
        self.copyButton = copyControl
        self.regenerateButton = regenControl
        self.speakButton = speakControl
        self.overflowButton = overflowControl
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        regenerateButton.translatesAutoresizingMaskIntoConstraints = false
        speakButton.translatesAutoresizingMaskIntoConstraints = false
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copyButton)
        addSubview(regenerateButton)
        addSubview(speakButton)
        addSubview(overflowButton)

        copyButton.setAction { [weak self] in
            guard let self else { return }
            self.onCopy?(self.turnId)
        }
        regenerateButton.setAction { [weak self] in
            guard let self else { return }
            self.onRegenerate?(self.turnId)
        }
        speakButton.setAction { [weak self] in
            guard let self else { return }
            self.onSpeak?(self.turnId)
        }
        overflowButton.setAction { [weak self] in
            self?.presentOverflowMenu()
        }

        let size: CGFloat = 28
        let speakLeading = speakButton.leadingAnchor.constraint(
            equalTo: regenerateButton.trailingAnchor,
            constant: 4
        )
        let speakWidth = speakButton.widthAnchor.constraint(equalToConstant: size)
        self.speakLeadingConstraint = speakLeading
        self.speakWidthConstraint = speakWidth

        NSLayoutConstraint.activate([
            copyButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: size),
            copyButton.heightAnchor.constraint(equalToConstant: size),

            regenerateButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 4),
            regenerateButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            regenerateButton.widthAnchor.constraint(equalToConstant: size),
            regenerateButton.heightAnchor.constraint(equalToConstant: size),

            speakLeading,
            speakButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            speakWidth,
            speakButton.heightAnchor.constraint(equalToConstant: size),

            overflowButton.leadingAnchor.constraint(equalTo: speakButton.trailingAnchor, constant: 4),
            overflowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflowButton.widthAnchor.constraint(equalToConstant: size),
            overflowButton.heightAnchor.constraint(equalToConstant: size),
            // Required equality (not `<=`) — with the 4th button, chaining another
            // `<=` here left this view's own trailing edge doubly unbounded (the
            // button's `<=` to us, ours `<=` to the cell in configureAsAssistantActions),
            // so nothing pinned our width to our content. Harmless while the row has
            // room, but leaves the row's own frame undefined the moment it doesn't —
            // hug the last button exactly instead.
        ])
        let overflowTrailing = overflowButton.trailingAnchor.constraint(equalTo: trailingAnchor)
        overflowTrailing.isActive = true
        overflowTrailingConstraint = overflowTrailing

        fileChangesButton.title = ""
        fileChangesButton.translatesAutoresizingMaskIntoConstraints = false
        fileChangesButton.isBordered = false
        fileChangesButton.bezelStyle = .inline
        fileChangesButton.imagePosition = .imageLeading
        fileChangesButton.setButtonType(.momentaryChange)
        fileChangesButton.isHidden = true
        fileChangesButton.target = self
        fileChangesButton.action = #selector(openFileChanges)
        addSubview(fileChangesButton)
        NSLayoutConstraint.activate([
            fileChangesButton.leadingAnchor.constraint(equalTo: overflowButton.trailingAnchor, constant: 10),
            fileChangesButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        fileChangesTrailingConstraint = fileChangesButton.trailingAnchor.constraint(equalTo: trailingAnchor)
        fileChangesObservation = NotificationCenter.default.addObserver(
            forName: .fileChangesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fileChangesLookupTurnId = nil
                self.refreshFileChangesSummary()
            }
        }

        ttsObservation = NotificationCenter.default.addObserver(
            forName: .ttsPlaybackStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTTSVisibility()
                self?.refreshSpeakIcon()
            }
        }
        ttsConfigObservation = NotificationCenter.default.addObserver(
            forName: .ttsConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTTSVisibility()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observation = ttsObservation {
            NotificationCenter.default.removeObserver(observation)
        }
        if let observation = ttsConfigObservation {
            NotificationCenter.default.removeObserver(observation)
        }
        if let observation = fileChangesObservation {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    // MARK: - File changes summary

    private func setFileChangesHidden(_ hidden: Bool) {
        fileChangesButton.isHidden = hidden
        fileChangesTrailingConstraint?.isActive = !hidden
        overflowTrailingConstraint?.isActive = hidden
    }

    private func refreshFileChangesSummary() {
        let turn = turnId
        guard fileChangesLookupTurnId != turn else {
            applyFileChangesSummary()
            return
        }
        fileChangesLookupTurnId = turn
        fileChangesSummary = nil
        setFileChangesHidden(true)
        Task { @MainActor [weak self] in
            let summary = await FileChangeJournal.shared.turnSummary(turnId: turn)
            guard let self, self.turnId == turn else { return }
            self.fileChangesSummary = summary
            self.applyFileChangesSummary()
        }
    }

    private func applyFileChangesSummary() {
        guard let summary = fileChangesSummary, let theme = currentTheme else {
            setFileChangesHidden(true)
            return
        }
        let count = summary.fileCount
        var title = L("\(count) files changed")
        title += summary.allReverted ? " · " + L("reverted") : " · " + L("View changes")
        let tint = NSColor(summary.allReverted ? theme.tertiaryText : theme.accentColor)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        fileChangesButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(theme.captionSize), weight: .medium),
                .foregroundColor: tint,
                .paragraphStyle: paragraph,
            ]
        )
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(theme.captionSize) - 1, weight: .medium)
        fileChangesButton.image = SymbolImageCache.image(
            "clock.arrow.circlepath", accessibilityDescription: nil
        )?.withSymbolConfiguration(cfg)
        fileChangesButton.contentTintColor = tint
        fileChangesButton.toolTip = L("Show in File Changes")
        fileChangesButton.setAccessibilityLabel(title)
        setFileChangesHidden(false)
    }

    @objc private func openFileChanges() {
        guard let summary = fileChangesSummary else { return }
        FileChangeSummaryStore.requestPanel(sessionId: summary.sessionId, focusing: summary.firstSetId)
    }

    func configure(
        turnId: UUID,
        theme: any ThemeProtocol,
        onCopy: ((UUID) -> Void)?,
        onRegenerate: ((UUID) -> Void)?,
        onSpeak: ((UUID) -> Void)?,
        onDeleteMessage: ((UUID) -> Void)? = nil,
        responseStatsForTurn: ((UUID) -> String?)? = nil
    ) {
        self.turnId = turnId
        self.responseStatsForTurn = responseStatsForTurn
        self.onCopy = onCopy
        self.onRegenerate = onRegenerate
        self.onSpeak = onSpeak
        self.onDeleteMessage = onDeleteMessage
        self.currentTheme = theme

        let pointSize = CGFloat(theme.captionSize) - 1
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        copyButton.setSymbol(
            SymbolImageCache.image("doc.on.doc", accessibilityDescription: L("Copy"))?
                .withSymbolConfiguration(cfg),
            toolTip: L("Copy"),
            theme: theme,
            iconTint: nil
        )
        regenerateButton.setSymbol(
            SymbolImageCache.image("arrow.counterclockwise", accessibilityDescription: L("Regenerate"))?
                .withSymbolConfiguration(cfg),
            toolTip: L("Regenerate"),
            theme: theme,
            iconTint: nil
        )
        overflowButton.setSymbol(
            SymbolImageCache.image("ellipsis", accessibilityDescription: L("More"))?
                .withSymbolConfiguration(cfg),
            toolTip: L("More"),
            theme: theme,
            iconTint: nil
        )
        applyTTSVisibility()
        refreshSpeakIcon()
        refreshFileChangesSummary()
    }

    private func presentOverflowMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let inspect = NSMenuItem(
            title: L("Inspect response"),
            action: #selector(inspectResponse),
            keyEquivalent: ""
        )
        inspect.target = self
        inspect.isEnabled = true
        // Upstream #2959: the response's metrics, then the log.
        if let stats = responseStatsForTurn?(turnId), !stats.isEmpty {
            let details = NSMenu()
            details.autoenablesItems = false
            for value in stats.components(separatedBy: " \u{2022} ") {
                let item = NSMenuItem(title: value, action: nil, keyEquivalent: "")
                item.isEnabled = false
                details.addItem(item)
            }
            details.addItem(.separator())
            let log = NSMenuItem(
                title: L("Open request and response log"),
                action: #selector(inspectResponse),
                keyEquivalent: ""
            )
            log.target = self
            details.addItem(log)
            inspect.action = nil
            inspect.submenu = details
        }
        menu.addItem(inspect)

        if onDeleteMessage != nil {
            menu.addItem(.separator())
            let delete = NSMenuItem(
                title: L("Delete message"),
                action: #selector(deleteMessage),
                keyEquivalent: ""
            )
            delete.target = self
            delete.isEnabled = true
            menu.addItem(delete)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: overflowButton)
    }

    /// Opens the Insights tab focused on the request/response log this
    /// assistant turn produced (upstream #1350). The log is persisted now
    /// (#2964) but still pruned by retention, so a turn older than the
    /// retention window (or one logged before the activity log existed)
    /// gets the upstream alert instead of an unrelated list.
    @objc private func inspectResponse() {
        MainActor.assumeIsolated {
            if InsightsService.shared.focus(turnId: turnId) {
                AppDelegate.shared?.showManagementWindow(initialTab: .insights)
            } else {
                presentLogUnavailableAlert()
            }
        }
    }

    @MainActor
    private func presentLogUnavailableAlert() {
        // Scope the alert to this chat window when we can resolve it, so it
        // dims and centers over the chat rather than another surface.
        let scope: ThemedAlertScope =
            window.flatMap { ChatWindowManager.shared.windowId(for: $0) }
            .map { .chat($0) } ?? .content
        let requestId = UUID()
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: L("Insights Unavailable"),
                message: L(
                    "Detailed request logs are kept only for a short duration to save storage, so there's nothing to show for this response."
                ),
                buttons: [.primary(L("OK")) {}],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    @objc private func deleteMessage() {
        onDeleteMessage?(turnId)
    }

    private func refreshSpeakIcon() {
        guard let theme = currentTheme else { return }
        let pointSize = CGFloat(theme.captionSize) - 1
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let isThisTurnPlaying = TTSService.shared.playingMessageId == turnId
        let symbolName = isThisTurnPlaying ? "stop.fill" : "speaker.wave.2"
        let tooltip = isThisTurnPlaying ? L("Stop") : L("Read aloud")
        speakButton.setSymbol(
            SymbolImageCache.image(symbolName, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(cfg),
            toolTip: tooltip,
            theme: theme,
            iconTint: nil
        )
    }

    private func applyTTSVisibility() {
        let enabled = TTSConfigurationStore.load().enabled
        // Hide only when the `speak` tool drove playback. manual
        // taps keep the button so the stop swap stays available.
        let toolDriven =
            TTSService.shared.playingMessageId == turnId
            && TTSService.shared.activeSpeakCallId != nil
        let visible = enabled && !toolDriven
        speakButton.isHidden = !visible
        speakWidthConstraint?.constant = visible ? 28 : 0
        speakLeadingConstraint?.constant = visible ? 4 : 0
    }
}

// MARK: - Padded inline edit buttons

/// Insets image/title layout so borderless buttons don’t hug the layer edge; extra gap after the icon.
private final class PaddedInlineButtonCell: NSButtonCell {
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 2
    /// additional space between SF Symbol and title (beyond default cell spacing)
    var imageTitleSpacing: CGFloat = 6

    override init(textCell string: String) {
        super.init(textCell: string)
        setButtonType(.momentaryPushIn)
    }

    required init(coder: NSCoder) {
        fatalError()
    }

    private func insetBounds(_ rect: NSRect) -> NSRect {
        rect.insetBy(dx: horizontalPadding, dy: verticalPadding)
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        super.imageRect(forBounds: insetBounds(rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = super.titleRect(forBounds: insetBounds(rect))
        if image != nil {
            r.origin.x += imageTitleSpacing
        }
        return r
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        var s = super.cellSize(forBounds: rect)
        s.width += horizontalPadding * 2
        s.height += verticalPadding * 2
        if image != nil {
            s.width += imageTitleSpacing
        }
        return s
    }
}

private final class PaddedInlineButton: NSButton {
    private let paddedButtonCell: PaddedInlineButtonCell

    fileprivate var paddedCell: PaddedInlineButtonCell { paddedButtonCell }

    override init(frame frameRect: NSRect) {
        let buttonCell = PaddedInlineButtonCell(textCell: "")
        buttonCell.bezelStyle = .rounded
        buttonCell.isBordered = false
        self.paddedButtonCell = buttonCell
        super.init(frame: frameRect)
        cell = buttonCell
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - UserMessageInlineEditView

/// AppKit counterpart to SwiftUI `InlineEditView` — editable plain text plus Cancel / Save & Regenerate.
private final class UserMessageInlineEditView: NSView, NSTextViewDelegate {

    private let scrollView = AutoSizingScrollView()
    private let textView: CustomNSTextView
    private let editBox = NSView()
    private let buttonStack = NSStackView()
    private var cancelButton: PaddedInlineButton!
    private var confirmButton: PaddedInlineButton!

    private var getText: () -> String = { "" }
    private var setText: (String) -> Void = { _ in }
    private var onConfirm: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var onHeightChanged: (() -> Void) = {}

    private var lastTheme: (any ThemeProtocol)?
    private var didApplyInitialFocus = false

    /// Undo state scoped to this editor's lifetime. Without this, NSTextView
    /// registers undo actions with the WINDOW's undo manager; after the edit
    /// UI is torn down those stale actions still target the deallocated text
    /// view, and a later Cmd+Z crashes in `-[NSUndoManager undoNestedGroup]`
    /// (production crash APPLE-MACOS-TG).
    private let editorUndoManager = UndoManager()

    override init(frame frameRect: NSRect) {
        // TextKit 1 from birth — avoids the lazy TextKit 2 → 1 downgrade on
        // first `.layoutManager` access (see EditableTextView.makeNSView).
        let tv = CustomNSTextView(usingTextLayoutManager: false)
        tv.maxHeight = 240
        tv.focusRingType = .none
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 8, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        self.textView = tv
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        textView.delegate = self

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.focusRingType = .none
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        editBox.wantsLayer = true
        editBox.translatesAutoresizingMaskIntoConstraints = false

        buttonStack.orientation = .horizontal
        buttonStack.spacing = 0
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fill
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // isolate cancel + confirm from the leading spacer so `.fill` cannot widen only the CTA
        let buttonPair = NSStackView()
        buttonPair.orientation = .horizontal
        buttonPair.spacing = 8
        buttonPair.alignment = .centerY
        buttonPair.distribution = .fillProportionally
        buttonPair.translatesAutoresizingMaskIntoConstraints = false
        buttonPair.setContentHuggingPriority(.required, for: .horizontal)
        buttonPair.setContentCompressionResistancePriority(.required, for: .horizontal)

        cancelButton = PaddedInlineButton(frame: .zero)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.isBordered = false
        cancelButton.wantsLayer = true
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []

        confirmButton = PaddedInlineButton(frame: .zero)
        confirmButton.target = self
        confirmButton.action = #selector(confirmTapped)
        confirmButton.bezelStyle = .rounded
        confirmButton.isBordered = false
        confirmButton.wantsLayer = true
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.image = SymbolImageCache.image("arrow.clockwise", accessibilityDescription: nil)
        confirmButton.imagePosition = .imageLeading

        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        confirmButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        confirmButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(editBox)
        editBox.addSubview(scrollView)
        addSubview(buttonStack)
        buttonPair.addArrangedSubview(cancelButton)
        buttonPair.addArrangedSubview(confirmButton)
        buttonStack.addArrangedSubview(spacer)
        buttonStack.addArrangedSubview(buttonPair)

        NSLayoutConstraint.activate([
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            confirmButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])

        NSLayoutConstraint.activate([
            editBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            editBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            editBox.topAnchor.constraint(equalTo: topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: editBox.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: editBox.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: editBox.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: editBox.bottomAnchor),

            buttonStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttonStack.topAnchor.constraint(equalTo: editBox.bottomAnchor, constant: 10),
            buttonStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(
        theme: any ThemeProtocol,
        getText: @escaping () -> String,
        setText: @escaping (String) -> Void,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        self.getText = getText
        self.setText = setText
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onHeightChanged = onHeightChanged
        lastTheme = theme

        let radius = CGFloat(theme.inputCornerRadius)
        editBox.layer?.cornerRadius = radius
        editBox.layer?.backgroundColor = NSColor(theme.primaryBackground).cgColor
        editBox.layer?.borderWidth = CGFloat(theme.defaultBorderWidth)
        editBox.layer?.borderColor = NSColor(theme.accentColor).withAlphaComponent(theme.borderOpacity + 0.2).cgColor

        let body = CGFloat(theme.bodySize)
        textView.font = .systemFont(ofSize: body)
        textView.textColor = NSColor(theme.primaryText)
        textView.insertionPointColor = NSColor(theme.accentColor)

        if textView.string != getText() {
            textView.string = getText()
            textView.invalidateIntrinsicContentSize()
            scrollView.invalidateIntrinsicContentSize()
        }

        refreshScrollerVisibility()
        updateConfirmButtons(theme: theme)

        if !didApplyInitialFocus {
            didApplyInitialFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.textView.window?.makeFirstResponder(self.textView)
                self.refreshScrollerVisibility()
                self.onHeightChanged()
            }
        }

        onHeightChanged()
    }

    private func refreshScrollerVisibility() {
        if let tc = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: tc)
        }
        let maxH = textView.maxHeight
        let needsScroller = textView.contentHeight > maxH + 0.5
        if scrollView.hasVerticalScroller != needsScroller {
            scrollView.hasVerticalScroller = needsScroller
            scrollView.invalidateIntrinsicContentSize()
        }
        scrollView.tile()
    }

    /// Matches ContentBlockView.InlineEditView — Cancel secondary chrome; Save accent + white when non-empty.
    private func updateConfirmButtons(theme: any ThemeProtocol) {
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        confirmButton.isEnabled = !empty
        let cap = CGFloat(theme.captionSize)

        cancelButton.layer?.masksToBounds = true
        confirmButton.layer?.masksToBounds = true

        cancelButton.layer?.cornerRadius = 6
        cancelButton.layer?.backgroundColor = NSColor(theme.secondaryBackground).cgColor
        cancelButton.layer?.borderWidth = CGFloat(theme.defaultBorderWidth)
        cancelButton.layer?.borderColor = NSColor(theme.primaryBorder).withAlphaComponent(theme.borderOpacity).cgColor
        cancelButton.attributedTitle = NSAttributedString(
            string: "Cancel",
            attributes: [
                .foregroundColor: NSColor(theme.secondaryText),
                .font: NSFont.systemFont(ofSize: cap, weight: .medium),
            ]
        )

        confirmButton.layer?.cornerRadius = 6
        if let sym = SymbolImageCache.image("arrow.clockwise", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: cap - 1, weight: .semibold)
            confirmButton.image = sym.withSymbolConfiguration(config) ?? sym
        }
        confirmButton.imagePosition = .imageLeading

        if empty {
            confirmButton.layer?.backgroundColor = NSColor(theme.secondaryBackground).cgColor
            confirmButton.attributedTitle = NSAttributedString(
                string: "Save & Regenerate",
                attributes: [
                    .foregroundColor: NSColor(theme.secondaryText),
                    .font: NSFont.systemFont(ofSize: cap, weight: .semibold),
                ]
            )
            confirmButton.contentTintColor = NSColor(theme.secondaryText)
        } else {
            confirmButton.layer?.backgroundColor = NSColor(theme.accentColor).cgColor
            confirmButton.attributedTitle = NSAttributedString(
                string: "Save & Regenerate",
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.systemFont(ofSize: cap, weight: .semibold),
                ]
            )
            confirmButton.contentTintColor = .white
        }

        let padH = max(12, cap + 4)
        let padV: CGFloat = 2
        let imageGap = max(4, cap * 0.35)
        for btn in [cancelButton, confirmButton] {
            btn?.paddedCell.horizontalPadding = padH
            btn?.paddedCell.verticalPadding = padV
            btn?.invalidateIntrinsicContentSize()
        }
        confirmButton.paddedCell.imageTitleSpacing = imageGap
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func confirmTapped() {
        guard !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onConfirm?()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        editorUndoManager
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv === textView else { return }
        setText(tv.string)
        tv.invalidateIntrinsicContentSize()
        scrollView.invalidateIntrinsicContentSize()
        refreshScrollerVisibility()
        if let theme = lastTheme {
            updateConfirmButtons(theme: theme)
        }
        onHeightChanged()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                return false
            }
            confirmTapped()
            return true
        }
        return false
    }
}

// MARK: - NativeStatsView

/// Incomplete-response warning. Generation metrics are available in the
/// response's overflow menu instead of occupying a row in the conversation
/// (upstream #2959).
final class NativeStatsView: NSView {
    private let label = NSTextField(labelWithString: "")

    /// "12.3s" under a minute, "2m5s" beyond (upstream `formatLoad`).
    nonisolated static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m\(whole % 60)s"
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        label.isEditable = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(
        ttft: TimeInterval?,
        tokensPerSecond: Double?,
        tokenCount: Int?,
        unclosedReasoning: Bool = false,
        totalDuration: TimeInterval? = nil,
        theme: any ThemeProtocol
    ) {
        // Upstream #2959: the metrics live in the response's "…" menu
        // (Inspect response); this row only carries the incomplete-response
        // warning.
        label.stringValue = unclosedReasoning
            ? L("⚠ thinking didn't close — answer may be in reasoning above") : ""
        label.font = NSFont.monospacedDigitSystemFont(
            ofSize: CGFloat(theme.captionSize) - 1,
            weight: .regular
        )
        label.textColor = NSColor(theme.tertiaryText)
    }

    /// The response's metrics as one " • "-separated line (the Inspect
    /// response submenu lists each part). Pure, so it is unit-testable.
    /// Intel: no model-load or cached-input chips (cloud models only report
    /// what Intel records).
    nonisolated static func statsText(
        ttft: TimeInterval?,
        tokensPerSecond: Double?,
        tokenCount: Int?,
        unclosedReasoning: Bool = false,
        totalDuration: TimeInterval? = nil
    ) -> String {
        var parts: [String] = []
        // Wall clock from the user's message to the end of the reply
        // (upstream #2916). Leads the line: it's the number people look for.
        if let totalDuration {
            parts.append(String(format: L("Worked for %@"), Self.formatDuration(totalDuration)))
        }
        if let ttft {
            if ttft < 0.01 {
                parts.append(String(format: L("TTFT %.0fms"), ttft * 1000))
            } else {
                parts.append(String(format: L("TTFT %.2fs"), ttft))
            }
        }
        if let tps = tokensPerSecond {
            parts.append(String(format: L("%.1f tok/s"), tps))
        }
        if let count = tokenCount {
            parts.append(count == 1 ? L("1 token") : L("\(count) tokens"))
        }
        // The model never closed its reasoning before EOS / max_tokens; the
        // answer may be in the reasoning pane above.
        if unclosedReasoning {
            parts.append(L("⚠ thinking didn't close — answer may be in reasoning above"))
        }
        return parts.joined(separator: " \u{2022} ")
    }
}

// MARK: - NativeEmptyResponseNoticeView

/// Footer shown when the Osaurus Router billed a turn that produced no visible
/// text (and no reasoning/tools). Surfaces the charge honestly with a Retry
/// affordance rather than letting the turn be silently dropped.
final class NativeEmptyResponseNoticeView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton()

    private var turnId: UUID = UUID()
    private var onRetry: ((UUID) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        for label in [titleLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.isSelectable = false
            label.isEditable = false
        }

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.title = L("Retry")
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.setContentHuggingPriority(.required, for: .horizontal)
        retryButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)
        addSubview(retryButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: retryButton.leadingAnchor, constant: -8),

            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func retryTapped() {
        onRetry?(turnId)
    }

    func configure(
        turnId: UUID,
        outputTokens: Int,
        costMicro: String,
        theme: any ThemeProtocol,
        onRetry: ((UUID) -> Void)?
    ) {
        self.turnId = turnId
        self.onRetry = onRetry

        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(theme.captionSize), weight: .medium)
        iconView.image = NSImage(
            systemSymbolName: "exclamationmark.bubble",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(cfg)
        iconView.contentTintColor = NSColor(theme.warningColor)

        titleLabel.stringValue = L("The model returned no visible text")
        titleLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) + 1, weight: .medium)
        titleLabel.textColor = NSColor(theme.primaryText)

        let formattedCost = OsaurusRouter.formatMicroAsCredits(costMicro)
        let detail: String
        if outputTokens > 0 {
            detail = String(
                format: L("You were charged %@ for %d tokens."),
                formattedCost,
                outputTokens
            )
        } else {
            detail = String(format: L("You were charged %@."), formattedCost)
        }
        detailLabel.stringValue = detail
        detailLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: CGFloat(theme.captionSize) - 1,
            weight: .regular
        )
        detailLabel.textColor = NSColor(theme.tertiaryText)
    }
}

// MARK: - NativeMessageCellView

final class NativeMessageCellView: NSTableCellView {

    // MARK: Subviews

    private var spacerView: NSView?
    private var nativeHeaderView: NativeHeaderView?
    private var nativeHeaderHeightConstraint: NSLayoutConstraint?

    // Native views (no NSHostingView)
    private var nativeMarkdownView: NativeMarkdownView?
    private var nativeThinkingView: NativeThinkingView?
    private var nativeToolCallGroupView: NativeToolCallGroupView?
    private var userMessageContainer: NSView?
    private var userTextView: NativeMarkdownView?
    private var userInlineEditView: UserMessageInlineEditView?
    private var userImageStack: NSStackView?
    private var userDocumentStack: NSStackView?
    private var nativePendingView: NativePendingToolCallView?
    private var nativeTypingView: NativeTypingIndicatorView?
    private var nativeArtifactView: NativeArtifactCardView?
    private var nativeChartView: NativeChartView?
    private var nativeFileDiffView: NativeFileDiffView?
    /// Follow-up suggestions are low-frequency (one per completed turn), so
    /// unlike the streaming-hot cells this one hosts the SwiftUI
    /// `FollowUpSuggestionsBar` directly — its intrinsic size drives the row
    /// height via `fittingSize`. (Upstream.)
    private var nativeFollowUpsView: NSHostingView<AnyView>?
    private var nativeCompactionMarkerView: NativeCompactionMarkerView?
    private var nativeActivityGroupView: NativeActivityGroupView?
    private var nativePreflightView: NativePreflightCapabilitiesView?
    private var nativeStatsView: NativeStatsView?
    private var nativeAssistantActionsView: NativeAssistantActionsView?
    private var nativeEmptyNoticeView: NativeEmptyResponseNoticeView?

    private var userBubbleCornerRadius: CGFloat = 0
    private var userBubbleWidthConstraint: NSLayoutConstraint?
    /// Height occupied by attachments above the bubble (docs + images + gaps), set during rebuild.
    private var userAttachmentsHeight: CGFloat = 0
    /// Last CGColor assigned to `layer.backgroundColor` for the assistant bubble, so
    /// per-token reconfigures can skip the CoreAnimation mutation when nothing changed.
    private var lastBubbleBackgroundCGColor: CGColor?
    private var lastBubbleCornerRadius: CGFloat = 0

    // MARK: State

    private var currentKindTag: ContentBlockKindTag?
    private var currentBlockId: String?

    /// tracks inline edit vs read-only markdown so we rebuild when edit mode toggles (same block kind)
    private var userMessageInlineEditActive: Bool = false
    /// Provenance chips above an enveloped user bubble, and the signature of
    /// the badges they show (a change rebuilds the row; upstream).
    private var userBadgeRow: NativeDispatchBadgeRow?
    private var userEnvelopeSignature: String?

    /// last width from CellRenderingContext — used for systemLayoutSizeFitting when reporting row height
    private var lastContextWidth: CGFloat = 400

    // MARK: Identity

    static let reuseId = NSUserInterfaceItemIdentifier("NativeMessageCell")

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = false
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
    }

    /// Row height from Auto Layout — avoids drift from hand-summed constants vs. actual constraints.
    /// AppKit `NSView` uses `fittingSize` (UIKit’s `systemLayoutSizeFitting` is not available here).
    /// Table view still uses `heightOfRow:` + cache (see MessageTableRepresentable); this only feeds accurate measurements.
    private func measureFittedRowHeight() -> CGFloat {
        // never call layoutSubtreeIfNeeded() here — heightOfRow / onHeightMeasured can run during an active layout pass
        let targetWidth = max(bounds.width > 1 ? bounds.width : lastContextWidth, 100)

        // user message: container is not pinned to cell bottom, so compute height manually.
        if userDocumentStack != nil || userImageStack != nil || userMessageContainer != nil {
            // Attachments above bubble (fixed heights)
            let attachOffset: CGFloat =
                userAttachmentsHeight > 0
                ? 8 + userAttachmentsHeight + 6  // outerTopGap + attachments + gap to bubble
                : 8  // outerTopGap only

            if let container = userMessageContainer {
                var widthPin: NSLayoutConstraint?
                if bounds.width <= 1 {
                    let c = widthAnchor.constraint(equalToConstant: targetWidth)
                    c.priority = .required
                    c.isActive = true
                    widthPin = c
                }
                defer { widthPin?.isActive = false }
                var containerH = container.fittingSize.height
                if containerH < 2, let mv = userTextView {
                    let bubbleW = userBubbleWidthConstraint?.constant ?? max(lastContextWidth - 32, 100)
                    let textH = mv.measuredHeight(for: max(bubbleW - 24, 100))
                    containerH = 10 + textH + 6
                }
                return ceil(max(attachOffset + containerH + 8, 56))
            }
            // Attachment-only (no text bubble)
            return ceil(max(8 + userAttachmentsHeight + 8, 56))
        }

        var widthPin: NSLayoutConstraint?
        if bounds.width <= 1 {
            let c = widthAnchor.constraint(equalToConstant: targetWidth)
            c.priority = NSLayoutConstraint.Priority.required
            c.isActive = true
            widthPin = c
        }
        defer { widthPin?.isActive = false }
        let h = fittingSize.height
        return ceil(max(h, 1))
    }

    // MARK: Configure

    func configure(block: ContentBlock, context: CellRenderingContext) {
        lastContextWidth = context.width
        let tag = block.kind.kindTag
        let sameKind = tag == currentKindTag
        currentKindTag = tag
        currentBlockId = block.id

        switch block.kind {
        case .groupSpacer:
            configureAsSpacer(sameKind: sameKind)

        case let .header(role, name, _):
            configureAsHeader(block: block, role: role, name: name, context: context, sameKind: sameKind)

        case let .paragraph(_, text, isStreaming, role):
            configureAsParagraph(
                block: block,
                text: text,
                isStreaming: isStreaming,
                role: role,
                context: context,
                sameKind: sameKind
            )

        case let .thinking(_, text, isStreaming):
            configureAsThinking(
                block: block,
                text: text,
                isStreaming: isStreaming,
                context: context,
                sameKind: sameKind
            )

        case let .toolCallGroup(calls):
            configureAsToolCallGroup(block: block, calls: calls, context: context, sameKind: sameKind)

        case let .activityGroup(children):
            configureAsActivityGroup(block: block, children: children, context: context, sameKind: sameKind)

        case let .userMessage(text, attachments, envelope):
            configureAsUserMessage(
                block: block,
                text: text,
                attachments: attachments,
                envelope: envelope,
                context: context,
                sameKind: sameKind
            )

        case let .pendingToolCall(toolName, argPreview, argSize):
            configureAsPendingToolCall(
                block: block,
                toolName: toolName,
                argPreview: argPreview,
                argSize: argSize,
                context: context,
                sameKind: sameKind
            )

        case .typingIndicator:
            configureAsTypingIndicator(context: context, sameKind: sameKind)

        case let .sharedArtifact(artifact):
            configureAsArtifact(block: block, artifact: artifact, context: context, sameKind: sameKind)

        case let .chart(spec):
            configureAsChart(block: block, spec: spec, context: context, sameKind: sameKind)

        case let .fileDiff(diff):
            configureAsFileDiff(block: block, diff: diff, context: context, sameKind: sameKind)

        case let .followUpSuggestions(_, suggestions):
            configureAsFollowUpSuggestions(
                block: block,
                suggestions: suggestions,
                context: context,
                sameKind: sameKind
            )

        case let .compactionMarker(savedTokens, modelName, summaryText):
            configureAsCompactionMarker(
                block: block,
                savedTokens: savedTokens,
                modelName: modelName,
                summaryText: summaryText,
                context: context,
                sameKind: sameKind
            )

        case let .preflightCapabilities(items):
            configureAsPreflight(block: block, items: items, context: context, sameKind: sameKind)

        case let .generationStats(ttft, tokensPerSecond, tokenCount, unclosedReasoning, totalDuration):
            configureAsStats(
                ttft: ttft,
                tokensPerSecond: tokensPerSecond,
                tokenCount: tokenCount,
                unclosedReasoning: unclosedReasoning,
                totalDuration: totalDuration,
                context: context,
                sameKind: sameKind
            )

        case let .assistantActions(turnId):
            configureAsAssistantActions(turnId: turnId, context: context, sameKind: sameKind)

        case let .emptyResponseNotice(turnId, outputTokens, costMicro, _):
            configureAsEmptyResponseNotice(
                turnId: turnId,
                outputTokens: outputTokens,
                costMicro: costMicro,
                context: context,
                sameKind: sameKind
            )
        }
    }

    // MARK: - Empty response notice (upstream)

    private func configureAsEmptyResponseNotice(
        turnId: UUID,
        outputTokens: Int,
        costMicro: String,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeEmptyNoticeView == nil {
            removeAllContentViews()
            let nv = NativeEmptyResponseNoticeView()
            nv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(nv)
            NSLayoutConstraint.activate([
                nv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                nv.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                nv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                nv.heightAnchor.constraint(equalToConstant: 36),
                nv.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            ])
            nativeEmptyNoticeView = nv
        }
        nativeEmptyNoticeView?.configure(
            turnId: turnId,
            outputTokens: outputTokens,
            costMicro: costMicro,
            theme: context.theme,
            onRetry: context.onRegenerate
        )
    }

    /// Direct hover update on the header row — no SwiftUI re-render needed.
    func setTurnHovered(_ hovered: Bool) {
        nativeHeaderView?.setHovered(hovered)
    }

    // MARK: - Spacer

    private func configureAsSpacer(sameKind: Bool) {
        guard !sameKind || spacerView == nil else { return }
        removeAllContentViews()
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor),
            v.heightAnchor.constraint(equalToConstant: 16),
        ])
        spacerView = v
    }

    // MARK: - Header

    private func configureAsHeader(
        block: ContentBlock,
        role: MessageRole,
        name: String,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeHeaderView == nil {
            removeAllContentViews()
            let hv = NativeHeaderView()
            hv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hv)
            let bottomGap = bottomAnchor.constraint(equalTo: hv.bottomAnchor, constant: 12)
            // below required so transient table sizing (e.g. NSView-Encapsulated-Layout-Height) can
            // squeeze the cell without fighting our top+height+bottom; row height still comes from the delegate
            bottomGap.priority = .init(999)
            let heightC = hv.heightAnchor.constraint(equalToConstant: 28)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                hv.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                heightC,
                bottomGap,
            ])
            nativeHeaderView = hv
            nativeHeaderHeightConstraint = heightC
        }
        nativeHeaderHeightConstraint?.constant = NativeCellHeightEstimator.headerInnerHeight(for: context.theme)

        let displayName = role == .user ? "You" : (name.isEmpty ? "Assistant" : name)
        nativeHeaderView?.configure(
            turnId: block.turnId,
            role: role,
            name: displayName,
            avatar: context.agentAvatar,
            customAvatarPath: context.agentCustomAvatarPath,
            isEditing: context.editingTurnId == block.turnId,
            isHovered: context.isTurnHovered,
            theme: context.theme,
            onCopy: context.onCopy,
            onRegenerate: context.onRegenerate,
            onEdit: context.onEdit,
            onDelete: context.onDelete,
            onCancelEdit: context.onCancelEdit,
            showsActions: false
        )
    }

    // MARK: - Paragraph (native NSTextView)

    private func configureAsParagraph(
        block: ContentBlock,
        text: String,
        isStreaming: Bool,
        role: MessageRole,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeMarkdownView == nil {
            removeAllContentViews()
            let mv = NativeMarkdownView()
            mv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mv)
            NSLayoutConstraint.activate([
                mv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                mv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                mv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeMarkdownView = mv
        }
        let mv = nativeMarkdownView!
        mv.onHeightChanged = { [weak self, weak mv] in
            guard let self, let mv, let id = self.currentBlockId else { return }
            let h = mv.measuredHeight(for: context.width - 32)
            context.onHeightMeasured?(h + 8, id)
        }
        mv.configure(
            text: text,
            width: context.width - 32,
            theme: context.theme,
            cacheKey: block.id,
            isStreaming: isStreaming
        )
        mv.setSearchHighlight(query: context.searchHighlightQuery, theme: context.theme)

        // Apply assistant bubble background only when the target value actually changes —
        // configure() runs on every streaming token, so unconditional CGColor assignment
        // would churn the layer and force per-token compositor work.
        let targetBg: CGColor?
        let targetRadius: CGFloat
        if role == .assistant, let bubbleColor = context.theme.assistantBubbleColor {
            targetBg =
                NSColor(bubbleColor)
                .withAlphaComponent(context.theme.assistantBubbleOpacity).cgColor
            targetRadius = 12
        } else {
            targetBg = nil
            targetRadius = 0
        }
        // sppress implicit CABasicAnimation on layer property mutations. Without this,
        // every backgroundColor / cornerRadius change kicks off a 0.25s animation that
        // continues compositing across frames during streaming
        let bgChanged = !cgColorsEqual(lastBubbleBackgroundCGColor, targetBg)
        let radiusChanged = lastBubbleCornerRadius != targetRadius
        if targetBg != nil || bgChanged || radiusChanged {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if targetBg != nil { self.wantsLayer = true }
            if bgChanged {
                self.layer?.backgroundColor = targetBg
                lastBubbleBackgroundCGColor = targetBg
            }
            if radiusChanged {
                self.layer?.cornerRadius = targetRadius
                lastBubbleCornerRadius = targetRadius
            }
            CATransaction.commit()
        }

        // always report height: configure() can return early when text is unchanged (e.g. tool row
        // expand/collapse) and otherwise the table keeps a stale row height → clipped / squeezed text.
        let h = mv.measuredHeight(for: context.width - 32) + 8
        context.onHeightMeasured?(h, block.id)
    }

    // MARK: - Thinking (NativeThinkingView)

    private func configureAsThinking(
        block: ContentBlock,
        text: String,
        isStreaming: Bool,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeThinkingView == nil {
            removeAllContentViews()
            let tv = NativeThinkingView()
            tv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                tv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                tv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeThinkingView = tv
        }
        let tv = nativeThinkingView!
        let thinkingLen: Int?
        if case .thinking(_, _, _) = block.kind { thinkingLen = text.count } else { thinkingLen = nil }

        let isExpanded = context.expandedIds.contains(block.id)
        tv.configure(
            thinking: text,
            thinkingLength: thinkingLen,
            width: context.width - 32,
            isStreaming: isStreaming,
            isExpanded: isExpanded,
            theme: context.theme,
            blockId: block.id,
            onToggle: { [weak self] in
                guard let self else { return }
                context.onToggleExpand(block.id)
                self.nativeThinkingView?.onHeightChanged?()
            },
            onHeightChanged: { [weak self] in
                guard let self, let tv = self.nativeThinkingView, let id = self.currentBlockId else { return }
                let h = tv.measuredHeight() + 8
                context.onHeightMeasured?(h, id)
            }
        )
    }

    // MARK: - Tool Call Group (NativeToolCallGroupView)

    private func configureAsToolCallGroup(
        block: ContentBlock,
        calls: [ToolCallItem],
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeToolCallGroupView == nil {
            removeAllContentViews()
            let gv = NativeToolCallGroupView()
            gv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(gv)
            NSLayoutConstraint.activate([
                gv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                gv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                gv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeToolCallGroupView = gv
        }
        nativeToolCallGroupView?.configure(
            calls: calls,
            expandedIds: context.expandedIds,
            width: context.width - 32,
            theme: context.theme,
            onToggle: { id in context.onToggleExpand(id) },
            onHeightChanged: { [weak self] in
                guard let self, let gv = self.nativeToolCallGroupView, let id = self.currentBlockId else { return }
                let h = gv.measuredHeight() + 8
                context.onHeightMeasured?(h, id)
            }
        )
    }

    // MARK: - User Message (native text + image thumbnails)

    private func configureAsUserMessage(
        block: ContentBlock,
        text rawText: String,
        attachments: [Attachment],
        envelope: DispatchEnvelope?,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        let images = attachments.filter(\.isImage)
        let documents = attachments.filter(\.isDocument)
        let theme = context.theme
        let innerWidth = max(context.width - 32, 100)

        // An enveloped turn (self-scheduled / watcher run) paints the
        // human-authored text under a provenance badge row (upstream).
        let text = envelope?.displayText ?? rawText
        let badges = envelope?.badges ?? []
        let badgeSignature = badges.isEmpty ? nil : NativeDispatchBadgeRow.signature(for: badges)

        let wantsInlineEdit =
            context.editingTurnId == block.turnId
            && context.editText != nil
            && context.onConfirmEdit != nil
            && context.onCancelEdit != nil

        // Bubble width: only text, measured to fit, capped at 65%.
        // Attachments live outside the bubble so they don't affect its width.
        let maxBubbleWidth = floor(innerWidth * 0.65)
        let bubbleWidth: CGFloat = {
            guard !text.isEmpty && !wantsInlineEdit else { return maxBubbleWidth }
            let font =
                NSFont(name: theme.primaryFontName, size: CGFloat(theme.bodySize))
                ?? NSFont.systemFont(ofSize: CGFloat(theme.bodySize))
            let measured = (text as NSString).boundingRect(
                with: NSSize(width: maxBubbleWidth - 24, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            let lineHeight = ceil(CGFloat(theme.bodySize) * 1.4)
            let isMultiLine = measured.height > lineHeight * 1.5
            return isMultiLine ? maxBubbleWidth : min(ceil(measured.width) + 24, maxBubbleWidth)
        }()

        let needsUserMessageRebuild =
            !sameKind || userMessageContainer == nil || userMessageInlineEditActive != wantsInlineEdit
            || userEnvelopeSignature != badgeSignature

        if needsUserMessageRebuild {
            removeAllContentViews()

            // Heights stacked above the bubble (needed for fittingSize
            // measurement later): badge row, documents, images, and the 6pt
            // gaps between them. Mirrors the estimator (upstream).
            let innerGap: CGFloat = 6
            let outerTopGap: CGFloat = 8
            var attachH: CGFloat = 0
            if !badges.isEmpty { attachH += NativeDispatchBadgeRow.rowHeight }
            if !documents.isEmpty { attachH += (attachH > 0 ? innerGap : 0) + 26 }
            if !images.isEmpty { attachH += (attachH > 0 ? innerGap : 0) + 96 }
            userAttachmentsHeight = attachH
            userEnvelopeSignature = badgeSignature

            // Provenance row, attachments, then the bubble — all right-aligned
            // at cell level. `nextGap` is the outer top inset for the first
            // element and the inner gap for every element after it.
            var cellTopAnchor = topAnchor
            var nextGap = outerTopGap

            if !badges.isEmpty {
                let row = NativeDispatchBadgeRow()
                addSubview(row)
                NSLayoutConstraint.activate([
                    row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                    row.topAnchor.constraint(equalTo: cellTopAnchor, constant: nextGap),
                    row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                ])
                userBadgeRow = row
                cellTopAnchor = row.bottomAnchor
                nextGap = innerGap
            } else {
                userBadgeRow = nil
            }

            if !documents.isEmpty {
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.spacing = 6
                stack.translatesAutoresizingMaskIntoConstraints = false
                addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                    stack.topAnchor.constraint(equalTo: cellTopAnchor, constant: nextGap),
                    stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                ])
                stack.alignment = .centerY
                userDocumentStack = stack
                cellTopAnchor = stack.bottomAnchor
                nextGap = innerGap
            } else {
                userDocumentStack = nil
            }

            if !images.isEmpty {
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.spacing = 8
                stack.translatesAutoresizingMaskIntoConstraints = false
                addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                    stack.topAnchor.constraint(equalTo: cellTopAnchor, constant: nextGap),
                    stack.heightAnchor.constraint(equalToConstant: 96),
                    stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                ])
                stack.alignment = .top
                userImageStack = stack
                cellTopAnchor = stack.bottomAnchor
                nextGap = innerGap
            } else {
                userImageStack = nil
            }

            // Text bubble — only created when there is text or inline edit.
            if !text.isEmpty || wantsInlineEdit {
                let container = NSView()
                container.translatesAutoresizingMaskIntoConstraints = false
                container.wantsLayer = true
                container.layer?.masksToBounds = false
                addSubview(container)
                let wc = container.widthAnchor.constraint(equalToConstant: bubbleWidth)
                NSLayoutConstraint.activate([
                    container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                    container.topAnchor.constraint(equalTo: cellTopAnchor, constant: nextGap),
                    wc,
                ])
                userBubbleWidthConstraint = wc
                userMessageContainer = container

                if wantsInlineEdit {
                    let ev = UserMessageInlineEditView()
                    ev.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(ev)
                    NSLayoutConstraint.activate([
                        ev.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                        ev.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                        ev.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                        ev.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
                    ])
                    userInlineEditView = ev
                    userMessageInlineEditActive = true
                    userTextView = nil
                } else {
                    userMessageInlineEditActive = false
                    userInlineEditView = nil

                    let mv = NativeMarkdownView()
                    mv.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(mv)
                    // Bottom padding is 6pt (10 - 4) to compensate for the 4pt paragraphSpacing
                    // that NSParagraphStyle appends after the last line in NativeMarkdownView,
                    // which would otherwise make the text appear above-center in the bubble.
                    NSLayoutConstraint.activate([
                        mv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                        mv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                        mv.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                        container.bottomAnchor.constraint(equalTo: mv.bottomAnchor, constant: 6),
                    ])
                    userTextView = mv
                }
            } else {
                userMessageContainer = nil
                userBubbleWidthConstraint = nil
                userMessageInlineEditActive = false
                userInlineEditView = nil
                userTextView = nil
            }

            // Hover action buttons — positioned to the left of the bubble (or attachments).
            // Anchor vertically to the bubble if it exists, otherwise to the first attachment stack.
            let anchorView = userMessageContainer ?? userImageStack ?? userDocumentStack ?? userBadgeRow
            if let anchorView {
                let hv = NativeHeaderView()
                hv.translatesAutoresizingMaskIntoConstraints = false
                addSubview(hv)
                NSLayoutConstraint.activate([
                    hv.trailingAnchor.constraint(equalTo: anchorView.leadingAnchor, constant: -8),
                    hv.centerYAnchor.constraint(equalTo: anchorView.centerYAnchor),
                    hv.heightAnchor.constraint(equalToConstant: 28),
                    hv.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
                ])
                nativeHeaderView = hv
            } else {
                nativeHeaderView = nil
            }
        }

        // Update width constraint even when not rebuilding (e.g. sidebar toggle changes available width)
        userBubbleWidthConstraint?.constant = bubbleWidth

        // apply bubble background
        if let container = userMessageContainer {
            let radius = UserAttachmentThumbnailView.cornerRadius
            let bubbleColor: NSColor = {
                if let c = theme.userBubbleColor { return NSColor(c).withAlphaComponent(theme.userBubbleOpacity) }
                return NSColor(theme.accentColor).withAlphaComponent(theme.userBubbleOpacity)
            }()

            container.layer?.cornerRadius = radius
            container.layer?.backgroundColor = bubbleColor.cgColor
            container.layer?.masksToBounds = true
            container.layer?.borderWidth = 0
            container.layer?.borderColor = nil

            userBubbleCornerRadius = radius
        }

        if wantsInlineEdit, let editPair = context.editText, let onConfirm = context.onConfirmEdit,
            let onCancel = context.onCancelEdit, let ev = userInlineEditView
        {
            let getT = editPair.0
            let setT = editPair.1
            ev.configure(
                theme: theme,
                getText: getT,
                setText: setT,
                onConfirm: onConfirm,
                onCancel: onCancel,
                onHeightChanged: { [weak self] in
                    guard let self, let id = self.currentBlockId else { return }
                    let totalH = self.measureFittedRowHeight()
                    context.onHeightMeasured?(totalH, id)
                }
            )
        } else if let mv = userTextView, !text.isEmpty {
            mv.onHeightChanged = { [weak self] in
                guard let self, let id = self.currentBlockId else { return }
                let totalH = self.measureFittedRowHeight()
                context.onHeightMeasured?(totalH, id)
            }
            mv.configure(
                text: text,
                width: bubbleWidth - 24,
                theme: theme,
                cacheKey: block.id,
                isStreaming: context.isStreaming
            )
            mv.setSearchHighlight(query: context.searchHighlightQuery, theme: theme)
        }

        if let stack = userImageStack {
            while stack.arrangedSubviews.count < images.count {
                let iv = UserAttachmentThumbnailView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                // height is fixed at 96; width is flexible via intrinsicContentSize
                iv.heightAnchor.constraint(equalToConstant: 96).isActive = true
                stack.addArrangedSubview(iv)
            }
            while stack.arrangedSubviews.count > images.count {
                let last = stack.arrangedSubviews.last!
                stack.removeArrangedSubview(last)
                last.removeFromSuperview()
            }

            for (index, attachment) in images.enumerated() {
                guard let iv = stack.arrangedSubviews[index] as? UserAttachmentThumbnailView else { continue }
                let attachId = attachment.id.uuidString
                iv.attachmentId = attachId
                iv.onTap = context.onUserImagePreview
                if let img = ChatImageCache.shared.cachedImage(for: attachId) {
                    iv.image = img
                } else if let data = attachment.imageData {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let img = await ChatImageCache.shared.decode(data, id: attachId)
                        iv.image = img
                        context.onHeightMeasured?(self.measureFittedRowHeight(), block.id)
                    }
                }
            }
        }

        if let stack = userDocumentStack {
            while stack.arrangedSubviews.count < documents.count {
                let chip = UserDocumentChipView()
                chip.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(chip)
            }
            while stack.arrangedSubviews.count > documents.count {
                let last = stack.arrangedSubviews.last!
                stack.removeArrangedSubview(last)
                last.removeFromSuperview()
            }

            for (index, attachment) in documents.enumerated() {
                guard let chip = stack.arrangedSubviews[index] as? UserDocumentChipView else { continue }
                chip.configure(attachment: attachment, theme: theme)
            }
        }

        userBadgeRow?.configure(badges: badges, theme: theme)

        // Configure hover action buttons (no name label for user messages).
        // An enveloped turn hides Edit (upstream).
        nativeHeaderView?.configure(
            turnId: block.turnId,
            role: .user,
            name: "",
            avatar: nil,
            customAvatarPath: nil,
            isEditing: context.editingTurnId == block.turnId,
            isHovered: context.isTurnHovered,
            theme: context.theme,
            onCopy: context.onCopy,
            onRegenerate: context.onRegenerate,
            onEdit: context.onEdit,
            onDelete: context.onDelete,
            onCancelEdit: context.onCancelEdit,
            allowsEdit: envelope == nil
        )

        // push fitted height even when NativeMarkdownView.configure returns early (no onHeightChanged),
        // and so row height updates when estimate vs fittingSize differ by only 1–2pt (see reportMeasuredHeight)
        context.onHeightMeasured?(measureFittedRowHeight(), block.id)
    }

    // MARK: - PendingToolCall

    private func configureAsPendingToolCall(
        block: ContentBlock,
        toolName: String,
        argPreview: String?,
        argSize: Int,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativePendingView == nil {
            removeAllContentViews()
            let pv = NativePendingToolCallView()
            pv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pv)
            NSLayoutConstraint.activate([
                pv.leadingAnchor.constraint(equalTo: leadingAnchor),
                pv.trailingAnchor.constraint(equalTo: trailingAnchor),
                pv.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                pv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
            nativePendingView = pv
        }
        nativePendingView?.configure(toolName: toolName, argPreview: argPreview, argSize: argSize, theme: context.theme)
    }

    // MARK: - TypingIndicator

    private func configureAsTypingIndicator(context: CellRenderingContext, sameKind: Bool) {
        if !sameKind || nativeTypingView == nil {
            removeAllContentViews()
            let tv = NativeTypingIndicatorView()
            tv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                tv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                tv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
                tv.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            ])
            nativeTypingView = tv
        }
        nativeTypingView?.configure(theme: context.theme)
    }

    // MARK: - GenerationStats

    private func configureAsStats(
        ttft: TimeInterval?,
        tokensPerSecond: Double?,
        tokenCount: Int?,
        unclosedReasoning: Bool,
        totalDuration: TimeInterval?,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeStatsView == nil {
            removeAllContentViews()
            let sv = NativeStatsView()
            sv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sv)
            NSLayoutConstraint.activate([
                sv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                sv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                sv.topAnchor.constraint(equalTo: topAnchor),
                sv.heightAnchor.constraint(equalToConstant: 24),
                sv.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            ])
            nativeStatsView = sv
        }
        nativeStatsView?.configure(
            ttft: ttft,
            tokensPerSecond: tokensPerSecond,
            tokenCount: tokenCount,
            unclosedReasoning: unclosedReasoning,
            totalDuration: totalDuration,
            theme: context.theme
        )
    }

    // MARK: - AssistantActions

    private func configureAsAssistantActions(
        turnId: UUID,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeAssistantActionsView == nil {
            removeAllContentViews()
            let av = NativeAssistantActionsView()
            av.translatesAutoresizingMaskIntoConstraints = false
            addSubview(av)
            NSLayoutConstraint.activate([
                av.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                av.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                av.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                av.heightAnchor.constraint(equalToConstant: 28),
                av.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            ])
            nativeAssistantActionsView = av
        }
        nativeAssistantActionsView?.configure(
            turnId: turnId,
            theme: context.theme,
            onCopy: context.onCopy,
            onRegenerate: context.onRegenerate,
            onSpeak: context.onSpeak,
            onDeleteMessage: context.onDeleteMessage,
            responseStatsForTurn: context.responseStatsForTurn
        )
    }

    // MARK: - SharedArtifact

    private func configureAsArtifact(
        block: ContentBlock,
        artifact: SharedArtifact,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeArtifactView == nil {
            removeAllContentViews()
            let av = NativeArtifactCardView()
            av.translatesAutoresizingMaskIntoConstraints = false
            addSubview(av)
            let bottomToCell = av.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
            // low priority: intrinsic card height should drive row via onHeightMeasured; if row is still too short, footer clips (mitigated by generous NativeCellHeightEstimator slack)
            bottomToCell.priority = NSLayoutConstraint.Priority(250)
            NSLayoutConstraint.activate([
                av.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                av.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                av.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
                av.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                bottomToCell,
            ])
            nativeArtifactView = av
        }
        let blockId = block.id
        nativeArtifactView?.onHeightChanged = { [weak self] in
            guard let self, let av = self.nativeArtifactView else { return }
            guard self.currentBlockId == blockId else { return }
            context.onHeightMeasured?(av.measuredCardHeight() + 12, blockId)
        }
        nativeArtifactView?.onImagePreviewTap = { id in context.onUserImagePreview?(id) }
        nativeArtifactView?.configure(artifact: artifact, theme: context.theme)
        // fittingSize before layout often omits footerStack height — row cache would clip Open in Finder.
        DispatchQueue.main.async { [weak self] in
            guard let self, let av = self.nativeArtifactView else { return }
            guard self.currentBlockId == blockId else { return }
            av.layoutSubtreeIfNeeded()
            context.onHeightMeasured?(av.measuredCardHeight() + 12, blockId)
        }
    }

    // MARK: - Chart

    private func configureAsChart(
        block: ContentBlock,
        spec: ChartSpec,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeChartView == nil {
            removeAllContentViews()
            let cv = NativeChartView()
            cv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(cv)
            let bottomToCell = cv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
            bottomToCell.priority = NSLayoutConstraint.Priority(250)
            NSLayoutConstraint.activate([
                cv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                cv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                cv.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                bottomToCell,
            ])
            nativeChartView = cv
        }
        // Chart cells host an AAChartView (WKWebView). The web layer renders
        // through its own CALayer and does not respect AppKit's default
        // bounds clipping; if the row height under-estimates the chart's
        // intrinsic height even by a frame, the chart can leak into adjacent
        // rows. The cell defaults to clipsToBounds = false (so user/assistant
        // bubble shadows aren't cut off); reset that for chart cells only and
        // restore the default in `removeAllContentViews`.
        clipsToBounds = true
        wantsLayer = true
        layer?.masksToBounds = true
        let blockId = block.id
        nativeChartView?.configure(spec: spec, theme: context.theme)
        DispatchQueue.main.async { [weak self] in
            guard let self, let cv = self.nativeChartView else { return }
            guard self.currentBlockId == blockId else { return }
            context.onHeightMeasured?(cv.measuredCardHeight() + 12, blockId)
        }
    }

    // MARK: - File Diff (upstream #1683 + #2907 part A)

    private func configureAsFileDiff(
        block: ContentBlock,
        diff: FileDiff,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeFileDiffView == nil {
            removeAllContentViews()
            let dv = NativeFileDiffView()
            dv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dv)
            // Weak bottom-to-cell pin (matches the chart/artifact cells): the
            // card sizes to its own intrinsicContentSize, and this just keeps
            // the cell content anchored. It must NOT be strong enough to
            // stretch the card to fill the row.
            let bottomToCell = dv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
            bottomToCell.priority = NSLayoutConstraint.Priority(250)
            NSLayoutConstraint.activate([
                dv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                dv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                dv.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                bottomToCell,
            ])
            nativeFileDiffView = dv
        }
        let blockId = block.id
        // Diff cards default to collapsed; presence in the shared `expandedIds`
        // set marks a card the user has expanded. The height estimator applies
        // the same rule.
        let collapsed = !context.expandedIds.contains(blockId)
        nativeFileDiffView?.onToggleCollapse = {
            context.onToggleExpand(blockId)
        }
        nativeFileDiffView?.onHeightChanged = { [weak self] in
            guard let self, let dv = self.nativeFileDiffView else { return }
            guard self.currentBlockId == blockId else { return }
            let h = dv.measuredCardHeight(outerWidth: context.width) + 12
            context.onHeightMeasured?(h, blockId)
        }
        nativeFileDiffView?.configure(
            diff: diff,
            collapsed: collapsed,
            width: context.width,
            theme: context.theme
        )
    }

    // MARK: - PreflightCapabilities

    private func configureAsPreflight(
        block: ContentBlock,
        items: [PreflightCapabilityItem],
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativePreflightView == nil {
            removeAllContentViews()
            let pfv = NativePreflightCapabilitiesView()
            pfv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pfv)
            NSLayoutConstraint.activate([
                pfv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                pfv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                pfv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativePreflightView = pfv
        }
        guard let pfv = nativePreflightView else { return }
        pfv.onHeightChanged = { [weak self, weak pfv] in
            guard let self, let pfv, let id = self.currentBlockId else { return }
            context.onHeightMeasured?(pfv.measuredContentHeight() + 8, id)
        }
        pfv.configure(items: items, theme: context.theme, layoutWidth: context.width)
        let est = PreflightCapabilitiesRowHeight.estimated(items: items, tableWidth: context.width)
        let h = max(pfv.measuredContentHeight(), est) + 8
        context.onHeightMeasured?(h, block.id)
    }

    // MARK: - Unsupported (should never appear; zero-height placeholder)

    private func configureAsUnsupported(sameKind: Bool) {
        guard !sameKind || spacerView == nil else { return }
        removeAllContentViews()
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor),
            v.heightAnchor.constraint(equalToConstant: 0),
        ])
        spacerView = v
    }

    // MARK: - Helpers

    // MARK: - FollowUpSuggestions (upstream)

    private func configureAsFollowUpSuggestions(
        block: ContentBlock,
        suggestions: [String],
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        let onTap = context.onFollowUpTap
        // Animate only the first time this row is shown; recycled re-mounts
        // after scrolling render in their final state (mirrors the chart cell).
        let animate = !(context.hasFollowUpsShown?(block.id) ?? false)
        context.markFollowUpsShown?(block.id)
        let rootView = AnyView(
            FollowUpSuggestionsBar(
                suggestions: suggestions,
                animate: animate,
                onSelect: { onTap?($0) }
            )
            .environment(\.theme, context.theme)
        )
        if !sameKind || nativeFollowUpsView == nil {
            removeAllContentViews()
            let hv = NSHostingView(rootView: rootView)
            hv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hv)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                hv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                // Pin the bottom so the cell's `fittingSize` reflects the
                // hosted content and the row sizes to it.
                hv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
            nativeFollowUpsView = hv
        } else {
            nativeFollowUpsView?.rootView = rootView
        }
        // Correct the row height once SwiftUI has laid out, mirroring the
        // artifact/user cells' measured-height report.
        let id = block.id
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            context.onHeightMeasured?(self.measureFittedRowHeight(), id)
        }
    }

    // MARK: - Activity Group (upstream NativeActivityGroupView)

    private func configureAsActivityGroup(
        block: ContentBlock,
        children: [ContentBlock],
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeActivityGroupView == nil {
            removeAllContentViews()
            let av = NativeActivityGroupView()
            av.translatesAutoresizingMaskIntoConstraints = false
            addSubview(av)
            NSLayoutConstraint.activate([
                av.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                av.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                av.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeActivityGroupView = av
        }
        nativeActivityGroupView?.configure(
            children: children,
            expandedIds: context.expandedIds,
            width: context.width - 32,
            theme: context.theme,
            isStreaming: context.isStreaming,
            blockId: block.id,
            onToggleChild: { id in context.onToggleExpand(id) },
            onToggle: { [weak self] in
                guard let self else { return }
                context.onToggleExpand(block.id)
                self.nativeActivityGroupView?.onHeightChanged?()
            },
            onHeightChanged: { [weak self] in
                guard let self, let av = self.nativeActivityGroupView, let id = self.currentBlockId else { return }
                let h = av.measuredHeight() + 8
                context.onHeightMeasured?(h, id)
            }
        )
    }

    // MARK: - Compaction Marker (upstream NativeCompactionMarkerView)

    private func configureAsCompactionMarker(
        block: ContentBlock,
        savedTokens: Int,
        modelName: String,
        summaryText: String,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeCompactionMarkerView == nil {
            removeAllContentViews()
            let mv = NativeCompactionMarkerView()
            mv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mv)
            NSLayoutConstraint.activate([
                mv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                mv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                mv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeCompactionMarkerView = mv
        }
        let isExpanded = context.expandedIds.contains(block.id)
        nativeCompactionMarkerView?.configure(
            savedTokens: savedTokens,
            modelName: modelName,
            summaryText: summaryText,
            width: context.width - 32,
            isExpanded: isExpanded,
            theme: context.theme,
            blockId: block.id,
            onToggle: { [weak self] in
                guard let self else { return }
                context.onToggleExpand(block.id)
                self.nativeCompactionMarkerView?.onHeightChanged?()
            },
            onHeightChanged: { [weak self] in
                guard let self, let mv = self.nativeCompactionMarkerView,
                    let id = self.currentBlockId
                else { return }
                let h = mv.measuredHeight() + 8
                context.onHeightMeasured?(h, id)
            }
        )
    }

    private func removeAllContentViews() {
        self.layer?.backgroundColor = nil
        self.layer?.cornerRadius = 0
        lastBubbleBackgroundCGColor = nil
        lastBubbleCornerRadius = 0
        // Restore the cell-wide default. configureAsChart opts back into
        // clipping for WKWebView-backed chart content; bubble cells rely on
        // unclipped bounds so shadows / halo affordances aren't cut off.
        clipsToBounds = false
        layer?.masksToBounds = false
        spacerView?.removeFromSuperview(); spacerView = nil
        nativeHeaderView?.removeFromSuperview(); nativeHeaderView = nil
        nativeHeaderHeightConstraint = nil
        nativeMarkdownView?.removeFromSuperview(); nativeMarkdownView = nil
        nativeThinkingView?.removeFromSuperview(); nativeThinkingView = nil
        nativeToolCallGroupView?.removeFromSuperview(); nativeToolCallGroupView = nil
        nativePendingView?.removeFromSuperview(); nativePendingView = nil
        nativeTypingView?.removeFromSuperview(); nativeTypingView = nil
        nativeArtifactView?.removeFromSuperview(); nativeArtifactView = nil
        // CRITICAL: NativeChartView wraps an AAChartView (WKWebView) which
        // composites its content through a process-isolated IOSurface that
        // ignores both `clipsToBounds` and `isHidden` on the AppKit parent.
        // If we leave the chart view parented after the cell is recycled
        // (e.g. chart row dequeued, reused as a paragraph row), the old
        // chart keeps rendering at its previous frame underneath the new
        // content — visible as charts bleeding through unrelated rows once
        // the user starts scrolling and recycling kicks in.
        nativeChartView?.removeFromSuperview(); nativeChartView = nil
        nativeFileDiffView?.removeFromSuperview(); nativeFileDiffView = nil
        nativeFollowUpsView?.removeFromSuperview(); nativeFollowUpsView = nil
        nativeCompactionMarkerView?.removeFromSuperview(); nativeCompactionMarkerView = nil
        nativeActivityGroupView?.removeFromSuperview(); nativeActivityGroupView = nil
        nativePreflightView?.removeFromSuperview(); nativePreflightView = nil
        nativeStatsView?.removeFromSuperview(); nativeStatsView = nil
        nativeAssistantActionsView?.removeFromSuperview(); nativeAssistantActionsView = nil
        nativeEmptyNoticeView?.removeFromSuperview(); nativeEmptyNoticeView = nil
        userMessageContainer?.removeFromSuperview(); userMessageContainer = nil
        userTextView = nil
        userInlineEditView = nil
        // Image / document stacks are added directly to the cell (not to
        // userMessageContainer) because they sit above the bubble; nil'ing
        // the property without removeFromSuperview leaks them as orphaned
        // subviews on the next reuse.
        userImageStack?.removeFromSuperview(); userImageStack = nil
        userDocumentStack?.removeFromSuperview(); userDocumentStack = nil
        userBadgeRow?.removeFromSuperview(); userBadgeRow = nil
        userEnvelopeSignature = nil
        userBubbleWidthConstraint = nil
        userAttachmentsHeight = 0
        userMessageInlineEditActive = false
    }
}

/// Thumbnail in user bubble — tap opens full-screen preview (wired via `CellRenderingContext.onUserImagePreview`).
/// `CALayer` corner radius + `NSImageView` in `NSTableView` still drew a square trailing edge here; clipping in `draw(_:)` is the reliable fix.
private final class UserAttachmentThumbnailView: NSView {
    static let cornerRadius: CGFloat = 10

    override var isFlipped: Bool { true }

    var attachmentId: String = ""
    var onTap: ((String) -> Void)?

    private var lastDrawBounds: NSRect = .zero

    var image: NSImage? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let img = image else { return NSSize(width: 96, height: 96) }
        // Shared rule with the composer chip — clamped aspect, no crop.
        return AttachmentThumbnailLayout.size(for: img, longAxis: 96)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // parent `NativeMessageCellView` is layer-backed; this makes `draw(_:)` reliably update the bitmap
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        if bounds != lastDrawBounds {
            lastDrawBounds = bounds
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image else { return }
        let rect = bounds
        guard rect.width > 0, rect.height > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        // clip to the actual view bounds (which now match the aspect ratio via intrinsicContentSize)
        NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high

        // since the view bounds (rect) already match the aspect ratio,
        // simple drawing into rect will show the full image correctly without stretching.
        img.draw(
            in: rect,
            from: NSRect(origin: .zero, size: img.size),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        onTap?(attachmentId)
    }
}

// MARK: - User Document Chip (native AppKit)

private final class UserDocumentChipView: NSView {
    override var isFlipped: Bool { true }

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")

    override var intrinsicContentSize: NSSize {
        let nameW = min(nameField.intrinsicContentSize.width, 130)
        let sizeW = sizeField.intrinsicContentSize.width
        let w = 8 + 14 + 5 + nameW + 5 + sizeW + 8
        return NSSize(width: min(w, 220), height: 26)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = UserAttachmentThumbnailView.cornerRadius

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        for field in [nameField, sizeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.isEditable = false
            field.isBordered = false
            field.drawsBackground = false
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
        addSubview(iconView)

        nameField.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        sizeField.font = NSFont.systemFont(ofSize: 9, weight: .regular)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 130),

            sizeField.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 5),
            sizeField.centerYAnchor.constraint(equalTo: centerYAnchor),
            sizeField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])

        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(attachment: Attachment, theme: any ThemeProtocol) {
        layer?.backgroundColor = NSColor(theme.secondaryBackground).withAlphaComponent(0.7).cgColor

        let summary = attachment.businessDocumentSummary
        let symbolName = summary?.systemImageName ?? attachment.fileIcon
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        iconView.image = SymbolImageCache.image(symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = NSColor(theme.accentColor)

        nameField.stringValue = attachment.filename ?? "Document"
        nameField.textColor = NSColor(theme.primaryText)

        sizeField.stringValue = summary?.chipDetailLabel ?? attachment.fileSizeFormatted ?? ""
        sizeField.textColor = NSColor(theme.tertiaryText)

        invalidateIntrinsicContentSize()
    }
}

/// Tri-state equality: two nils match, one nil differs, otherwise defer to CGColor.==.
private func cgColorsEqual(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (l?, r?): return l == r
    default: return false
    }
}

// MARK: - ContentBlockKindTag

/// Lightweight discriminator used to detect kind changes without comparing full associated values.
enum ContentBlockKindTag: Equatable {
    case header, paragraph, toolCallGroup, thinking, activityGroup, userMessage, pendingToolCall
    case generationStats, typingIndicator, groupSpacer, sharedArtifact, preflightCapabilities, chart
    case assistantActions, emptyResponseNotice, fileDiff, followUpSuggestions, compactionMarker, other
}

extension ContentBlockKind {
    var kindTag: ContentBlockKindTag {
        switch self {
        case .header: return .header
        case .paragraph: return .paragraph
        case .toolCallGroup: return .toolCallGroup
        case .thinking: return .thinking
        case .activityGroup: return .activityGroup
        case .userMessage: return .userMessage
        case .pendingToolCall: return .pendingToolCall
        case .generationStats: return .generationStats
        case .typingIndicator: return .typingIndicator
        case .groupSpacer: return .groupSpacer
        case .sharedArtifact: return .sharedArtifact
        case .preflightCapabilities: return .preflightCapabilities
        case .chart: return .chart
        case .assistantActions: return .assistantActions
        case .fileDiff: return .fileDiff
        case .followUpSuggestions: return .followUpSuggestions
        case .compactionMarker: return .compactionMarker
        case .emptyResponseNotice: return .emptyResponseNotice
        }
    }
}

// MARK: - NativeCellHeightEstimator

/// Provides height estimates for rows without triggering a full SwiftUI layout pass.
/// Used by the NSTableView height delegate as a fast path.
enum NativeCellHeightEstimator {

    /// Inner height of the assistant header row (avatar + name + actions),
    /// without the 12pt top/bottom cell padding. Must match the constraints
    /// installed by `configureAsHeader`.
    @MainActor static func headerInnerHeight(for theme: any ThemeProtocol) -> CGFloat {
        let clampedAvatar = max(
            NativeHeaderView.minAvatarSize,
            min(NativeHeaderView.maxAvatarSize, CGFloat(theme.inlineAvatarSize))
        )
        let avatarSpace = theme.showInlineAvatar ? clampedAvatar : 0
        return max(28, avatarSpace)
    }

    @MainActor static func estimatedHeight(
        for block: ContentBlock,
        width: CGFloat,
        theme: any ThemeProtocol,
        isExpanded: Bool
    ) -> CGFloat {
        switch block.kind {
        case .groupSpacer:
            return 16

        case .header:
            // 12 top + header content + 12 bottom; content grows with avatar size
            return 24 + headerInnerHeight(for: theme)

        case .generationStats:
            return 24

        case .assistantActions:
            // 4 top gap + 28 button + 8 bottom gap
            return 40

        case .emptyResponseNotice:
            // 4 top gap + 36 notice + 8 bottom gap
            return 48

        case .typingIndicator:
            // 4 top + ~22 content + 6 bottom (tight to header / thinking row above)
            return 32

        case let .pendingToolCall(_, argPreview, _):
            // header row + 52pt arg box + cell vertical insets
            return argPreview != nil ? 112 : 62

        case let .thinking(_, text, _):
            if !isExpanded { return 56 }
            let innerW = max(width - 64, 100)
            let charsPerLine = max(Int(innerW / 7), 20)
            let lines = max(1, (text.count + charsPerLine - 1) / charsPerLine)
            return 58 + min(CGFloat(lines) * 22 + 32, 356)

        case let .paragraph(_, text, _, _):
            let innerW = max(width - 32, 100)
            let cacheKey = "\(block.id)-w\(Int(innerW))"
            if let cached = ThreadCache.shared.height(for: cacheKey) {
                return cached + 24
            }
            let chars = max(Int(innerW / 7), 20)
            let lines = max(1, (text.count + chars - 1) / chars)
            return CGFloat(lines) * 22 + 24

        case let .userMessage(rawText, attachments, envelope):
            // Enveloped turns paint the human-authored text under a badge row.
            let text = envelope?.displayText ?? rawText
            let hasBadges = !(envelope?.badges.isEmpty ?? true)
            var h: CGFloat = 8  // outerTopGap
            let innerW = max(width - 32, 100)

            // Stacked above the bubble (fixed heights, 6pt gaps), mirroring
            // `configureAsUserMessage`: badge row, documents, images.
            let docCount = attachments.filter(\.isDocument).count
            let imageCount = attachments.filter(\.isImage).count
            var above: CGFloat = 0
            if hasBadges { above += NativeDispatchBadgeRow.rowHeight }
            if docCount > 0 { above += (above > 0 ? 6 : 0) + 26 }
            if imageCount > 0 { above += (above > 0 ? 6 : 0) + 96 }
            h += above
            if above > 0 && !text.isEmpty { h += 6 }  // gap to bubble

            // Text bubble (10pt top + text + 10pt bottom)
            if !text.isEmpty {
                let maxBubbleW = floor(innerW * 0.65)
                let textW = maxBubbleW - 24
                let cacheKey = "\(block.id)-w\(Int(textW))"
                let textH: CGFloat
                if let cached = ThreadCache.shared.height(for: cacheKey) {
                    textH = cached
                } else {
                    let chars = max(Int(textW / 7), 20)
                    let lines = max(1, (text.count + chars - 1) / chars)
                    textH = CGFloat(lines) * 22
                }
                h += 10 + textH + 6
            }

            h += 8  // bottom margin
            return max(h, 48)

        case let .toolCallGroup(calls):
            // each row self-sizes at ~41pt (40pt header + 1pt separator)
            return CGFloat(calls.count) * 41 + 8

        case let .activityGroup(children):
            // collapsed: 44pt header + 4pt inset + 8pt cell gap (upstream)
            if !isExpanded { return 56 }
            // expanded: header + separator/gaps + children estimated
            // collapsed; per-child expansion is corrected by the measured
            // height report
            let childrenH = children.reduce(CGFloat(0)) { acc, child in
                acc + estimatedHeight(for: child, width: width - 28, theme: theme, isExpanded: false)
            }
            return 44 + 1 + 8 + childrenH + 10 + 8

        case let .preflightCapabilities(items):
            return 8 + PreflightCapabilitiesRowHeight.estimated(items: items, tableWidth: width)

        case let .sharedArtifact(artifact):
            // matches NativeArtifactCardView: inner top 12 + bottom 8 (footerVerticalGap), symmetric gap above/below footer row
            var h: CGFloat = 12 + 24 + 8 + 8 + 40 + 4 + 4
            if let d = artifact.description, !d.isEmpty { h += 20 }
            let pathEmpty = artifact.hostPath.isEmpty
            if pathEmpty {
                if artifact.isText, let c = artifact.content, !c.isEmpty {
                    let lines = min(6, max(1, c.components(separatedBy: "\n").count))
                    h += CGFloat(lines) * 14 + 8
                }
            } else if artifact.isImage || artifact.isPDF || artifact.isVideo {
                h += 160 + 8
            } else if artifact.isAudio {
                h += 56 + 8
            } else if artifact.isHTML || artifact.isDirectory {
                h += 44 + 8
            } else if artifact.isText, let c = artifact.content, !c.isEmpty {
                let lines = min(6, max(1, c.components(separatedBy: "\n").count))
                h += CGFloat(lines) * 14 + 8
            }
            // configureAsArtifact reports measuredCardHeight() + 12 for cell top/bottom inset — match that here
            // extra slack: intrinsic footer + deferred layout can exceed this; too-small row clips Open in Finder
            return h + 12 + 24

        case let .chart(spec):
            // Layout: cell.top(6) + cardPadding + picker(24) + chartHeight
            //          + (note ? 6 + 16 + cardPadding : cardPadding) + cell.bottom(6)
            //
            // Title shares the picker row (centerYAnchor) so it never adds
            // height. The previous estimator added 24pt only when a title
            // was present, double-counting with title and dropping to zero
            // for no-title charts — leaving a 24pt gap that let the
            // WKWebView-backed chart layer leak into the next row. Always
            // account for the picker, never the title.
            let p = NativeChartView.cardPadding
            let pickerH: CGFloat = 24  // picker height + 4pt gap
            var h: CGFloat = 12 + p + pickerH + NativeChartView.chartHeight
            h +=
                (spec.note ?? "").isEmpty
                ? p
                : (6 + 16 + p)
            return h

        case let .fileDiff(diff):
            // Diff cards default to collapsed and only expand when the user
            // opted in via `expandedIds`. configureAsFileDiff reports
            // measuredCardHeight(...) + 12 for the cell top/bottom inset —
            // match that. Upstream.
            let header = NativeFileDiffView.headerHeight
            if !isExpanded { return header + 12 }
            let innerW = max(width - 32 - 14 - 8, 100)
            let chars = max(Int(innerW / 7), 20)
            var lineRows = 0
            for line in diff.lines {
                lineRows += max(1, (line.text.count + chars - 1) / chars)
            }
            let fontLineHeight: CGFloat = max(10, CGFloat(theme.codeSize) - 1) * 1.35
            return header + 6 + CGFloat(lineRows) * fontLineHeight + 6 + 12

        case let .followUpSuggestions(_, suggestions):
            // Mirrors `FollowUpSuggestionsBar` (upstream estimate); corrected
            // by the measured-height report either way.
            let innerW = max(width - 80, 100)
            let chars = max(Int(innerW / 7), 20)
            var rows: CGFloat = 0
            for s in suggestions {
                let lines = max(1, (s.count + chars - 1) / chars)
                rows += CGFloat(lines) * 18 + 20
            }
            let dividers = CGFloat(max(0, suggestions.count - 1))
            return 23 + rows + dividers + 16 + 12

        case let .compactionMarker(_, _, summaryText):
            // Collapsed: 4 top inset + 32 header + 8 cell gap. Expanded adds
            // the summary text, estimated like thinking; the cell corrects
            // via the measured-height report. (Upstream.)
            if !isExpanded { return 44 }
            let innerW = max(width - 60, 100)
            let charsPerLine = max(Int(innerW / 7), 20)
            let lines = max(1, (summaryText.count + charsPerLine - 1) / charsPerLine)
            return 44 + 8 + CGFloat(lines) * 22 + 10
        }
    }
}
