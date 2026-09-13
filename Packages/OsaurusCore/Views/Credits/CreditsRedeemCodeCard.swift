import SwiftUI

struct CreditsRedeemCodeCard: View {
    let isEnabled: Bool
    @Environment(\.theme) private var theme
    @StateObject private var redemption = RedeemCodeService()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Have a code?", bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Enter it below and we’ll take it from here.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Text("Optional", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }

            if case .success(let response) = redemption.state {
                success(response)
            } else {
                entry
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Enter your code", text: $redemption.code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .focused($focused)
                    .disabled(!isEnabled || redemption.isSubmitting)
                    .onChange(of: redemption.code) { _ in redemption.noteCodeEdited() }
                    .onSubmit { submit() }
                Button { submit() } label: {
                    if redemption.isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Redeem", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isEnabled || !redemption.canSubmit)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.inputBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? theme.accentColor : theme.inputBorder))

            if !isEnabled {
                Text("Turn on Router and set up Identity to redeem codes.", bundle: .module)
                    .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
            } else if case .failure(let message) = redemption.state {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12)).foregroundColor(theme.errorColor)
            }
        }
    }

    private func success(_ response: OsaurusRouterRedeemCodeResponse) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(theme.successColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(response.alreadyRedeemed ? "Code already redeemed" : "Code redeemed", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                Text(verbatim: response.redemptionMessage)
                    .font(.system(size: 12)).foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button("Redeem another code") { redemption.reset(); focused = true }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func submit() {
        guard isEnabled, redemption.canSubmit else { return }
        focused = false
        Task { await redemption.submit() }
    }
}
