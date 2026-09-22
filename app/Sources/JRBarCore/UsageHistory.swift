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

/// Per-million-token prices the daemon used for `cost_usd`: the model's
/// own list price when its table row priced the records (`estimated ==
/// false`), else a stand-in's rate marked approximate.
public struct UsagePricing: Codable, Hashable, Sendable {
    public var inputPerMillion: Double?
    public var outputPerMillion: Double?
    public var cacheReadPerMillion: Double?
    public var asOf: String?
    /// The rate-table generation this quote was priced under
    /// (`jrbar-rates-v3`), when the daemon stamps it.
    public var tableVersion: String?
    /// The same flag as `estimated`: a stand-in rate is approximate, a
    /// model's own table row is a list price. Kept decoded-and-derived —
    /// the daemon writes it, and older daemons that hardcoded `true`
    /// stay honest because it is recomputed from `estimated` here.
    public var approximate: Bool
    public var currency: String
    /// The model this quote is for — the dominant model's own row, the
    /// Codex default, or the provider's reference stand-in.
    public var model: String?
    /// `table` / `codex_default` / `reference` — where the rate came from.
    public var source: String?
    /// True when the rate is a stand-in, not the model's own table row.
    public var estimated: Bool

    public init(inputPerMillion: Double? = nil, outputPerMillion: Double? = nil, cacheReadPerMillion: Double? = nil,
                asOf: String? = nil, tableVersion: String? = nil, approximate: Bool = true, currency: String = "USD",
                model: String? = nil, source: String? = nil, estimated: Bool = false) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.asOf = asOf
        self.tableVersion = tableVersion
        self.approximate = approximate
        self.currency = currency
        self.model = model
        self.source = source
        self.estimated = estimated
    }

    enum CodingKeys: String, CodingKey {
        case inputPerMillion = "input_per_mtok"
        case outputPerMillion = "output_per_mtok"
        case cacheReadPerMillion = "cache_read_per_mtok"
        case asOf = "as_of"
        case tableVersion = "table_version"
        case approximate, currency, model, source, estimated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputPerMillion = try c.decodeIfPresent(Double.self, forKey: .inputPerMillion)
        outputPerMillion = try c.decodeIfPresent(Double.self, forKey: .outputPerMillion)
        cacheReadPerMillion = try c.decodeIfPresent(Double.self, forKey: .cacheReadPerMillion)
        asOf = try c.decodeIfPresent(String.self, forKey: .asOf)
        tableVersion = try c.decodeIfPresent(String.self, forKey: .tableVersion)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        estimated = try c.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
        // The wire's `approximate` says the same thing `estimated` does;
        // derive it here so a daemon that still hardcodes true cannot
        // call a list price approximate.
        approximate = estimated
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
    /// Counted records priced at a reference stand-in rather than their
    /// model's own row (T24: estimates stay labeled).
    public var estimatedRecords: Int
    /// Counted records whose model has no price at all — their tokens are
    /// in the rows; the cost they contributed is a real absence.
    public var unpricedRecords: Int
    public var unpricedModels: [String]

    public init(provider: String, range: String, days: [UsageHistoryDay] = [], hours: [UsageHistoryHour] = [], pricing: UsagePricing? = nil,
                account: UsageAccount? = nil, records: Int? = nil, partial: Bool = false,
                estimatedRecords: Int = 0, unpricedRecords: Int = 0, unpricedModels: [String] = []) {
        self.provider = provider
        self.range = range
        self.days = days
        self.hours = hours
        self.pricing = pricing
        self.account = account
        self.records = records
        self.partial = partial
        self.estimatedRecords = estimatedRecords
        self.unpricedRecords = unpricedRecords
        self.unpricedModels = unpricedModels
    }

    enum CodingKeys: String, CodingKey {
        case provider, range, days, hours, pricing, account, records, partial
        case estimatedRecords = "estimated_records"
        case unpricedRecords = "unpriced_records"
        case unpricedModels = "unpriced_models"
    }

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
        estimatedRecords = (try? c.decodeIfPresent(Int.self, forKey: .estimatedRecords)) ?? 0
        unpricedRecords = (try? c.decodeIfPresent(Int.self, forKey: .unpricedRecords)) ?? 0
        unpricedModels = (try? c.decodeIfPresent([String].self, forKey: .unpricedModels)) ?? []
    }

    /// True while the dollars are approximate: the headline quote is a
    /// stand-in (`pricing.estimated`), some counted record was priced at
    /// a reference rate, or no table was reported at all. The UI prefixes
    /// approximate costs with `≈`; a fully table-priced range drops it.
    public var costsApproximate: Bool {
        (pricing?.estimated ?? true) || estimatedRecords > 0
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
        // Past a thousand the cents are noise and the digits run together:
        // "$253,305" reads, "$253305" does not.
        if usd >= 1000 { return symbol + grouped(usd.rounded()) }
        return String(format: "%@%.2f", symbol, usd)
    }

    /// 253305 → "253,305", in the reader's own locale.
    static let groupingFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    public static func grouped(_ value: Double) -> String {
        groupingFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}
