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
        case .mistralVibe: return Color(red: 0.85, green: 0.64, blue: 0.25)   // Ochre Gold
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
    case mismatch = "mismatch"
    case totalOnly = "totalOnly"
    case relayOnly = "relayOnly"
    case noData = "noData"

    public func label(in language: AppLanguage) -> String {
        switch self {
        case .complete:
            return language == .zhHans ? "完整" : "Complete"
        case .mismatch:
            return language == .zhHans ? "总量不一致" : "Total mismatch"
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
    public var pricedRecordCount: Int
    public var estimatedCostUSD: Double?
    public var unknownModelRecordCount: Int
    public var cacheHitRate: Double?
    public var dataSource: String
    public var completeness: DataCompleteness
    public var hasRolloutMismatch: Bool
    public var rolloutMismatchCount: Int
    public var mismatchDetails: [String]
    public var rateLimit429Count: Int

    public init(
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        totalTokens: Int?,
        recordCount: Int,
        pricedRecordCount: Int = 0,
        estimatedCostUSD: Double?,
        unknownModelRecordCount: Int,
        cacheHitRate: Double?,
        dataSource: String,
        completeness: DataCompleteness,
        hasRolloutMismatch: Bool = false,
        rolloutMismatchCount: Int = 0,
        mismatchDetails: [String] = [],
        rateLimit429Count: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.recordCount = recordCount
        self.pricedRecordCount = pricedRecordCount
        self.estimatedCostUSD = estimatedCostUSD
        self.unknownModelRecordCount = unknownModelRecordCount
        self.cacheHitRate = cacheHitRate
        self.dataSource = dataSource
        self.completeness = completeness
        self.hasRolloutMismatch = hasRolloutMismatch
        self.rolloutMismatchCount = rolloutMismatchCount
        self.mismatchDetails = mismatchDetails
        self.rateLimit429Count = rateLimit429Count
    }

    public func costNote(in language: AppLanguage) -> String? {
        guard pricedRecordCount > 0 || unknownModelRecordCount > 0 else {
            return nil
        }
        return TelemetryFormatter.costCoverageNote(
            pricedCount: pricedRecordCount,
            unmatchedCount: unknownModelRecordCount,
            in: language
        )
    }

    public func mismatchNote(in language: AppLanguage) -> String? {
        guard hasRolloutMismatch else { return nil }
        let unique = Array(NSOrderedSet(array: mismatchDetails)) as? [String] ?? mismatchDetails
        let joined = unique.joined(separator: "; ")
        if joined.isEmpty {
            return language == .zhHans ? "rollout 与 SQLite 总量不一致" : "rollout vs SQLite total mismatch"
        }
        return language == .zhHans ? "总量不一致（\(joined)）" : "Total mismatch (\(joined))"
    }

    public static func empty(dataSource: String, completeness: DataCompleteness = .noData) -> VendorWindowMetrics {
        VendorWindowMetrics(
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            totalTokens: nil,
            recordCount: 0,
            pricedRecordCount: 0,
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
    /// Verification status of the embedded local API-equivalent rate table.
    /// Inherited rates have not been live-verified in offline runs and are marked `"unverified"` (`"未核对"`).
    public static let pricingVersion = "unverified"

    public static func localizedPricingVersion(in language: AppLanguage) -> String {
        pricingVersion == "unverified" ? (language == .zhHans ? "未核对" : "unverified") : pricingVersion
    }

    public enum MatchKind: String, Sendable, Equatable, Codable {
        case prefix
        case exactOrHyphenPrefix
    }

    public struct ModelRates: Sendable, Equatable, Codable {
        public let modelPrefix: String
        public let matchKind: MatchKind
        public let family: String
        public let inputPerMillion: Double
        public let cachedInputPerMillion: Double
        public let cacheWritePerMillion: Double
        public let outputPerMillion: Double
        public let sourceURL: String
        public let verifiedAt: String

        public var cacheReadPerMillion: Double { cachedInputPerMillion }

        public init(
            modelPrefix: String,
            matchKind: MatchKind = .prefix,
            family: String,
            inputPerMillion: Double,
            cachedInputPerMillion: Double,
            cacheWritePerMillion: Double,
            outputPerMillion: Double,
            sourceURL: String,
            verifiedAt: String = "unverified"
        ) {
            self.modelPrefix = modelPrefix
            self.matchKind = matchKind
            self.family = family
            self.inputPerMillion = inputPerMillion
            self.cachedInputPerMillion = cachedInputPerMillion
            self.cacheWritePerMillion = cacheWritePerMillion
            self.outputPerMillion = outputPerMillion
            self.sourceURL = sourceURL
            self.verifiedAt = verifiedAt
        }

        public func localizedVerifiedAt(in language: AppLanguage) -> String {
            if verifiedAt == "unverified" {
                return language == .zhHans ? "未核对" : "unverified"
            }
            return verifiedAt
        }

        public func matches(normalizedModelID m: String) -> Bool {
            switch matchKind {
            case .prefix:
                return m.hasPrefix(modelPrefix)
            case .exactOrHyphenPrefix:
                return m == modelPrefix || m.hasPrefix(modelPrefix + "-")
            }
        }
    }

    private static let anthropicPricingURL = "https://docs.anthropic.com/en/docs/about-claude/pricing"
    private static let openAIPricingURL = "https://platform.openai.com/docs/pricing"
    private static let deepSeekPricingURL = "https://api-docs.deepseek.com/quick_start/pricing"
    private static let googleGeminiPricingURL = "https://ai.google.dev/gemini-api/docs/pricing"

    /// Per-model-prefix rate table: one row per model prefix with unit rates, official source URL, and verification status.
    public static let entries: [ModelRates] = [
        // Anthropic Claude Opus
        ModelRates(modelPrefix: "claude-opus", family: "claude-opus", inputPerMillion: 15.0, cachedInputPerMillion: 1.50, cacheWritePerMillion: 18.75, outputPerMillion: 75.0, sourceURL: anthropicPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "claude-3-opus", family: "claude-opus", inputPerMillion: 15.0, cachedInputPerMillion: 1.50, cacheWritePerMillion: 18.75, outputPerMillion: 75.0, sourceURL: anthropicPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "claude-4-opus", family: "claude-opus", inputPerMillion: 15.0, cachedInputPerMillion: 1.50, cacheWritePerMillion: 18.75, outputPerMillion: 75.0, sourceURL: anthropicPricingURL, verifiedAt: "unverified"),
        // Anthropic Claude Sonnet
        ModelRates(modelPrefix: "claude-sonnet", family: "claude-sonnet", inputPerMillion: 3.0, cachedInputPerMillion: 0.30, cacheWritePerMillion: 3.75, outputPerMillion: 15.0, sourceURL: anthropicPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "claude-3-5-sonnet", family: "claude-sonnet", inputPerMillion: 3.0, cachedInputPerMillion: 0.30, cacheWritePerMillion: 3.75, outputPerMillion: 15.0, sourceURL: anthropicPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "claude-3-7-sonnet", family: "claude-sonnet", inputPerMillion: 3.0, cachedInputPerMillion: 0.30, cacheWritePerMillion: 3.75, outputPerMillion: 15.0, sourceURL: anthropicPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "claude-4-sonnet", family: "claude-sonnet", inputPerMillion: 3.0, cachedInputPerMillion: 0.30, cacheWritePerMillion: 3.75, outputPerMillion: 15.0, sourceURL: anthropicPricingURL, verifiedAt: "unverified"),
        // Anthropic Claude Haiku
        ModelRates(modelPrefix: "claude-haiku", family: "claude-haiku", inputPerMillion: 0.80, cachedInputPerMillion: 0.08, cacheWritePerMillion: 1.00, outputPerMillion: 4.00, sourceURL: anthropicPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "claude-3-haiku", family: "claude-haiku", inputPerMillion: 0.80, cachedInputPerMillion: 0.08, cacheWritePerMillion: 1.00, outputPerMillion: 4.00, sourceURL: anthropicPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "claude-3-5-haiku", family: "claude-haiku", inputPerMillion: 0.80, cachedInputPerMillion: 0.08, cacheWritePerMillion: 1.00, outputPerMillion: 4.00, sourceURL: anthropicPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "claude-4-haiku", family: "claude-haiku", inputPerMillion: 0.80, cachedInputPerMillion: 0.08, cacheWritePerMillion: 1.00, outputPerMillion: 4.00, sourceURL: anthropicPricingURL, verifiedAt: "unverified"),
        // OpenAI GPT / Codex / o-series
        ModelRates(modelPrefix: "gpt-6", family: "openai-gpt-codex", inputPerMillion: 2.00, cachedInputPerMillion: 0.50, cacheWritePerMillion: 2.00, outputPerMillion: 8.00, sourceURL: openAIPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "gpt-5", family: "openai-gpt-codex", inputPerMillion: 2.00, cachedInputPerMillion: 0.50, cacheWritePerMillion: 2.00, outputPerMillion: 8.00, sourceURL: openAIPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "codex-mini", family: "openai-gpt-codex", inputPerMillion: 2.00, cachedInputPerMillion: 0.50, cacheWritePerMillion: 2.00, outputPerMillion: 8.00, sourceURL: openAIPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "o3", matchKind: .exactOrHyphenPrefix, family: "openai-gpt-codex", inputPerMillion: 2.00, cachedInputPerMillion: 0.50, cacheWritePerMillion: 2.00, outputPerMillion: 8.00, sourceURL: openAIPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "o4-mini", family: "openai-gpt-codex", inputPerMillion: 2.00, cachedInputPerMillion: 0.50, cacheWritePerMillion: 2.00, outputPerMillion: 8.00, sourceURL: openAIPricingURL, verifiedAt: "unverified"),
        // DeepSeek
        ModelRates(modelPrefix: "deepseek-v4", family: "deepseek", inputPerMillion: 0.30, cachedInputPerMillion: 0.007, cacheWritePerMillion: 0.30, outputPerMillion: 1.20, sourceURL: deepSeekPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "deepseek-v3", family: "deepseek", inputPerMillion: 0.30, cachedInputPerMillion: 0.007, cacheWritePerMillion: 0.30, outputPerMillion: 1.20, sourceURL: deepSeekPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "deepseek-chat", family: "deepseek", inputPerMillion: 0.30, cachedInputPerMillion: 0.007, cacheWritePerMillion: 0.30, outputPerMillion: 1.20, sourceURL: deepSeekPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "deepseek-reasoner", family: "deepseek", inputPerMillion: 0.30, cachedInputPerMillion: 0.007, cacheWritePerMillion: 0.30, outputPerMillion: 1.20, sourceURL: deepSeekPricingURL, verifiedAt: "unverified"),
        // Google Gemini Pro / Carbon & Flash / Argon
        ModelRates(modelPrefix: "gemini-4-carbon", family: "gemini-pro-carbon", inputPerMillion: 1.25, cachedInputPerMillion: 0.30, cacheWritePerMillion: 1.25, outputPerMillion: 5.00, sourceURL: googleGeminiPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "gemini 4 carbon", family: "gemini-pro-carbon", inputPerMillion: 1.25, cachedInputPerMillion: 0.30, cacheWritePerMillion: 1.25, outputPerMillion: 5.00, sourceURL: googleGeminiPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "gemini-2.5-pro", family: "gemini-pro-carbon", inputPerMillion: 1.25, cachedInputPerMillion: 0.30, cacheWritePerMillion: 1.25, outputPerMillion: 5.00, sourceURL: googleGeminiPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "gemini-3-pro", family: "gemini-pro-carbon", inputPerMillion: 1.25, cachedInputPerMillion: 0.30, cacheWritePerMillion: 1.25, outputPerMillion: 5.00, sourceURL: googleGeminiPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "gemini-4-argon", family: "gemini-flash-argon", inputPerMillion: 0.30, cachedInputPerMillion: 0.075, cacheWritePerMillion: 0.30, outputPerMillion: 1.20, sourceURL: googleGeminiPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "gemini 4 argon", family: "gemini-flash-argon", inputPerMillion: 0.30, cachedInputPerMillion: 0.075, cacheWritePerMillion: 0.30, outputPerMillion: 1.20, sourceURL: googleGeminiPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "gemini-2.0-flash", family: "gemini-flash-argon", inputPerMillion: 0.30, cachedInputPerMillion: 0.075, cacheWritePerMillion: 0.30, outputPerMillion: 1.20, sourceURL: googleGeminiPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "gemini-2.5-flash", family: "gemini-flash-argon", inputPerMillion: 0.30, cachedInputPerMillion: 0.075, cacheWritePerMillion: 0.30, outputPerMillion: 1.20, sourceURL: googleGeminiPricingURL, verifiedAt: "unverified"),
        ModelRates(modelPrefix: "gemini-3-flash", family: "gemini-flash-argon", inputPerMillion: 0.30, cachedInputPerMillion: 0.075, cacheWritePerMillion: 0.30, outputPerMillion: 1.20, sourceURL: googleGeminiPricingURL, verifiedAt: "unverified")
    ]

    public static func costDisclaimer(in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return "按 API 价折算（单价未核对；只含已计价记录，未知型号未计入）"
        case .en:
            return "API-equivalent estimate (rates unverified; covers priced records only, unknown models excluded)"
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

    /// Looks up per-1M-token rates in `PriceCatalog.entries` (marked `unverified` unless live-verified).
    /// Returns `nil` for unrecognized, empty, or unpublished internal model IDs — never falls back by vendor.
    public static func rates(for model: String) -> ModelRates? {
        let m = normalizeModelID(model)
        guard !m.isEmpty else { return nil }
        return entries.first(where: { $0.matches(normalizedModelID: m) })
    }

    /// Estimates API-equivalent USD when token breakdown is known and the model is in `PriceCatalog.entries`.
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
            + (Double(max(0, cacheRead)) / m) * r.cachedInputPerMillion
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
    public var timestamp: Date?
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
    public var hasRolloutMismatch: Bool
    public var expectedTotalTokens: Int?
    public var mismatchNote: String?

    public init(
        id: String,
        vendor: AgentVendor,
        origin: SampleOrigin = .standalone,
        timestamp: Date?,
        sessionID: String,
        projectName: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        recordedCostUSD: Double? = nil,
        isRateLimited: Bool = false,
        hasRolloutMismatch: Bool = false,
        expectedTotalTokens: Int? = nil,
        mismatchNote: String? = nil
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
        self.hasRolloutMismatch = hasRolloutMismatch
        self.expectedTotalTokens = expectedTotalTokens
        self.mismatchNote = mismatchNote
    }

    public init(
        unsplitID id: String,
        vendor: AgentVendor,
        origin: SampleOrigin,
        timestamp: Date?,
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
        self.hasRolloutMismatch = false
        self.expectedTotalTokens = nil
        self.mismatchNote = nil
    }

    public init(
        aggregatedID id: String,
        vendor: AgentVendor,
        origin: SampleOrigin,
        timestamp: Date?,
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
        isRateLimited: Bool,
        hasRolloutMismatch: Bool = false,
        expectedTotalTokens: Int? = nil,
        mismatchNote: String? = nil
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
        self.hasRolloutMismatch = hasRolloutMismatch
        self.expectedTotalTokens = expectedTotalTokens
        self.mismatchNote = mismatchNote
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

public struct RateLimitEvent: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var vendor: AgentVendor
    public var timestamp: Date
    public var sessionID: String
    public var code: String

    public init(id: String, vendor: AgentVendor, timestamp: Date, sessionID: String = "", code: String = "429") {
        self.id = id
        self.vendor = vendor
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.code = code
    }
}

public struct DailyVendorMetrics: Codable, Sendable, Equatable {
    public var uncachedInputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var recordCount: Int
    public var pricedRecordCount: Int
    public var unmatchedModelCount: Int
    public var estimatedCostUSD: Double?
    public var hasRolloutMismatch: Bool
    public var rolloutMismatchCount: Int
    public var mismatchDetails: [String]
    public var rateLimit429Count: Int
    public var completeness: DataCompleteness

    public init(
        uncachedInputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        recordCount: Int = 0,
        pricedRecordCount: Int = 0,
        unmatchedModelCount: Int = 0,
        estimatedCostUSD: Double? = nil,
        hasRolloutMismatch: Bool = false,
        rolloutMismatchCount: Int = 0,
        mismatchDetails: [String] = [],
        rateLimit429Count: Int = 0,
        completeness: DataCompleteness = .noData
    ) {
        self.uncachedInputTokens = uncachedInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.recordCount = recordCount
        self.pricedRecordCount = pricedRecordCount
        self.unmatchedModelCount = unmatchedModelCount
        self.estimatedCostUSD = estimatedCostUSD
        self.hasRolloutMismatch = hasRolloutMismatch
        self.rolloutMismatchCount = rolloutMismatchCount
        self.mismatchDetails = mismatchDetails
        self.rateLimit429Count = rateLimit429Count
        self.completeness = completeness
    }

    public func costNote(in language: AppLanguage) -> String? {
        guard pricedRecordCount > 0 || unmatchedModelCount > 0 else { return nil }
        return TelemetryFormatter.costCoverageNote(
            pricedCount: pricedRecordCount,
            unmatchedCount: unmatchedModelCount,
            in: language
        )
    }

    public func mismatchNote(in language: AppLanguage) -> String? {
        guard hasRolloutMismatch else { return nil }
        let unique = Array(NSOrderedSet(array: mismatchDetails)) as? [String] ?? mismatchDetails
        let joined = unique.joined(separator: "; ")
        if joined.isEmpty {
            return language == .zhHans ? "rollout 与 SQLite 总量不一致" : "rollout vs SQLite total mismatch"
        }
        return language == .zhHans ? "总量不一致（\(joined)）" : "Total mismatch (\(joined))"
    }
}

public struct DailyLedgerDay: Identifiable, Codable, Sendable, Equatable {
    public var id: String { dateString }
    public var dateString: String
    public var dayStart: Date
    public var uncachedInputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var recordCount: Int
    public var pricedRecordCount: Int
    public var unmatchedModelCount: Int
    public var estimatedCostUSD: Double?
    public var hasCodexRolloutMismatch: Bool
    public var codexMismatchDetails: [String]
    public var rateLimit429Count: Int
    public var vendors: [AgentVendor: DailyVendorMetrics]

    public init(
        dateString: String,
        dayStart: Date,
        uncachedInputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        recordCount: Int = 0,
        pricedRecordCount: Int = 0,
        unmatchedModelCount: Int = 0,
        estimatedCostUSD: Double? = nil,
        hasCodexRolloutMismatch: Bool = false,
        codexMismatchDetails: [String] = [],
        rateLimit429Count: Int = 0,
        vendors: [AgentVendor: DailyVendorMetrics] = [:]
    ) {
        self.dateString = dateString
        self.dayStart = dayStart
        self.uncachedInputTokens = uncachedInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.recordCount = recordCount
        self.pricedRecordCount = pricedRecordCount
        self.unmatchedModelCount = unmatchedModelCount
        self.estimatedCostUSD = estimatedCostUSD
        self.hasCodexRolloutMismatch = hasCodexRolloutMismatch
        self.codexMismatchDetails = codexMismatchDetails
        self.rateLimit429Count = rateLimit429Count
        self.vendors = vendors
    }

    public func metrics(for vendor: AgentVendor) -> DailyVendorMetrics {
        vendors[vendor] ?? DailyVendorMetrics()
    }

    public func costNote(in language: AppLanguage) -> String? {
        guard pricedRecordCount > 0 || unmatchedModelCount > 0 else { return nil }
        return TelemetryFormatter.costCoverageNote(
            pricedCount: pricedRecordCount,
            unmatchedCount: unmatchedModelCount,
            in: language
        )
    }

    public func codexMismatchNote(in language: AppLanguage) -> String? {
        guard hasCodexRolloutMismatch else { return nil }
        let unique = Array(NSOrderedSet(array: codexMismatchDetails)) as? [String] ?? codexMismatchDetails
        let joined = unique.joined(separator: "; ")
        if joined.isEmpty {
            return language == .zhHans ? "rollout 与 SQLite 总量不一致" : "rollout vs SQLite total mismatch"
        }
        return language == .zhHans ? "总量不一致（\(joined)）" : "Total mismatch (\(joined))"
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
    public var untimestamped: VendorWindowMetrics
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
        untimestamped: VendorWindowMetrics? = nil,
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
        self.untimestamped = untimestamped ?? VendorWindowMetrics(
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: 0,
            recordCount: 0,
            pricedRecordCount: 0,
            estimatedCostUSD: 0.0,
            unknownModelRecordCount: 0,
            cacheHitRate: nil,
            dataSource: dataSource,
            completeness: .noData,
            rateLimit429Count: 0
        )
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
    public var timeZoneIdentifier: String
    public var isDemoData: Bool
    public var vendorSummaries: [VendorSummary]
    public var dailyBuckets: [DailyVendorBucket]
    public var dailyBreakdown: [DailyLedgerDay]
    public var untimestampedLedger: DailyLedgerDay
    public var recentSessions: [UsageSample]
    public var relayRuns: [RelayRunSummary]
    public var rateLimitEvents: [RateLimitEvent]

    public static func untimestampedLabel(in language: AppLanguage) -> String {
        language == .zhHans ? "没有时间" : "No timestamp"
    }

    public init(
        capturedAt: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        isDemoData: Bool = false,
        vendorSummaries: [VendorSummary],
        dailyBuckets: [DailyVendorBucket],
        dailyBreakdown: [DailyLedgerDay] = [],
        untimestampedLedger: DailyLedgerDay = DailyLedgerDay(dateString: "No timestamp", dayStart: .distantPast),
        recentSessions: [UsageSample],
        relayRuns: [RelayRunSummary],
        rateLimitEvents: [RateLimitEvent] = []
    ) {
        self.capturedAt = capturedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isDemoData = isDemoData
        self.vendorSummaries = vendorSummaries
        self.dailyBuckets = dailyBuckets
        self.dailyBreakdown = dailyBreakdown
        self.untimestampedLedger = untimestampedLedger
        self.recentSessions = recentSessions
        self.relayRuns = relayRuns
        self.rateLimitEvents = rateLimitEvents
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

    public var pricedRecordCountToday: Int {
        vendorSummaries.map { $0.metrics(for: .today).pricedRecordCount }.reduce(0, +)
    }

    public var unknownModelRecordCountToday: Int {
        vendorSummaries.map { $0.metrics(for: .today).unknownModelRecordCount }.reduce(0, +)
    }

    public func todayCostNote(in language: AppLanguage) -> String? {
        guard pricedRecordCountToday > 0 || unknownModelRecordCountToday > 0 else { return nil }
        return TelemetryFormatter.costCoverageNote(
            pricedCount: pricedRecordCountToday,
            unmatchedCount: unknownModelRecordCountToday,
            in: language
        )
    }

    public var pricedRecordCount30d: Int {
        vendorSummaries.map { $0.metrics(for: .thirtyDays).pricedRecordCount }.reduce(0, +)
    }

    public var unknownModelRecordCount30d: Int {
        vendorSummaries.map(\.unknownModelRecordCount30d).reduce(0, +)
    }

    public func thirtyDayCostNote(in language: AppLanguage) -> String? {
        guard pricedRecordCount30d > 0 || unknownModelRecordCount30d > 0 else { return nil }
        return TelemetryFormatter.costCoverageNote(
            pricedCount: pricedRecordCount30d,
            unmatchedCount: unknownModelRecordCount30d,
            in: language
        )
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

    public static func costCoverageNote(
        pricedCount: Int,
        unmatchedCount: Int,
        in language: AppLanguage
    ) -> String {
        switch language {
        case .zhHans:
            if unmatchedCount > 0 {
                return "只含已计价的 \(pricedCount) 条，另有 \(unmatchedCount) 条未知型号未计入"
            }
            return "含已计价的 \(pricedCount) 条，0 条未知型号未计入"
        case .en:
            return "Covers \(pricedCount) priced records only; \(unmatchedCount) unknown-model records excluded"
        }
    }
}
