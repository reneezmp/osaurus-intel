//
//  IntelAppleAppsGuidance.swift
//  osaurus
//
//  Prompt grounding for the built-in Apple app tools on Intel. Adapted from
//  upstream `SystemPromptTemplates.appleAppsGuidance` (#2855 series):
//
//   - Intel has no `get_current_time` tool, so the local date, time and
//     time zone ride the per-turn prefix (`clock`) instead; the stable
//     guidance stays cacheable.
//   - Approvals follow Intel's per-tool policy: reads run, changes ask
//     (docs/APPLE_APPS_INTEL_PLAN.md).
//   - Lists only the apps that resolved into this turn's tool schema, so the
//     prompt never advertises an app the model cannot reach.
//

import Foundation

enum IntelAppleAppsGuidance {
    /// Stable section for the system prompt. Empty when no app is active.
    static func guidance(apps: [AppleApp]) -> String {
        guard !apps.isEmpty else { return "" }
        let names = apps.map(\.displayName).joined(separator: ", ")
        let prefixes = toolPrefixes(for: apps).map { "`\($0)_*`" }.joined(separator: ", ")
        var lines: [String] = [
            "## Apple apps",
            "",
            "- You can work directly with the user's \(names) through the \(prefixes) tools. Use them instead of saying you cannot access these apps.",
            "- Resolve relative dates (\"tomorrow\", \"next Monday\", \"this week\") against the current local time given with the user's message; pass dates as ISO 8601 with the local offset. A bare `YYYY-MM-DD` means local midnight and an end date is inclusive.",
            "- Read before you write: look the item up first (its `id`, list or calendar) and reuse the returned identifiers instead of guessing names.",
            "- Creating, changing and deleting pause for the user's approval. State exactly what you will change and let that approval handle confirmation — do not ask for permission yourself first.",
            "- After a change, report back the exact title, date/time or list the tool returned so the user can verify it.",
            "- If a tool returns `permission_denied`, tell the user which macOS permission to grant (the message names the System Settings pane) and stop; do not retry in a loop.",
        ]
        if apps.contains(.calendar) || apps.contains(.reminders) {
            lines.append(
                "- Calendar/Reminders: when the user names a calendar or list, resolve it with `calendar_list` / `reminders_lists` first; otherwise the default is used and reported."
            )
        }
        if apps.contains(.shortcuts) {
            lines.append(
                "- Shortcuts: list first with `shortcuts_list`; `shortcuts_run` passes `input` as text and returns the shortcut's text output."
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Per-turn clock line: local date/time with offset, weekday and zone.
    static func clock(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.timeZone = timeZone
        weekday.dateFormat = "EEEE"
        return "## Current local time\n\(iso.string(from: now)) (\(weekday.string(from: now)), \(timeZone.identifier))"
    }

    /// Apps whose tools are in `toolNames`, in catalog order.
    static func activeApps(in toolNames: Set<String>) -> [AppleApp] {
        AppleApp.allCases.filter { !$0.toolNames.isDisjoint(with: toolNames) }
    }

    /// Distinct `<prefix>` values of `<prefix>_<verb>` across the apps' tool
    /// names, in catalog order.
    static func toolPrefixes(for apps: [AppleApp]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for app in apps {
            for name in app.toolNames.sorted() {
                let prefix = name.split(separator: "_", maxSplits: 1).first.map(String.init) ?? name
                if seen.insert(prefix).inserted { out.append(prefix) }
            }
        }
        return out
    }
}
