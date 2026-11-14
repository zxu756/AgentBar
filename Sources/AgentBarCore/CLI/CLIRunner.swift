import Foundation

public struct CLIExecutionResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct CLIWindowPayload: Codable, Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let totalTokens: Int?
    public let recordCount: Int
    public let pricedRecordCount: Int
    public let estimatedCostUSD: Double?
    public let unknownModelRecordCount: Int
    public let unmatchedModelCount: Int
    public let costNote: String?
    public let cacheHitRate: Double?
    public let dataSource: String
    public let completeness: String
    public let completenessLabel: String
    public let hasRolloutMismatch: Bool
    public let rolloutMismatchCount: Int
    public let mismatchNote: String?
    public let rateLimit429Count: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheWriteTokens
        case totalTokens
        case recordCount
        case pricedRecordCount
        case estimatedCostUSD
        case unknownModelRecordCount
        case unmatchedModelCount
        case costNote
        case cacheHitRate
        case dataSource
        case completeness
        case completenessLabel
        case hasRolloutMismatch
        case rolloutMismatchCount
        case mismatchNote
        case rateLimit429Count
    }

    public init(metrics: VendorWindowMetrics, vendor: AgentVendor, language: AppLanguage) {
        self.inputTokens = metrics.inputTokens
        self.outputTokens = metrics.outputTokens
        self.cacheReadTokens = metrics.cacheReadTokens
        self.cacheWriteTokens = metrics.cacheWriteTokens
        self.totalTokens = metrics.totalTokens
        self.recordCount = metrics.recordCount
        self.pricedRecordCount = metrics.pricedRecordCount
        self.estimatedCostUSD = metrics.estimatedCostUSD
        self.unknownModelRecordCount = metrics.unknownModelRecordCount
        self.unmatchedModelCount = metrics.unknownModelRecordCount
        self.costNote = metrics.costNote(in: language)
        self.cacheHitRate = metrics.cacheHitRate
        self.dataSource = LocalTelemetryCollector.defaultDataSourceDescription(for: vendor, language: language)
        self.completeness = metrics.completeness.rawValue
        self.completenessLabel = metrics.completeness.label(in: language)
        self.hasRolloutMismatch = metrics.hasRolloutMismatch
        self.rolloutMismatchCount = metrics.rolloutMismatchCount
        self.mismatchNote = metrics.mismatchNote(in: language)
        self.rateLimit429Count = metrics.rateLimit429Count
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeOptional(inputTokens, forKey: .inputTokens, in: &c)
        try encodeOptional(outputTokens, forKey: .outputTokens, in: &c)
        try encodeOptional(cacheReadTokens, forKey: .cacheReadTokens, in: &c)
        try encodeOptional(cacheWriteTokens, forKey: .cacheWriteTokens, in: &c)
        try encodeOptional(totalTokens, forKey: .totalTokens, in: &c)
        try c.encode(recordCount, forKey: .recordCount)
        try c.encode(pricedRecordCount, forKey: .pricedRecordCount)
        try encodeOptional(estimatedCostUSD, forKey: .estimatedCostUSD, in: &c)
        try c.encode(unknownModelRecordCount, forKey: .unknownModelRecordCount)
        try c.encode(unmatchedModelCount, forKey: .unmatchedModelCount)
        try encodeOptional(costNote, forKey: .costNote, in: &c)
        try encodeOptional(cacheHitRate, forKey: .cacheHitRate, in: &c)
        try c.encode(dataSource, forKey: .dataSource)
        try c.encode(completeness, forKey: .completeness)
        try c.encode(completenessLabel, forKey: .completenessLabel)
        try c.encode(hasRolloutMismatch, forKey: .hasRolloutMismatch)
        try c.encode(rolloutMismatchCount, forKey: .rolloutMismatchCount)
        try encodeOptional(mismatchNote, forKey: .mismatchNote, in: &c)
        try c.encode(rateLimit429Count, forKey: .rateLimit429Count)
    }
}

public struct CLIVendorPayload: Codable, Sendable, Equatable {
    public let vendor: String
    public let displayName: String
    public let dataSource: String
    public let completeness: String
    public let completenessLabel: String
    public let activeModel: String?
    public let sessionCount30d: Int
    public let pricedRecordCount30d: Int
    public let unknownModelRecordCount30d: Int
    public let unmatchedModelCount30d: Int
    public let costNote30d: String?
    public let hasRolloutMismatch30d: Bool
    public let mismatchNote30d: String?
    public let rateLimitHits24h: Int
    public let windows: [String: CLIWindowPayload]

    enum CodingKeys: String, CodingKey {
        case vendor
        case displayName
        case dataSource
        case completeness
        case completenessLabel
        case activeModel
        case sessionCount30d
        case pricedRecordCount30d
        case unknownModelRecordCount30d
        case unmatchedModelCount30d
        case costNote30d
        case hasRolloutMismatch30d
        case mismatchNote30d
        case rateLimitHits24h
        case windows
    }

    public init(summary: VendorSummary, language: AppLanguage) {
        let w30 = summary.metrics(for: .thirtyDays)
        self.vendor = summary.vendor.rawValue
        self.displayName = summary.vendor.displayName
        self.dataSource = LocalTelemetryCollector.defaultDataSourceDescription(for: summary.vendor, language: language)
        self.completeness = summary.completeness.rawValue
        self.completenessLabel = summary.completeness.label(in: language)
        self.activeModel = (summary.activeModel.isEmpty || summary.activeModel == "—") ? nil : summary.activeModel
        self.sessionCount30d = summary.sessionCount30d
        self.pricedRecordCount30d = w30.pricedRecordCount
        self.unknownModelRecordCount30d = summary.unknownModelRecordCount30d
        self.unmatchedModelCount30d = summary.unknownModelRecordCount30d
        self.costNote30d = w30.costNote(in: language)
        self.hasRolloutMismatch30d = w30.hasRolloutMismatch
        self.mismatchNote30d = w30.mismatchNote(in: language)
        self.rateLimitHits24h = summary.rateLimitHits24h

        var winMap: [String: CLIWindowPayload] = [:]
        for w in TelemetryWindow.allCases {
            winMap[w.rawValue] = CLIWindowPayload(metrics: summary.metrics(for: w), vendor: summary.vendor, language: language)
        }
        self.windows = winMap
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vendor, forKey: .vendor)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(dataSource, forKey: .dataSource)
        try c.encode(completeness, forKey: .completeness)
        try c.encode(completenessLabel, forKey: .completenessLabel)
        try encodeOptional(activeModel, forKey: .activeModel, in: &c)
        try c.encode(sessionCount30d, forKey: .sessionCount30d)
        try c.encode(pricedRecordCount30d, forKey: .pricedRecordCount30d)
        try c.encode(unknownModelRecordCount30d, forKey: .unknownModelRecordCount30d)
        try c.encode(unmatchedModelCount30d, forKey: .unmatchedModelCount30d)
        try encodeOptional(costNote30d, forKey: .costNote30d, in: &c)
        try c.encode(hasRolloutMismatch30d, forKey: .hasRolloutMismatch30d)
        try encodeOptional(mismatchNote30d, forKey: .mismatchNote30d, in: &c)
        try c.encode(rateLimitHits24h, forKey: .rateLimitHits24h)
        try c.encode(windows, forKey: .windows)
    }
}

public struct CLIDailyVendorPayload: Codable, Sendable, Equatable {
    public let uncachedInputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let recordCount: Int
    public let pricedRecordCount: Int
    public let unmatchedModelCount: Int
    public let estimatedCostUSD: Double?
    public let costNote: String?
    public let hasRolloutMismatch: Bool
    public let rolloutMismatchCount: Int
    public let mismatchNote: String?
    public let rateLimit429Count: Int
    public let completeness: String
    public let completenessLabel: String

    enum CodingKeys: String, CodingKey {
        case uncachedInputTokens
        case cachedInputTokens
        case cacheWriteTokens
        case outputTokens
        case totalTokens
        case recordCount
        case pricedRecordCount
        case unmatchedModelCount
        case estimatedCostUSD
        case costNote
        case hasRolloutMismatch
        case rolloutMismatchCount
        case mismatchNote
        case rateLimit429Count
        case completeness
        case completenessLabel
    }

    public init(metrics: DailyVendorMetrics, language: AppLanguage) {
        self.uncachedInputTokens = metrics.uncachedInputTokens
        self.cachedInputTokens = metrics.cachedInputTokens
        self.cacheWriteTokens = metrics.cacheWriteTokens
        self.outputTokens = metrics.outputTokens
        self.totalTokens = metrics.totalTokens
        self.recordCount = metrics.recordCount
        self.pricedRecordCount = metrics.pricedRecordCount
        self.unmatchedModelCount = metrics.unmatchedModelCount
        self.estimatedCostUSD = metrics.estimatedCostUSD
        self.costNote = metrics.costNote(in: language)
        self.hasRolloutMismatch = metrics.hasRolloutMismatch
        self.rolloutMismatchCount = metrics.rolloutMismatchCount
        self.mismatchNote = metrics.mismatchNote(in: language)
        self.rateLimit429Count = metrics.rateLimit429Count
        self.completeness = metrics.completeness.rawValue
        self.completenessLabel = metrics.completeness.label(in: language)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uncachedInputTokens, forKey: .uncachedInputTokens)
        try c.encode(cachedInputTokens, forKey: .cachedInputTokens)
        try c.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(totalTokens, forKey: .totalTokens)
        try c.encode(recordCount, forKey: .recordCount)
        try c.encode(pricedRecordCount, forKey: .pricedRecordCount)
        try c.encode(unmatchedModelCount, forKey: .unmatchedModelCount)
        try encodeOptional(estimatedCostUSD, forKey: .estimatedCostUSD, in: &c)
        try encodeOptional(costNote, forKey: .costNote, in: &c)
        try c.encode(hasRolloutMismatch, forKey: .hasRolloutMismatch)
        try c.encode(rolloutMismatchCount, forKey: .rolloutMismatchCount)
        try encodeOptional(mismatchNote, forKey: .mismatchNote, in: &c)
        try c.encode(rateLimit429Count, forKey: .rateLimit429Count)
        try c.encode(completeness, forKey: .completeness)
        try c.encode(completenessLabel, forKey: .completenessLabel)
    }
}

public struct CLIDailyEntryPayload: Codable, Sendable, Equatable {
    public let date: String
    public let uncachedInputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let recordCount: Int
    public let pricedRecordCount: Int
    public let unmatchedModelCount: Int
    public let estimatedCostUSD: Double?
    public let costNote: String?
    public let hasCodexRolloutMismatch: Bool
    public let codexMismatchNote: String?
    public let rateLimit429Count: Int
    public let vendors: [String: CLIDailyVendorPayload]

    enum CodingKeys: String, CodingKey {
        case date
        case uncachedInputTokens
        case cachedInputTokens
        case cacheWriteTokens
        case outputTokens
        case totalTokens
        case recordCount
        case pricedRecordCount
        case unmatchedModelCount
        case estimatedCostUSD
        case costNote
        case hasCodexRolloutMismatch
        case codexMismatchNote
        case rateLimit429Count
        case vendors
    }

    public init(day: DailyLedgerDay, language: AppLanguage) {
        self.date = day.dateString
        self.uncachedInputTokens = day.uncachedInputTokens
        self.cachedInputTokens = day.cachedInputTokens
        self.cacheWriteTokens = day.cacheWriteTokens
        self.outputTokens = day.outputTokens
        self.totalTokens = day.totalTokens
        self.recordCount = day.recordCount
        self.pricedRecordCount = day.pricedRecordCount
        self.unmatchedModelCount = day.unmatchedModelCount
        self.estimatedCostUSD = day.estimatedCostUSD
        self.costNote = day.costNote(in: language)
        self.hasCodexRolloutMismatch = day.hasCodexRolloutMismatch
        self.codexMismatchNote = day.codexMismatchNote(in: language)
        self.rateLimit429Count = day.rateLimit429Count

        var vMap: [String: CLIDailyVendorPayload] = [:]
        for v in AgentVendor.allCases {
            vMap[v.rawValue] = CLIDailyVendorPayload(metrics: day.metrics(for: v), language: language)
        }
        self.vendors = vMap
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(uncachedInputTokens, forKey: .uncachedInputTokens)
        try c.encode(cachedInputTokens, forKey: .cachedInputTokens)
        try c.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(totalTokens, forKey: .totalTokens)
        try c.encode(recordCount, forKey: .recordCount)
        try c.encode(pricedRecordCount, forKey: .pricedRecordCount)
        try c.encode(unmatchedModelCount, forKey: .unmatchedModelCount)
        try encodeOptional(estimatedCostUSD, forKey: .estimatedCostUSD, in: &c)
        try encodeOptional(costNote, forKey: .costNote, in: &c)
        try c.encode(hasCodexRolloutMismatch, forKey: .hasCodexRolloutMismatch)
        try encodeOptional(codexMismatchNote, forKey: .codexMismatchNote, in: &c)
        try c.encode(rateLimit429Count, forKey: .rateLimit429Count)
        try c.encode(vendors, forKey: .vendors)
    }
}

public struct CLIRelayStepPayload: Codable, Sendable, Equatable {
    public let stepID: String
    public let vendor: String?
    public let status: String
    public let durationSeconds: Int
    public let timestamp: String
    public let model: String?
    public let costUSD: Double?
    public let tokens: Int?

    enum CodingKeys: String, CodingKey {
        case stepID
        case vendor
        case status
        case durationSeconds
        case timestamp
        case model
        case costUSD
        case tokens
    }

    public init(step: RelayBatonStep) {
        self.stepID = step.stepID
        self.vendor = step.vendor?.rawValue
        self.status = step.status
        self.durationSeconds = step.durationSeconds
        self.timestamp = step.timestampString
        self.model = (step.model.isEmpty || step.model == "default") ? nil : step.model
        self.costUSD = step.costUSD
        self.tokens = step.tokens
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stepID, forKey: .stepID)
        try encodeOptional(vendor, forKey: .vendor, in: &c)
        try c.encode(status, forKey: .status)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(timestamp, forKey: .timestamp)
        try encodeOptional(model, forKey: .model, in: &c)
        try encodeOptional(costUSD, forKey: .costUSD, in: &c)
        try encodeOptional(tokens, forKey: .tokens, in: &c)
    }
}

public struct CLIRelayRunPayload: Codable, Sendable, Equatable {
    public let projectName: String
    public let stepCount: Int
    public let totalCostUSD: Double
    public let steps: [CLIRelayStepPayload]

    public init(run: RelayRunSummary) {
        self.projectName = run.projectName
        self.stepCount = run.steps.count
        self.totalCostUSD = run.totalCostUSD
        self.steps = run.steps.map(CLIRelayStepPayload.init)
    }
}

public struct CLISnapshotPayload: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let capturedAt: String
    public let timeZone: String
    public let language: String
    public let isDemoData: Bool
    public let pricingVersion: String
    public let costDisclaimer: String
    public let timeAttributionNote: String
    public let vendors: [String: CLIVendorPayload]
    public let dailyBreakdown: [CLIDailyEntryPayload]
    public let relayRuns: [CLIRelayRunPayload]

    public init(snapshot: TelemetrySnapshot, language: AppLanguage) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        self.schemaVersion = "1.1"
        self.capturedAt = iso.string(from: snapshot.capturedAt)
        self.timeZone = snapshot.timeZoneIdentifier
        self.language = language.rawValue
        self.isDemoData = snapshot.isDemoData
        self.pricingVersion = PriceCatalog.pricingVersion
        self.costDisclaimer = PriceCatalog.costDisclaimer(in: language)
        self.timeAttributionNote = language == .zhHans
            ? "M1 时间归属：Claude、Codex（rollout token_count 增量）、OpenCode（session_message）与 Mistral Vibe（unified journal）均按单条事件时间戳归桶；仅缺细账时退回会话时间。"
            : "M1 time attribution: Claude, Codex (rollout token_count deltas), OpenCode (session_message), and Mistral Vibe (unified journal) bucket by per-event timestamp, falling back to session time only when event logs are absent."

        var map: [String: CLIVendorPayload] = [:]
        for summary in snapshot.vendorSummaries {
            map[summary.vendor.rawValue] = CLIVendorPayload(summary: summary, language: language)
        }
        self.vendors = map
        self.dailyBreakdown = snapshot.dailyBreakdown.map { CLIDailyEntryPayload(day: $0, language: language) }
        self.relayRuns = snapshot.relayRuns.map(CLIRelayRunPayload.init)
    }
}

private func encodeOptional<T: Encodable, K: CodingKey>(
    _ value: T?,
    forKey key: K,
    in container: inout KeyedEncodingContainer<K>
) throws {
    if let value {
        try container.encode(value, forKey: key)
    } else {
        try container.encodeNil(forKey: key)
    }
}

public enum CLIRunner {

    public static func usageText(in language: AppLanguage = .en) -> String {
        if language == .zhHans {
            return """
            用法:
              AgentBar --cli snapshot [--json] [--lang en|zh] [--tz <UTC|local|时区ID>] [--home <目录>] [--workspace <目录>] [--now <ISO8601|秒>] [--no-zstd] [--demo]
              AgentBar --cli daily [--json] [--lang en|zh] [--tz <UTC|local|时区ID>] [--home <目录>] [--workspace <目录>] [--now <ISO8601|秒>] [--no-zstd] [--demo]
              AgentBar [--lang en|zh] [--demo]
              AgentBar --export-screenshots <输出目录> [--lang en|zh]
            """
        }
        return """
        Usage:
          AgentBar --cli snapshot [--json] [--lang en|zh] [--tz <UTC|local|tzID>] [--home <dir>] [--workspace <dir>] [--now <ISO8601|epoch>] [--no-zstd] [--demo]
          AgentBar --cli daily [--json] [--lang en|zh] [--tz <UTC|local|tzID>] [--home <dir>] [--workspace <dir>] [--now <ISO8601|epoch>] [--no-zstd] [--demo]
          AgentBar [--lang en|zh] [--demo]
          AgentBar --export-screenshots <dir> [--lang en|zh]
        """
    }

    public static func execute(
        arguments: [String],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> CLIExecutionResult {
        var defaultLang: AppLanguage = {
            if let first = preferredLanguages.first,
               first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("zh") {
                return .zhHans
            }
            return .en
        }()

        // Pre-scan --lang so error messages also honor requested language when valid
        for (i, arg) in arguments.enumerated() {
            if arg == "--lang", i + 1 < arguments.count, let parsed = AppLanguage.parseCLI(arguments[i + 1]) {
                defaultLang = parsed
            } else if arg.hasPrefix("--lang="), let parsed = AppLanguage.parseCLI(String(arg.dropFirst("--lang=".count))) {
                defaultLang = parsed
            }
        }

        let tokens = Array(arguments.dropFirst())
        if tokens == ["--help"] || tokens == ["-h"] || tokens == ["--cli", "--help"] || tokens == ["--cli", "-h"] {
            return CLIExecutionResult(exitCode: 0, stdout: usageText(in: defaultLang) + "\n", stderr: "")
        }

        var sawCLI = false
        var subcommand: String?
        var outputJSON = false
        var useDemo = false
        var allowZstd = true
        var homeOverride: URL?
        var workspaceOverride: URL?
        var nowOverride: Date?
        var timeZoneOverride: TimeZone?
        var language = defaultLang

        var idx = 0
        while idx < tokens.count {
            let arg = tokens[idx]
            switch arg {
            case "--cli":
                sawCLI = true
                idx += 1
            case "--json":
                outputJSON = true
                idx += 1
            case "--demo":
                useDemo = true
                idx += 1
            case "--no-zstd":
                allowZstd = false
                idx += 1
            case "--help", "-h":
                return CLIExecutionResult(exitCode: 0, stdout: usageText(in: language) + "\n", stderr: "")
            case "--lang":
                guard idx + 1 < tokens.count, let parsed = AppLanguage.parseCLI(tokens[idx + 1]) else {
                    let msg = language == .zhHans
                        ? "错误：--lang 参数无效（仅支持 en 或 zh）。\n"
                        : "Error: invalid --lang value (expected en or zh).\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg + usageText(in: language) + "\n")
                }
                language = parsed
                idx += 2
            case _ where arg.hasPrefix("--lang="):
                let val = String(arg.dropFirst("--lang=".count))
                guard let parsed = AppLanguage.parseCLI(val) else {
                    let msg = language == .zhHans
                        ? "错误：--lang 参数无效（仅支持 en 或 zh）。\n"
                        : "Error: invalid --lang value (expected en or zh).\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg + usageText(in: language) + "\n")
                }
                language = parsed
                idx += 1
            case "--tz":
                guard idx + 1 < tokens.count, let parsedTZ = parseTimeZoneArgument(tokens[idx + 1]) else {
                    let msg = language == .zhHans
                        ? "错误：--tz 参数无效（支持 UTC、local 或有效 IANA 时区名）。\n"
                        : "Error: invalid --tz value (expected UTC, local, or a valid IANA time zone identifier).\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg)
                }
                timeZoneOverride = parsedTZ
                idx += 2
            case _ where arg.hasPrefix("--tz="):
                let val = String(arg.dropFirst("--tz=".count))
                guard let parsedTZ = parseTimeZoneArgument(val) else {
                    let msg = language == .zhHans
                        ? "错误：--tz 参数无效（支持 UTC、local 或有效 IANA 时区名）。\n"
                        : "Error: invalid --tz value (expected UTC, local, or a valid IANA time zone identifier).\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg)
                }
                timeZoneOverride = parsedTZ
                idx += 1
            case "--home":
                guard idx + 1 < tokens.count, !tokens[idx + 1].isEmpty else {
                    let msg = language == .zhHans ? "错误：--home 需要提供目录路径。\n" : "Error: --home requires a directory path.\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg)
                }
                homeOverride = URL(fileURLWithPath: tokens[idx + 1])
                idx += 2
            case _ where arg.hasPrefix("--home="):
                let val = String(arg.dropFirst("--home=".count))
                guard !val.isEmpty else {
                    let msg = language == .zhHans ? "错误：--home 需要提供目录路径。\n" : "Error: --home requires a directory path.\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg)
                }
                homeOverride = URL(fileURLWithPath: val)
                idx += 1
            case "--workspace":
                guard idx + 1 < tokens.count, !tokens[idx + 1].isEmpty else {
                    let msg = language == .zhHans ? "错误：--workspace 需要提供目录路径。\n" : "Error: --workspace requires a directory path.\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg)
                }
                workspaceOverride = URL(fileURLWithPath: tokens[idx + 1])
                idx += 2
            case _ where arg.hasPrefix("--workspace="):
                let val = String(arg.dropFirst("--workspace=".count))
                guard !val.isEmpty else {
                    let msg = language == .zhHans ? "错误：--workspace 需要提供目录路径。\n" : "Error: --workspace requires a directory path.\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg)
                }
                workspaceOverride = URL(fileURLWithPath: val)
                idx += 1
            case "--now":
                guard idx + 1 < tokens.count, let parsedNow = parseNowArgument(tokens[idx + 1]) else {
                    let msg = language == .zhHans ? "错误：--now 需要有效的 ISO8601 时间或 Unix 秒数。\n" : "Error: --now requires a valid ISO8601 timestamp or Unix epoch seconds.\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg)
                }
                nowOverride = parsedNow
                idx += 2
            case _ where arg.hasPrefix("--now="):
                let val = String(arg.dropFirst("--now=".count))
                guard let parsedNow = parseNowArgument(val) else {
                    let msg = language == .zhHans ? "错误：--now 需要有效的 ISO8601 时间或 Unix 秒数。\n" : "Error: --now requires a valid ISO8601 timestamp or Unix epoch seconds.\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg)
                }
                nowOverride = parsedNow
                idx += 1
            default:
                if arg.hasPrefix("-") {
                    let msg = language == .zhHans
                        ? "错误：未知选项 '\(arg)'。\n"
                        : "Error: unknown option '\(arg)'.\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg + usageText(in: language) + "\n")
                }
                if subcommand == nil {
                    subcommand = arg
                    idx += 1
                } else {
                    let msg = language == .zhHans
                        ? "错误：多余的位置参数 '\(arg)'。\n"
                        : "Error: unexpected positional argument '\(arg)'.\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg + usageText(in: language) + "\n")
                }
            }
        }

        guard sawCLI else {
            let msg = language == .zhHans ? "错误：缺少 --cli 标志。\n" : "Error: missing --cli flag.\n"
            return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg + usageText(in: language) + "\n")
        }

        guard let subcommand else {
            let msg = language == .zhHans
                ? "错误：缺少子命令（可用子命令：snapshot, daily）。\n"
                : "Error: missing subcommand (available: snapshot, daily).\n"
            return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg + usageText(in: language) + "\n")
        }

        guard subcommand == "snapshot" || subcommand == "daily" else {
            let msg = language == .zhHans
                ? "错误：未知子命令 '\(subcommand)'（可用子命令：snapshot, daily）。\n"
                : "Error: unknown subcommand '\(subcommand)' (available: snapshot, daily).\n"
            return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg + usageText(in: language) + "\n")
        }

        let evalTimeZone = timeZoneOverride ?? .current
        let snapshot: TelemetrySnapshot
        if useDemo {
            snapshot = DemoSnapshotFactory.makePreviewSnapshot()
        } else {
            let fm = FileManager.default
            if let explicitHome = homeOverride {
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: explicitHome.path, isDirectory: &isDir) || !isDir.boolValue {
                    let msg = language == .zhHans
                        ? "错误：--home 指定的目录不存在或不是目录：'\(explicitHome.path)'。\n"
                        : "Error: --home directory does not exist or is not a directory: '\(explicitHome.path)'.\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg)
                }
            }
            if let explicitWorkspace = workspaceOverride {
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: explicitWorkspace.path, isDirectory: &isDir) || !isDir.boolValue {
                    let msg = language == .zhHans
                        ? "错误：--workspace 指定的目录不存在或不是目录：'\(explicitWorkspace.path)'。\n"
                        : "Error: --workspace directory does not exist or is not a directory: '\(explicitWorkspace.path)'.\n"
                    return CLIExecutionResult(exitCode: 2, stdout: "", stderr: msg)
                }
            }
            let homeURL = homeOverride ?? CollectorPaths.resolveDefaultHomeDirectory()
            let paths = CollectorPaths.liveDefault(home: homeURL, workspaceRoot: workspaceOverride)
            let evalNow = nowOverride ?? Date()
            snapshot = LocalTelemetryCollector.collectSnapshot(
                paths: paths,
                now: evalNow,
                lookbackDays: 30,
                allowZstdRollout: allowZstd,
                timeZone: evalTimeZone
            )
        }

        if outputJSON {
            let payload = CLISnapshotPayload(snapshot: snapshot, language: language)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(payload)
                let text = String(decoding: data, as: UTF8.self) + "\n"
                return CLIExecutionResult(exitCode: 0, stdout: text, stderr: "")
            } catch {
                return CLIExecutionResult(exitCode: 1, stdout: "", stderr: "Failed to encode JSON: \(error)\n")
            }
        } else if subcommand == "daily" {
            let formatted = formatDailyHumanReadable(snapshot: snapshot, language: language)
            return CLIExecutionResult(exitCode: 0, stdout: formatted, stderr: "")
        } else {
            let formatted = formatHumanReadable(snapshot: snapshot, language: language)
            return CLIExecutionResult(exitCode: 0, stdout: formatted, stderr: "")
        }
    }

    public static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        let res = execute(arguments: arguments)
        if !res.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(res.stdout.utf8))
        }
        if !res.stderr.isEmpty {
            FileHandle.standardError.write(Data(res.stderr.utf8))
        }
        return res.exitCode
    }

    private static func parseTimeZoneArgument(_ raw: String) -> TimeZone? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower == "utc" || lower == "gmt" || lower == "z" {
            return TimeZone(secondsFromGMT: 0)
        }
        if lower == "local" {
            return TimeZone.current
        }
        return TimeZone(identifier: trimmed)
    }

    private static func parseNowArgument(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let epoch = Double(trimmed) {
            return Date(timeIntervalSince1970: epoch)
        }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: trimmed) { return d }
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        return isoPlain.date(from: trimmed)
    }

    public static func formatHumanReadable(snapshot: TelemetrySnapshot, language: AppLanguage) -> String {
        let isZH = (language == .zhHans)
        var lines: [String] = []
        let demoBanner = snapshot.isDemoData
            ? (isZH ? " [DEMO / 演示数据]" : " [DEMO]")
            : ""
        let headerTitle = isZH ? "AgentBar 本地只读用量快照" : "AgentBar Read-Only Local Snapshot"
        lines.append("\(headerTitle)\(demoBanner)")
        lines.append("\(PriceCatalog.costDisclaimer(in: language))")
        lines.append(isZH
            ? "M1 时间归属：Claude、Codex、OpenCode 与 Mistral Vibe 均按单条事件时间戳归桶（时区：\(snapshot.timeZoneIdentifier)）。"
            : "M1 time attribution: Claude, Codex, OpenCode, and Mistral Vibe bucket by per-event timestamp (tz: \(snapshot.timeZoneIdentifier)).")
        lines.append(String(repeating: "-", count: 78))

        for item in snapshot.vendorSummaries {
            let compLabel = item.completeness.label(in: language)
            let localizedSource = LocalTelemetryCollector.defaultDataSourceDescription(for: item.vendor, language: language)
            let wToday = item.metrics(for: .today)
            let w30 = item.metrics(for: .thirtyDays)

            let todayTokStr = TelemetryFormatter.optionalTokens(wToday.totalTokens, completeness: wToday.completeness, language: language)
            let todayCostBase = TelemetryFormatter.optionalUSD(wToday.estimatedCostUSD, completeness: wToday.completeness, language: language)
            let todayCostStr: String = {
                if let note = wToday.costNote(in: language), wToday.estimatedCostUSD != nil {
                    return isZH ? "\(todayCostBase)（\(note)）" : "\(todayCostBase) (\(note))"
                }
                return todayCostBase
            }()
            let tok30Str = TelemetryFormatter.optionalTokens(w30.totalTokens, completeness: w30.completeness, language: language)
            let cost30Base = TelemetryFormatter.optionalUSD(w30.estimatedCostUSD, completeness: w30.completeness, language: language)
            let cost30Str: String = {
                if let note = w30.costNote(in: language) {
                    return isZH ? "\(cost30Base)（\(note)）" : "\(cost30Base) (\(note))"
                }
                return cost30Base
            }()
            let hit30Str = TelemetryFormatter.optionalPercent(w30.cacheHitRate, completeness: w30.completeness, language: language)

            lines.append("[\(item.vendor.displayName)] (\(compLabel)) — \(localizedSource)")
            if isZH {
                var row = "  今天: Token \(todayTokStr), 折算 \(todayCostStr) | 30天: Token \(tok30Str), 折算 \(cost30Str), 缓存命中率 \(hit30Str), 记录数 \(w30.recordCount)"
                if item.rateLimitHits24h > 0 {
                    row += ", 24h限流(429) \(item.rateLimitHits24h)"
                }
                if let mis = w30.mismatchNote(in: language) {
                    row += ", \(mis)"
                }
                lines.append(row)
            } else {
                var row = "  Today: tokens \(todayTokStr), cost \(todayCostStr) | 30d: tokens \(tok30Str), cost \(cost30Str), cache hit \(hit30Str), records \(w30.recordCount)"
                if item.rateLimitHits24h > 0 {
                    row += ", 24h 429s \(item.rateLimitHits24h)"
                }
                if let mis = w30.mismatchNote(in: language) {
                    row += ", \(mis)"
                }
                lines.append(row)
            }
        }

        if !snapshot.relayRuns.isEmpty {
            lines.append(String(repeating: "-", count: 78))
            for run in snapshot.relayRuns {
                if isZH {
                    lines.append("接力日志 (\(run.projectName)): \(run.steps.count) 个步骤, 已记录开销 \(TelemetryFormatter.usd(run.totalCostUSD))")
                } else {
                    lines.append("Relay log (\(run.projectName)): \(run.steps.count) steps, recorded cost \(TelemetryFormatter.usd(run.totalCostUSD))")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public static func formatDailyHumanReadable(snapshot: TelemetrySnapshot, language: AppLanguage) -> String {
        let isZH = (language == .zhHans)
        var lines: [String] = []
        let demoBanner = snapshot.isDemoData
            ? (isZH ? " [DEMO / 演示数据]" : " [DEMO]")
            : ""
        let headerTitle = isZH
            ? "AgentBar 14 天按日事件细账（时区：\(snapshot.timeZoneIdentifier)）"
            : "AgentBar 14-Day Per-Event Daily Ledger (tz: \(snapshot.timeZoneIdentifier))"
        lines.append("\(headerTitle)\(demoBanner)")
        lines.append(PriceCatalog.costDisclaimer(in: language))
        lines.append(String(repeating: "-", count: 78))

        for day in snapshot.dailyBreakdown {
            let tokStr = TelemetryFormatter.compactTokens(day.totalTokens)
            let costStr: String = {
                guard let c = day.estimatedCostUSD else {
                    return isZH ? "未知" : "Unknown"
                }
                let base = TelemetryFormatter.usd(c)
                if let note = day.costNote(in: language) {
                    return isZH ? "\(base)（\(note)）" : "\(base) (\(note))"
                }
                return base
            }()

            if isZH {
                var row = "\(day.dateString) | Token \(tokStr) | 折算 \(costStr) | 记录 \(day.recordCount) | 429限流 \(day.rateLimit429Count)"
                if let mis = day.codexMismatchNote(in: language) {
                    row += " | \(mis)"
                }
                lines.append(row)
            } else {
                var row = "\(day.dateString) | tokens \(tokStr) | cost \(costStr) | records \(day.recordCount) | 429s \(day.rateLimit429Count)"
                if let mis = day.codexMismatchNote(in: language) {
                    row += " | \(mis)"
                }
                lines.append(row)
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
