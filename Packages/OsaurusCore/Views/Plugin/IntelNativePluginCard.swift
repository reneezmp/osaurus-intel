//
//  IntelNativePluginCard.swift
//  OsaurusCore — Intel fork
//
//  Polished card + detail sheet for natively-loaded x86_64 plugins, shown in
//  the Plugins → Installed tab. Mirrors the registry PluginCard's affordances
//  (accent outline, loaded badge, tool count, options menu, tap → detail).
//

#if OSAURUS_INTEL

import SwiftUI
import AppKit

struct NativePluginCard: View {
    let plugin: PluginManager.LoadedPluginInfo
    let isConfigurable: Bool
    let onOpenSettings: () -> Void
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(plugin.name).font(.headline)
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill").font(.caption2)
                            Text("Loaded").font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(.green)
                    }
                    Text("v\(plugin.version) · native x86_64")
                        .font(.caption).foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack(spacing: 14) {
                Label("\(plugin.toolNames.count)", systemImage: "wrench.and.screwdriver")
                    .font(.caption).foregroundStyle(.secondary)
                if isConfigurable {
                    Label("Settings", systemImage: "gearshape")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !plugin.toolNames.isEmpty {
                Text(plugin.toolNames.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(isHovered ? 0.6 : 0.28), lineWidth: 1)
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

struct IntelNativePluginDetailView: View {
    let pluginId: String
    let onOpenSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var version = ""
    @State private var detailText = ""
    @State private var tools: [IntelPluginToolSpec] = []
    @State private var configFields: [IntelPluginConfigField] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? pluginId : name).font(.title2.bold())
                    Text("v\(version) · native x86_64").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !detailText.isEmpty {
                        Text(detailText).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tools (\(tools.count))").font(.headline)
                        ForEach(tools) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.id).font(.subheadline.weight(.medium))
                                if !tool.description.isEmpty {
                                    Text(tool.description).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !configFields.isEmpty {
                        Button {
                            onOpenSettings()
                        } label: {
                            Label("Settings (\(configFields.count))", systemImage: "gearshape")
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 470)
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
