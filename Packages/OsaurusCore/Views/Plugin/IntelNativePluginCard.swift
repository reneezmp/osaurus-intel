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
    /// True when the repo index has a newer version than the installed one.
    var hasUpdate: Bool = false
    let onOpenSettings: () -> Void
    let onSelect: () -> Void
    var onUpgrade: (() async throws -> Void)? = nil
    var onUninstall: (() -> Void)? = nil

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
                        if hasUpdate {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.circle.fill").font(.caption2)
                                Text(localized: "Update").font(.caption2.weight(.medium))
                            }
                            .foregroundColor(.orange)
                        } else {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.circle.fill").font(.caption2)
                                Text(localized: "Loaded").font(.caption2.weight(.medium))
                            }
                            .foregroundColor(theme.successColor)
                        }
                    }
                    Text("v\(plugin.version) · native x86_64")
                        .font(.caption).foregroundColor(theme.secondaryText)
                }

                Spacer()

                Menu {
                    Button { onSelect() } label: { Label(localized: "View Details", systemImage: "info.circle") }
                    if hasUpdate, let onUpgrade {
                        Button {
                            Task { try? await onUpgrade() }
                        } label: { Label(localized: "Update", systemImage: "arrow.up.circle.fill") }
                    }
                    if isConfigurable {
                        Button { onOpenSettings() } label: { Label(localized: "Settings", systemImage: "gearshape") }
                    }
                    Button { revealInFinder() } label: { Label(localized: "Reveal in Finder", systemImage: "folder") }
                    if let onUninstall {
                        Divider()
                        Button(role: .destructive) {
                            onUninstall()
                        } label: { Label(localized: "Uninstall", systemImage: "trash") }
                    }
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
                    Label(localized: "Settings", systemImage: "gearshape")
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
    var onUninstall: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var version = ""
    @State private var detailText = ""
    @State private var tools: [PluginManifest.ToolSpec] = []
    @State private var secrets: [PluginManifest.SecretSpec] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back header
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(localized: "Plugins")
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                Spacer()
                if let onUninstall {
                    Button(action: onUninstall) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .localizedHelp("Uninstall plugin")
                }
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
                        Text(localized: "Tools (\(tools.count))")
                            .font(.headline).foregroundColor(theme.primaryText)
                        ForEach(tools, id: \.id) { tool in
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

                    if !secrets.isEmpty {
                        Button(action: onOpenSettings) {
                            Label(localized: "Settings (\(secrets.count))", systemImage: "gearshape")
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
        guard let loaded = PluginManager.shared.loadedPlugin(for: pluginId) else { return }
        let manifest = loaded.plugin.manifest
        name = manifest.name ?? pluginId
        tools = manifest.capabilities.tools ?? []
        secrets = manifest.secrets ?? []
        version = manifest.version ?? ""
        detailText = manifest.description ?? ""
    }
}

#endif
