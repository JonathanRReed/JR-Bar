import Foundation

// The `usage_history` command (an app-proposed protocol extension, see
// app/README.md): `{provider, range}` → `{provider, range, days[], hours[],
// pricing?, account?}`. Days carry a calendar date, hours an ISO hour;
// both carry tokens in/out, cache reads and an estimated cost.

public enum UsageHistoryRange: String, CaseIterable, Sendable, Identifiable {
    case week = "7d"
    case month = "30d"
    case quarter = "90d"
    case year = "365d"

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        }
    }

    public var label: String { rawValue }
}

public struct UsageHistoryDay: Codable, Hashable, Sendable, Identifiable {
    /// `YYYY-MM-DD` in the daemon's local calendar.
    public var date: String
    public var tokensIn: Int
    public var tokensOut: Int
    public var cacheRead: Int
    public var costUsd: Double

    public var id: String { date }
    public var totalTokens: Int { tokensIn + tokensOut + cacheRead }

    public init(date: String, tokensIn: Int = 0, tokensOut: Int = 0, cacheRead: Int = 0, costUsd: Double = 0) {
        self.date = date
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.cacheRead = cacheRead
        self.costUsd = costUsd
    }

    enum CodingKeys: String, CodingKey {
        case date
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case cacheRead = "cache_read"
        case costUsd = "cost_usd"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        tokensIn = try c.decodeIfPresent(Int.self, forKey: .tokensIn) ?? 0
        tokensOut = try c.decodeIfPresent(Int.self, forKey: .tokensOut) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
    }

    /// The date as a `Date` at local midnight, for the chart's axis.
    public var day: Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

public struct UsageHistoryHour: Codable, Hashable, Sendable, Identifiable {
    /// `YYYY-MM-DDTHH:00` local, or an epoch under `at`.
    public var hour: String
    public var at: Double?
    public var tokensIn: Int
    public var tokensOut: Int
    public var cacheRead: Int
    public var costUsd: Double

    public var id: String { hour }
    public var totalTokens: Int { tokensIn + tokensOut + cacheRead }

    public init(hour: String, at: Double? = nil, tokensIn: Int = 0, tokensOut: Int = 0, cacheRead: Int = 0, costUsd: Double = 0) {
        self.hour = hour
        self.at = at
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.cacheRead = cacheRead
        self.costUsd = costUsd
    }

    enum CodingKeys: String, CodingKey {
        case hour, at
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case cacheRead = "cache_read"
        case costUsd = "cost_usd"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hour = try c.decodeIfPresent(String.self, forKey: .hour) ?? ""
        at = try c.decodeIfPresent(Double.self, forKey: .at)
        tokensIn = try c.decodeIfPresent(Int.self, forKey: .tokensIn) ?? 0
        tokensOut = try c.decodeIfPresent(Int.self, forKey: .tokensOut) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
    }

    public var date: Date? {
        if let at { return Date(timeIntervalSince1970: at) }
        let pieces = hour.split(separator: "T")
        guard pieces.count == 2 else { return nil }
        let ymd = pieces[0].split(separator: "-").compactMap { Int($0) }
        let hm = pieces[1].split(separator: ":").compactMap { Int($0) }
        guard ymd.count == 3, let h = hm.first else { return nil }
        return Calendar.current.date(from: DateComponents(year: ymd[0], month: ymd[1], day: ymd[2], hour: h))
    }
}

/// Per-million-token prices the daemon used for `cost_usd`; always an
/// approximation of the provider's list price.
public struct UsagePricing: Codable, Hashable, Sendable {
    public var inputPerMillion: Double?
    public var outputPerMillion: Double?
    public var cacheReadPerMillion: Double?
    public var asOf: String?
    public var approximate: Bool
    public var currency: String

    public init(inputPerMillion: Double? = nil, outputPerMillion: Double? = nil, cacheReadPerMillion: Double? = nil, asOf: String? = nil, approximate: Bool = true, currency: String = "USD") {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.asOf = asOf
        self.approximate = approximate
        self.currency = currency
    }

    enum CodingKeys: String, CodingKey {
        case inputPerMillion = "input_per_mtok"
        case outputPerMillion = "output_per_mtok"
        case cacheReadPerMillion = "cache_read_per_mtok"
        case asOf = "as_of"
        case approximate, currency
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputPerMillion = try c.decodeIfPresent(Double.self, forKey: .inputPerMillion)
        outputPerMillion = try c.decodeIfPresent(Double.self, forKey: .outputPerMillion)
        cacheReadPerMillion = try c.decodeIfPresent(Double.self, forKey: .cacheReadPerMillion)
        asOf = try c.decodeIfPresent(String.self, forKey: .asOf)
        approximate = try c.decodeIfPresent(Bool.self, forKey: .approximate) ?? true
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
    }
}

/// The account behind a provider's usage: plan name, a label (an email or
/// an org), and how the daemon knows (`official`, `derived`, `manual`).
public struct UsageAccount: Codable, Hashable, Sendable {
    public var plan: String?
    public var label: String?
    public var fidelity: String?

    public init(plan: String? = nil, label: String? = nil, fidelity: String? = nil) {
        self.plan = plan
        self.label = label
        self.fidelity = fidelity
    }
}

public struct UsageHistory: Codable, Hashable, Sendable {
    public var provider: String
    public var range: String
    public var days: [UsageHistoryDay]
    public var hours: [UsageHistoryHour]
    public var pricing: UsagePricing?
    public var account: UsageAccount?
    /// How many transcript records the scan counted; 0 means the provider
    /// has no local records at all (as opposed to a range with none).
    public var records: Int?
    /// True while the daemon's scan is still running and these rows are
    /// what it has so far; a `usage_history_ready` event follows.
    public var partial: Bool

    public init(provider: String, range: String, days: [UsageHistoryDay] = [], hours: [UsageHistoryHour] = [], pricing: UsagePricing? = nil,
                account: UsageAccount? = nil, records: Int? = nil, partial: Bool = false) {
        self.provider = provider
        self.range = range
        self.days = days
        self.hours = hours
        self.pricing = pricing
        self.account = account
        self.records = records
        self.partial = partial
    }

    enum CodingKeys: String, CodingKey { case provider, range, days, hours, pricing, account, records, partial }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        range = try c.decodeIfPresent(String.self, forKey: .range) ?? ""
        days = try c.decodeIfPresent([UsageHistoryDay].self, forKey: .days) ?? []
        hours = try c.decodeIfPresent([UsageHistoryHour].self, forKey: .hours) ?? []
        pricing = try c.decodeIfPresent(UsagePricing.self, forKey: .pricing)
        account = try c.decodeIfPresent(UsageAccount.self, forKey: .account)
        records = try? c.decodeIfPresent(Int.self, forKey: .records)
        partial = (try? c.decodeIfPresent(Bool.self, forKey: .partial)) ?? false
    }

    public var isEmpty: Bool { days.isEmpty && hours.isEmpty }
    /// The scan *finished* and found nothing for this provider on this
    /// Mac. A partial answer is a scan still running, not a verdict — and
    /// the daemon pads its answer with a row per day whether or not it
    /// read anything, so an all-zero month with no records is this, not a
    /// month that happened to be quiet.
    public var hasNoLocalRecords: Bool { records == 0 && !partial && (isEmpty || totalTokens == 0) }
    public var totalCost: Double { days.reduce(0) { $0 + $1.costUsd } }
    public var totalTokens: Int { days.reduce(0) { $0 + $1.totalTokens } }
    public var totalCacheRead: Int { days.reduce(0) { $0 + $1.cacheRead } }
    public var totalInput: Int { days.reduce(0) { $0 + $1.tokensIn } }

    /// What the cache reads would have cost at the input price minus what
    /// they cost at the cache price; nil without both prices.
    public var cacheSavings: Double? {
        guard let pricing, let input = pricing.inputPerMillion, let cache = pricing.cacheReadPerMillion, input > cache else { return nil }
        return Double(totalCacheRead) / 1_000_000 * (input - cache)
    }

    /// Share of all input-side tokens served from cache, 0...1.
    public var cacheShare: Double? {
        let base = totalInput + totalCacheRead
        guard base > 0 else { return nil }
        return Double(totalCacheRead) / Double(base)
    }

    /// The busiest day, for the axis ceiling.
    public var peakDayTokens: Int { days.map(\.totalTokens).max() ?? 0 }
}

public enum UsageFormat {
    /// 1234 → "1.2k", 4_560_000 → "4.6M".
    public static func tokens(_ count: Int) -> String {
        let value = Double(count)
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: value >= 10_000_000 ? "%.0fM" : "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: value >= 10_000 ? "%.0fk" : "%.1fk", value / 1_000) }
        return "\(count)"
    }

    public static func cost(_ usd: Double, currency: String = "USD") -> String {
        let symbol = currency == "USD" ? "$" : (currency == "EUR" ? "€" : (currency == "GBP" ? "£" : currency + " "))
        if usd < 0.01, usd > 0 { return "<\(symbol)0.01" }
        if usd >= 1000 { return String(format: "%@%.0f", symbol, usd) }
        return String(format: "%@%.2f", symbol, usd)
    }
}
