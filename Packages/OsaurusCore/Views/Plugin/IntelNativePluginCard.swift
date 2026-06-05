//
//  IntelNativePluginCard.swift
//  OsaurusCore — Intel fork
//
//  Polished card + inline detail for natively-loaded x86_64 plugins, shown in
//  the Plugins → Installed tab. Uses the app THEME colors (not system colors)
//  so it reads correctly under any theme, and renders the detail INLINE in the
//  settings content (not a sheet), matching the registry PluginDetailView.
//

#if OSAURUS_INTEL

import SwiftUI
import AppKit

struct NativePluginCard: View {
    let plugin: PluginManager.LoadedPluginInfo
    let isConfigurable: Bool
    let onOpenSettings: () -> Void
    let onSelect: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title3)
                    .foregroundColor(theme.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(plugin.name).font(.headline).foregroundColor(theme.primaryText)
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill").font(.caption2)
                            Text("Loaded").font(.caption2.weight(.medium))
                        }
                        .foregroundColor(theme.successColor)
                    }
                    Text("v\(plugin.version) · native x86_64")
                        .font(.caption).foregroundColor(theme.secondaryText)
                }

                Spacer()

                Menu {
                    Button { onSelect() } label: { Label("View Details", systemImage: "info.circle") }
                    if isConfigurable {
                        Button { onOpenSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    }
                    Button { revealInFinder() } label: { Label("Reveal in Finder", systemImage: "folder") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack(spacing: 14) {
                Label("\(plugin.toolNames.count)", systemImage: "wrench.and.screwdriver")
                    .font(.caption).foregroundColor(theme.secondaryText)
                if isConfigurable {
                    Label("Settings", systemImage: "gearshape")
                        .font(.caption).foregroundColor(theme.secondaryText)
                }
            }

            if !plugin.toolNames.isEmpty {
                Text(plugin.toolNames.joined(separator: ", "))
                    .font(.caption).foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? theme.accentColor : theme.cardBorder,
                        lineWidth: isHovered ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
    }

    private func revealInFinder() {
        let dir = OsaurusPaths.root()
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent(plugin.pluginId, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}

/// Inline detail page (rendered in the settings content area, with a back
/// button) — NOT a sheet, so it inherits the theme background + colors.
struct IntelNativePluginDetailView: View {
    let pluginId: String
    let onBack: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var version = ""
    @State private var detailText = ""
    @State private var tools: [IntelPluginToolSpec] = []
    @State private var configFields: [IntelPluginConfigField] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back header
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Plugins")
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 40))
                            .foregroundColor(theme.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name.isEmpty ? pluginId : name)
                                .font(.title.bold()).foregroundColor(theme.primaryText)
                            Text("v\(version) · native x86_64")
                                .font(.subheadline).foregroundColor(theme.secondaryText)
                            if !detailText.isEmpty {
                                Text(detailText)
                                    .font(.body).foregroundColor(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 2)
                            }
                        }
                        Spacer()
                    }

                    // Tools
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tools (\(tools.count))")
                            .font(.headline).foregroundColor(theme.primaryText)
                        ForEach(tools) { tool in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tool.id)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(theme.primaryText)
                                if !tool.description.isEmpty {
                                    Text(tool.description)
                                        .font(.caption).foregroundColor(theme.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
                        }
                    }

                    if !configFields.isEmpty {
                        Button(action: onOpenSettings) {
                            Label("Settings (\(configFields.count))", systemImage: "gearshape")
                                .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.primaryBackground)
        .onAppear(perform: load)
    }

    private func load() {
        guard let handle = PluginManager.shared.nativeHandle(for: pluginId) else { return }
        name = handle.displayName
        tools = handle.toolSpecs
        configFields = handle.configFields
        if let data = handle.manifestJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            version = obj["version"] as? String ?? ""
            detailText = obj["description"] as? String ?? ""
        }
    }
}

#endif
