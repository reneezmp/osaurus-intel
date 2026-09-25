import Foundation

enum OsaurusRouter {
    static let productionBaseURL = URL(string: "https://router.osaurus.ai")!
    static let stagingBaseURL = URL(string: "https://osaurus-router.fly.dev")!

    static var defaultBaseURL: URL {
        #if DEBUG
            if let override = UserDefaults.standard.string(forKey: "ai.osaurus.router.baseURL"),
                let url = URL(string: override.trimmingCharacters(in: .whitespacesAndNewlines)),
                url.scheme != nil,
                url.host != nil
            {
                return url
            }
        #endif
        return productionBaseURL
    }

    static let enabledDefaultsKey = "ai.osaurus.router.enabled"

    /// The Router is available by default; only an explicit user opt-out turns
    /// it off. Tests can pass an isolated defaults suite without touching the
    /// user's live preference.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    static var isEnabled: Bool { isEnabled() }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledDefaultsKey)
    }

    static let minimumTopUpMicro = 5_000_000
    static let microPerCredit: Int64 = 100

    /// Parse a positive dollar amount into whole micro-USD without allowing a
    /// floating-point conversion to overflow `Int`.
    static func parseMicroUSD(_ rawValue: String) -> Int? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.hasPrefix("$") ? String(trimmed.dropFirst()) : trimmed
        guard let dollars = Double(cleaned), dollars.isFinite, dollars > 0 else { return nil }
        let micro = (dollars * 1_000_000).rounded()
        guard micro <= Double(Int.max) else { return nil }
        return Int(micro)
    }

    static func formatMicroUSD(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNegative = trimmed.hasPrefix("-")
        let unsigned = String(trimmed.drop { $0 == "-" || $0 == "+" })
        guard let micro = Int64(unsigned) else { return "$0.00" }

        let dollars = micro / 1_000_000
        let cents = (micro % 1_000_000) / 10_000
        let sign = isNegative ? "-" : ""
        return "\(sign)$\(dollars).\(String(format: "%02d", cents))"
    }

    /// Like `formatMicroUSD` but keeps sub-cent precision so tiny per-request
    /// charges don't all collapse to "$0.00". Two decimals at or above one cent,
    /// four decimals below it, and "<$0.0001" for a non-zero amount smaller than
    /// that. Intended for per-row cost display, not the headline balance.
    static func formatMicroUSDPrecise(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNegative = trimmed.hasPrefix("-")
        let unsigned = String(trimmed.drop { $0 == "-" || $0 == "+" })
        guard let micro = Int64(unsigned), micro != 0 else { return "$0.00" }

        let sign = isNegative ? "-" : ""
        let dollars = Double(micro) / 1_000_000.0
        if micro >= 10_000 {
            return "\(sign)$\(String(format: "%.2f", dollars))"
        }
        if micro < 100 {
            return "\(sign)<$0.0001"
        }
        return "\(sign)$\(String(format: "%.4f", dollars))"
    }

    static func formatMicroAsCredits(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNegative = trimmed.hasPrefix("-")
        let unsigned = String(trimmed.drop { $0 == "-" || $0 == "+" })
        guard let micro = Int64(unsigned), micro != 0 else { return "0 credits" }
        let sign = isNegative ? "-" : ""
        let credits = micro / microPerCredit
        let residue = micro % microPerCredit
        guard credits != 0 else { return "\(sign)<1 credit" }
        var value = groupedThousands(credits)
        if residue != 0 { value += ".\(String(format: "%02d", residue))" }
        let unit = credits == 1 && residue == 0 ? "credit" : "credits"
        return "\(sign)\(value) \(unit)"
    }

    static func formatMicroAsCreditsValue(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNegative = trimmed.hasPrefix("-")
        let unsigned = String(trimmed.drop { $0 == "-" || $0 == "+" })
        guard let micro = Int64(unsigned), micro != 0 else { return "0" }
        let sign = isNegative ? "-" : ""
        let credits = micro / microPerCredit
        return credits == 0 ? "\(sign)<1" : "\(sign)\(groupedThousands(credits))"
    }

    static func formatMicroAsCreditsCompact(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNegative = trimmed.hasPrefix("-")
        let unsigned = String(trimmed.drop { $0 == "-" || $0 == "+" })
        guard let micro = Int64(unsigned), micro != 0 else { return "0 credits" }
        let sign = isNegative ? "-" : ""
        let credits = micro / microPerCredit
        guard credits != 0 else { return "\(sign)<1 credit" }
        if credits < 10_000 {
            return "\(sign)\(groupedThousands(credits)) \(credits == 1 ? "credit" : "credits")"
        }
        let millions = credits >= 999_950
        let scaled = millions ? Double(credits) / 1_000_000 : Double(credits) / 1_000
        var figure = String(format: millions ? "%.2f" : "%.1f", scaled)
        while figure.contains("."), figure.hasSuffix("0") { figure.removeLast() }
        if figure.hasSuffix(".") { figure.removeLast() }
        return "\(sign)\(figure)\(millions ? "M" : "K") credits"
    }

    /// "N cached" label for the router's prompt-cache split (upstream
    /// 9b3336d68). `nil` when nothing was cached, so callers can hide the
    /// label instead of rendering "0 cached". Pass `inputTokens` to append the
    /// hit ratio; it is omitted when the total is unknown, zero, or smaller
    /// than the cached count.
    static func formatCachedInputLabel(cachedTokens: Int, inputTokens: Int? = nil) -> String? {
        guard cachedTokens > 0 else { return nil }
        var label = "\(groupedThousands(Int64(cachedTokens))) cached"
        if let inputTokens, inputTokens > 0, cachedTokens <= inputTokens {
            let percent = Int((Double(cachedTokens) / Double(inputTokens) * 100).rounded())
            label += " · \(percent)%"
        }
        return label
    }

    private static func groupedThousands(_ value: Int64) -> String {
        var grouped: [Character] = []
        for (offset, character) in String(value).reversed().enumerated() {
            if offset != 0, offset.isMultiple(of: 3) { grouped.append(",") }
            grouped.append(character)
        }
        return String(grouped.reversed())
    }

    /// True when a chat/stream error string indicates the router rejected the
    /// request for lack of credits (HTTP 402 `INSUFFICIENT_FUNDS`). The
    /// streaming path surfaces the raw server body inside a
    /// `RemoteProviderServiceError.requestFailed("HTTP 402: {json}")` string,
    /// so match the stable server error code rather than a localized message.
    static func isInsufficientFundsError(_ message: String) -> Bool {
        message.range(of: "INSUFFICIENT_FUNDS", options: .caseInsensitive) != nil
    }
}

struct OsaurusRouterErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
    }

    let error: Body
}

enum OsaurusRouterAPIError: LocalizedError, Sendable {
    case noIdentity
    case invalidURL
    case invalidResponse
    case transport(String)
    case server(code: String, message: String, status: Int)
    case belowMinimumTopUp
    case insufficientFunds
    case accountFrozen
    case unauthorized
    case rateLimited(retryAfter: String?)
    case paidWebDisabled
    case idempotencyConflict

    var errorDescription: String? {
        switch self {
        case .noIdentity:
            return "Set up your Osaurus Identity before using the router."
        case .invalidURL:
            return "Router URL is invalid."
        case .invalidResponse:
            return "Router returned an invalid response."
        case .transport(let message):
            return message
        case .server(_, let message, _):
            return message
        case .belowMinimumTopUp:
            return "Minimum top-up is $5.00."
        case .insufficientFunds:
            return "Insufficient credits. Add balance to continue."
        case .accountFrozen:
            return "Your Osaurus billing account is on hold."
        case .unauthorized:
            return "Router authentication failed. Check your clock and identity."
        case .rateLimited:
            return "Too many router requests. Please try again in a moment."
        case .paidWebDisabled:
            return "Paid web search is turned off. Remaining search credits still work."
        case .idempotencyConflict:
            return "Duplicate router request detected."
        }
    }

    static func from(code: String, message: String, status: Int, retryAfter: String? = nil) -> OsaurusRouterAPIError {
        switch code {
        case "BELOW_MINIMUM_TOPUP":
            return .belowMinimumTopUp
        case "INSUFFICIENT_FUNDS":
            return .insufficientFunds
        case "ACCOUNT_FROZEN":
            return .accountFrozen
        case "UNAUTHORIZED", "INVALID_SIGNATURE":
            return .unauthorized
        case "RATE_LIMITED":
            return .rateLimited(retryAfter: retryAfter)
        case "PAID_WEB_DISABLED":
            return .paidWebDisabled
        case "IDEMPOTENCY_CONFLICT":
            return .idempotencyConflict
        default:
            return .server(code: code, message: message, status: status)
        }
    }
}

struct OsaurusRouterBalanceResponse: Decodable, Equatable, Sendable {
    let balanceMicro: String
    let frozen: Bool

    enum CodingKeys: String, CodingKey {
        case balanceMicro = "balance_micro"
        case frozen
    }
}

struct OsaurusRouterCheckoutResponse: Decodable, Equatable, Sendable {
    let clientSecret: String
    let checkoutURL: String

    enum CodingKeys: String, CodingKey {
        case clientSecret = "client_secret"
        case checkoutURL = "checkout_url"
    }
}

struct OsaurusRouterRedeemCodeResponse: Decodable, Equatable, Sendable {
    let redeemed: Bool
    let alreadyRedeemed: Bool
    let campaignKind: String
    let amountMicro: String
    let referralPending: Bool
    let redemptionMessage: String

    enum CodingKeys: String, CodingKey {
        case redeemed
        case alreadyRedeemed = "already_redeemed"
        case campaignKind = "campaign_kind"
        case amountMicro = "amount_micro"
        case referralPending = "referral_pending"
        case redemptionMessage = "redemption_message"
    }
}

struct OsaurusRouterModelListResponse: Decodable, Sendable {
    let data: [OsaurusRouterModel]
}

struct OsaurusRouterModelDiscovery: Equatable, Sendable {
    let models: [String]
    let totalCount: Int
    let staleCount: Int
    /// Full per-model metadata for the fresh (non-stale) models, keyed by the
    /// unprefixed model id (matching `models`). Lets the picker show provider,
    /// pricing, and context without re-fetching `/models`.
    let catalog: [String: OsaurusRouterModel]

    init(
        models: [String],
        totalCount: Int,
        staleCount: Int,
        catalog: [String: OsaurusRouterModel] = [:]
    ) {
        self.models = models
        self.totalCount = totalCount
        self.staleCount = staleCount
        self.catalog = catalog
    }
}

struct OsaurusRouterModel: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let provider: String
    let contextLength: Int
    let inputMicroPerMTok: String
    let outputMicroPerMTok: String
    let inputDisplay: String
    let outputDisplay: String
    let inputCreditsDisplay: String?
    let outputCreditsDisplay: String?
    let stale: Bool
    let capabilities: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case id, provider, capabilities, stale
        case contextLength = "context_length"
        case inputMicroPerMTok = "input_micro_per_mtok"
        case outputMicroPerMTok = "output_micro_per_mtok"
        case inputDisplay = "input_display"
        case outputDisplay = "output_display"
        case inputCreditsDisplay = "input_credits_display"
        case outputCreditsDisplay = "output_credits_display"
    }
}

extension OsaurusRouterModel {
    /// Compact one-line summary for the model picker: underlying provider,
    /// input/output price, and context window. e.g.
    /// "venice · $2.00/M in · $4.00/M out · 131K ctx".
    var pickerDescription: String? {
        var parts: [String] = []

        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProvider.isEmpty {
            parts.append(trimmedProvider)
        }

        let inputCredits = inputCreditsDisplay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let input = inputCredits.isEmpty
            ? inputDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
            : inputCredits
        if !input.isEmpty {
            parts.append("\(input) in")
        }

        let outputCredits = outputCreditsDisplay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let output = outputCredits.isEmpty
            ? outputDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
            : outputCredits
        if !output.isEmpty {
            parts.append("\(output) out")
        }

        if let context = Self.formatContextLength(contextLength) {
            parts.append("\(context) ctx")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// True when the model advertises a vision/image capability, so the picker
    /// can show its "Vision" badge. Capability keys vary, so match common ones.
    var supportsVision: Bool {
        guard let capabilities else { return false }
        let visionKeys: Set<String> = ["vision", "image", "images", "multimodal"]
        return capabilities.contains { key, value in
            value && visionKeys.contains(key.lowercased())
        }
    }

    /// Human-friendly context window (e.g. 131072 -> "131K", 1048576 -> "1M").
    static func formatContextLength(_ context: Int) -> String? {
        guard context > 0 else { return nil }
        if context >= 1_000_000 {
            let millions = Double(context) / 1_000_000
            let format = millions == millions.rounded() ? "%.0fM" : "%.1fM"
            return String(format: format, millions)
        }
        if context >= 1000 {
            return "\(context / 1000)K"
        }
        return "\(context)"
    }
}

struct OsaurusRouterUsageResponse: Decodable, Sendable {
    let data: [OsaurusRouterUsageItem]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextCursor = "next_cursor"
    }
}

struct OsaurusRouterUsageItem: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let requestId: String?
    let model: String
    let provider: String
    let inputTokens: Int
    let outputTokens: Int
    /// Provider prompt-cache split; subsets of `inputTokens`. Absent on
    /// pre-cache routers → 0.
    let cachedInputTokens: Int
    let cacheWriteTokens: Int
    let costMicro: String
    let status: String
    let tokenSource: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, model, provider, status
        case requestId = "request_id"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case costMicro = "cost_micro"
        case tokenSource = "token_source"
        case createdAt = "created_at"
    }

    init(
        id: String,
        requestId: String?,
        model: String,
        provider: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        costMicro: String,
        status: String,
        tokenSource: String,
        createdAt: String
    ) {
        self.id = id
        self.requestId = requestId
        self.model = model
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costMicro = costMicro
        self.status = status
        self.tokenSource = tokenSource
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        model = try c.decode(String.self, forKey: .model)
        provider = try c.decode(String.self, forKey: .provider)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cachedInputTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0)
        cacheWriteTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0)
        costMicro = try c.decode(String.self, forKey: .costMicro)
        status = try c.decode(String.self, forKey: .status)
        tokenSource = try c.decode(String.self, forKey: .tokenSource)
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }
}

struct OsaurusRouterTransactionsResponse: Decodable, Sendable {
    let data: [OsaurusRouterTransactionItem]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextCursor = "next_cursor"
    }
}

struct OsaurusRouterTransactionItem: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let amountMicro: String
    let entryType: String
    let refType: String?
    let refId: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case amountMicro = "amount_micro"
        case entryType = "entry_type"
        case refType = "ref_type"
        case refId = "ref_id"
        case createdAt = "created_at"
    }
}

struct OsaurusRouterEstimateResponse: Decodable, Equatable, Sendable {
    let estimatedMaxMicro: String
    let typicalMicro: String

    enum CodingKeys: String, CodingKey {
        case estimatedMaxMicro = "estimated_max_micro"
        case typicalMicro = "typical_micro"
    }
}

struct OsaurusRouterSummaryEvent: Decodable, Equatable, Sendable {
    struct Summary: Decodable, Equatable, Sendable {
        let requestId: String?
        let costMicro: String
        let status: String
        let tokenSource: String
        let inputTokens: Int
        let outputTokens: Int
        /// Provider-reported prompt-cache split; subsets of `inputTokens`.
        /// Absent on pre-cache routers → decoded as `0`.
        let cachedInputTokens: Int
        let cacheWriteTokens: Int

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case costMicro = "cost_micro"
            case status
            case tokenSource = "token_source"
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case cacheWriteTokens = "cache_write_tokens"
        }

        init(
            requestId: String?,
            costMicro: String,
            status: String,
            tokenSource: String,
            inputTokens: Int,
            outputTokens: Int,
            cachedInputTokens: Int = 0,
            cacheWriteTokens: Int = 0
        ) {
            self.requestId = requestId
            self.costMicro = costMicro
            self.status = status
            self.tokenSource = tokenSource
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cachedInputTokens = cachedInputTokens
            self.cacheWriteTokens = cacheWriteTokens
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
            costMicro = try c.decode(String.self, forKey: .costMicro)
            status = try c.decode(String.self, forKey: .status)
            tokenSource = try c.decode(String.self, forKey: .tokenSource)
            inputTokens = try c.decode(Int.self, forKey: .inputTokens)
            outputTokens = try c.decode(Int.self, forKey: .outputTokens)
            cachedInputTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0)
            cacheWriteTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0)
        }
    }

    let osaurus: Summary
}

/// Local, persistable snapshot of a single Osaurus Router billing event.
///
/// `OsaurusRouterSummaryEvent.Summary` is the wire shape (`Decodable`-only); this
/// is the decoupled value the app actually carries around — encoded onto the chat
/// stream as a `StreamingBillingHint`, stamped on the assistant `ChatTurn`, and
/// written to the on-device billing ledger. Metadata only: no prompt/response text.
public struct RouterBillingSummary: Codable, Equatable, Sendable {
    public var requestId: String?
    public var costMicro: String
    public var status: String
    public var tokenSource: String
    public var inputTokens: Int
    public var outputTokens: Int
    /// Prompt-cache split reported by the upstream provider and billed by the
    /// router at cache rates. Both are subsets of `inputTokens`. `0` = no
    /// cache activity (or a pre-cache router / ledger row).
    public var cachedInputTokens: Int
    public var cacheWriteTokens: Int

    public init(
        requestId: String? = nil,
        costMicro: String,
        status: String,
        tokenSource: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0
    ) {
        self.requestId = requestId
        self.costMicro = costMicro
        self.status = status
        self.tokenSource = tokenSource
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    init(_ summary: OsaurusRouterSummaryEvent.Summary) {
        self.requestId = summary.requestId
        self.costMicro = summary.costMicro
        self.status = summary.status
        self.tokenSource = summary.tokenSource
        self.inputTokens = summary.inputTokens
        self.outputTokens = summary.outputTokens
        self.cachedInputTokens = summary.cachedInputTokens
        self.cacheWriteTokens = summary.cacheWriteTokens
    }

    enum CodingKeys: String, CodingKey {
        case requestId, costMicro, status, tokenSource, inputTokens, outputTokens
        case cachedInputTokens, cacheWriteTokens
    }

    /// Tolerates hints/ledger payloads persisted before the cache split
    /// existed (fields absent → 0).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        costMicro = try c.decode(String.self, forKey: .costMicro)
        status = try c.decode(String.self, forKey: .status)
        tokenSource = try c.decode(String.self, forKey: .tokenSource)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cachedInputTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0)
        cacheWriteTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0)
    }
}
// MARK: - Hosted web search (`/v1/search`, `/v1/contents`, `/credits/web-*`)

/// `POST /v1/search` body. Field names are the wire names; the canonical
/// encoder sorts keys so the signed bytes equal the sent bytes.
struct OsaurusRouterWebSearchRequestBody: Encodable, Sendable {
    var query: String
    var category: String?
    var num_results: Int?
    var site: String?
    var file_type: String?
    var time_range: String?
    var region: String?
    var contents: OsaurusRouterWebContentsSpec?
    var idempotency_key: String
}

/// `POST /v1/contents` body.
struct OsaurusRouterWebContentsRequestBody: Encodable, Sendable {
    var urls: [String]
    var contents: OsaurusRouterWebContentsSpec?
    var idempotency_key: String
}

/// The optional `contents` extraction spec shared by both POST routes.
struct OsaurusRouterWebContentsSpec: Encodable, Sendable {
    struct Text: Encodable, Sendable {
        var max_characters: Int
    }

    var text: Text?
    var highlights: Bool?
}

/// Lifetime free-request grant state for one operation. Grants never refill;
/// `nil` on a response means the account holds no one-time grant.
struct OsaurusRouterWebAllowance: Decodable, Equatable, Sendable {
    let includedTotal: Int
    let usedTotal: Int
    let remainingTotal: Int

    enum CodingKeys: String, CodingKey {
        case includedTotal = "included_total"
        case usedTotal = "used_total"
        case remainingTotal = "remaining_total"
    }
}

/// The `osaurus` billing object every hosted search/contents response carries.
struct OsaurusRouterWebBilling: Decodable, Equatable, Sendable {
    let requestId: String?
    let operation: String
    let provider: String?
    /// "free" (inside the grant) or "paid" (billed against the balance).
    let billing: String
    let costMicro: String
    let allowance: OsaurusRouterWebAllowance?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case operation, provider, billing, allowance, status
        case requestId = "request_id"
        case costMicro = "cost_micro"
    }
}

/// One result row from `/v1/search` or `/v1/contents`. `text` / `highlights`
/// / `summary` appear only when requested and returned.
struct OsaurusRouterWebResult: Decodable, Sendable {
    let title: String?
    let url: String?
    let publishedDate: String?
    let author: String?
    let highlights: [String]?
    let text: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case title, url, author, highlights, text, summary
        case publishedDate = "published_date"
    }
}

struct OsaurusRouterWebSearchResponse: Decodable, Sendable {
    let requestId: String?
    let results: [OsaurusRouterWebResult]
    let warnings: [String]?
    /// True when this idempotency key already completed server-side: billing
    /// metadata is authoritative but `results` is empty (content is never
    /// persisted, so it cannot be replayed).
    let replayed: Bool?
    let osaurus: OsaurusRouterWebBilling?

    enum CodingKeys: String, CodingKey {
        case results, warnings, replayed, osaurus
        case requestId = "request_id"
    }
}

/// Per-URL fetch outcome in a `/v1/contents` response. Failed pages are not
/// billed; the client falls back locally per URL.
struct OsaurusRouterWebURLStatus: Decodable, Equatable, Sendable {
    let url: String
    let status: String
    let error: String?
}

struct OsaurusRouterWebContentsResponse: Decodable, Sendable {
    let requestId: String?
    let results: [OsaurusRouterWebResult]
    let statuses: [OsaurusRouterWebURLStatus]?
    let replayed: Bool?
    let osaurus: OsaurusRouterWebBilling?

    enum CodingKeys: String, CodingKey {
        case results, statuses, replayed, osaurus
        case requestId = "request_id"
    }
}

/// `GET/POST /credits/web-settings`: the paid-web-search switch plus the
/// current lifetime grant state per operation.
struct OsaurusRouterWebSettingsResponse: Decodable, Equatable, Sendable {
    struct Grants: Decodable, Equatable, Sendable {
        var search: OsaurusRouterWebAllowance?
        var contents: OsaurusRouterWebAllowance?
    }

    var autoPayEnabled: Bool
    var grants: Grants?

    enum CodingKeys: String, CodingKey {
        case grants
        case autoPayEnabled = "auto_pay_enabled"
    }

    init(autoPayEnabled: Bool, grants: Grants?) {
        self.autoPayEnabled = autoPayEnabled
        self.grants = grants
    }
}

struct OsaurusRouterWebUsageResponse: Decodable, Sendable {
    let data: [OsaurusRouterWebUsageItem]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextCursor = "next_cursor"
    }
}

/// One metadata-only billed web request from `GET /credits/web-usage` — no
/// queries, URLs, or content, by design.
struct OsaurusRouterWebUsageItem: Decodable, Identifiable, Equatable, Sendable {
    struct Units: Decodable, Equatable, Sendable {
        let requests: Int?
        let extraResults: Int?
        let contentPages: Int?
        let summaryPages: Int?

        enum CodingKeys: String, CodingKey {
            case requests
            case extraResults = "extra_results"
            case contentPages = "content_pages"
            case summaryPages = "summary_pages"
        }
    }

    let id: String
    let requestId: String?
    let operation: String
    let provider: String?
    let billing: String
    let units: Units?
    let costMicro: String
    let status: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, operation, provider, billing, units, status
        case requestId = "request_id"
        case costMicro = "cost_micro"
        case createdAt = "created_at"
    }
}

/// Local, persistable snapshot of one hosted web search/contents billing
/// outcome — the web analogue of `RouterBillingSummary`. Metadata only:
/// never a query, URL, or page content.
public struct RouterWebBillingSummary: Codable, Equatable, Sendable {
    public var requestId: String?
    /// "search" or "contents".
    public var operation: String
    /// "free" (grant) or "paid" (balance).
    public var billing: String
    public var costMicro: String
    public var allowanceIncluded: Int?
    public var allowanceUsed: Int?
    public var allowanceRemaining: Int?
    public var status: String?

    public init(
        requestId: String? = nil,
        operation: String,
        billing: String,
        costMicro: String,
        allowanceIncluded: Int? = nil,
        allowanceUsed: Int? = nil,
        allowanceRemaining: Int? = nil,
        status: String? = nil
    ) {
        self.requestId = requestId
        self.operation = operation
        self.billing = billing
        self.costMicro = costMicro
        self.allowanceIncluded = allowanceIncluded
        self.allowanceUsed = allowanceUsed
        self.allowanceRemaining = allowanceRemaining
        self.status = status
    }

    init(_ billing: OsaurusRouterWebBilling) {
        self.requestId = billing.requestId
        self.operation = billing.operation
        self.billing = billing.billing
        self.costMicro = billing.costMicro
        self.allowanceIncluded = billing.allowance?.includedTotal
        self.allowanceUsed = billing.allowance?.usedTotal
        self.allowanceRemaining = billing.allowance?.remainingTotal
        self.status = billing.status
    }

    /// True when the request rode the lifetime free grant.
    public var isIncluded: Bool { billing.lowercased() == "free" }
}
