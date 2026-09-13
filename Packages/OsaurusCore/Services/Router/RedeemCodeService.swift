import Foundation

@MainActor
final class RedeemCodeService: ObservableObject {
    enum State: Equatable {
        case idle
        case submitting
        case success(OsaurusRouterRedeemCodeResponse)
        case failure(String)
    }

    @Published var code = ""
    @Published private(set) var state: State = .idle

    private let redeem: @Sendable (String) async throws -> OsaurusRouterRedeemCodeResponse
    private let refreshBalance: @MainActor () async -> Void

    init(
        redeem: @escaping @Sendable (String) async throws -> OsaurusRouterRedeemCodeResponse = {
            try await OsaurusRouterAPIClient.shared.redeemCode($0)
        },
        refreshBalance: @escaping @MainActor () async -> Void = {
            await OsaurusRouterAccountService.shared.refreshBalance()
        }
    ) {
        self.redeem = redeem
        self.refreshBalance = refreshBalance
    }

    var normalizedCode: String {
        String(code.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
    }

    var canSubmit: Bool {
        !normalizedCode.isEmpty && state != .submitting
    }

    var isSubmitting: Bool { state == .submitting }

    func submit() async {
        let submitted = normalizedCode
        guard !submitted.isEmpty else {
            state = .failure(L("Enter a redeemable code."))
            return
        }
        guard state != .submitting else { return }
        guard OsaurusRouter.isEnabled else {
            state = .failure(L("Turn on Osaurus Router before redeeming a code."))
            return
        }
        guard OsaurusIdentity.exists() else {
            state = .failure(L("Set up your Osaurus Identity before redeeming a code."))
            return
        }

        code = submitted
        state = .submitting
        do {
            let raw = try await redeem(submitted)
            guard raw.redeemed else { throw OsaurusRouterAPIError.invalidResponse }
            let safe = Self.presentationSafe(raw)
            if Int64(safe.amountMicro) != 0 { await refreshBalance() }
            state = .success(safe)
        } catch let error as OsaurusRouterAPIError {
            state = .failure(Self.message(for: error))
        } catch {
            state = .failure(L("We couldn’t redeem this code. Check your connection and try again."))
        }
    }

    static func presentationSafe(_ raw: OsaurusRouterRedeemCodeResponse) -> OsaurusRouterRedeemCodeResponse {
        OsaurusRouterRedeemCodeResponse(
                redeemed: raw.redeemed,
                alreadyRedeemed: raw.alreadyRedeemed,
                campaignKind: raw.campaignKind,
                amountMicro: raw.amountMicro,
                referralPending: raw.referralPending,
                redemptionMessage: String(raw.redemptionMessage.prefix(500))
            )
    }

    func noteCodeEdited() {
        if case .failure = state { state = .idle }
    }

    func reset() {
        guard !isSubmitting else { return }
        code = ""
        state = .idle
    }

    private static func message(for error: OsaurusRouterAPIError) -> String {
        switch error {
        case .rateLimited:
            return L("Too many attempts. Please wait before trying again.")
        case .server(_, _, let status) where status == 400:
            return L("Check the code and try again.")
        case .server(_, _, let status) where status == 403:
            return L("This code isn’t available for this account.")
        case .accountFrozen:
            return L("This code isn’t available for this account.")
        case .server(_, _, let status) where status >= 500:
            return L("The redeem service is temporarily unavailable. Please try again.")
        case .unauthorized:
            return L("We couldn’t verify your identity. Please try again.")
        case .transport:
            return L("We couldn’t redeem this code. Check your connection and try again.")
        case .noIdentity:
            return L("Set up your Osaurus Identity before redeeming a code.")
        case .invalidResponse:
            return L("The redeem service returned an invalid response. Please try again.")
        case .invalidURL, .server, .belowMinimumTopUp, .insufficientFunds,
            .paidWebDisabled, .idempotencyConflict:
            return error.localizedDescription
        }
    }
}
