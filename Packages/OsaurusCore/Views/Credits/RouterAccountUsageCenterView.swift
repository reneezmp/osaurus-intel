import SwiftUI

struct RouterAccountUsageCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject private var account = OsaurusRouterAccountService.shared

    private var snapshot: RouterAccountUsageSnapshot {
        RouterAccountUsageCenter.snapshot(usage: account.usage, transactions: account.transactions)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Account details", bundle: .module)
                        .font(.system(size: 20, weight: .bold))
                    Text("Router usage and wallet movement loaded from your account.", bundle: .module)
                        .font(.system(size: 12)).foregroundColor(theme.secondaryText)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 12) {
                        metric("Requests", String(snapshot.requestCount))
                        metric("Input tokens", snapshot.inputTokens.formatted())
                        // Shown only once the router reports cache hits, so a
                        // pre-cache router keeps the original metrics.
                        if let cached = OsaurusRouter.formatCachedInputLabel(
                            cachedTokens: snapshot.cachedInputTokens,
                            inputTokens: snapshot.inputTokens
                        ) {
                            metric("Cached input", cached)
                        }
                        metric("Output tokens", snapshot.outputTokens.formatted())
                        metric("Usage cost", OsaurusRouter.formatMicroAsCredits(String(snapshot.spentMicro)))
                        metric("Credits added", OsaurusRouter.formatMicroAsCredits(String(snapshot.creditedMicro)))
                        metric("Wallet net", signedCredits(snapshot.netTransactionMicro))
                    }

                    section("Recent Router usage") {
                        if account.usage.isEmpty { empty("No usage loaded.") }
                        else { ForEach(account.usage.prefix(50)) { usageRow($0) } }
                    }

                    section("Wallet activity") {
                        if account.transactions.isEmpty { empty("No wallet activity loaded.") }
                        else { ForEach(account.transactions.prefix(50)) { transactionRow($0) } }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 760, minHeight: 580)
        .background(theme.primaryBackground)
        .task { await account.refreshAll() }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.secondaryText)
            Text(verbatim: value).font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(1)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder))
        }
    }

    private func usageTokenLine(_ item: OsaurusRouterUsageItem) -> String {
        var line = "\(item.inputTokens.formatted()) in · \(item.outputTokens.formatted()) out"
        if let cached = OsaurusRouter.formatCachedInputLabel(cachedTokens: item.cachedInputTokens) {
            line += " · \(cached)"
        }
        return line
    }

    private func usageRow(_ item: OsaurusRouterUsageItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.model).font(.system(size: 12, weight: .semibold))
                Text(verbatim: usageTokenLine(item))
                    .font(.system(size: 11)).foregroundColor(theme.secondaryText)
            }
            Spacer()
            Text(verbatim: "-" + OsaurusRouter.formatMicroAsCredits(item.costMicro))
                .font(.system(size: 12, design: .monospaced))
        }.padding(12)
    }

    private func transactionRow(_ item: OsaurusRouterTransactionItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.entryType).font(.system(size: 12, weight: .semibold))
                Text(verbatim: item.createdAt).font(.system(size: 11)).foregroundColor(theme.secondaryText)
            }
            Spacer()
            Text(verbatim: signedCredits(Int64(item.amountMicro) ?? 0))
                .font(.system(size: 12, design: .monospaced))
        }.padding(12)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(theme.secondaryText)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func signedCredits(_ micro: Int64) -> String {
        let value = OsaurusRouter.formatMicroAsCredits(String(micro))
        return micro > 0 ? "+" + value : value
    }
}
