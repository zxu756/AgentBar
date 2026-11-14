import Foundation
import SwiftUI

public enum AgentVendor: String, CaseIterable, Codable, Identifiable, Sendable {
    case claudeCode = "claude"
    case codex = "codex"
    case openCode = "opencode"
    case mistralVibe = "vibe"
    case antigravity = "agy"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .openCode: return "OpenCode"
        case .mistralVibe: return "Mistral Vibe"
        case .antigravity: return "Antigravity"
        }
    }

    public var shortLabel: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .mistralVibe: return "Vibe"
        case .antigravity: return "AGY"
        }
    }

    public var symbolName: String {
        switch self {
        case .claudeCode: return "sparkle.magnifyingglass"
        case .codex: return "terminal.fill"
        case .openCode: return "cpu.fill"
        case .mistralVibe: return "bolt.horizontal.fill"
        case .antigravity: return "atom"
        }
    }

    public var color: Color {
        switch self {
        case .claudeCode: return Color(red: 0.88, green: 0.48, blue: 0.28)    // Burnished Copper
        case .codex: return Color(red: 0.29, green: 0.62, blue: 0.51)         // Mineral Jade
        case .openCode: return Color(red: 0.36, green: 0.55, blue: 0.75)      // Steel Cerulean
        case .mistralVibe: return Color(red: 0.848, green: 0.64, blue: 0.25)  // Ochre Gold
        case .antigravity: return Color(red: 0.61, green: 0.49, blue: 0.78)   // Muted Iris
        }
    }

    /// Soft reference ceiling for the 5-hour rolling burst gauge (tokens).
    public var fiveHourBurstCeilingTokens: Int {
        switch self {
        case .claudeCode: return 2_500_000
        case .codex: return 2_000_000
        case .openCode: return 4_000_000
        case .mistralVibe: return 3_000_000
        case .antigravity: return 2_500_000
        }
    }
}

public enum DataCompleteness: String, CaseIterable, Codable, Sendable, Equatable {
    case complete = "complete"
    case totalOnly = "totalOnly"
    case relayOnly = "relayOnly"
    case noData = "noData"

    public func label(in language: AppLanguage) -> String {
        switch self {
        case .complete:
            return language == .zhHans ? "完整" : "Complete"
        case .totalOnly:
            return language == .zhHans ? "只有总量" : "Total only"
        case .relayOnly:
            return language == .zhHans ? "只有接力里的部分" : "Relay logs only"
        case .noData:
            return language == .zhHans ? "没有数据" : "No data"
        }
    }
}

public enum TelemetryWindow: String, CaseIterable, Codable, Sendable, Hashable {
    case fiveHours = "fiveHours"
    case today = "today"
    case sevenDays = "sevenDays"
    case thirtyDays = "thirtyDays"

    public func label(in language: AppLanguage) -> String {
        switch self {
        case .fiveHours: return language == .zhHans ? "最近 5 小时" : "5 Hours"
        case .today: return language == .zhHans ? "今天" : "Today"
        case .sevenDays: return language == .zhHans ? "7 天" : "7 Days"
        case .thirtyDays: return language == .zhHans ? "30 天" : "30 Days"
        }
    }
}

public struct VendorWindowMetrics: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var totalTokens: Int?
    public var recordCount: Int
    public var estimatedCostUSD: Double?
    public var unknownModelRecordCount: Int
    public var cacheHitRate: Double?
    public var dataSource: String
    public var completeness: DataCompleteness

    public init(
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        totalTokens: Int?,
        recordCount: Int,
        estimatedCostUSD: Double?,
        unknownModelRecordCount: Int,
        cacheHitRate: Double?,
        dataSource: String,
        completeness: DataCompleteness
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.recordCount = recordCount
        self.estimatedCostUSD = estimatedCostUSD
        self.unknownModelRecordCount = unknownModelRecordCount
        self.cacheHitRate = cacheHitRate
        self.dataSource = dataSource
        self.completeness = completeness
    }

    public static func empty(dataSource: String, completeness: DataCompleteness = .noData) -> VendorWindowMetrics {
        VendorWindowMetrics(
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            totalTokens: nil,
            recordCount: 0,
            estimatedCostUSD: nil,
            unknownModelRecordCount: 0,
            cacheHitRate: nil,
            dataSource: dataSource,
            completeness: completeness
        )
    }
}

public enum MenuBarLabelMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case todayCost = "todayCost"
    case fiveHourTokens = "fiveHourTokens"
    case iconOnly = "iconOnly"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .todayCost: return "Today API-Eq Spend ($)"
        case .fiveHourTokens: return "5h Rolling Tokens"
        case .iconOnly: return "Icon Only"
        }
    }

    @MainActor
    public func localizedTitle(_ localizer: AppLocalizer) -> String {
        switch self {
        case .todayCost: return localizer.L("Today API-Eq Spend ($)", "今日按 API 价折算 ($)")
        case .fiveHourTokens: return localizer.L("5h Rolling Tokens", "5 小时滚动 Token")
        case .iconOnly: return localizer.L("Icon Only", "仅显示图标")
        }
    }
}

public enum PriceCatalog {
    /// Pricing snapshot version (YYYY-MM) for API-equivalent USD conversion.
    public static let pricingVersion = "2026-11"

    public struct ModelRates: Sendable, Equatable {
        public let family: String
        public let inputPerMillion: Double
        public let outputPerMillion: Double
        public let cacheReadPerMillion: Double
        public let cacheWritePerMillion: Double

        public init(
            family: String,
            inputPerMillion: Double,
            outputPerMillion: Double,
            cacheReadPerMillion: Double,
            cacheWritePerMillion: Double
        ) {
            self.family = family
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
            self.cacheReadPerMillion = cacheReadPerMillion
            self.cacheWritePerMillion = cacheWritePerMillion
        }
    }

    public static func costDisclaimer(in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return "按 API 价折算（价格表 \(pricingVersion)）"
        case .en:
            return "API-equivalent estimate (pricing \(pricingVersion))"
        }
    }

    public static func normalizeModelID(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let askedRange = cleaned.range(of: " (asked for ", options: .caseInsensitive) {
            cleaned = String(cleaned[..<askedRange.lowerBound])
        }
        if let commaIdx = cleaned.firstIndex(of: ",") {
            cleaned = String(cleaned[..<commaIdx])
        }
        if let slashIdx = cleaned.lastIndex(of: "/"), slashIdx < cleaned.index(before: cleaned.endIndex) {
            let afterSlash = String(cleaned[cleaned.index(after: slashIdx)...])
            if !afterSlash.isEmpty {
                cleaned = afterSlash
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Looks up published per-1M-token rates in the 2026-11 catalog.
    /// Returns `nil` for unrecognized, empty, or unpublished internal model IDs — never falls back by vendor.
    public static func rates(for model: String) -> ModelRates? {
        let m = normalizeModelID(model)
        guard !m.isEmpty else { return nil }

        // Anthropic Claude published tiers (Opus / Sonnet / Haiku)
        if m.hasPrefix("claude-opus") || m.hasPrefix("claude-3-opus") || m.hasPrefix("claude-4-opus") {
            return ModelRates(family: "claude-opus", inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.50, cacheWritePerMillion: 18.75)
        }
        if m.hasPrefix("claude-sonnet") || m.hasPrefix("claude-3-5-sonnet") || m.hasPrefix("claude-3-7-sonnet") || m.hasPrefix("claude-4-sonnet") {
            return ModelRates(family: "claude-sonnet", inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75)
        }
        if m.hasPrefix("claude-haiku") || m.hasPrefix("claude-3-haiku") || m.hasPrefix("claude-3-5-haiku") || m.hasPrefix("claude-4-haiku") {
            return ModelRates(family: "claude-haiku", inputPerMillion: 0.80, outputPerMillion: 4.00, cacheReadPerMillion: 0.08, cacheWritePerMillion: 1.00)
        }

        // OpenAI GPT-5 / GPT-6 / Codex / o-series published tiers
        if m.hasPrefix("gpt-6") || m.hasPrefix("gpt-5") || m.hasPrefix("codex-mini") || m == "o3" || m.hasPrefix("o3-") || m.hasPrefix("o4-mini") {
            return ModelRates(family: "openai-gpt-codex", inputPerMillion: 2.00, outputPerMillion: 8.00, cacheReadPerMillion: 0.50, cacheWritePerMillion: 2.00)
        }

        // DeepSeek V3 / V4 / Chat / Reasoner published tiers
        if m.hasPrefix("deepseek-v4") || m.hasPrefix("deepseek-v3") || m.hasPrefix("deepseek-chat") || m.hasPrefix("deepseek-reasoner") {
            return ModelRates(family: "deepseek", inputPerMillion: 0.30, outputPerMillion: 1.20, cacheReadPerMillion: 0.007, cacheWritePerMillion: 0.30)
        }

        // Google Gemini Pro / Carbon & Flash / Argon tiers
        if m.hasPrefix("gemini-4-carbon") || m.hasPrefix("gemini 4 carbon") || m.hasPrefix("gemini-2.5-pro") || m.hasPrefix("gemini-3-pro") {
            return ModelRates(family: "gemini-pro-carbon", inputPerMillion: 1.25, outputPerMillion: 5.00, cacheReadPerMillion: 0.30, cacheWritePerMillion: 1.25)
        }
        if m.hasPrefix("gemini-4-argon") || m.hasPrefix("gemini 4 argon") || m.hasPrefix("gemini-2.5-flash") || m.hasPrefix("gemini-2.0-flash") || m.hasPrefix("gemini-3-flash") {
            return ModelRates(family: "gemini-flash-argon", inputPerMillion: 0.30, outputPerMillion: 1.20, cacheReadPerMillion: 0.075, cacheWritePerMillion: 0.30)
        }

        return nil
    }

    /// Estimates API-equivalent USD when token breakdown is known and the model is in the 2026-11 price catalog.
    /// Returns `nil` when the model is unrecognized.
    public static func estimateUSD(
        model: String,
        vendor: AgentVendor? = nil,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int
    ) -> Double? {
        guard let r = rates(for: model) else { return nil }
        let m = 1_000_000.0
        return (Double(max(0, input)) / m) * r.inputPerMillion
            + (Double(max(0, output)) / m) * r.outputPerMillion
            + (Double(max(0, cacheRead)) / m) * r.cacheReadPerMillion
            + (Double(max(0, cacheWrite)) / m) * r.cacheWritePerMillion
    }
}

public enum SampleOrigin: String, Codable, Sendable, Equatable {
    case standalone = "standalone"
    case relayLog = "relayLog"
}

public struct UsageSample: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var vendor: AgentVendor
    public var origin: SampleOrigin
    public var timestamp: Date
    public var sessionID: String
    public var projectName: String
    public var model: String
    public var hasTokenBreakdown: Bool
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var knownTotalTokens: Int?
    public var recordedCostUSD: Double?
    public var estimatedAPICostUSD: Double?
    public var unmatchedModelCount: Int
    public var isRateLimited: Bool

    public init(
        id: String,
        vendor: AgentVendor,
        origin: SampleOrigin = .standalone,
        timestamp: Date,
        sessionID: String,
        projectName: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        recordedCostUSD: Double? = nil,
        isRateLimited: Bool = false
    ) {
        self.id = id
        self.vendor = vendor
        self.origin = origin
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.projectName = projectName
        self.model = model
        self.hasTokenBreakdown = true
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        let sumTok = self.inputTokens + self.outputTokens + self.cacheReadTokens + self.cacheWriteTokens
        self.knownTotalTokens = sumTok
        self.recordedCostUSD = recordedCostUSD
        let est = PriceCatalog.estimateUSD(
            model: model,
            vendor: vendor,
            input: self.inputTokens,
            output: self.outputTokens,
            cacheRead: self.cacheReadTokens,
            cacheWrite: self.cacheWriteTokens
        )
        self.estimatedAPICostUSD = est
        let hasValidRecordedCost = (recordedCostUSD ?? 0) > 0
        self.unmatchedModelCount = (!hasValidRecordedCost && est == nil) ? 1 : 0
        self.isRateLimited = isRateLimited
    }

    public init(
        unsplitID id: String,
        vendor: AgentVendor,
        origin: SampleOrigin,
        timestamp: Date,
        sessionID: String,
        projectName: String,
        model: String,
        rawTotalTokens: Int?,
        recordedCostUSD: Double? = nil,
        isRateLimited: Bool = false
    ) {
        self.id = id
        self.vendor = vendor
        self.origin = origin
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.projectName = projectName
        self.model = model
        self.hasTokenBreakdown = false
        self.inputTokens = 0
        self.outputTokens = 0
        self.cacheReadTokens = 0
        self.cacheWriteTokens = 0
        self.knownTotalTokens = rawTotalTokens.map { max(0, $0) }
        self.recordedCostUSD = recordedCostUSD
        self.estimatedAPICostUSD = nil
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitModel = !trimmedModel.isEmpty && trimmedModel != "—" && trimmedModel != "unknown" && trimmedModel != "default" && trimmedModel != "?"
        let hasValidRecordedCost = (recordedCostUSD ?? 0) > 0
        self.unmatchedModelCount = (!hasValidRecordedCost && hasExplicitModel && PriceCatalog.rates(for: trimmedModel) == nil) ? 1 : 0
        self.isRateLimited = isRateLimited
    }

    public init(
        aggregatedID id: String,
        vendor: AgentVendor,
        origin: SampleOrigin,
        timestamp: Date,
        sessionID: String,
        projectName: String,
        model: String,
        hasTokenBreakdown: Bool,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        knownTotalTokens: Int?,
        recordedCostUSD: Double?,
        estimatedAPICostUSD: Double?,
        unmatchedModelCount: Int,
        isRateLimited: Bool
    ) {
        self.id = id
        self.vendor = vendor
        self.origin = origin
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.projectName = projectName
        self.model = model
        self.hasTokenBreakdown = hasTokenBreakdown
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.knownTotalTokens = knownTotalTokens
        self.recordedCostUSD = recordedCostUSD
        self.estimatedAPICostUSD = estimatedAPICostUSD
        self.unmatchedModelCount = unmatchedModelCount
        self.isRateLimited = isRateLimited
    }

    public var effectiveCostUSD: Double? {
        if let rec = recordedCostUSD, rec > 0 {
            return rec
        }
        return estimatedAPICostUSD
    }

    public var totalTokens: Int {
        if let knownTotalTokens {
            return knownTotalTokens
        }
        return inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }
}

public struct DailyVendorBucket: Identifiable, Codable, Sendable, Equatable {
    public var id: String { "\(vendor.rawValue)-\(Int(date.timeIntervalSince1970))" }
    public var date: Date
    public var vendor: AgentVendor
    public var tokens: Int
    public var costUSD: Double
    public var sessions: Int

    public init(date: Date, vendor: AgentVendor, tokens: Int, costUSD: Double, sessions: Int) {
        self.date = date
        self.vendor = vendor
        self.tokens = tokens
        self.costUSD = costUSD
        self.sessions = sessions
    }
}

public struct VendorSummary: Identifiable, Codable, Sendable, Equatable {
    public var id: String { vendor.rawValue }
    public var vendor: AgentVendor
    public var sourceAvailable: Bool
    public var dataSource: String
    public var completeness: DataCompleteness
    public var windows: [TelemetryWindow: VendorWindowMetrics]
    public var sessionCount30d: Int
    public var activeModel: String
    public var lastActive: Date?
    public var rateLimitHits24h: Int

    public init(
        vendor: AgentVendor,
        sourceAvailable: Bool,
        dataSource: String,
        completeness: DataCompleteness,
        windows: [TelemetryWindow: VendorWindowMetrics],
        sessionCount30d: Int,
        activeModel: String,
        lastActive: Date?,
        rateLimitHits24h: Int
    ) {
        self.vendor = vendor
        self.sourceAvailable = sourceAvailable
        self.dataSource = dataSource
        self.completeness = completeness
        self.windows = windows
        self.sessionCount30d = sessionCount30d
        self.activeModel = activeModel
        self.lastActive = lastActive
        self.rateLimitHits24h = rateLimitHits24h
    }

    public func metrics(for window: TelemetryWindow) -> VendorWindowMetrics {
        windows[window] ?? .empty(dataSource: dataSource, completeness: completeness)
    }

    public var todayCostUSD: Double? { metrics(for: .today).estimatedCostUSD }
    public var todayTokens: Int? { metrics(for: .today).totalTokens }
    public var fiveHourTokens: Int? { metrics(for: .fiveHours).totalTokens }
    public var fiveHourCostUSD: Double? { metrics(for: .fiveHours).estimatedCostUSD }
    public var thirtyDayCostUSD: Double? { metrics(for: .thirtyDays).estimatedCostUSD }
    public var thirtyDayTokens: Int? { metrics(for: .thirtyDays).totalTokens }
    public var cacheHitRatio: Double? { metrics(for: .thirtyDays).cacheHitRate }
    public var unknownModelRecordCount30d: Int { metrics(for: .thirtyDays).unknownModelRecordCount }

    public var fiveHourBurstFraction: Double {
        guard let tok = fiveHourTokens, tok > 0 else { return 0.0 }
        return min(1.0, Double(tok) / Double(max(1, vendor.fiveHourBurstCeilingTokens)))
    }
}

public struct RelayBatonStep: Identifiable, Codable, Sendable, Equatable {
    public var id: String { "\(stepID)-\(timestampString)" }
    public var stepID: String
    public var vendor: AgentVendor?
    public var status: String
    public var durationSeconds: Int
    public var timestampString: String
    public var model: String
    public var costUSD: Double?
    public var tokens: Int?

    public init(
        stepID: String,
        vendor: AgentVendor?,
        status: String,
        durationSeconds: Int,
        timestampString: String,
        model: String,
        costUSD: Double? = nil,
        tokens: Int? = nil
    ) {
        self.stepID = stepID
        self.vendor = vendor
        self.status = status
        self.durationSeconds = durationSeconds
        self.timestampString = timestampString
        self.model = model
        self.costUSD = costUSD
        self.tokens = tokens
    }

    @MainActor
    public func localizedStatus(_ localizer: AppLocalizer) -> String {
        let lower = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "ok" || lower == "done" || lower == "pass" || lower == "passed" {
            return localizer.L(status, "完成")
        }
        if lower.contains("flag") || lower.contains("warn") || lower.contains("partial") {
            return localizer.L(status, "告警")
        }
        if lower.contains("fail") || lower.contains("err") || lower.contains("timeout") {
            return localizer.L(status, "失败")
        }
        return status
    }
}

public struct RelayRunSummary: Identifiable, Codable, Sendable, Equatable {
    public var id: String { logPath }
    public var projectName: String
    public var logPath: String
    public var updatedAt: Date
    public var steps: [RelayBatonStep]

    public init(projectName: String, logPath: String, updatedAt: Date, steps: [RelayBatonStep]) {
        self.projectName = projectName
        self.logPath = logPath
        self.updatedAt = updatedAt
        self.steps = steps
    }

    public var totalCostUSD: Double {
        steps.compactMap(\.costUSD).reduce(0, +)
    }

    public var flaggedCount: Int {
        steps.filter {
            let s = $0.status.lowercased()
            return s.contains("flag") || s.contains("fail") || s.contains("timeout")
        }.count
    }
}

public struct TelemetrySnapshot: Codable, Sendable, Equatable {
    public var capturedAt: Date
    public var isDemoData: Bool
    public var vendorSummaries: [VendorSummary]
    public var dailyBuckets: [DailyVendorBucket]
    public var recentSessions: [UsageSample]
    public var relayRuns: [RelayRunSummary]

    public init(
        capturedAt: Date,
        isDemoData: Bool = false,
        vendorSummaries: [VendorSummary],
        dailyBuckets: [DailyVendorBucket],
        recentSessions: [UsageSample],
        relayRuns: [RelayRunSummary]
    ) {
        self.capturedAt = capturedAt
        self.isDemoData = isDemoData
        self.vendorSummaries = vendorSummaries
        self.dailyBuckets = dailyBuckets
        self.recentSessions = recentSessions
        self.relayRuns = relayRuns
    }

    public var todayTotalCostUSD: Double {
        vendorSummaries.compactMap(\.todayCostUSD).reduce(0, +)
    }

    public var hasKnownTodayCost: Bool {
        vendorSummaries.contains { $0.todayCostUSD != nil }
    }

    public var todayTotalTokens: Int {
        vendorSummaries.compactMap(\.todayTokens).reduce(0, +)
    }

    public var fiveHourTotalTokens: Int {
        vendorSummaries.compactMap(\.fiveHourTokens).reduce(0, +)
    }

    public var fiveHourTotalCostUSD: Double {
        vendorSummaries.compactMap(\.fiveHourCostUSD).reduce(0, +)
    }

    public var thirtyDayTotalCostUSD: Double {
        vendorSummaries.compactMap(\.thirtyDayCostUSD).reduce(0, +)
    }

    public var hasKnownThirtyDayCost: Bool {
        vendorSummaries.contains { $0.thirtyDayCostUSD != nil }
    }

    public var thirtyDayTotalTokens: Int {
        vendorSummaries.compactMap(\.thirtyDayTokens).reduce(0, +)
    }

    public var unknownModelRecordCount30d: Int {
        vendorSummaries.map(\.unknownModelRecordCount30d).reduce(0, +)
    }

    public var rateLimitHits24h: Int {
        vendorSummaries.map(\.rateLimitHits24h).reduce(0, +)
    }

    public var activeVendorCount: Int {
        vendorSummaries.filter { $0.completeness != .noData }.count
    }
}

public enum TelemetryFormatter {
    public static func usd(_ value: Double) -> String {
        if value == 0 {
            return "$0.00"
        }
        if value < 0.01 {
            return String(format: "$%.3f", value)
        }
        if value >= 100 {
            return String(format: "$%.0f", value)
        }
        return String(format: "$%.2f", value)
    }

    public static func optionalUSD(_ value: Double?, completeness: DataCompleteness, language: AppLanguage) -> String {
        if let value {
            return usd(value)
        }
        if completeness == .noData {
            return language == .zhHans ? "没有数据" : "No data"
        }
        return language == .zhHans ? "未知" : "Unknown"
    }

    public static func compactTokens(_ count: Int) -> String {
        let absVal = Double(abs(count))
        if absVal >= 1_000_000_000 {
            return String(format: "%.2fB", Double(count) / 1_000_000_000.0)
        }
        if absVal >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if absVal >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    public static func optionalTokens(_ value: Int?, completeness: DataCompleteness, language: AppLanguage) -> String {
        if let value {
            return compactTokens(value)
        }
        if completeness == .noData {
            return language == .zhHans ? "没有数据" : "No data"
        }
        return language == .zhHans ? "未知" : "Unknown"
    }

    public static func percent(_ ratio: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, ratio)) * 100.0)
    }

    public static func optionalPercent(_ ratio: Double?, completeness: DataCompleteness, language: AppLanguage) -> String {
        if let ratio {
            return percent(ratio)
        }
        if completeness == .noData {
            return language == .zhHans ? "没有数据" : "No data"
        }
        return language == .zhHans ? "未知" : "Unknown"
    }
}
