import AppKit
import Foundation

@MainActor
final class OsaurusRouterAccountService: ObservableObject {
    static let shared = OsaurusRouterAccountService()

    @Published private(set) var balance: OsaurusRouterBalanceResponse?
    @Published private(set) var usage: [OsaurusRouterUsageItem] = []
    @Published private(set) var transactions: [OsaurusRouterTransactionItem] = []
    @Published private(set) var nextUsageCursor: String?
    @Published private(set) var isLoadingBalance = false
    @Published private(set) var isLoadingUsage = false
    @Published private(set) var isLoadingTransactions = false
    @Published private(set) var webSettings: OsaurusRouterWebSettingsResponse?
    @Published private(set) var webUsage: [OsaurusRouterWebUsageItem] = []
    @Published private(set) var lastWebBilling: RouterWebBillingSummary?
    @Published private(set) var webSearchNeedsTopUp = false
    @Published private(set) var isCreatingCheckout = false
    @Published var lastError: String?

    /// Bumped (debounced) whenever a billed Router stream settled, so a usage
    /// list that is on screen can refetch `/credits/usage` while hidden
    /// surfaces fetch nothing. Replaces the old per-summary usage fetch,
    /// which issued one signed request per tool round of an agent loop even
    /// with no Credits UI open.
    @Published private(set) var usageRevision = 0

    private let client: OsaurusRouterAPIClient
    // Retained for the lifetime of the singleton so balance refreshes when the
    // user returns from Stripe Checkout.
    private var activationObserver: NSObjectProtocol?
    /// Set when a Checkout session is created; cleared once an observed balance
    /// increase confirms it (or after `maxTopUpConfirmationPolls` fruitless
    /// activation polls — the tab was abandoned). Gates both the
    /// activation-driven balance poll and `balance_topup_succeeded`, so the
    /// Router is only asked on activation while a top-up is actually pending.
    private(set) var awaitingTopUpConfirmation = false
    private var topUpConfirmationPolls = 0
    nonisolated static let maxTopUpConfirmationPolls = 10

    /// Last successful `/credits/balance` fetch (monotonic clock, so sleep
    /// and wall-clock corrections cannot make an old value look fresh) and
    /// the in-flight refresh every concurrent caller shares.
    private var balanceFetchedAt: ContinuousClock.Instant?
    private var balanceRefreshTask: Task<Void, Never>?

    /// Debounce before `usageRevision` moves after a billed stream, so a
    /// tool-heavy turn's burst of summaries becomes one refetch. Injectable
    /// for tests.
    private let usageRevisionDebounce: TimeInterval
    private var usageRevisionTask: Task<Void, Never>?
    nonisolated static let defaultUsageRevisionDebounce: TimeInterval = 5

    /// Eventually-consistent identity gate for the balance path (see
    /// `refreshBalance`; upstream `existsCached()` memo, #1523). Injectable so
    /// tests can run the request contract without a keychain.
    private let identityExists: () -> Bool

    init(
        client: OsaurusRouterAPIClient = .shared,
        usageRevisionDebounce: TimeInterval = OsaurusRouterAccountService.defaultUsageRevisionDebounce,
        observesNotifications: Bool = true,
        identityExists: @escaping () -> Bool = { OsaurusIdentity.existsCached() }
    ) {
        self.client = client
        self.usageRevisionDebounce = usageRevisionDebounce
        self.identityExists = identityExists
        guard observesNotifications else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleAppActivation()
            }
        }
    }

    /// App regained focus. The only reason to ask the Router here is a
    /// pending Stripe top-up: the redirect grants nothing, the webhook does,
    /// so poll the balance until the increase is visible — bounded, because
    /// an abandoned Checkout tab would otherwise poll on every activation
    /// forever. Every other surface fetches when it is opened.
    func handleAppActivation() async {
        guard OsaurusRouter.isEnabled, awaitingTopUpConfirmation else { return }
        topUpConfirmationPolls += 1
        await refreshBalance()
        if awaitingTopUpConfirmation, topUpConfirmationPolls >= Self.maxTopUpConfirmationPolls {
            awaitingTopUpConfirmation = false
        }
    }

    var formattedBalance: String {
        OsaurusRouter.formatMicroAsCredits(balance?.balanceMicro ?? "0")
    }

    var formattedBalanceValue: String {
        OsaurusRouter.formatMicroAsCreditsValue(balance?.balanceMicro ?? "0")
    }

    var compactFormattedBalance: String {
        OsaurusRouter.formatMicroAsCreditsCompact(balance?.balanceMicro ?? "0")
    }

    /// Current balance in micro-USD (0 when unknown or unparseable).
    var balanceMicroValue: Int64 {
        Int64(balance?.balanceMicro ?? "") ?? 0
    }

    var isFrozen: Bool {
        balance?.frozen == true
    }

    func refreshAll() async {
        guard OsaurusRouter.isEnabled else { return }
        await RemoteProviderManager.shared.connectOsaurusRouterIfPossible()
        await refreshBalance()
        await refreshUsage(reset: true)
        await refreshTransactions(reset: true)
        await refreshWebSettings()
        await refreshWebUsage()
    }

    func clearForDisabledRouter() {
        balanceFetchedAt = nil
        awaitingTopUpConfirmation = false
        balance = nil
        usage = []
        transactions = []
        webSettings = nil
        webUsage = []
        lastWebBilling = nil
        webSearchNeedsTopUp = false
        nextUsageCursor = nil
        lastError = nil
    }

    /// Fetch `/credits/balance`. With `ifOlderThan`, a balance fetched more
    /// recently than that is kept (passive chrome uses this; user-opened
    /// surfaces refresh unconditionally). Concurrent callers share one
    /// in-flight request, so N surfaces mounting at once is one signed
    /// request, not N.
    func refreshBalance(ifOlderThan maxAge: TimeInterval? = nil) async {
        // Master switch off: never hit `/credits/balance`. This also neutralizes
        // the activation path, which calls straight in here.
        guard OsaurusRouter.isEnabled else { return }
        guard identityExists() else {
            balance = nil
            lastError = OsaurusRouterAPIError.noIdentity.localizedDescription
            return
        }
        if let maxAge, balance != nil, let fetchedAt = balanceFetchedAt,
            fetchedAt.duration(to: .now) < .seconds(maxAge)
        {
            return
        }
        if let inFlight = balanceRefreshTask {
            await inFlight.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performBalanceRefresh()
        }
        balanceRefreshTask = task
        await task.value
        if balanceRefreshTask == task { balanceRefreshTask = nil }
    }

    private func performBalanceRefresh() async {
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        do {
            let previousMicro = balanceMicroValue
            let newBalance = try await client.balance()
            balance = newBalance
            balanceFetchedAt = .now
            lastError = nil
            // Best-effort top-up confirmation: a balance increase after we
            // initiated a Checkout (and returned to the app) means the funds
            // landed. Server-side webhook confirmation isn't available client-
            // side, so this stands in — and it never fires on mere sheet
            // dismissal because the balance wouldn't have moved.
            let newMicro = Int64(newBalance.balanceMicro) ?? 0
            if awaitingTopUpConfirmation, newMicro > previousMicro {
                awaitingTopUpConfirmation = false
                // (Intel) upstream FeatureTelemetry analytics omitted.
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshUsage(reset: Bool = true) async {
        guard OsaurusRouter.isEnabled else { return }
        guard OsaurusIdentity.exists() else {
            usage = []
            nextUsageCursor = nil
            lastError = OsaurusRouterAPIError.noIdentity.localizedDescription
            return
        }

        if reset {
            nextUsageCursor = nil
        }
        isLoadingUsage = true
        defer { isLoadingUsage = false }
        do {
            let response = try await client.usage(limit: 50, cursor: reset ? nil : nextUsageCursor)
            usage = reset ? response.data : usage + response.data
            nextUsageCursor = response.nextCursor
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadMoreUsage() async {
        guard nextUsageCursor != nil, !isLoadingUsage else { return }
        await refreshUsage(reset: false)
    }

    func refreshTransactions(reset: Bool = true) async {
        guard OsaurusRouter.isEnabled else { return }
        guard OsaurusIdentity.exists() else {
            transactions = []
            return
        }
        isLoadingTransactions = true
        defer { isLoadingTransactions = false }
        do {
            let response = try await client.transactions(limit: 100, cursor: nil)
            transactions = response.data
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshWebSettings() async {
        guard OsaurusRouter.isEnabled, OsaurusIdentity.existsCached() else { return }
        do { webSettings = try await client.webSettings() }
        catch { if !Self.isWebFeatureUnavailable(error) { lastError = error.localizedDescription } }
    }

    func setWebAutoPay(_ enabled: Bool) async {
        guard OsaurusRouter.isEnabled, OsaurusIdentity.existsCached() else { return }
        do { webSettings = try await client.updateWebSettings(autoPayEnabled: enabled) }
        catch { lastError = error.localizedDescription }
    }

    func refreshWebUsage() async {
        guard OsaurusRouter.isEnabled, OsaurusIdentity.existsCached() else { webUsage = []; return }
        do { webUsage = try await client.webUsage(limit: 50).data }
        catch { if !Self.isWebFeatureUnavailable(error) { lastError = error.localizedDescription } }
    }

    func noteWebBilling(_ summary: RouterWebBillingSummary) {
        lastWebBilling = summary
        webSearchNeedsTopUp = false
        guard summary.billing.lowercased() == "paid" else { return }
        guard let current = balance,
              let currentMicro = Int64(current.balanceMicro),
              let cost = Int64(summary.costMicro), cost > 0 else { return }
        balance = .init(balanceMicro: String(max(0, currentMicro - cost)), frozen: current.frozen)
    }

    func noteWebInsufficientFunds() {
        webSearchNeedsTopUp = true
        Task { await refreshBalance() }
    }

    func noteWebPaidDisabled() {
        guard var current = webSettings else { return }
        current.autoPayEnabled = false
        webSettings = current
    }

    private static func isWebFeatureUnavailable(_ error: Error) -> Bool {
        guard case .server(_, _, let status) = error as? OsaurusRouterAPIError else { return false }
        return status == 404
    }

    func createCheckout(amountMicro: Int = OsaurusRouter.minimumTopUpMicro) async -> URL? {
        guard amountMicro >= OsaurusRouter.minimumTopUpMicro else {
            lastError = OsaurusRouterAPIError.belowMinimumTopUp.localizedDescription
            return nil
        }
        guard OsaurusIdentity.exists() else {
            lastError = OsaurusRouterAPIError.noIdentity.localizedDescription
            return nil
        }

        isCreatingCheckout = true
        defer { isCreatingCheckout = false }
        do {
            let checkout = try await client.checkout(amountMicro: String(amountMicro))
            guard let url = URL(string: checkout.checkoutURL) else {
                throw OsaurusRouterAPIError.invalidResponse
            }
            lastError = nil
            armTopUpConfirmation()
            // (Intel) upstream FeatureTelemetry analytics omitted.
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// A Checkout session exists and is about to open. Arm the confirmation
    /// watcher so activation polls the balance until the increase lands (and
    /// that increase counts as a completed top-up). Internal so tests can
    /// exercise the bounded poll without a Stripe round-trip.
    func armTopUpConfirmation() {
        awaitingTopUpConfirmation = true
        topUpConfirmationPolls = 0
    }

    func noteRouterSummary(_ summary: OsaurusRouterSummaryEvent.Summary) {
        // The usage list, when one is on screen, refetches on the (debounced)
        // revision bump rather than after every summary frame.
        scheduleUsageRevisionBump()
        guard let current = balance, let currentMicro = Int64(current.balanceMicro),
            let costMicro = Int64(summary.costMicro)
        else {
            Task { await refreshBalance() }
            return
        }
        let updated = max(0, currentMicro - costMicro)
        balance = OsaurusRouterBalanceResponse(balanceMicro: String(updated), frozen: current.frozen)
    }

    /// Coalesce a burst of billed summaries (one per tool round) into a
    /// single `usageRevision` increment shortly after the last. Surfaces
    /// showing usage observe the revision; nothing is fetched here.
    private func scheduleUsageRevisionBump() {
        guard usageRevisionTask == nil else { return }
        usageRevisionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.usageRevisionDebounce ?? 0))
            guard let self, !Task.isCancelled else { return }
            self.usageRevisionTask = nil
            self.usageRevision &+= 1
        }
    }

    private var missingSummaryReconcileTask: Task<Void, Never>?
    /// Debounce before reconciling after a Router stream that ended without
    /// its summary frame (a burst of aborted rounds becomes one refresh).
    nonisolated static let missingSummaryReconcileDelay: TimeInterval = 3

    /// A Router stream ended (mid-stream error, user cancel, truncation)
    /// without its summary frame. The server may still have charged for the
    /// partial generation, and the optimistic local decrement
    /// (`noteRouterSummary`) never ran, so the cached balance can drift from
    /// server truth. Schedule a debounced balance refresh as reconciliation
    /// (the server is authoritative) and bump the usage revision so an open
    /// usage list catches up too. (Upstream.)
    func reconcileAfterStreamWithoutSummary() {
        guard OsaurusRouter.isEnabled else { return }
        scheduleUsageRevisionBump()
        missingSummaryReconcileTask?.cancel()
        missingSummaryReconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.missingSummaryReconcileDelay))
            guard !Task.isCancelled else { return }
            await self?.refreshBalance()
        }
    }
}
