//
//  AppleSiliconOnlyTab.swift
//  OsaurusCore
//
//  Intel fork — full-tab placeholder for amputated settings sections.
//

import SwiftUI

/// Replaces the entire body of a Settings tab that is entirely Apple Silicon only.
/// Shows an informative placeholder instead of being empty/missing.
public struct AppleSiliconOnlyTab: View {
    let tabName: String
    let symbol: String

    public init(tabName: String, symbol: String = "apple.logo") {
        self.tabName = tabName
        self.symbol = symbol
    }

    public var body: some View {
        if OsaurusBuild.isIntel {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: symbol)
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)

                Text(verbatim: tabName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text(verbatim: "This feature requires Apple Silicon and is unavailable on Intel Macs.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 40)

                Text(verbatim: "Osaurus (Intel) provides cloud-only inference, MCP tools, and identity sync. Local model execution, voice features, and sandbox are Apple Silicon only.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.quaternary)
                    .padding(.horizontal, 40)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyView()
        }
    }
}
