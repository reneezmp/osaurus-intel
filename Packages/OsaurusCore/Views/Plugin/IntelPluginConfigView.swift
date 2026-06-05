//
//  IntelPluginConfigView.swift
//  OsaurusCore — Intel fork
//
//  A minimal settings sheet for natively-loaded x86_64 plugins that declare
//  config fields (manifest `secrets[]`). Values persist to the scoped plugin
//  config store; saving calls the plugin's `on_config_changed` callback.
//

#if OSAURUS_INTEL

import SwiftUI

struct IntelPluginConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var plugins: [PluginManager.ConfigurablePlugin] = []
    @State private var values: [String: String] = [:]
    @State private var savedKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Plugin Settings").font(.headline).foregroundColor(theme.primaryText)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider().overlay(theme.primaryBorder)

            if plugins.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 32))
                        .foregroundColor(theme.secondaryText)
                    Text("No native plugins declare settings.")
                        .foregroundColor(theme.secondaryText)
                    Text("A plugin advertises settings via `secrets` in its manifest.")
                        .font(.caption)
                        .foregroundColor(theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(plugins) { plugin in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(plugin.name).font(.headline).foregroundColor(theme.primaryText)
                                ForEach(plugin.fields) { field in
                                    fieldRow(plugin: plugin, field: field)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 10).fill(theme.cardBackground)
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 480, height: 440)
        .background(theme.primaryBackground)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func fieldRow(plugin: PluginManager.ConfigurablePlugin, field: IntelPluginConfigField) -> some View {
        let key = storeKey(plugin.id, field.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(field.label).font(.subheadline.weight(.medium)).foregroundColor(theme.primaryText)
                if field.required {
                    Text("*").foregroundColor(theme.errorColor)
                }
            }
            if let detail = field.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundColor(theme.secondaryText)
            }
            HStack(spacing: 8) {
                Group {
                    if field.isSecret {
                        SecureField("value", text: binding(key))
                    } else {
                        TextField("value", text: binding(key))
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button(savedKey == key ? "Saved ✓" : "Save") {
                    PluginManager.shared.setConfig(
                        pluginId: plugin.id, key: field.id, value: values[key] ?? "")
                    savedKey = key
                }
                .disabled(savedKey == key)
            }
            if let urlString = field.url, let url = URL(string: urlString) {
                Link("Where to get this →", destination: url)
                    .font(.caption).foregroundColor(theme.accentColor)
            }
        }
    }

    private func storeKey(_ pluginId: String, _ fieldId: String) -> String {
        "\(pluginId)\u{1}\(fieldId)"
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: {
                values[key] = $0
                if savedKey == key { savedKey = nil }  // re-enable Save on edit
            }
        )
    }

    private func load() {
        plugins = PluginManager.shared.configurablePlugins()
        for plugin in plugins {
            for field in plugin.fields {
                let key = storeKey(plugin.id, field.id)
                values[key] = PluginManager.shared.configValue(pluginId: plugin.id, key: field.id)
            }
        }
    }
}

#endif
