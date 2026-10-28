//
//  MediaComposerChips.swift
//  osaurus
//
//  Upstream's `catalogMediaComposerChips` (FloatingInputCard) as one view
//  for Intel's composer (`W-media-generation`): the options a selected
//  Osaurus Cloud or Venice image/video model advertises, in the selector row
//  where the chat chips normally sit. Only the catalog (cloud) branch:
//  upstream's local MLX controls (sampler, strength, bundle sizes) are not
//  on Intel. The negative prompt opens in a popover instead of upstream's
//  alert accessory.
//

import SwiftUI

struct MediaComposerChips: View {
    let media: MediaModelInfo
    @Binding var settings: ImageComposerSettings
    /// Image attachments currently in the composer (image-to-video needs one).
    let sourceImageCount: Int

    @Environment(\.theme) private var theme
    @State private var showNegativePrompt = false

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                chips.padding(.vertical, 2)
            }
            negativePromptButton
        }
    }

    // MARK: - Chips (upstream order)

    private var chips: some View {
        HStack(spacing: 6) {
            if media.kind == .image,
                media.constraints.aspectRatios.isEmpty,
                media.constraints.resolutions.isEmpty
            {
                sizeChip
            }
            if !media.constraints.aspectRatios.isEmpty {
                choiceChip(
                    title: L("Aspect"), icon: "aspectratio",
                    options: media.constraints.aspectRatios,
                    selection: $settings.aspectRatio)
            }
            if !media.constraints.resolutions.isEmpty {
                choiceChip(
                    title: L("Resolution"), icon: "rectangle.inset.filled",
                    options: media.constraints.resolutions,
                    selection: $settings.resolution)
            }
            if !media.constraints.qualities.isEmpty {
                choiceChip(
                    title: L("Quality"), icon: "sparkles",
                    options: media.constraints.qualities,
                    selection: $settings.quality)
            }
            if media.kind.isVideo, !media.constraints.durations.isEmpty {
                choiceChip(
                    title: L("Duration"), icon: "clock",
                    options: media.constraints.durations,
                    selection: $settings.duration)
            }
            if media.kind.isVideo, media.constraints.audioConfigurable {
                audioChip
            }
            if media.kind == .image {
                if media.constraints.defaultSteps != nil || media.constraints.maxSteps != nil {
                    stepsChip
                }
                cfgChip
                seedChip
                choiceChip(
                    title: L("Format"), icon: "doc",
                    options: ImageOutputFormat.allCases.map(\.rawValue),
                    selection: Binding(
                        get: { Optional(settings.effectiveOutputFormat.rawValue) },
                        set: { settings.outputFormat = $0.flatMap { ImageOutputFormat(rawValue: $0) } }
                    ))
                choiceChip(
                    title: L("Count"), icon: "square.stack.3d.up",
                    options: (1 ... 4).map(String.init),
                    selection: Binding(
                        get: { Optional(String(settings.clampedImageCount)) },
                        set: { settings.imageCount = $0.flatMap { Int($0) } }
                    ))
            }
            if let minimum = media.pricing?.minimumUSD {
                Text(verbatim: "From \(OsaurusRouter.formatUSDAsCredits(minimum))")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(chipBackground)
            }
            if media.kind == .imageToVideo {
                Label(L("1 source image"), systemImage: "photo")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(sourceImageCount == 1 ? theme.secondaryText : Color.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(chipBackground)
            }
        }
    }

    private func choiceChip(
        title: String,
        icon: String,
        options: [String],
        selection: Binding<String?>
    ) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    if selection.wrappedValue == option {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .foregroundColor(theme.tertiaryText)
                Text(selection.wrappedValue ?? title)
                    .foregroundColor(theme.secondaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 3, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(chipBackground)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(verbatim: title))
    }

    /// Upstream's size presets for a catalog model without aspect ratios or
    /// resolutions, as a menu (upstream uses a popover with descriptions).
    private var sizeChip: some View {
        let sizes: [(Int, Int)] = [(512, 512), (768, 768), (1024, 1024), (1280, 720), (720, 1280)]
        let label = settings.width == settings.height
            ? "\(settings.width)px" : "\(settings.width)×\(settings.height)"
        return choiceChip(
            title: label, icon: "aspectratio",
            options: sizes.map { "\($0.0) × \($0.1)" },
            selection: Binding(
                get: { "\(settings.width) × \(settings.height)" },
                set: { value in
                    guard let value,
                        let size = sizes.first(where: { "\($0.0) × \($0.1)" == value })
                    else { return }
                    settings.width = size.0
                    settings.height = size.1
                }
            ))
    }

    private var stepsChip: some View {
        let maximum = media.constraints.maxSteps ?? 50
        return HStack(spacing: 6) {
            stepperButton("minus") { settings.steps = max(1, settings.steps - 1) }
            HStack(spacing: 3) {
                Text("\(settings.steps)")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .monospacedDigit()
                Text("steps", bundle: .module)
                    .fixedSize()
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            stepperButton("plus") { settings.steps = min(maximum, settings.steps + 1) }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(chipBackground)
        .localizedHelp("Denoising steps")
    }

    private var cfgChip: some View {
        HStack(spacing: 5) {
            Text("CFG", bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            TextField("", value: $settings.guidance, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 28)
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(chipBackground)
        .localizedHelp("Classifier-free guidance")
    }

    /// Upstream: remote media keeps a digits-only seed.
    private var seedChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "number")
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            TextField(
                "Seed",
                text: Binding(get: { settings.seed }, set: { settings.seed = $0.filter(\.isNumber) })
            )
            .textFieldStyle(.plain)
            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
            .foregroundColor(theme.primaryText)
            .fixedSize()
            .frame(minWidth: 34)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(chipBackground)
        .localizedHelp("Optional numeric seed")
    }

    private var audioChip: some View {
        Button {
            settings.audio = !(settings.audio ?? media.constraints.supportsAudio)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: settings.audio == true ? "speaker.wave.2.fill" : "speaker.slash.fill")
                Text(settings.audio == true ? L("Audio") : L("Muted"))
            }
            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(chipBackground)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var negativePromptButton: some View {
        let value = settings.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValue = !value.isEmpty
        return Button {
            showNegativePrompt = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: hasValue ? "minus.circle.fill" : "minus.circle")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                    .foregroundColor(hasValue ? theme.accentColor : theme.tertiaryText)
                Text(hasValue ? value : L("Add a negative prompt"))
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: hasValue ? .medium : .regular))
                    .foregroundColor(hasValue ? theme.secondaryText : theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(chipBackground)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .localizedHelp("Terms to avoid during generation")
        .popover(isPresented: $showNegativePrompt, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Negative prompt", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                TextField(
                    text: $settings.negativePrompt,
                    prompt: Text("e.g. blurry, low quality, extra fingers", bundle: .module),
                    axis: .vertical
                ) {
                    Text("Negative prompt", bundle: .module)
                }
                .textFieldStyle(.plain)
                .lineLimit(3, reservesSpace: true)
                .font(theme.font(size: CGFloat(theme.bodySize)))
                .foregroundColor(theme.primaryText)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.secondaryBackground.opacity(0.6))
                )
            }
            .padding(12)
            .frame(width: 280)
            .environment(\.theme, theme)
        }
    }

    private func stepperButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var chipBackground: some View {
        Capsule()
            .fill(theme.secondaryBackground.opacity(0.6))
            .overlay(Capsule().strokeBorder(theme.primaryBorder.opacity(0.4), lineWidth: 0.5))
    }
}
