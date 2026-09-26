//
//  IntelThemedControls.swift
//  osaurus
//
//  Explicitly themed stand-ins for native SwiftUI controls that Ventura
//  renders blank or white-on-white on Rosy: segmented pickers, bordered
//  buttons, menu pickers, and switch/checkbox toggles. Every glyph here
//  draws with a theme colour, so nothing depends on AppKit picking the
//  right appearance before first interaction. `IntelVenturaControlGuardTests`
//  keeps the native segmented and bordered styles out of compiled views.
//

import SwiftUI

// MARK: - Segmented picker

/// Replacement for `Picker` + `.pickerStyle(.segmented)`.
struct ThemedSegmentedPicker<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var fontSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                segment(option.value, title: option.title)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func segment(_ value: Value, title: String) -> some View {
        let isSelected = value == selection
        return Button {
            selection = value
        } label: {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: fontSize, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? theme.accentColor.opacity(0.14) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? theme.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Menu picker

/// Replacement for a menu-style `Picker`: a `Menu` with a themed label, the
/// pattern the Memory console already proved on Rosy. Options with an empty
/// title render as a divider.
struct ThemedMenuPicker<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var width: CGFloat? = nil
    /// Optional per-option font for the menu rows and the label (font pickers).
    var font: ((Value) -> Font?)? = nil

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                if option.title.isEmpty {
                    Divider()
                } else {
                    Button {
                        selection = option.value
                    } label: {
                        if option.value == selection {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedTitle)
                    .font(font?(selection) ?? .system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var selectedTitle: String {
        options.first(where: { $0.value == selection && !$0.title.isEmpty })?.title ?? ""
    }
}

// MARK: - Toggles

/// Replacement for `.toggleStyle(.switch)`. Keeps its colours when the window
/// is inactive; Ventura's native switch fades to near-invisible there.
struct ThemedSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ThemedSwitchBody(configuration: configuration)
    }

    private struct ThemedSwitchBody: View {
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            HStack(spacing: 8) {
                configuration.label
                    .foregroundColor(theme.primaryText)
                Button {
                    configuration.isOn.toggle()
                } label: {
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule()
                            .fill(configuration.isOn ? theme.accentColor : theme.tertiaryBackground)
                            .overlay(
                                Capsule().stroke(
                                    configuration.isOn ? theme.accentColor : theme.inputBorder,
                                    lineWidth: 1
                                )
                            )
                        Circle()
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.2), radius: 1, y: 0.5)
                            .padding(2)
                    }
                    .frame(width: 32, height: 18)
                    .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(configuration.isOn ? "On" : "Off", bundle: .module))
            }
            .opacity(isEnabled ? 1 : 0.5)
        }
    }
}

/// Replacement for a native checkbox `Toggle` whose label Ventura draws white.
struct ThemedCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ThemedCheckboxBody(configuration: configuration)
    }

    private struct ThemedCheckboxBody: View {
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(configuration.isOn ? theme.accentColor : theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(configuration.isOn ? theme.accentColor : theme.inputBorder, lineWidth: 1)
                            )
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 15, height: 15)
                    configuration.label
                        .foregroundColor(theme.primaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(configuration.isOn ? "On" : "Off", bundle: .module))
            .opacity(isEnabled ? 1 : 0.5)
        }
    }
}

// MARK: - Bordered buttons

/// Replacement for `.buttonStyle(.bordered)` / `.borderedProminent`, whose
/// labels Ventura renders white on the light Settings paper.
struct ThemedBorderedButtonStyle: ButtonStyle {
    var prominent: Bool = false
    /// Stands in for the old `.tint(.red)` on destructive bordered buttons.
    var destructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        ThemedBorderedButtonBody(
            configuration: configuration, prominent: prominent, destructive: destructive)
    }

    private struct ThemedBorderedButtonBody: View {
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        let configuration: Configuration
        let prominent: Bool
        let destructive: Bool

        var body: some View {
            let isSmall = controlSize == .small || controlSize == .mini
            let isDestructive = destructive || configuration.role == .destructive
            configuration.label
                .font(.system(size: isSmall ? 11 : 13, weight: .medium))
                .foregroundColor(foreground(isDestructive: isDestructive))
                .padding(.horizontal, isSmall ? 8 : 12)
                .padding(.vertical, isSmall ? 3 : 6)
                .background(
                    RoundedRectangle(cornerRadius: isSmall ? 6 : 7)
                        .fill(background(isDestructive: isDestructive))
                        .overlay(
                            RoundedRectangle(cornerRadius: isSmall ? 6 : 7)
                                .stroke(prominent ? Color.clear : theme.buttonBorder, lineWidth: 1)
                        )
                )
                .opacity(configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.5))
                .contentShape(Rectangle())
        }

        private func foreground(isDestructive: Bool) -> Color {
            if prominent { return .white }
            return isDestructive ? theme.errorColor : theme.primaryText
        }

        private func background(isDestructive: Bool) -> Color {
            if prominent { return isDestructive ? theme.errorColor : theme.accentColor }
            return theme.buttonBackground
        }
    }
}
