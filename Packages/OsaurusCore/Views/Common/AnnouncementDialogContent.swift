//
//  AnnouncementDialogContent.swift
//  osaurus
//
//  Body of a router-served announcement dialog (see `AnnouncementsService`
//  and `AppDelegate.presentAnnouncementIfEligible`): an optional hosted
//  header image followed by the operator-authored Markdown body rendered
//  with the chat engine (`MarkdownDocument`). Slots into a
//  `ThemedAlertRequest.accessory` so the title header, button row and
//  dismissal chrome stay the standard alert ones.
//
//  Intel: a banner above the content says the announcement comes from the
//  upstream Osaurus project, not Osaurus Intel, and that what it promotes
//  may need an Apple Silicon Mac or a newer macOS and may be missing here.
//

import SwiftUI

struct AnnouncementDialogContent: View {
    let body_: String
    let imageURL: URL?

    @Environment(\.theme) private var theme

    init(body: String, imageURL: URL?) {
        self.body_ = body
        self.imageURL = imageURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            UpstreamAnnouncementNotice()

            if let imageURL {
                // Loaded asynchronously; the dialog shows without it on
                // failure (the contract says never block on the image).
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    case .empty:
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.tertiaryBackground.opacity(0.4))
                            .frame(height: 120)
                            .overlay(ProgressView().controlSize(.small))
                    default:
                        EmptyView()
                    }
                }
            }

            // Operators keep bodies to a few short paragraphs; cap the
            // height anyway so a long one scrolls instead of growing the
            // dialog past the screen.
            ScrollView(.vertical, showsIndicators: true) {
                MarkdownDocument(text: body_)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

/// Intel: who this announcement is from, and what that means here.
struct UpstreamAnnouncementNotice: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.warningColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("From the upstream Osaurus project, not Osaurus Intel", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Upstream writes these for Osaurus on Apple Silicon Macs. Features, models and offers it mentions may need an Apple Silicon Mac or a newer macOS, and may not exist in Osaurus Intel. Links open upstream's pages.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.warningColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.warningColor.opacity(0.35), lineWidth: 1)
        )
    }
}
