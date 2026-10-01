//
//  ActivityLogSettingsSection.swift
//  osaurus
//
//  Retention + content policy for the on-device activity log that Insights
//  reads (upstream #2964's `activityLogSection` in `PrivacyOverviewTab`,
//  verbatim body). Intel has no Privacy tab, so the card sits on Settings ›
//  General › Advanced › Data & Storage next to File History
//  (docs/INSIGHTS_INTEL.md).
//

import SwiftUI

struct ActivityLogSettingsSection: View {
    /// Persisted activity-log policy (retention + content). Read live from
    /// the Insights facade so the picker reflects what the logger enforces.
    @ObservedObject private var insights = InsightsService.shared

    /// Retention changes prune immediately; the content switch applies to
    /// records written from now on (existing rows keep whatever was stored
    /// at the time).
    var body: some View {
        SettingsSection(title: L("Activity Log"), icon: "list.bullet.clipboard") {
            SettingsPickerRow(
                title: L("Keep Activity History"),
                description:
                    "How long Insights keeps the record of every model request, web search, URL fetch, MCP call, channel delivery, and Router call made from this Mac. Older records are removed automatically.",
                anchorId: "privacy.activityLog.retention",
                style: .menu,
                selection: Binding(
                    get: { insights.settings.retentionDays ?? 0 },
                    set: { newValue in
                        var next = insights.settings
                        next.retentionDays = newValue == 0 ? nil : newValue
                        insights.updateSettings(next)
                    }
                ),
                options: ActivityLogSettings.retentionChoices.map { days in
                    .init(days ?? 0, ActivityLogSettings.retentionLabel(days))
                }
            )

            SettingsToggle(
                title: L("Store Prompts and Responses"),
                description:
                    "Keep the full prompt, response, tool arguments, and wire payloads in the activity log so a reviewer can read exactly what was sent. Turn off to keep only metadata (destination, sizes, timing, tokens) for new records.",
                anchorId: "privacy.activityLog.storeContent",
                isOn: Binding(
                    get: { insights.settings.storeContent },
                    set: { newValue in
                        var next = insights.settings
                        next.storeContent = newValue
                        insights.updateSettings(next)
                    }
                )
            )

            SettingsLinkRow(
                title: L("Review Activity in Insights"),
                description: L("Filter, verify the tamper-evident chain, and export the log for outside review."),
                icon: "chart.bar.doc.horizontal",
                actionTitle: "Open Insights",
                anchorId: "privacy.activityLog.openInsights"
            ) {
                ManagementStateManager.shared.selectedTab = .insights
            }
        }
    }
}
