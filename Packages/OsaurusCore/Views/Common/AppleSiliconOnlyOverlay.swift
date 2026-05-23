//
//  AppleSiliconOnlyOverlay.swift
//  OsaurusCore
//
//  Intel fork — reusable overlay for amputated features.
//

import SwiftUI

/// A translucent overlay shown over amputated feature sections on Intel builds.
/// Displays an icon, headline, and caption explaining the feature requires Apple Silicon.
public struct AppleSiliconOnlyOverlay: View {
    let headline: String
    let caption: String
    var onDismiss: (() -> Void)?

    public init(headline: String, caption: String, onDismiss: (() -> Void)? = nil) {
        self.headline = headline
        self.caption = caption
        self.onDismiss = onDismiss
    }

    public var body: some View {
        if OsaurusBuild.isIntel {
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 12) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)

                    Text(verbatim: headline)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Text(verbatim: caption)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tertiary)

                    if let onDismiss {
                        Button("Dismiss") { onDismiss() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                .padding(24)
            }
        } else {
            // On Apple Silicon, render nothing — content passes through.
            EmptyView()
        }
    }
}

/// A view modifier that applies the Apple Silicon overlay when on Intel.
public struct AppleSiliconOnlyModifier: ViewModifier {
    let headline: String
    let caption: String

    public func body(content: Content) -> some View {
        if OsaurusBuild.isIntel {
            content
                .disabled(true)
                .opacity(0.25)
                .overlay(AppleSiliconOnlyOverlay(headline: headline, caption: caption))
        } else {
            content
        }
    }
}

public extension View {
    func appleSiliconOnly(headline: String, caption: String) -> some View {
        modifier(AppleSiliconOnlyModifier(headline: headline, caption: caption))
    }
}
