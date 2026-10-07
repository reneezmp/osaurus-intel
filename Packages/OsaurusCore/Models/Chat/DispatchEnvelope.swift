//
//  DispatchEnvelope.swift
//  osaurus
//
//  Display-time parser for the machine-generated envelopes that background
//  dispatch paths write into a user turn's `content`. The stored turn and
//  the model request are never touched: this only recovers the
//  human-authored text (plus a little provenance) so the chat renders a
//  message, with a badge row (`NativeDispatchBadgeRow`), instead of a
//  template. Producers expose their fixed fragments as shared constants and
//  the round-trip tests pin them, so producer and parser cannot drift.
//
//  Intel port of upstream's file (`W-chat-ux`). Kinds with a producer on
//  Intel today:
//  - self-scheduled runs (`NextRunScheduler`, upstream preamble);
//  - watcher runs, parsed from Intel's current watcher framing
//    (`WatcherManager.firstRunFraming` / `followUpFraming` /
//    `idempotencyFooter`). Upstream's newer watcher prompt (watched-folder
//    line, changed paths) arrives with the watcher upgrade; the `.watcherRun`
//    fields for it are kept so the badges light up then.
//  Staged until their producers land: channel messages (`W-channels`),
//  delegated tasks (upstream `AgentDelegationDispatcher`'s contract; Intel's
//  Orchestrator delegation is a one-shot with no visible delegate chat) and
//  the folder-unreadable preamble.
//
//  Performance contract (upstream): no regular expressions; every kind is
//  gated by a `hasPrefix` / `hasSuffix` check before any scan.
//

import Foundation

// MARK: - Channel envelope

/// Parsed provenance label of a channel message, e.g.
/// `"n8n connection n8n-clippy, conversation demo-helpdesk, sender workflow"`
/// → provider `n8n`, parts `[connection: n8n-clippy, conversation: demo-helpdesk, sender: workflow]`.
struct ChannelMessageSource: Equatable, Sendable {
    struct Part: Equatable, Sendable {
        let label: String
        let value: String
    }

    /// Provider name as the adapter spelled it ("n8n", "Slack", "Discord",
    /// "Telegram", "WhatsApp", "iMessage").
    let provider: String
    let parts: [Part]
    /// The verbatim label, for tooltips.
    let raw: String

    /// First part whose label matches any of the given names, in order.
    func value(forAny labels: [String]) -> String? {
        for label in labels {
            if let part = parts.first(where: { $0.label == label }) { return part.value }
        }
        return nil
    }

    /// Where the message came from within the provider (conversation,
    /// channel, chat, or room), whichever the adapter supplied.
    var conversation: String? {
        value(forAny: ["conversation", "channel", "chat", "room"])
    }

    var sender: String? { value(forAny: ["sender"]) }

    /// Every adapter emits `"<Provider> <label> <value>, <label> <value>, …"`.
    /// Segments without a label/value pair are kept as unlabeled values so
    /// nothing the adapter wrote is silently dropped.
    static func parse(_ label: String) -> ChannelMessageSource {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.components(separatedBy: ", ")
        var provider = ""
        var parts: [Part] = []
        for (index, segment) in segments.enumerated() {
            let tokens = segment.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if index == 0 {
                guard let first = tokens.first else { continue }
                provider = first
                if tokens.count >= 3 {
                    parts.append(Part(label: tokens[1], value: tokens.dropFirst(2).joined(separator: " ")))
                } else if tokens.count == 2 {
                    parts.append(Part(label: "", value: tokens[1]))
                }
            } else if tokens.count >= 2 {
                parts.append(Part(label: tokens[0], value: tokens.dropFirst().joined(separator: " ")))
            } else if let only = tokens.first {
                parts.append(Part(label: "", value: only))
            }
        }
        return ChannelMessageSource(provider: provider, parts: parts, raw: trimmed)
    }
}

// MARK: - Dispatch envelope

/// A user turn whose stored content is a machine-generated dispatch envelope,
/// reduced to the human-authored text plus provenance for the badge row.
struct DispatchEnvelope: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case selfScheduledRun(scheduledBy: String?, scheduledAt: String?, previousRun: String?)
        case watcherRun(watchedFolder: String?, changedPaths: [String], overflowCount: Int, iteration: Int?)
    }

    let kind: Kind?
    /// What the bubble should show in place of the raw content.
    let displayText: String

    /// Recover the display text from an envelope. Returns nil when the
    /// content is not an envelope (or reduces to nothing), so the caller
    /// falls back to the raw text. The watcher framing has no markers of its
    /// own, so it is only tried for `.watcher` sessions (upstream).
    static func parse(_ content: String, sessionSource: SessionSource) -> DispatchEnvelope? {
        var kind: Kind?
        var display = content
        if let scheduled = parseSelfScheduled(content) {
            kind = scheduled.kind
            display = scheduled.instructions
        } else if sessionSource == .watcher, let watcher = parseWatcher(content) {
            kind = watcher.kind
            display = watcher.instructions
        }
        guard kind != nil else { return nil }
        let trimmedDisplay = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplay.isEmpty else { return nil }
        return DispatchEnvelope(kind: kind, displayText: trimmedDisplay)
    }

    // MARK: Self-scheduled run

    private static func parseSelfScheduled(_ text: String) -> (kind: Kind, instructions: String)? {
        guard text.hasPrefix(NextRunScheduler.selfScheduledRunPrefix) else { return nil }
        let header = "\n" + NextRunScheduler.instructionsHeader + "\n"
        guard let range = text.range(of: header) else { return nil }
        let preamble = text[..<range.lowerBound]
        var scheduledBy: String?
        var scheduledAt: String?
        var previousRun: String?
        for line in preamble.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if s.hasPrefix(NextRunScheduler.scheduledByLinePrefix) {
                // "Scheduled by: <who>, for <when>."
                var rest = String(s.dropFirst(NextRunScheduler.scheduledByLinePrefix.count))
                if rest.hasSuffix(".") { rest.removeLast() }
                if let split = rest.range(of: ", for ") {
                    scheduledBy = String(rest[..<split.lowerBound])
                    scheduledAt = String(rest[split.upperBound...])
                } else {
                    scheduledBy = rest
                }
            } else if s.hasPrefix(NextRunScheduler.previousRunLinePrefix) {
                previousRun = s
            }
        }
        let instructions = String(text[range.upperBound...])
        return (
            .selfScheduledRun(scheduledBy: scheduledBy, scheduledAt: scheduledAt, previousRun: previousRun),
            instructions
        )
    }

    // MARK: Watcher run (Intel framing)

    /// `<instructions><firstRunFraming | followUpFraming><idempotencyFooter>`,
    /// as `WatcherManager.buildDispatchPrompt` writes it.
    private static func parseWatcher(_ text: String) -> (kind: Kind, instructions: String)? {
        let footer = WatcherManager.idempotencyFooter
        guard text.hasSuffix(footer) else { return nil }
        let body = text.dropLast(footer.count)
        let framings: [(String, Int)] = [
            (WatcherManager.firstRunFraming, 1), (WatcherManager.followUpFraming, 2),
        ]
        for (framing, iteration) in framings where body.hasSuffix(framing) {
            let instructions = String(body.dropLast(framing.count))
            return (
                .watcherRun(watchedFolder: nil, changedPaths: [], overflowCount: 0, iteration: iteration),
                instructions
            )
        }
        return nil
    }
}

// MARK: - Badge presentation

extension DispatchEnvelope {
    /// One chip in the provenance badge row.
    struct Badge: Equatable, Sendable {
        enum Tone: Equatable, Sendable {
            case neutral
            case warning
            case error
        }

        let symbol: String
        let label: String
        let tooltip: String?
        let tone: Tone

        init(symbol: String, label: String, tooltip: String? = nil, tone: Tone = .neutral) {
            self.symbol = symbol
            self.label = label
            self.tooltip = tooltip
            self.tone = tone
        }
    }

    /// Provider-specific glyph for the channel chip.
    static func providerSymbol(_ provider: String) -> String {
        switch provider.lowercased() {
        case "n8n": return "arrow.triangle.branch"
        case "slack": return "number"
        case "discord": return "bubble.left.and.bubble.right"
        case "telegram": return "paperplane"
        case "whatsapp": return "phone"  // Intel: `phone.bubble` is macOS 14
        case "imessage": return "message"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Badges in display order: provenance first, then context, then any
    /// warnings. The renderer caps the visible count and folds the rest into
    /// a "+N" chip, so order here is also priority.
    var badges: [Badge] {
        var out: [Badge] = []
        switch kind {
        case let .selfScheduledRun(scheduledBy, scheduledAt, previousRun):
            var tooltipLines: [String] = []
            if let scheduledBy { tooltipLines.append(L("Scheduled by \(scheduledBy)")) }
            if let previousRun { tooltipLines.append(previousRun) }
            out.append(
                Badge(
                    symbol: "alarm",
                    label: L("Self-scheduled"),
                    tooltip: tooltipLines.isEmpty ? nil : tooltipLines.joined(separator: "\n")
                )
            )
            if let scheduledAt {
                out.append(Badge(symbol: "clock", label: scheduledAt, tooltip: L("Scheduled for")))
            }

        case let .watcherRun(watchedFolder, changedPaths, overflowCount, iteration):
            out.append(
                Badge(
                    symbol: "folder.badge.gearshape",
                    label: L("Watcher run"),
                    tooltip: iteration.map { $0 == 1 ? L("First pass") : L("Follow-up pass") }
                )
            )
            if let watchedFolder {
                let name = (watchedFolder as NSString).lastPathComponent
                out.append(
                    Badge(
                        symbol: "folder",
                        label: name.isEmpty ? watchedFolder : name,
                        tooltip: watchedFolder
                    )
                )
            }
            let total = changedPaths.count + overflowCount
            if total > 0 {
                var lines = changedPaths
                if overflowCount > 0 { lines.append(L("…and \(overflowCount) more")) }
                out.append(
                    Badge(
                        symbol: "doc.text.magnifyingglass",  // Intel: `doc.badge.clock` is macOS 14
                        label: total == 1 ? L("1 changed") : L("\(total) changed"),
                        tooltip: lines.joined(separator: "\n")
                    )
                )
            }

        case nil:
            break
        }
        return out
    }
}
