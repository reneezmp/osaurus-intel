//
//  CreditsWelcomeClaimCard.swift
//  osaurus
//
//  Intel (2026-10-10, `W-credits-ui-sync`): the Router's one-time welcome
//  credit, claimed only when the user presses Claim. Upstream claims it
//  automatically at launch / activation / identity setup; Intel keeps Router
//  actions consent-first (docs/CREDITS_ROUTER_INTEL_PLAN.md). The claim
//  itself is upstream's `WelcomeCreditService.claimIfNeeded()`. The card
//  hides once the claim settles (granted, already used by a code, or refused
//  by the Router).
//

import SwiftUI

struct CreditsWelcomeClaimCard: View {
    let isEnabled: Bool

    @Environment(\.theme) private var theme
    @State private var resolution = WelcomeCreditService.shared.resolution
    @State private var isClaiming = false
    @State private var failureMessage: String?

    var body: some View {
        if resolution == nil {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "gift.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(theme.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome credit", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "New to Osaurus credits? Claim the one-time welcome credit. This sends a hashed ID of this Mac, so it can be claimed once per Mac.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                if let failureMessage {
                    Label {
                        Text(failureMessage)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(theme.errorColor)
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await claim() }
            } label: {
                if isClaiming {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Claim", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(ThemedBorderedButtonStyle(prominent: true))
            .disabled(!isEnabled || isClaiming)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
    }

    @MainActor
    private func claim() async {
        isClaiming = true
        failureMessage = nil
        let service = WelcomeCreditService.shared
        let settled = await service.claimIfNeeded()
        isClaiming = false
        resolution = service.resolution
        guard !settled, resolution == nil else { return }
        failureMessage =
            service.retryNotBefore != nil
            ? L("Too many attempts. Try again in a few minutes.")
            : L("The welcome credit couldn’t be claimed right now. Check your connection and try again.")
    }
}
