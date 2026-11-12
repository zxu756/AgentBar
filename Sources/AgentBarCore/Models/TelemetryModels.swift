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
        case .claudeCode: return Color(red: 0.88, green: 0.48, blue: 0.28)   // Burnished Copper
        case .codex: return Color(red: 0.29, green: 0.62, blue: 0.51)        // Mineral Jade
        case .openCode: return Color(red: 0.36, green: 0.55, blue: 0.75)     // Steel Cerulean
        case .mistralVibe: return Color(red: 0.85, green: 0.64, blue: 0.25)  // Ochre Gold
        case .antigravity: return Color(red: 0.61, green: 0.49, blue: 0.78)  // Muted Iris
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
}

public enum PriceCatalog {
    /// Estimates API-equivalent USD when a local CLI session is on a flat subscription and logs `cost = nil` or `0`.
    /// Rates are per 1,000,000 tokens: (input, output, cacheRead, cacheWrite).
    public static func estimateUSD(
        model: String,
        vendor: AgentVendor,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int
    ) -> Double {
        let lower = model.lowercased()
        let rates: (inp: Double, out: Double, cr: Double, cw: Double)

        if lower.contains("opus") {
            rates = (15.0, 75.0, 1.50, 18.75)
        } else if lower.contains("sonnet") || lower.contains("fable") {
            rates = (3.0, 15.0, 0.30, 3.75)
        } else if lower.contains("haiku") {
            rates = (0.80, 4.0, 0.08, 1.0)
        } else if lower.contains("deepseek") {
            rates = (0.30, 1.20, 0.007, 0.30)
        } else if lower.contains("gpt-6") || lower.contains("gpt-5") || lower.contains("codex") || vendor == .codex {
            rates = (2.00, 8.00, 0.50, 2.00)
        } else if lower.contains("carbon") || lower.contains("pro") {
            rates = (1.25, 5.00, 0.30, 1.25)
        } else if lower.contains("flash") || lower.contains("argon") {
            rates = (0.30, 1.20, 0.075, 0.30)
        } else {
            switch vendor {
            case .claudeCode: rates = (3.0, 15.0, 0.30, 3.75)
            case .codex: rates = (2.0, 8.0, 0.50, 2.0)
            case .openCode: rates = (0.50, 2.0, 0.05, 0.50)
            case .mistralVibe: rates = (0.30, 1.20, 0.007, 0.30)
            case .antigravity: rates = (1.25, 5.0, 0.30, 1.25)
            }
        }

        let m = 1_000_000.0
        return (Double(input) / m) * rates.inp
            + (Double(output) / m) * rates.out
            + (Double(cacheRead) / m) * rates.cr
            + (Double(cacheWrite) / m) * rates.cw
    }
}

public struct UsageSample: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var vendor: AgentVendor
    public var timestamp: Date
    public var sessionID: String
    public var projectName: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var recordedCostUSD: Double?
    public var estimatedAPICostUSD: Double
    public var isRateLimited: Bool

    public init(
        id: String,
        vendor: AgentVendor,
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
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.projectName = projectName
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.recordedCostUSD = recordedCostUSD
        self.estimatedAPICostUSD = PriceCatalog.estimateUSD(
            model: model,
            vendor: vendor,
            input: self.inputTokens,
            output: self.outputTokens,
            cacheRead: self.cacheReadTokens,
            cacheWrite: self.cacheWriteTokens
        )
        self.isRateLimited = isRateLimited
    }

    public var effectiveCostUSD: Double {
        if let rec = recordedCostUSD, rec > 0 {
            return rec
        }
        return estimatedAPICostUSD
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
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
    public var todayCostUSD: Double
    public var todayTokens: Int
    public var fiveHourTokens: Int
    public var fiveHourCostUSD: Double
    public var thirtyDayCostUSD: Double
    public var thirtyDayTokens: Int
    public var sessionCount30d: Int
    public var cacheHitRatio: Double
    public var activeModel: String
    public var lastActive: Date?
    public var rateLimitHits24h: Int

    public init(
        vendor: AgentVendor,
        sourceAvailable: Bool,
        todayCostUSD: Double,
        todayTokens: Int,
        fiveHourTokens: Int,
        fiveHourCostUSD: Double,
        thirtyDayCostUSD: Double,
        thirtyDayTokens: Int,
        sessionCount30d: Int,
        cacheHitRatio: Double,
        activeModel: String,
        lastActive: Date?,
        rateLimitHits24h: Int
    ) {
        self.vendor = vendor
        self.sourceAvailable = sourceAvailable
        self.todayCostUSD = todayCostUSD
        self.todayTokens = todayTokens
        self.fiveHourTokens = fiveHourTokens
        self.fiveHourCostUSD = fiveHourCostUSD
        self.thirtyDayCostUSD = thirtyDayCostUSD
        self.thirtyDayTokens = thirtyDayTokens
        self.sessionCount30d = sessionCount30d
        self.cacheHitRatio = cacheHitRatio
        self.activeModel = activeModel
        self.lastActive = lastActive
        self.rateLimitHits24h = rateLimitHits24h
    }

    public var fiveHourBurstFraction: Double {
        min(1.0, Double(fiveHourTokens) / Double(max(1, vendor.fiveHourBurstCeilingTokens)))
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
        steps.filter { $0.status.lowercased().contains("flag") || $0.status.lowercased().contains("fail") }.count
    }
}

public struct TelemetrySnapshot: Codable, Sendable, Equatable {
    public var capturedAt: Date
    public var vendorSummaries: [VendorSummary]
    public var dailyBuckets: [DailyVendorBucket]
    public var recentSessions: [UsageSample]
    public var relayRuns: [RelayRunSummary]

    public init(
        capturedAt: Date,
        vendorSummaries: [VendorSummary],
        dailyBuckets: [DailyVendorBucket],
        recentSessions: [UsageSample],
        relayRuns: [RelayRunSummary]
    ) {
        self.capturedAt = capturedAt
        self.vendorSummaries = vendorSummaries
        self.dailyBuckets = dailyBuckets
        self.recentSessions = recentSessions
        self.relayRuns = relayRuns
    }

    public var todayTotalCostUSD: Double {
        vendorSummaries.map(\.todayCostUSD).reduce(0, +)
    }

    public var todayTotalTokens: Int {
        vendorSummaries.map(\.todayTokens).reduce(0, +)
    }

    public var fiveHourTotalTokens: Int {
        vendorSummaries.map(\.fiveHourTokens).reduce(0, +)
    }

    public var fiveHourTotalCostUSD: Double {
        vendorSummaries.map(\.fiveHourCostUSD).reduce(0, +)
    }

    public var thirtyDayTotalCostUSD: Double {
        vendorSummaries.map(\.thirtyDayCostUSD).reduce(0, +)
    }

    public var thirtyDayTotalTokens: Int {
        vendorSummaries.map(\.thirtyDayTokens).reduce(0, +)
    }

    public var rateLimitHits24h: Int {
        vendorSummaries.map(\.rateLimitHits24h).reduce(0, +)
    }

    public var activeVendorCount: Int {
        vendorSummaries.filter { $0.thirtyDayTokens > 0 || $0.sourceAvailable }.count
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

    public static func percent(_ ratio: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, ratio)) * 100.0)
    }
}
