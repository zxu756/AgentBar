import Foundation
import SQLite3

public struct CollectorPaths: Sendable, Equatable {
    public var claudeProjectsDir: URL
    public var codexSQLiteFile: URL
    public var openCodeSQLiteFile: URL
    public var vibeSessionsDir: URL
    public var antigravityLogsDir: URL
    public var workspaceRootDir: URL

    public init(
        claudeProjectsDir: URL,
        codexSQLiteFile: URL,
        openCodeSQLiteFile: URL,
        vibeSessionsDir: URL,
        antigravityLogsDir: URL,
        workspaceRootDir: URL
    ) {
        self.claudeProjectsDir = claudeProjectsDir
        self.codexSQLiteFile = codexSQLiteFile
        self.openCodeSQLiteFile = openCodeSQLiteFile
        self.vibeSessionsDir = vibeSessionsDir
        self.antigravityLogsDir = antigravityLogsDir
        self.workspaceRootDir = workspaceRootDir
    }

    public static func resolveDefaultHomeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let envHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envHome.isEmpty {
            return URL(fileURLWithPath: envHome)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func liveDefault(
        home: URL = CollectorPaths.resolveDefaultHomeDirectory(),
        workspaceRoot: URL? = nil
    ) -> CollectorPaths {
        CollectorPaths(
            claudeProjectsDir: home.appendingPathComponent(".claude/projects"),
            codexSQLiteFile: home.appendingPathComponent(".codex/state_5.sqlite"),
            openCodeSQLiteFile: home.appendingPathComponent(".local/share/opencode/opencode.db"),
            vibeSessionsDir: home.appendingPathComponent(".vibe/logs/session/unified"),
            antigravityLogsDir: home.appendingPathComponent(".gemini/antigravity-cli/log"),
            workspaceRootDir: workspaceRoot ?? home.appendingPathComponent("Projects")
        )
    }
}

private final class CodexRolloutCache: @unchecked Sendable {
    static let shared = CodexRolloutCache()

    struct Key: Hashable {
        let path: String
        let modTime: TimeInterval
        let fileSize: UInt64
    }

    struct TurnEvent: Sendable {
        let index: Int
        let timestamp: Date?
        let uncachedInput: Int
        let cachedInput: Int
        let cacheWrite: Int
        let output: Int
        let model: String?
    }

    struct RateLimitHit: Sendable {
        let index: Int
        let timestamp: Date?
    }

    struct Entry: Sendable {
        let events: [TurnEvent]
        let rateLimits: [RateLimitHit]
        let reportedTotalTokens: Int?
        let latestModel: String?

        var rolloutTotalTokens: Int {
            events.reduce(0) { $0 + $1.uncachedInput + $1.cachedInput + $1.cacheWrite + $1.output }
        }
    }

    private let lock = NSLock()
    private var storage: [Key: Entry] = [:]

    func get(_ key: Key) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ key: Key, value: Entry) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }
}

public enum LocalTelemetryCollector {

    public struct ClaudeCollectionResult: Sendable {
        public let samples: [UsageSample]
        public let rateLimitEvents: [RateLimitEvent]
        public let rateLimitHits24h: Int
    }

    public struct CodexCollectionResult: Sendable {
        public let samples: [UsageSample]
        public let rateLimitEvents: [RateLimitEvent]
    }

    public struct OpenCodeCollectionResult: Sendable {
        public let samples: [UsageSample]
        public let rateLimitEvents: [RateLimitEvent]
    }

    public struct VibeCollectionResult: Sendable {
        public let samples: [UsageSample]
        public let rateLimitEvents: [RateLimitEvent]
        public let configuredActiveModel: String?
    }

    public struct AntigravityCollectionResult: Sendable {
        public let samples: [UsageSample]
        public let latestModel: String?
        public let rateLimitEvents: [RateLimitEvent]
        public let rateLimitHits24h: Int
    }

    public static func defaultDataSourceDescription(
        for vendor: AgentVendor,
        language: AppLanguage = .en
    ) -> String {
        switch vendor {
        case .claudeCode:
            return "~/.claude/projects/**/*.jsonl"
        case .codex:
            return "~/.codex/state_5.sqlite + rollout-*.jsonl"
        case .openCode:
            return language == .zhHans
                ? "~/.local/share/opencode/opencode.db（session_message 逐事件 + session_v2 兜底）"
                : "~/.local/share/opencode/opencode.db (session_message events + session_v2 fallback)"
        case .mistralVibe:
            return "~/.vibe/logs/session/unified/*/journal/*.jsonl + .relay/LOG.md"
        case .antigravity:
            return language == .zhHans
                ? "~/Projects/*/.relay/LOG.md（cli-*.log 无 Token 统计）"
                : "~/Projects/*/.relay/LOG.md (cli-*.log lacks token stats)"
        }
    }

    public static func collectSnapshot(
        paths: CollectorPaths = .liveDefault(),
        now: Date = Date(),
        lookbackDays: Int = 30,
        allowZstdRollout: Bool = true,
        timeZone: TimeZone = .current
    ) -> TelemetrySnapshot {
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400.0)
        let fm = FileManager.default

        let claudeAvailable = fm.fileExists(atPath: paths.claudeProjectsDir.path)
        let codexAvailable = fm.fileExists(atPath: paths.codexSQLiteFile.path)
        let openCodeAvailable = fm.fileExists(atPath: paths.openCodeSQLiteFile.path)
        let vibeAvailable = fm.fileExists(atPath: paths.vibeSessionsDir.path)
        let agyAvailable = fm.fileExists(atPath: paths.antigravityLogsDir.path)

        let claudeResult = collectClaudeTelemetry(dir: paths.claudeProjectsDir, since: cutoff, now: now)
        let codexResult = collectCodexTelemetry(dbURL: paths.codexSQLiteFile, since: cutoff, now: now, allowZstd: allowZstdRollout)
        let openCodeResult = collectOpenCodeTelemetry(dbURL: paths.openCodeSQLiteFile, since: cutoff, now: now)
        let relayRuns = collectRelayRuns(workspaceRoot: paths.workspaceRootDir)
        let vibeResult = collectVibeTelemetry(vibeDir: paths.vibeSessionsDir, relayRuns: relayRuns, since: cutoff, now: now, timeZone: timeZone)
        let agyResult = collectAntigravityTelemetry(logDir: paths.antigravityLogsDir, relayRuns: relayRuns, since: cutoff, now: now, timeZone: timeZone)

        let allTurnSamples = claudeResult.samples
            + codexResult.samples
            + openCodeResult.samples
            + vibeResult.samples
            + agyResult.samples

        let allRateLimitEvents = claudeResult.rateLimitEvents
            + codexResult.rateLimitEvents
            + openCodeResult.rateLimitEvents
            + vibeResult.rateLimitEvents
            + agyResult.rateLimitEvents

        let availability: [AgentVendor: Bool] = [
            .claudeCode: claudeAvailable,
            .codex: codexAvailable,
            .openCode: openCodeAvailable,
            .mistralVibe: vibeAvailable || !vibeResult.samples.isEmpty,
            .antigravity: agyAvailable || !agyResult.samples.isEmpty
        ]

        let extraActiveModels: [AgentVendor: String] = [
            .mistralVibe: vibeResult.configuredActiveModel,
            .antigravity: agyResult.latestModel
        ].compactMapValues { $0 }

        return buildSnapshot(
            samples: allTurnSamples,
            relayRuns: relayRuns,
            availability: availability,
            extraActiveModels: extraActiveModels,
            extraRateLimits: [:],
            rateLimitEvents: allRateLimitEvents,
            now: now,
            timeZone: timeZone
        )
    }

    public static func buildSnapshot(
        samples: [UsageSample],
        relayRuns: [RelayRunSummary],
        availability: [AgentVendor: Bool],
        extraActiveModels: [AgentVendor: String] = [:],
        extraRateLimits: [AgentVendor: Int] = [:],
        rateLimitEvents: [RateLimitEvent] = [],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> TelemetrySnapshot {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        let startOfToday = cal.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5.0 * 3600.0)
        let sevenDaysAgo = now.addingTimeInterval(-7.0 * 86_400.0)
        let thirtyDaysAgo = now.addingTimeInterval(-30.0 * 86_400.0)
        let twentyFourHoursAgo = now.addingTimeInterval(-24.0 * 3600.0)
        let fourteenDaysAgo = cal.date(byAdding: .day, value: -13, to: startOfToday) ?? startOfToday

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = cal
        dayFormatter.timeZone = timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var summaries: [VendorSummary] = []
        for vendor in AgentVendor.allCases {
            let vendorAll = samples.filter { $0.vendor == vendor }
            let vSamples = vendorAll.filter { $0.timestamp != nil }.sorted { $0.timestamp! < $1.timestamp! }
            let untimestampedVSamples = vendorAll.filter { $0.timestamp == nil }
            let vRateEvents = rateLimitEvents.filter { $0.vendor == vendor && $0.timestamp <= now }
            let sourceAvail = availability[vendor] ?? !vendorAll.isEmpty
            let dataSource = defaultDataSourceDescription(for: vendor)

            let fiveHourSlice = vSamples.filter { $0.timestamp! >= fiveHoursAgo && $0.timestamp! <= now }
            let todaySlice = vSamples.filter { $0.timestamp! >= startOfToday && $0.timestamp! <= now }
            let sevenDaySlice = vSamples.filter { $0.timestamp! >= sevenDaysAgo && $0.timestamp! <= now }
            let thirtyDaySlice = vSamples.filter { $0.timestamp! >= thirtyDaysAgo && $0.timestamp! <= now }

            let overallCompleteness = classifyVendorCompleteness(
                vendor: vendor,
                samples: thirtyDaySlice + untimestampedVSamples
            )

            let rl5h = vRateEvents.filter { $0.timestamp >= fiveHoursAgo }.count + fiveHourSlice.filter(\.isRateLimited).count
            let rlToday = vRateEvents.filter { $0.timestamp >= startOfToday }.count + todaySlice.filter(\.isRateLimited).count
            let rl7d = vRateEvents.filter { $0.timestamp >= sevenDaysAgo }.count + sevenDaySlice.filter(\.isRateLimited).count
            let rl30d = vRateEvents.filter { $0.timestamp >= thirtyDaysAgo }.count + thirtyDaySlice.filter(\.isRateLimited).count

            let windows: [TelemetryWindow: VendorWindowMetrics] = [
                .fiveHours: computeWindowMetrics(
                    vendor: vendor,
                    slice: fiveHourSlice,
                    rateLimit429Count: rl5h,
                    overallCompleteness: overallCompleteness,
                    sourceAvailable: sourceAvail,
                    dataSource: dataSource
                ),
                .today: computeWindowMetrics(
                    vendor: vendor,
                    slice: todaySlice,
                    rateLimit429Count: rlToday,
                    overallCompleteness: overallCompleteness,
                    sourceAvailable: sourceAvail,
                    dataSource: dataSource
                ),
                .sevenDays: computeWindowMetrics(
                    vendor: vendor,
                    slice: sevenDaySlice,
                    rateLimit429Count: rl7d,
                    overallCompleteness: overallCompleteness,
                    sourceAvailable: sourceAvail,
                    dataSource: dataSource
                ),
                .thirtyDays: computeWindowMetrics(
                    vendor: vendor,
                    slice: thirtyDaySlice,
                    rateLimit429Count: rl30d,
                    overallCompleteness: overallCompleteness,
                    sourceAvailable: sourceAvail,
                    dataSource: dataSource
                )
            ]

            let untimestampedMetrics: VendorWindowMetrics = {
                if untimestampedVSamples.isEmpty {
                    return VendorWindowMetrics(
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
                }
                return computeWindowMetrics(
                    vendor: vendor,
                    slice: untimestampedVSamples,
                    rateLimit429Count: untimestampedVSamples.filter(\.isRateLimited).count,
                    overallCompleteness: classifyVendorCompleteness(vendor: vendor, samples: untimestampedVSamples),
                    sourceAvailable: sourceAvail,
                    dataSource: dataSource
                )
            }()

            let distinctSessions = Set(thirtyDaySlice.map(\.sessionID)).count
            let latestSample = vSamples.last(where: { !$0.model.isEmpty && $0.model != "—" && $0.model != "unknown" })
                ?? untimestampedVSamples.last(where: { !$0.model.isEmpty && $0.model != "—" && $0.model != "unknown" })
                ?? vSamples.last
                ?? untimestampedVSamples.last
            let modelName: String = {
                if let m = latestSample?.model, !m.isEmpty, m != "unknown" {
                    return m
                }
                return extraActiveModels[vendor] ?? "—"
            }()

            let event429_24h = vRateEvents.filter { $0.timestamp >= twentyFourHoursAgo }.count
            let sample429_24h = vSamples.filter { $0.isRateLimited && $0.timestamp! >= twentyFourHoursAgo && $0.timestamp! <= now }.count
            let hits429 = event429_24h + sample429_24h + (extraRateLimits[vendor] ?? 0)

            summaries.append(
                VendorSummary(
                    vendor: vendor,
                    sourceAvailable: sourceAvail,
                    dataSource: dataSource,
                    completeness: overallCompleteness,
                    windows: windows,
                    untimestamped: untimestampedMetrics,
                    sessionCount30d: distinctSessions,
                    activeModel: modelName,
                    lastActive: vSamples.last?.timestamp,
                    rateLimitHits24h: hits429
                )
            )
        }

        let timedSamples = samples.filter { $0.timestamp != nil }
        let untimestampedSamples = samples.filter { $0.timestamp == nil }

        // Build 14-day daily buckets per vendor AND rich M1 per-day breakdown (with B14, B15, B7)
        var dailyBuckets: [DailyVendorBucket] = []
        var dailyBreakdown: [DailyLedgerDay] = []
        for dayOffset in 0..<14 {
            guard let dayStart = cal.date(byAdding: .day, value: dayOffset, to: fourteenDaysAgo),
                  let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let dateStr = dayFormatter.string(from: dayStart)
            let daySlice = timedSamples.filter { $0.timestamp! >= dayStart && $0.timestamp! < dayEnd && $0.timestamp! <= now }
            let dayRLSlice = rateLimitEvents.filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd && $0.timestamp <= now }

            let built = buildDailyLedgerEntry(
                dateString: dateStr,
                dayStart: dayStart,
                slice: daySlice,
                rlSlice: dayRLSlice,
                appendChartBuckets: true,
                dailyBuckets: &dailyBuckets
            )
            dailyBreakdown.append(built)
        }

        var unusedBuckets: [DailyVendorBucket] = []
        let untimestampedLedger = buildDailyLedgerEntry(
            dateString: "No timestamp",
            dayStart: .distantPast,
            slice: untimestampedSamples,
            rlSlice: [],
            appendChartBuckets: false,
            dailyBuckets: &unusedBuckets
        )

        // Roll up recent sessions by (vendor, sessionID) preserving exact per-turn costs and breakdown honesty
        var groupedSessions: [String: UsageSample] = [:]
        for sample in samples where sample.timestamp == nil || sample.timestamp! <= now {
            let key = "\(sample.vendor.rawValue)::\(sample.sessionID)"
            if let existing = groupedSessions[key] {
                let newerTS: Date? = {
                    switch (existing.timestamp, sample.timestamp) {
                    case let (a?, b?): return max(a, b)
                    case let (a?, nil): return a
                    case let (nil, b?): return b
                    case (nil, nil): return nil
                    }
                }()
                let chosenModel: String = {
                    if !sample.model.isEmpty, sample.model != "—" {
                        switch (existing.timestamp, sample.timestamp) {
                        case let (a?, b?) where b >= a:
                            return sample.model
                        case (nil, _?):
                            return sample.model
                        default:
                            if existing.model.isEmpty || existing.model == "—" {
                                return sample.model
                            }
                        }
                    }
                    return existing.model
                }()
                let combinedBreakdown = existing.hasTokenBreakdown && sample.hasTokenBreakdown
                let combinedOrigin: SampleOrigin = (existing.origin == .relayLog || sample.origin == .relayLog) ? .relayLog : .standalone
                let combinedRecorded: Double? = sumOptionalDoubles(existing.recordedCostUSD, sample.recordedCostUSD)
                let combinedEstimated: Double? = combinedBreakdown
                    ? sumOptionalDoubles(existing.estimatedAPICostUSD, sample.estimatedAPICostUSD)
                    : nil
                let combinedKnownTokens: Int? = {
                    switch (existing.knownTotalTokens, sample.knownTotalTokens) {
                    case let (a?, b?): return a + b
                    case let (a?, nil): return a
                    case let (nil, b?): return b
                    case (nil, nil): return nil
                    }
                }()
                let combinedMismatch = existing.hasRolloutMismatch || sample.hasRolloutMismatch
                let combinedExpectedTokens: Int? = existing.expectedTotalTokens ?? sample.expectedTotalTokens
                let combinedMismatchNote: String? = {
                    let parts = uniqueStrings([existing.mismatchNote, sample.mismatchNote].compactMap { $0 }.filter { !$0.isEmpty })
                    return parts.isEmpty ? nil : parts.joined(separator: "; ")
                }()
                groupedSessions[key] = UsageSample(
                    aggregatedID: existing.id,
                    vendor: existing.vendor,
                    origin: combinedOrigin,
                    timestamp: newerTS,
                    sessionID: existing.sessionID,
                    projectName: existing.projectName,
                    model: chosenModel,
                    hasTokenBreakdown: combinedBreakdown,
                    inputTokens: combinedBreakdown ? (existing.inputTokens + sample.inputTokens) : 0,
                    outputTokens: combinedBreakdown ? (existing.outputTokens + sample.outputTokens) : 0,
                    cacheReadTokens: combinedBreakdown ? (existing.cacheReadTokens + sample.cacheReadTokens) : 0,
                    cacheWriteTokens: combinedBreakdown ? (existing.cacheWriteTokens + sample.cacheWriteTokens) : 0,
                    knownTotalTokens: combinedKnownTokens,
                    recordedCostUSD: combinedRecorded,
                    estimatedAPICostUSD: combinedEstimated,
                    unmatchedModelCount: existing.unmatchedModelCount + sample.unmatchedModelCount,
                    isRateLimited: existing.isRateLimited || sample.isRateLimited,
                    hasRolloutMismatch: combinedMismatch,
                    expectedTotalTokens: combinedExpectedTokens,
                    mismatchNote: combinedMismatchNote
                )
            } else {
                groupedSessions[key] = sample
            }
        }

        let recentSessions = groupedSessions.values
            .filter { $0.totalTokens > 0 || ($0.effectiveCostUSD ?? 0) > 0 }
            .sorted { lhs, rhs in
                switch (lhs.timestamp, rhs.timestamp) {
                case let (a?, b?):
                    return a == b ? lhs.id < rhs.id : a > b
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.id < rhs.id
                }
            }
            .prefix(30)
            .map { $0 }

        return TelemetrySnapshot(
            capturedAt: now,
            timeZoneIdentifier: timeZone.identifier,
            isDemoData: false,
            vendorSummaries: summaries,
            dailyBuckets: dailyBuckets,
            dailyBreakdown: dailyBreakdown,
            untimestampedLedger: untimestampedLedger,
            recentSessions: recentSessions,
            relayRuns: relayRuns.sorted { $0.updatedAt > $1.updatedAt },
            rateLimitEvents: rateLimitEvents
        )
    }

    private static func buildDailyLedgerEntry(
        dateString: String,
        dayStart: Date,
        slice: [UsageSample],
        rlSlice: [RateLimitEvent],
        appendChartBuckets: Bool,
        dailyBuckets: inout [DailyVendorBucket]
    ) -> DailyLedgerDay {
        var vendorMetricsMap: [AgentVendor: DailyVendorMetrics] = [:]
        var dayUncached = 0
        var dayCached = 0
        var dayCW = 0
        var dayOut = 0
        var dayTot = 0
        var dayRec = 0
        var dayPriced = 0
        var dayUnmatched = 0
        var dayCostAccum = 0.0
        var dayHasAnyPriced = false
        var dayRLTotal = 0

        for vendor in AgentVendor.allCases {
            let vs = slice.filter { $0.vendor == vendor }
            let vRL = rlSlice.filter { $0.vendor == vendor }.count + vs.filter(\.isRateLimited).count
            let uncached = vs.filter(\.hasTokenBreakdown).map(\.inputTokens).reduce(0, +)
            let cached = vs.filter(\.hasTokenBreakdown).map(\.cacheReadTokens).reduce(0, +)
            let cw = vs.filter(\.hasTokenBreakdown).map(\.cacheWriteTokens).reduce(0, +)
            let out = vs.filter(\.hasTokenBreakdown).map(\.outputTokens).reduce(0, +)
            let tok = vs.map(\.totalTokens).reduce(0, +)
            let pricedValues = vs.compactMap(\.effectiveCostUSD)
            let vCost: Double? = pricedValues.isEmpty ? (vs.isEmpty ? 0.0 : nil) : pricedValues.reduce(0, +)
            let vUnmatched = vs.map(\.unmatchedModelCount).reduce(0, +)
            let misSamples = vs.filter(\.hasRolloutMismatch)
            let vHasMis = !misSamples.isEmpty
            let vMisCount = Set(misSamples.map(\.sessionID)).count
            let vMisDetails = uniqueStrings(misSamples.compactMap(\.mismatchNote))
            let vComp: DataCompleteness = vs.isEmpty ? .noData : classifyVendorCompleteness(vendor: vendor, samples: vs)

            if appendChartBuckets {
                let sessCount = Set(vs.map(\.sessionID)).count
                dailyBuckets.append(
                    DailyVendorBucket(
                        date: dayStart,
                        vendor: vendor,
                        tokens: tok,
                        costUSD: pricedValues.reduce(0, +),
                        sessions: sessCount
                    )
                )
            }

            vendorMetricsMap[vendor] = DailyVendorMetrics(
                uncachedInputTokens: uncached,
                cachedInputTokens: cached,
                cacheWriteTokens: cw,
                outputTokens: out,
                totalTokens: tok,
                recordCount: vs.count,
                pricedRecordCount: pricedValues.count,
                unmatchedModelCount: vUnmatched,
                estimatedCostUSD: vCost,
                hasRolloutMismatch: vHasMis,
                rolloutMismatchCount: vMisCount,
                mismatchDetails: vMisDetails,
                rateLimit429Count: vRL,
                completeness: vComp
            )

            dayUncached += uncached
            dayCached += cached
            dayCW += cw
            dayOut += out
            dayTot += tok
            dayRec += vs.count
            dayPriced += pricedValues.count
            dayUnmatched += vUnmatched
            if !pricedValues.isEmpty {
                dayHasAnyPriced = true
                dayCostAccum += pricedValues.reduce(0, +)
            }
            dayRLTotal += vRL
        }

        let codexDay = vendorMetricsMap[.codex] ?? DailyVendorMetrics()
        let dayCost: Double? = dayHasAnyPriced ? dayCostAccum : (dayRec == 0 ? 0.0 : nil)

        return DailyLedgerDay(
            dateString: dateString,
            dayStart: dayStart,
            uncachedInputTokens: dayUncached,
            cachedInputTokens: dayCached,
            cacheWriteTokens: dayCW,
            outputTokens: dayOut,
            totalTokens: dayTot,
            recordCount: dayRec,
            pricedRecordCount: dayPriced,
            unmatchedModelCount: dayUnmatched,
            estimatedCostUSD: dayCost,
            hasCodexRolloutMismatch: codexDay.hasRolloutMismatch,
            codexMismatchDetails: codexDay.mismatchDetails,
            rateLimit429Count: dayRLTotal,
            vendors: vendorMetricsMap
        )
    }

    private static func classifyVendorCompleteness(
        vendor: AgentVendor,
        samples: [UsageSample]
    ) -> DataCompleteness {
        guard !samples.isEmpty else { return .noData }
        switch vendor {
        case .antigravity:
            return .relayOnly
        case .mistralVibe:
            if samples.contains(where: { $0.origin == .relayLog }) {
                return .relayOnly
            }
            if samples.allSatisfy(\.hasTokenBreakdown) {
                return .complete
            }
            return .totalOnly
        case .claudeCode, .codex, .openCode:
            if samples.contains(where: \.hasRolloutMismatch) {
                return .mismatch
            }
            if samples.allSatisfy(\.hasTokenBreakdown) {
                return .complete
            }
            return .totalOnly
        }
    }

    private static func computeWindowMetrics(
        vendor: AgentVendor,
        slice: [UsageSample],
        rateLimit429Count: Int = 0,
        overallCompleteness: DataCompleteness,
        sourceAvailable: Bool,
        dataSource: String
    ) -> VendorWindowMetrics {
        if slice.isEmpty {
            if vendor == .antigravity
                || !sourceAvailable
                || overallCompleteness == .noData
                || overallCompleteness == .relayOnly {
                var empty = VendorWindowMetrics.empty(dataSource: dataSource, completeness: .noData)
                empty.rateLimit429Count = rateLimit429Count
                return empty
            }
            if overallCompleteness == .complete {
                return VendorWindowMetrics(
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
                    completeness: .complete,
                    rateLimit429Count: rateLimit429Count
                )
            }
            return VendorWindowMetrics(
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                totalTokens: 0,
                recordCount: 0,
                pricedRecordCount: 0,
                estimatedCostUSD: nil,
                unknownModelRecordCount: 0,
                cacheHitRate: nil,
                dataSource: dataSource,
                completeness: overallCompleteness == .mismatch ? .mismatch : .totalOnly,
                rateLimit429Count: rateLimit429Count
            )
        }

        let completeness = classifyVendorCompleteness(vendor: vendor, samples: slice)
        let unknownModels = slice.map(\.unmatchedModelCount).reduce(0, +)
        let mismatchSamples = slice.filter(\.hasRolloutMismatch)
        let hasMismatch = !mismatchSamples.isEmpty
        let mismatchCount = Set(mismatchSamples.map(\.sessionID)).count
        let mismatchDetails = uniqueStrings(mismatchSamples.compactMap(\.mismatchNote))

        if completeness == .complete || (completeness == .mismatch && slice.allSatisfy(\.hasTokenBreakdown)) {
            let inp = slice.map(\.inputTokens).reduce(0, +)
            let out = slice.map(\.outputTokens).reduce(0, +)
            let cr = slice.map(\.cacheReadTokens).reduce(0, +)
            let cw = slice.map(\.cacheWriteTokens).reduce(0, +)
            let tot = inp + out + cr + cw
            let denom = inp + cr + cw
            let hitRate: Double? = denom > 0 ? Double(cr) / Double(denom) : nil
            let priced = slice.compactMap(\.effectiveCostUSD)
            let cost: Double? = priced.isEmpty ? nil : priced.reduce(0, +)

            return VendorWindowMetrics(
                inputTokens: inp,
                outputTokens: out,
                cacheReadTokens: cr,
                cacheWriteTokens: cw,
                totalTokens: tot,
                recordCount: slice.count,
                pricedRecordCount: priced.count,
                estimatedCostUSD: cost,
                unknownModelRecordCount: unknownModels,
                cacheHitRate: hitRate,
                dataSource: dataSource,
                completeness: completeness,
                hasRolloutMismatch: hasMismatch,
                rolloutMismatchCount: mismatchCount,
                mismatchDetails: mismatchDetails,
                rateLimit429Count: rateLimit429Count
            )
        } else {
            let knownTots = slice.compactMap(\.knownTotalTokens)
            let tot: Int? = knownTots.isEmpty ? nil : knownTots.reduce(0, +)
            let pricedAndCost: (count: Int, cost: Double?) = {
                if completeness == .totalOnly || completeness == .mismatch {
                    let recs = slice.compactMap { ($0.recordedCostUSD ?? 0) > 0 ? $0.recordedCostUSD : nil }
                    let known = (recs.count == slice.count && !recs.isEmpty) ? recs.reduce(0, +) : nil
                    return (known != nil ? recs.count : 0, known)
                }
                let priced = slice.compactMap(\.effectiveCostUSD)
                return (priced.count, priced.isEmpty ? nil : priced.reduce(0, +))
            }()

            return VendorWindowMetrics(
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                totalTokens: tot,
                recordCount: slice.count,
                pricedRecordCount: pricedAndCost.count,
                estimatedCostUSD: pricedAndCost.cost,
                unknownModelRecordCount: unknownModels,
                cacheHitRate: nil,
                dataSource: dataSource,
                completeness: completeness,
                hasRolloutMismatch: hasMismatch,
                rolloutMismatchCount: mismatchCount,
                mismatchDetails: mismatchDetails,
                rateLimit429Count: rateLimit429Count
            )
        }
    }

    private static func sumOptionalDoubles(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (x?, y?): return x + y
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }

    private static func uniqueStrings(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for s in items where !s.isEmpty {
            if seen.insert(s).inserted {
                out.append(s)
            }
        }
        return out
    }

    // MARK: - Structured 429 / Rate-Limit Detection (Zero Substring Matching on Free-Form Text)

    private static let structuredRateLimitCodes: Set<String> = [
        "429",
        "rate_limit",
        "rate_limit_error",
        "rate_limit_exceeded",
        "too_many_requests",
        "resource_exhausted"
    ]

    private static func hasStructured429Status(_ dict: [String: Any]) -> Bool {
        for key in ["status", "status_code", "statusCode", "http_status", "httpStatus"] {
            if let v = dict[key], intVal(v) == 429 {
                return true
            }
        }
        return false
    }

    private static func isStructuredRateLimitValue(_ any: Any?) -> Bool {
        guard let any else { return false }
        if let s = any as? String {
            let norm = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return structuredRateLimitCodes.contains(norm)
        }
        if let n = any as? NSNumber {
            return n.intValue == 429
        }
        if let dict = any as? [String: Any] {
            if hasStructured429Status(dict) {
                return true
            }
            for key in ["code", "type", "error_code", "errorCode", "reason"] {
                if let v = dict[key] {
                    if let s = v as? String,
                       structuredRateLimitCodes.contains(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                        return true
                    }
                    if let n = v as? NSNumber, n.intValue == 429 {
                        return true
                    }
                }
            }
            if let nestedData = dict["data"] as? [String: Any], isStructuredRateLimitValue(nestedData) {
                return true
            }
            if let nestedErr = dict["error"], isStructuredRateLimitValue(nestedErr) {
                return true
            }
        }
        return false
    }

    // MARK: - 1. Claude Code JSONL Reader (Read-Only, In-Memory Line Parsing, Deduplicated by message.id + requestId)

    public static func collectClaudeSamples(
        dir: URL,
        since: Date,
        now: Date = Date()
    ) -> (samples: [UsageSample], rateLimitHits24h: Int) {
        let res = collectClaudeTelemetry(dir: dir, since: since, now: now)
        return (res.samples, res.rateLimitHits24h)
    }

    public static func collectClaudeTelemetry(
        dir: URL,
        since: Date,
        now: Date = Date()
    ) -> ClaudeCollectionResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            return ClaudeCollectionResult(samples: [], rateLimitEvents: [], rateLimitHits24h: 0)
        }
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ClaudeCollectionResult(samples: [], rateLimitEvents: [], rateLimitHits24h: 0)
        }

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        struct ClaudeAccumulator {
            var orderIndex: Int
            var id: String
            var timestamp: Date?
            var sessionID: String
            var projectName: String
            var model: String
            var inp: Int
            var out: Int
            var cr: Int
            var cw: Int
            var cost: Double?
        }

        let dayAgo = now.addingTimeInterval(-86_400)
        let upperBound = now
        var deduped: [String: ClaudeAccumulator] = [:]
        var nextOrder = 0
        var rateLimitDedup: [String: RateLimitEvent] = [:]

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let fallbackProject = cleanProjectLabel(from: fileURL.deletingLastPathComponent().lastPathComponent)

            var lineIdx = 0
            text.enumerateLines { line, _ in
                lineIdx += 1
                guard line.contains("\"assistant\"") || line.contains("\"error\"") || line.contains("429") || line.contains("rate_limit") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

                let tsStr = obj["timestamp"] as? String ?? ""
                let parsedTS = isoFrac.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                let sessID = (obj["sessionId"] as? String) ?? fileURL.deletingPathExtension().lastPathComponent
                let msg = obj["message"] as? [String: Any]
                let msgID = (msg?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let reqID = (obj["requestId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let isStructured429: Bool = {
                    if let isApiErr = obj["isApiErrorMessage"] as? Bool, isApiErr {
                        return isStructuredRateLimitValue(obj["error"]) || hasStructured429Status(obj)
                    }
                    if (obj["type"] as? String) == "error" {
                        return isStructuredRateLimitValue(obj["error"]) || hasStructured429Status(obj)
                    }
                    if let errDict = obj["error"] as? [String: Any] {
                        return isStructuredRateLimitValue(errDict)
                    }
                    return false
                }()

                if isStructured429, let rlTS = parsedTS, rlTS >= since, rlTS <= upperBound {
                    let rlKey: String
                    if !msgID.isEmpty && !reqID.isEmpty {
                        rlKey = "mr:\(msgID)::\(reqID)"
                    } else if !reqID.isEmpty {
                        rlKey = "r:\(reqID)"
                    } else if !msgID.isEmpty {
                        rlKey = "m:\(msgID)"
                    } else if let uuid = obj["uuid"] as? String, !uuid.isEmpty {
                        rlKey = "u:\(uuid)"
                    } else {
                        rlKey = "line:\(fileURL.path)::\(lineIdx)"
                    }
                    if rateLimitDedup[rlKey] == nil {
                        rateLimitDedup[rlKey] = RateLimitEvent(
                            id: "claude-429-\(rlKey)",
                            vendor: .claudeCode,
                            timestamp: rlTS,
                            sessionID: sessID
                        )
                    }
                }

                guard (obj["type"] as? String) == "assistant",
                      let msg,
                      let usage = msg["usage"] as? [String: Any] else { return }

                let inp = intVal(usage["input_tokens"])
                let out = intVal(usage["output_tokens"])
                let cr = intVal(usage["cache_read_input_tokens"])
                let cw = intVal(usage["cache_creation_input_tokens"])
                let cost = (obj["costUSD"] as? NSNumber)?.doubleValue
                if inp == 0 && out == 0 && cr == 0 && cw == 0 && (cost ?? 0) == 0 { return }

                let dedupKey: String
                if !msgID.isEmpty && !reqID.isEmpty {
                    dedupKey = "mr:\(msgID)::\(reqID)"
                } else if !msgID.isEmpty {
                    dedupKey = "m:\(msgID)"
                } else if !reqID.isEmpty {
                    dedupKey = "r:\(reqID)"
                } else {
                    dedupKey = "line:\(fileURL.path)::\(lineIdx)"
                }

                let model = (msg["model"] as? String) ?? ""
                let cwd = obj["cwd"] as? String
                let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallbackProject

                if var existing = deduped[dedupKey] {
                    existing.inp = max(existing.inp, inp)
                    existing.out = max(existing.out, out)
                    existing.cr = max(existing.cr, cr)
                    existing.cw = max(existing.cw, cw)
                    if let cost {
                        existing.cost = max(existing.cost ?? 0, cost)
                    }
                    if existing.model.isEmpty && !model.isEmpty {
                        existing.model = model
                    }
                    if existing.timestamp == nil, let parsedTS {
                        existing.timestamp = parsedTS
                    }
                    deduped[dedupKey] = existing
                } else {
                    nextOrder += 1
                    deduped[dedupKey] = ClaudeAccumulator(
                        orderIndex: nextOrder,
                        id: "claude-\(sessID)-\(nextOrder)",
                        timestamp: parsedTS,
                        sessionID: sessID,
                        projectName: project,
                        model: model,
                        inp: inp,
                        out: out,
                        cr: cr,
                        cw: cw,
                        cost: cost
                    )
                }
            }
        }

        let samples = deduped.values
            .filter { acc in
                guard let ts = acc.timestamp else { return true }
                return ts >= since && ts <= upperBound
            }
            .sorted { $0.orderIndex < $1.orderIndex }
            .map { acc in
                UsageSample(
                    id: acc.id,
                    vendor: .claudeCode,
                    origin: .standalone,
                    timestamp: acc.timestamp,
                    sessionID: acc.sessionID,
                    projectName: acc.projectName,
                    model: acc.model,
                    inputTokens: acc.inp,
                    outputTokens: acc.out,
                    cacheReadTokens: acc.cr,
                    cacheWriteTokens: acc.cw,
                    recordedCostUSD: acc.cost
                )
            }
        let rlEvents = rateLimitDedup.values.sorted { $0.timestamp < $1.timestamp }
        let hits24h = rlEvents.filter { $0.timestamp >= dayAgo && $0.timestamp <= upperBound }.count
        return ClaudeCollectionResult(samples: samples, rateLimitEvents: rlEvents, rateLimitHits24h: hits24h)
    }

    // MARK: - 2. Codex SQLite + Per-Event Rollout JSONL Reader (SQLITE_OPEN_READONLY, Incremental Event Deltas)

    public static func collectCodexSamples(
        dbURL: URL,
        since: Date,
        now: Date = Date(),
        allowZstd: Bool = true
    ) -> [UsageSample] {
        collectCodexTelemetry(dbURL: dbURL, since: since, now: now, allowZstd: allowZstd).samples
    }

    public static func collectCodexTelemetry(
        dbURL: URL,
        since: Date,
        now: Date = Date(),
        allowZstd: Bool = true
    ) -> CodexCollectionResult {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return CodexCollectionResult(samples: [], rateLimitEvents: [])
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return CodexCollectionResult(samples: [], rateLimitEvents: [])
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let hasModelCol = tableHasColumn(db: db, table: "threads", column: "model")
        let hasRolloutCol = tableHasColumn(db: db, table: "threads", column: "rollout_path")
        let hasCreatedCol = tableHasColumn(db: db, table: "threads", column: "created_at")
        let modelExpr = hasModelCol ? "model" : "NULL"
        let rolloutExpr = hasRolloutCol ? "rollout_path" : "NULL"
        let createdExpr = hasCreatedCol ? "created_at" : "0"
        let sql = "SELECT id, cwd, tokens_used, updated_at, \(createdExpr), \(modelExpr), \(rolloutExpr) FROM threads WHERE tokens_used > 0;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return CodexCollectionResult(samples: [], rateLimitEvents: [])
        }
        defer { sqlite3_finalize(stmt) }

        let upperBound = now
        let fm = FileManager.default
        var results: [UsageSample] = []
        var rateLimits: [RateLimitEvent] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, 0) ?? UUID().uuidString
            let cwd = columnText(stmt, 1) ?? ""
            let totalTok = Int(sqlite3_column_int64(stmt, 2))
            let rawUpdated = sqlite3_column_int64(stmt, 3)
            let rawCreated = sqlite3_column_int64(stmt, 4)
            let dbModel = (columnText(stmt, 5) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rolloutPath = (columnText(stmt, 6) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            let rawEpoch = rawUpdated > 0 ? rawUpdated : (rawCreated > 0 ? rawCreated : 0)
            let sessionTS: Date? = rawEpoch > 0 ? normalizeEpoch(rawEpoch) : nil
            let proj = cwd.isEmpty ? "codex" : URL(fileURLWithPath: cwd).lastPathComponent

            let shouldReadRollout = !rolloutPath.isEmpty && (
                fm.fileExists(atPath: rolloutPath)
                || sessionTS == nil
                || sessionTS! >= since.addingTimeInterval(-86_400)
            )
            if shouldReadRollout,
               let breakdown = readCodexRolloutEntry(rolloutPath: rolloutPath, allowZstd: allowZstd) {
                for rl in breakdown.rateLimits {
                    if let rlTS = rl.timestamp, rlTS >= since, rlTS <= upperBound {
                        rateLimits.append(
                            RateLimitEvent(
                                id: "codex-429-\(id)-\(rl.index)",
                                vendor: .codex,
                                timestamp: rlTS,
                                sessionID: id
                            )
                        )
                    }
                }

                if !breakdown.events.isEmpty {
                    let rolloutTotal = breakdown.rolloutTotalTokens
                    let isMismatch = (rolloutTotal != totalTok)
                        || (breakdown.reportedTotalTokens != nil && breakdown.reportedTotalTokens != totalTok)
                    let note: String? = isMismatch ? "\(id): rollout=\(rolloutTotal) vs sqlite=\(totalTok)" : nil

                    for ev in breakdown.events {
                        if let evTS = ev.timestamp, (evTS < since || evTS > upperBound) {
                            continue
                        }
                        let effectiveModel = (ev.model?.isEmpty == false) ? ev.model! : dbModel
                        results.append(
                            UsageSample(
                                id: "codex-\(id)-\(ev.index)",
                                vendor: .codex,
                                origin: .standalone,
                                timestamp: ev.timestamp,
                                sessionID: id,
                                projectName: proj,
                                model: effectiveModel,
                                inputTokens: ev.uncachedInput,
                                outputTokens: ev.output,
                                cacheReadTokens: ev.cachedInput,
                                cacheWriteTokens: ev.cacheWrite,
                                hasRolloutMismatch: isMismatch,
                                expectedTotalTokens: isMismatch ? totalTok : nil,
                                mismatchNote: note
                            )
                        )
                    }
                    continue
                }
            }

            // Fallback ONLY when no rollout file (or rollout contains 0 token_count events):
            // attribute totalTokens to session timestamp if valid, or to untimestamped if missing/0.
            let ts = sessionTS
            if ts == nil || (ts! >= since && ts! <= upperBound) {
                results.append(
                    UsageSample(
                        unsplitID: "codex-\(id)",
                        vendor: .codex,
                        origin: .standalone,
                        timestamp: ts,
                        sessionID: id,
                        projectName: proj,
                        model: dbModel,
                        rawTotalTokens: totalTok
                    )
                )
            }
        }
        return CodexCollectionResult(samples: results, rateLimitEvents: rateLimits)
    }

    private static func readCodexRolloutEntry(
        rolloutPath: String,
        allowZstd: Bool
    ) -> CodexRolloutCache.Entry? {
        let fm = FileManager.default
        if fm.fileExists(atPath: rolloutPath) {
            let attrs = try? fm.attributesOfItem(atPath: rolloutPath)
            let mod = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let cacheKey = CodexRolloutCache.Key(path: rolloutPath, modTime: mod, fileSize: size)
            if let cached = CodexRolloutCache.shared.get(cacheKey) {
                return cached
            }
            if let parsed = parsePlainRolloutFile(atPath: rolloutPath) {
                CodexRolloutCache.shared.set(cacheKey, value: parsed)
                return parsed
            }
            return nil
        }

        let zstPath = rolloutPath + ".zst"
        if allowZstd, fm.fileExists(atPath: zstPath), let zstdBin = resolveZstdExecutable() {
            let attrs = try? fm.attributesOfItem(atPath: zstPath)
            let mod = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let cacheKey = CodexRolloutCache.Key(path: zstPath, modTime: mod, fileSize: size)
            if let cached = CodexRolloutCache.shared.get(cacheKey) {
                return cached
            }
            if let parsed = parseZstdRolloutFile(atPath: zstPath, zstdExecutable: zstdBin) {
                CodexRolloutCache.shared.set(cacheKey, value: parsed)
                return parsed
            }
        }
        return nil
    }

    private static func resolveZstdExecutable() -> String? {
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func parsePlainRolloutFile(atPath path: String) -> CodexRolloutCache.Entry? {
        let url = URL(fileURLWithPath: path)
        guard let fullData = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let fullText = String(decoding: fullData, as: UTF8.self)
        return extractCodexRolloutEvents(from: fullText)
    }

    private static func parseZstdRolloutFile(atPath zstPath: String, zstdExecutable: String) -> CodexRolloutCache.Entry? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: zstdExecutable)
        proc.arguments = ["-dc", zstPath]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return extractCodexRolloutEvents(from: text)
    }

    private static func extractCodexRolloutEvents(from text: String) -> CodexRolloutCache.Entry {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        var events: [CodexRolloutCache.TurnEvent] = []
        var rateLimits: [CodexRolloutCache.RateLimitHit] = []
        var currentModel: String?
        var prevUncached = 0
        var prevCached = 0
        var prevCacheWrite = 0
        var prevOutput = 0
        var baseReportedTotal = 0
        var lastSegmentReported: Int?
        var lineIndex = 0

        text.enumerateLines { line, _ in
            lineIndex += 1
            guard line.contains("\"token_count\"")
                || line.contains("\"turn_context\"")
                || line.contains("\"error\"")
                || line.contains("429")
                || line.contains("rate_limit") else { return }
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

            let tsStr = (obj["timestamp"] as? String) ?? ""
            let parsedTS = isoFrac.date(from: tsStr) ?? isoPlain.date(from: tsStr)
            let topType = (obj["type"] as? String) ?? ""
            let payload = obj["payload"] as? [String: Any]

            // Check structured 429 in Codex rollout record
            let is429: Bool = {
                if hasStructured429Status(obj) || isStructuredRateLimitValue(obj["error"]) {
                    return true
                }
                if let payload {
                    if hasStructured429Status(payload) || isStructuredRateLimitValue(payload["error"]) {
                        return true
                    }
                    if (payload["type"] as? String) == "error", isStructuredRateLimitValue(payload) {
                        return true
                    }
                }
                return false
            }()
            if is429 {
                rateLimits.append(CodexRolloutCache.RateLimitHit(index: lineIndex, timestamp: parsedTS))
            }

            guard let payload else { return }
            if topType == "turn_context",
               let m = (payload["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !m.isEmpty {
                currentModel = m
            } else if topType == "event_msg",
                      (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let totalUsage = info["total_token_usage"] as? [String: Any],
                      totalUsage["input_tokens"] != nil,
                      totalUsage["output_tokens"] != nil {
                let rawInput = max(0, intVal(totalUsage["input_tokens"]))
                let cachedInput = max(0, intVal(totalUsage["cached_input_tokens"]))
                let cacheWrite = max(0, intVal(totalUsage["cache_write_input_tokens"]))
                let output = max(0, intVal(totalUsage["output_tokens"]))
                let uncachedInput = max(0, rawInput - cachedInput)

                // Handle cumulative counter reset if a rollout segment restarts counters from 0
                if uncachedInput < prevUncached || cachedInput < prevCached || cacheWrite < prevCacheWrite || output < prevOutput {
                    if let lastSeg = lastSegmentReported {
                        baseReportedTotal += lastSeg
                    }
                    prevUncached = 0
                    prevCached = 0
                    prevCacheWrite = 0
                    prevOutput = 0
                }

                let dUncached = max(0, uncachedInput - prevUncached)
                let dCached = max(0, cachedInput - prevCached)
                let dCW = max(0, cacheWrite - prevCacheWrite)
                let dOut = max(0, output - prevOutput)

                prevUncached = uncachedInput
                prevCached = cachedInput
                prevCacheWrite = cacheWrite
                prevOutput = output
                if totalUsage["total_tokens"] != nil {
                    lastSegmentReported = max(0, intVal(totalUsage["total_tokens"]))
                }

                let deltaTotal = dUncached + dCached + dCW + dOut
                guard deltaTotal > 0 else { return }

                events.append(
                    CodexRolloutCache.TurnEvent(
                        index: events.count + 1,
                        timestamp: parsedTS,
                        uncachedInput: dUncached,
                        cachedInput: dCached,
                        cacheWrite: dCW,
                        output: dOut,
                        model: currentModel
                    )
                )
            }
        }

        let totalReported: Int? = lastSegmentReported.map { baseReportedTotal + $0 }
        return CodexRolloutCache.Entry(
            events: events,
            rateLimits: rateLimits,
            reportedTotalTokens: totalReported,
            latestModel: currentModel
        )
    }

    // MARK: - 3. OpenCode SQLite Reader (SQLITE_OPEN_READONLY, Per-Event session_message + session_v2 Fallback)

    public static func collectOpenCodeSamples(
        dbURL: URL,
        since: Date,
        now: Date = Date()
    ) -> [UsageSample] {
        collectOpenCodeTelemetry(dbURL: dbURL, since: since, now: now).samples
    }

    public static func collectOpenCodeTelemetry(
        dbURL: URL,
        since: Date,
        now: Date = Date()
    ) -> OpenCodeCollectionResult {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return OpenCodeCollectionResult(samples: [], rateLimitEvents: [])
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return OpenCodeCollectionResult(samples: [], rateLimitEvents: [])
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        struct SessionV2Row {
            let id: String
            let projectName: String
            let cost: Double
            let tIn: Int
            let tOut: Int
            let tCR: Int
            let tCW: Int
            let cleanModel: String
            let timeUpdated: Date?
        }

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        func parseISOTS(_ any: Any?) -> Date? {
            guard let s = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return isoFrac.date(from: s) ?? isoPlain.date(from: s)
        }

        var sessionMap: [String: SessionV2Row] = [:]
        var sessionOrder: [String] = []

        if tableExists(db: db, table: "session_v2") {
            let sqlV2 = """
            SELECT id, directory, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, model, time_updated
            FROM session_v2;
            """
            var stmtV2: OpaquePointer?
            if sqlite3_prepare_v2(db, sqlV2, -1, &stmtV2, nil) == SQLITE_OK, let stmtV2 {
                defer { sqlite3_finalize(stmtV2) }
                while sqlite3_step(stmtV2) == SQLITE_ROW {
                    let id = columnText(stmtV2, 0) ?? UUID().uuidString
                    let dir = columnText(stmtV2, 1) ?? ""
                    let cost = sqlite3_column_double(stmtV2, 2)
                    let tIn = Int(sqlite3_column_int64(stmtV2, 3))
                    let tOut = Int(sqlite3_column_int64(stmtV2, 4)) + Int(sqlite3_column_int64(stmtV2, 5))
                    let tCR = Int(sqlite3_column_int64(stmtV2, 6))
                    let tCW = Int(sqlite3_column_int64(stmtV2, 7))
                    let rawModel = columnText(stmtV2, 8) ?? ""
                    let rawUpdated = sqlite3_column_int64(stmtV2, 9)

                    let proj = dir.isEmpty ? "opencode" : URL(fileURLWithPath: dir).lastPathComponent
                    let row = SessionV2Row(
                        id: id,
                        projectName: proj,
                        cost: cost,
                        tIn: tIn,
                        tOut: tOut,
                        tCR: tCR,
                        tCW: tCW,
                        cleanModel: parseOpenCodeModelLabel(rawModel),
                        timeUpdated: rawUpdated > 0 ? normalizeEpoch(rawUpdated) : nil
                    )
                    sessionMap[id] = row
                    sessionOrder.append(id)
                }
            }
        }

        let upperBound = now
        var results: [UsageSample] = []
        var rateLimits: [RateLimitEvent] = []
        var sessionsWithMessages: Set<String> = []

        let msgTable: String? = {
            if tableExists(db: db, table: "session_message") { return "session_message" }
            if tableExists(db: db, table: "message") { return "message" }
            return nil
        }()

        if let msgTable {
            let hasTypeCol = tableHasColumn(db: db, table: msgTable, column: "type")
            let hasTimeCol = tableHasColumn(db: db, table: msgTable, column: "time_created")
            let typeExpr = hasTypeCol ? "type" : "NULL"
            let timeExpr = hasTimeCol ? "time_created" : "0"
            let whereClause = hasTypeCol
                ? "WHERE type IN ('assistant', 'compaction') OR instr(data, 'error') > 0 OR instr(data, '429') > 0"
                : ""
            let sqlMsg = "SELECT id, session_id, \(typeExpr), \(timeExpr), data FROM \(msgTable) \(whereClause);"

            var stmtMsg: OpaquePointer?
            if sqlite3_prepare_v2(db, sqlMsg, -1, &stmtMsg, nil) == SQLITE_OK, let stmtMsg {
                defer { sqlite3_finalize(stmtMsg) }
                while sqlite3_step(stmtMsg) == SQLITE_ROW {
                    let msgID = columnText(stmtMsg, 0) ?? UUID().uuidString
                    let sessID = columnText(stmtMsg, 1) ?? ""
                    let rowType = (columnText(stmtMsg, 2) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let rawTimeCreated = sqlite3_column_int64(stmtMsg, 3)
                    guard let dataStr = columnText(stmtMsg, 4),
                          let dataBytes = dataStr.data(using: .utf8),
                          let obj = (try? JSONSerialization.jsonObject(with: dataBytes)) as? [String: Any] else { continue }

                    let msgTS: Date? = {
                        if let timeDict = obj["time"] as? [String: Any] {
                            if let createdEpoch = int64Val(timeDict["created"]) ?? int64Val(timeDict["completed"]),
                               createdEpoch > 0 {
                                return normalizeEpoch(createdEpoch)
                            }
                            if let isoDate = parseISOTS(timeDict["created"]) ?? parseISOTS(timeDict["completed"]) {
                                return isoDate
                            }
                        }
                        if rawTimeCreated > 0 {
                            return normalizeEpoch(rawTimeCreated)
                        }
                        if let isoDate = parseISOTS(obj["timestamp"]) {
                            return isoDate
                        }
                        return nil
                    }()

                    if isStructuredRateLimitValue(obj["error"]) || hasStructured429Status(obj),
                       let rlTS = msgTS,
                       rlTS >= since,
                       rlTS <= upperBound {
                        rateLimits.append(
                            RateLimitEvent(
                                id: "opencode-429-\(msgID)",
                                vendor: .openCode,
                                timestamp: rlTS,
                                sessionID: sessID
                            )
                        )
                    }

                    let roleOrType = rowType.isEmpty ? ((obj["role"] as? String) ?? (obj["type"] as? String) ?? "") : rowType
                    if !roleOrType.isEmpty && roleOrType != "assistant" && roleOrType != "compaction" {
                        continue
                    }

                    let tokDict = obj["tokens"] as? [String: Any]
                    let cacheDict = tokDict?["cache"] as? [String: Any]
                    // Verified against live opencode.db: tokens.input in session_message is ALREADY uncached input.
                    let tIn = max(0, intVal(tokDict?["input"]))
                    let tOut = max(0, intVal(tokDict?["output"])) + max(0, intVal(tokDict?["reasoning"]))
                    let tCR = max(0, intVal(cacheDict?["read"]))
                    let tCW = max(0, intVal(cacheDict?["write"]))
                    let cost = (obj["cost"] as? NSNumber)?.doubleValue ?? 0.0

                    if tIn == 0 && tOut == 0 && tCR == 0 && tCW == 0 && cost <= 0 { continue }
                    sessionsWithMessages.insert(sessID)

                    if let ts = msgTS, (ts < since || ts > upperBound) {
                        continue
                    }

                    let model: String = {
                        if let mDict = obj["model"] as? [String: Any] {
                            if let id = mDict["id"] as? String, !id.isEmpty { return id }
                            if let id = mDict["modelID"] as? String, !id.isEmpty { return id }
                        }
                        if let mStr = obj["model"] as? String, !mStr.isEmpty {
                            return parseOpenCodeModelLabel(mStr)
                        }
                        if let mID = obj["modelID"] as? String, !mID.isEmpty {
                            return mID
                        }
                        return sessionMap[sessID]?.cleanModel ?? ""
                    }()
                    let proj = sessionMap[sessID]?.projectName ?? "opencode"

                    results.append(
                        UsageSample(
                            id: "opencode-\(sessID)-\(msgID)",
                            vendor: .openCode,
                            origin: .standalone,
                            timestamp: msgTS,
                            sessionID: sessID,
                            projectName: proj,
                            model: model,
                            inputTokens: tIn,
                            outputTokens: tOut,
                            cacheReadTokens: tCR,
                            cacheWriteTokens: tCW,
                            recordedCostUSD: cost > 0 ? cost : nil
                        )
                    )
                }
            }
        }

        // Fall back to session_v2 ONLY for sessions that have 0 token-bearing rows in session_message
        for sessID in sessionOrder where !sessionsWithMessages.contains(sessID) {
            guard let row = sessionMap[sessID] else { continue }
            if row.tIn == 0 && row.tOut == 0 && row.tCR == 0 && row.tCW == 0 && row.cost <= 0 { continue }
            if let ts = row.timeUpdated, (ts < since || ts > upperBound) { continue }
            results.append(
                UsageSample(
                    id: "opencode-\(row.id)",
                    vendor: .openCode,
                    origin: .standalone,
                    timestamp: row.timeUpdated,
                    sessionID: row.id,
                    projectName: row.projectName,
                    model: row.cleanModel,
                    inputTokens: row.tIn,
                    outputTokens: row.tOut,
                    cacheReadTokens: row.tCR,
                    cacheWriteTokens: row.tCW,
                    recordedCostUSD: row.cost > 0 ? row.cost : nil
                )
            )
        }

        return OpenCodeCollectionResult(samples: results, rateLimitEvents: rateLimits)
    }

    // MARK: - 4. Agent-Relay `.relay/LOG.md` Scanner (Strict Heading Vendor, Zero Bleed)

    public static func collectRelayRuns(workspaceRoot: URL) -> [RelayRunSummary] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: workspaceRoot.path) else { return [] }
        var logFiles: [URL] = []

        let directRelay = workspaceRoot.appendingPathComponent(".relay/LOG.md")
        if fm.fileExists(atPath: directRelay.path) {
            logFiles.append(directRelay)
        }

        if let children = try? fm.contentsOfDirectory(
            at: workspaceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let candidate = child.appendingPathComponent(".relay/LOG.md")
                if fm.fileExists(atPath: candidate.path) {
                    logFiles.append(candidate)
                }
            }
        }

        return logFiles.compactMap { parseRelayLogFile(at: $0) }
    }

    public static func vendorFromStepHeadingID(_ stepID: String) -> AgentVendor? {
        let parts = stepID.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" })
        for part in parts {
            switch part {
            case "claude": return .claudeCode
            case "codex": return .codex
            case "opencode": return .openCode
            case "vibe": return .mistralVibe
            case "agy", "antigravity": return .antigravity
            default: continue
            }
        }
        return nil
    }

    public static func parseRelayLogFile(at logURL: URL) -> RelayRunSummary? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        let modDate = (try? logURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let projectDir = logURL.deletingLastPathComponent().deletingLastPathComponent()
        let projectName = projectDir.lastPathComponent

        let stepHeadingRegex = try? NSRegularExpression(pattern: #"^#{2,3}\s+([^\s:]+):\s*(.+)$"#)
        let trailingTimestampRegex = try? NSRegularExpression(pattern: #"^(.*),\s*(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?)\s*$"#)
        let trailingDurationRegex = try? NSRegularExpression(pattern: #"^(.*),\s*(\d+)s\s*$"#)
        let trailingConductorRegex = try? NSRegularExpression(pattern: #"^(.*),\s*done in-session.*$"#)
        let costRegex = try? NSRegularExpression(pattern: #"\bcost\s+\$([0-9]+(?:\.[0-9]+)?)"#)
        let tokensRegex = try? NSRegularExpression(pattern: #"\btokens\s+([0-9,]+)"#)
        let modelRegex = try? NSRegularExpression(pattern: #"\bmodel\s+(.+?)(?:,\s*(?:cost|tokens|session|outcome)\b|;|$)"#)

        var steps: [RelayBatonStep] = []
        var currentHeader: (step: String, vendor: AgentVendor?, status: String, secs: Int, ts: String)?
        var currentModel = "default"
        var currentCost: Double?
        var currentTokens: Int?

        func flushStep() {
            guard let hdr = currentHeader else { return }
            steps.append(
                RelayBatonStep(
                    stepID: hdr.step,
                    vendor: hdr.vendor,
                    status: hdr.status.trimmingCharacters(in: .whitespaces),
                    durationSeconds: hdr.secs,
                    timestampString: hdr.ts.trimmingCharacters(in: .whitespaces),
                    model: currentModel,
                    costUSD: currentCost,
                    tokens: currentTokens
                )
            )
            currentHeader = nil
            currentModel = "default"
            currentCost = nil
            currentTokens = nil
        }

        let ignoredBulletPrefixes = [
            "- prompt:",
            "- files changed:",
            "- final message:",
            "- checks:",
            "- command:",
            "- workspace:",
            "- output"
        ]

        text.enumerateLines { line, _ in
            if line.hasPrefix("#") {
                flushStep()
                let ns = line as NSString
                let fullRange = NSRange(location: 0, length: ns.length)
                guard let m = stepHeadingRegex?.firstMatch(in: line, range: fullRange), m.numberOfRanges == 3 else {
                    return
                }
                let stepID = ns.substring(with: m.range(at: 1))
                let rest = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let vendor = vendorFromStepHeadingID(stepID)

                var statusPart = rest
                var secs = 0
                var tsPart = ""

                let nsRest = rest as NSString
                if let tm = trailingTimestampRegex?.firstMatch(in: rest, range: NSRange(location: 0, length: nsRest.length)),
                   tm.numberOfRanges == 3 {
                    let beforeTS = nsRest.substring(with: tm.range(at: 1))
                    tsPart = nsRest.substring(with: tm.range(at: 2))

                    let nsBefore = beforeTS as NSString
                    let beforeRange = NSRange(location: 0, length: nsBefore.length)
                    if let dm = trailingDurationRegex?.firstMatch(in: beforeTS, range: beforeRange), dm.numberOfRanges == 3 {
                        statusPart = nsBefore.substring(with: dm.range(at: 1))
                        secs = Int(nsBefore.substring(with: dm.range(at: 2))) ?? 0
                    } else if let cm = trailingConductorRegex?.firstMatch(in: beforeTS, range: beforeRange), cm.numberOfRanges == 2 {
                        statusPart = nsBefore.substring(with: cm.range(at: 1))
                        secs = 0
                    } else {
                        statusPart = beforeTS
                    }
                }

                currentHeader = (step: stepID, vendor: vendor, status: statusPart, secs: secs, ts: tsPart)
                return
            }

            guard currentHeader != nil, line.hasPrefix("- ") else { return }
            let lowerLine = line.lowercased()
            if ignoredBulletPrefixes.contains(where: { lowerLine.hasPrefix($0) }) {
                return
            }

            let ns = line as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            if let mm = modelRegex?.firstMatch(in: line, range: fullRange), mm.numberOfRanges == 2 {
                let extracted = ns.substring(with: mm.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if !extracted.isEmpty && extracted != "?" && !extracted.hasPrefix("? ") {
                    currentModel = extracted
                }
            }
            if let cm = costRegex?.firstMatch(in: line, range: fullRange), cm.numberOfRanges == 2 {
                currentCost = Double(ns.substring(with: cm.range(at: 1)))
            }
            if let tm = tokensRegex?.firstMatch(in: line, range: fullRange), tm.numberOfRanges == 2 {
                let digits = ns.substring(with: tm.range(at: 1)).replacingOccurrences(of: ",", with: "")
                if let val = Int(digits) {
                    currentTokens = val
                }
            }
        }
        flushStep()
        guard !steps.isEmpty else { return nil }
        return RelayRunSummary(projectName: projectName, logPath: logURL.path, updatedAt: modDate, steps: steps)
    }

    // MARK: - 5. Mistral Vibe Unified Journal Reader & Antigravity Metadata Reader

    public static func collectVibeSamples(
        vibeDir: URL,
        relayRuns: [RelayRunSummary],
        since: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [UsageSample] {
        collectVibeTelemetry(vibeDir: vibeDir, relayRuns: relayRuns, since: since, now: now, timeZone: timeZone).samples
    }

    public static func collectVibeTelemetry(
        vibeDir: URL,
        relayRuns: [RelayRunSummary],
        since: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> VibeCollectionResult {
        var samples: [UsageSample] = []
        var rateLimits: [RateLimitEvent] = []
        var unifiedSessionIDs: Set<String> = []
        let upperBound = now
        let fm = FileManager.default

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        func parseISO(_ raw: String?) -> Date? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return isoFrac.date(from: raw) ?? isoPlain.date(from: raw)
        }

        // ~/.vibe/logs/session/unified -> ~/.vibe/config.toml
        let vibeConfigURL = vibeDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("config.toml")
        let configActiveModel = parseVibeConfigActiveModel(at: vibeConfigURL)

        if fm.fileExists(atPath: vibeDir.path),
           let children = try? fm.contentsOfDirectory(
               at: vibeDir,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for folder in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let metaURL = folder.appendingPathComponent("meta.json")
                let metaObj: [String: Any]? = {
                    guard let data = try? Data(contentsOf: metaURL) else { return nil }
                    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                }()

                let sessID = nonEmptyString(metaObj?["session_id"]) ?? folder.lastPathComponent
                unifiedSessionIDs.insert(sessID)

                let startTS = parseISO(metaObj?["start_time"] as? String)
                let endTS = parseISO(metaObj?["end_time"] as? String)
                let metaTS: Date? = startTS ?? endTS
                let origin = (metaObj?["origin_directory"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "vibe"

                let cfg = metaObj?["config"] as? [String: Any]
                let sessionModel = nonEmptyString(cfg?["active_model"])
                    ?? nonEmptyString(cfg?["model_name"])
                    ?? nonEmptyString(metaObj?["model"])
                    ?? configActiveModel
                    ?? ""

                var emittedJournalTurns = false
                let journalDir = folder.appendingPathComponent("journal")
                if let segmentFiles = try? fm.contentsOfDirectory(
                    at: journalDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    let sortedSegments = segmentFiles
                        .filter { $0.pathExtension == "jsonl" }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }

                    var seenActionIDs: Set<String> = []
                    var seenFailedActionIDs: Set<String> = []
                    var runningTS: Date? = nil
                    var turnSeq = 0

                    for segURL in sortedSegments {
                        guard let text = try? String(contentsOf: segURL, encoding: .utf8) else { continue }
                        text.enumerateLines { line, _ in
                            guard let data = line.data(using: .utf8),
                                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

                            let recType = (obj["type"] as? String) ?? ""
                            let hasDirectTSKey = obj["time_unix_ms"] != nil || obj["timestamp"] != nil || obj["created_at"] != nil
                            let directTS: Date? = {
                                for key in ["time_unix_ms", "timestamp", "created_at"] {
                                    if let num = int64Val(obj[key]), num > 0 {
                                        return normalizeEpoch(num)
                                    }
                                    if let str = obj[key] as? String, let d = parseISO(str) {
                                        return d
                                    }
                                }
                                return nil
                            }()

                            if recType == "core_input" {
                                runningTS = extractVibeRecordTimestamp(obj, parseISO: parseISO)
                            } else if let recordTS = extractVibeRecordTimestamp(obj, parseISO: parseISO) {
                                runningTS = recordTS
                            }

                            guard recType == "action_result",
                                  let payload = obj["payload"] as? [String: Any] else { return }

                            let evTS: Date? = hasDirectTSKey ? directTS : runningTS
                            let actionID = (payload["action_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let state = (payload["state"] as? String) ?? ""
                            let resObj = payload["result"] as? [String: Any]

                            if state == "succeeded",
                               (resObj?["type"] as? String) == "completion_succeeded",
                               let innerRes = resObj?["result"] as? [String: Any],
                               let usage = innerRes["usage"] as? [String: Any] {
                                if !actionID.isEmpty {
                                    guard seenActionIDs.insert(actionID).inserted else { return }
                                }
                                // Verified on live Vibe unified journals: input_tokens ALREADY includes cached_input_tokens,
                                // and output_tokens ALREADY includes reasoning_tokens.
                                let rawIn = max(0, intVal(usage["input_tokens"]))
                                let cachedIn = max(0, intVal(usage["cached_input_tokens"]))
                                let cw = max(0, intVal(usage["cache_write_tokens"]))
                                let out = max(0, intVal(usage["output_tokens"]))
                                let uncachedIn = max(0, rawIn - cachedIn)
                                guard (uncachedIn + cachedIn + cw + out) > 0 else { return }

                                emittedJournalTurns = true
                                turnSeq += 1
                                if let ts = evTS, (ts < since || ts > upperBound) { return }

                                let sampleID = actionID.isEmpty ? "vibe-\(sessID)-\(turnSeq)" : "vibe-\(sessID)-\(actionID)"
                                samples.append(
                                    UsageSample(
                                        id: sampleID,
                                        vendor: .mistralVibe,
                                        origin: .standalone,
                                        timestamp: evTS,
                                        sessionID: sessID,
                                        projectName: origin,
                                        model: sessionModel,
                                        inputTokens: uncachedIn,
                                        outputTokens: out,
                                        cacheReadTokens: cachedIn,
                                        cacheWriteTokens: cw
                                    )
                                )
                            } else if state == "failed" {
                                if isStructuredRateLimitValue(resObj?["error"] ?? payload["error"]) {
                                    if !actionID.isEmpty {
                                        guard seenFailedActionIDs.insert(actionID).inserted else { return }
                                    }
                                    if let ts = evTS, ts >= since, ts <= upperBound {
                                        rateLimits.append(
                                            RateLimitEvent(
                                                id: "vibe-429-\(sessID)-\(actionID.isEmpty ? UUID().uuidString : actionID)",
                                                vendor: .mistralVibe,
                                                timestamp: ts,
                                                sessionID: sessID
                                            )
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                // Fallback to legacy meta.json numeric stats ONLY if journal/*.jsonl yielded 0 completion turns
                if !emittedJournalTurns, let metaObj {
                    let stats = metaObj["stats"] as? [String: Any]
                    let inTok = intVal(stats?["session_prompt_tokens"]) + intVal(stats?["prompt_tokens"])
                    let outTok = intVal(stats?["session_completion_tokens"]) + intVal(stats?["completion_tokens"])
                    let cost = (stats?["session_cost"] as? NSNumber)?.doubleValue
                    if inTok > 0 || outTok > 0 || (cost ?? 0) > 0 {
                        if let ts = metaTS, (ts < since || ts > upperBound) {
                            continue
                        }
                        let rawTot = (inTok + outTok) > 0 ? (inTok + outTok) : nil
                        samples.append(
                            UsageSample(
                                unsplitID: "vibe-meta-\(sessID)",
                                vendor: .mistralVibe,
                                origin: .standalone,
                                timestamp: metaTS,
                                sessionID: sessID,
                                projectName: origin,
                                model: sessionModel,
                                rawTotalTokens: rawTot,
                                recordedCostUSD: cost
                            )
                        )
                    }
                }
            }
        }

        // Include .relay/LOG.md Vibe steps ONLY when their session is NOT already covered by unified/
        for run in relayRuns {
            let relayDir = URL(fileURLWithPath: run.logPath).deletingLastPathComponent()
            for step in run.steps where step.vendor == .mistralVibe {
                guard (step.tokens ?? 0) > 0 || (step.costUSD ?? 0) > 0 else { continue }
                if let exportedSessID = readRelayVibeSessionID(relayDir: relayDir, stepID: step.stepID),
                   unifiedSessionIDs.contains(exportedSessID) {
                    continue
                }
                let stepTS = parseRelayStepTimestamp(step.timestampString, timeZone: timeZone)
                if let ts = stepTS, (ts < since || ts > upperBound) { continue }
                samples.append(
                    UsageSample(
                        unsplitID: "vibe-relay-\(run.projectName)-\(step.id)",
                        vendor: .mistralVibe,
                        origin: .relayLog,
                        timestamp: stepTS,
                        sessionID: "\(run.projectName)-\(step.stepID)",
                        projectName: run.projectName,
                        model: step.model == "default" ? "" : step.model,
                        rawTotalTokens: step.tokens,
                        recordedCostUSD: step.costUSD
                    )
                )
            }
        }

        return VibeCollectionResult(
            samples: samples,
            rateLimitEvents: rateLimits,
            configuredActiveModel: configActiveModel
        )
    }

    private static func parseVibeConfigActiveModel(at configURL: URL) -> String? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        let activeRegex = try? NSRegularExpression(pattern: #"^\s*active_model\s*=\s*"([^"]+)""#)
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                // Stop at the first TOML section header so only root-level `active_model` is matched
                break
            }
            let ns = rawLine as NSString
            if let m = activeRegex?.firstMatch(in: rawLine, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges == 2 {
                let model = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !model.isEmpty { return model }
            }
        }
        return nil
    }

    private static func extractVibeRecordTimestamp(
        _ obj: [String: Any],
        parseISO: (String?) -> Date?
    ) -> Date? {
        for key in ["time_unix_ms", "timestamp", "created_at"] {
            if let num = int64Val(obj[key]), num > 0 {
                return normalizeEpoch(num)
            }
            if let str = obj[key] as? String, let d = parseISO(str) {
                return d
            }
        }

        guard let payload = obj["payload"] as? [String: Any] else { return nil }

        if let input = payload["input"] as? [String: Any],
           let det = input["determinism"] as? [String: Any],
           let ms = int64Val(det["time_unix_ms"]),
           ms > 0 {
            return normalizeEpoch(ms)
        }

        if let deltas = payload["delta"] as? [[String: Any]] {
            var latestEpoch: Int64 = 0
            var latestDate: Date?
            for delta in deltas {
                guard let entry = delta["entry"] as? [String: Any] else { continue }
                for key in ["updatedAt", "createdAt"] {
                    if let num = int64Val(entry[key]), num > latestEpoch {
                        latestEpoch = num
                    } else if let str = entry[key] as? String, let d = parseISO(str) {
                        if latestDate == nil || d > latestDate! {
                            latestDate = d
                        }
                    }
                }
            }
            if latestEpoch > 0 { return normalizeEpoch(latestEpoch) }
            if let latestDate { return latestDate }
        }

        if let sa = payload["session_api"] as? [String: Any],
           let outcomes = sa["turn_outcomes"] as? [String: Any] {
            var latestEpoch: Int64 = 0
            for val in outcomes.values {
                if let outDict = val as? [String: Any],
                   let completed = int64Val(outDict["completedAt"]),
                   completed > latestEpoch {
                    latestEpoch = completed
                }
            }
            if latestEpoch > 0 { return normalizeEpoch(latestEpoch) }
        }

        return nil
    }

    private static func readRelayVibeSessionID(relayDir: URL, stepID: String) -> String? {
        let stepFolder = relayDir.appendingPathComponent("\(stepID).vibe")
        let candidates = [
            stepFolder.appendingPathComponent("export.json"),
            stepFolder.appendingPathComponent("session/meta.json"),
            stepFolder.appendingPathComponent("meta.json")
        ]
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let sid = nonEmptyString(obj["session_id"]) {
                return sid
            }
        }
        return nil
    }

    public static func collectAntigravitySamples(
        logDir: URL,
        relayRuns: [RelayRunSummary],
        since: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> (samples: [UsageSample], latestModel: String?, rateLimitHits24h: Int) {
        let res = collectAntigravityTelemetry(logDir: logDir, relayRuns: relayRuns, since: since, now: now, timeZone: timeZone)
        return (res.samples, res.latestModel, res.rateLimitHits24h)
    }

    public static func collectAntigravityTelemetry(
        logDir: URL,
        relayRuns: [RelayRunSummary],
        since: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> AntigravityCollectionResult {
        var samples: [UsageSample] = []
        var rateLimits: [RateLimitEvent] = []
        let upperBound = now

        for run in relayRuns {
            for step in run.steps where step.vendor == .antigravity {
                guard (step.tokens ?? 0) > 0 || (step.costUSD ?? 0) > 0 else { continue }
                let stepTS = parseRelayStepTimestamp(step.timestampString, timeZone: timeZone)
                if let ts = stepTS, (ts < since || ts > upperBound) { continue }
                samples.append(
                    UsageSample(
                        unsplitID: "agy-relay-\(run.projectName)-\(step.id)",
                        vendor: .antigravity,
                        origin: .relayLog,
                        timestamp: stepTS,
                        sessionID: "\(run.projectName)-\(step.stepID)",
                        projectName: run.projectName,
                        model: step.model == "default" ? "" : step.model,
                        rawTotalTokens: step.tokens,
                        recordedCostUSD: step.costUSD
                    )
                )
            }
        }

        var latestModel: String?
        var latestDate: Date = .distantPast
        let dayAgo = now.addingTimeInterval(-86_400)
        let labelRegex = try? NSRegularExpression(pattern: #"label="([^"]+)""#)
        let structuredStatus429Regex = try? NSRegularExpression(pattern: #"(?:^|[\s,;(])(?:status|http_status|status_code)=429(?=$|[\s,;)])"#)
        let leadingISORegex = try? NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))"#)
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        let fm = FileManager.default
        if fm.fileExists(atPath: logDir.path),
           let files = try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "log" {
                let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                var fileModel: String?
                var lineNo = 0
                text.enumerateLines { line, _ in
                    lineNo += 1
                    let ns = line as NSString
                    let fullRange = NSRange(location: 0, length: ns.length)
                    if line.contains("override to backend: label="),
                       let m = labelRegex?.firstMatch(in: line, range: fullRange) {
                        fileModel = ns.substring(with: m.range(at: 1))
                    }
                    var jsonTS: Date?
                    let is429: Bool = {
                        if structuredStatus429Regex?.firstMatch(in: line, range: fullRange) != nil {
                            return true
                        }
                        if line.hasPrefix("{"),
                           let d = line.data(using: .utf8),
                           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                            if let tsStr = obj["timestamp"] as? String {
                                jsonTS = isoFrac.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                            }
                            return hasStructured429Status(obj) || isStructuredRateLimitValue(obj["error"])
                        }
                        return false
                    }()
                    if is429 {
                        var rlTS: Date? = jsonTS
                        if rlTS == nil,
                           let tm = leadingISORegex?.firstMatch(in: line, range: fullRange),
                           tm.numberOfRanges == 2 {
                            let tsStr = ns.substring(with: tm.range(at: 1))
                            rlTS = isoFrac.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                        }
                        if let rlTS, rlTS >= since, rlTS <= upperBound {
                            rateLimits.append(
                                RateLimitEvent(
                                    id: "agy-429-\(file.lastPathComponent)-\(lineNo)",
                                    vendor: .antigravity,
                                    timestamp: rlTS,
                                    sessionID: file.deletingPathExtension().lastPathComponent
                                )
                            )
                        }
                    }
                }
                if let fileModel, mod >= latestDate {
                    latestDate = mod
                    latestModel = fileModel
                }
            }
        }

        let hits24h = rateLimits.filter { $0.timestamp >= dayAgo && $0.timestamp <= upperBound }.count
        return AntigravityCollectionResult(
            samples: samples,
            latestModel: latestModel,
            rateLimitEvents: rateLimits,
            rateLimitHits24h: hits24h
        )
    }

    private static func parseRelayStepTimestamp(_ raw: String, timeZone: TimeZone) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let dateParts = parts[0].split(separator: "-").compactMap { Int($0) }
        let timeParts = parts[1].split(separator: ":").compactMap { Int($0) }
        guard dateParts.count == 3, (timeParts.count == 2 || timeParts.count == 3) else { return nil }

        let year = dateParts[0]
        let month = dateParts[1]
        let day = dateParts[2]
        let hour = timeParts[0]
        let minute = timeParts[1]
        let second = timeParts.count == 3 ? timeParts[2] : 0
        guard (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var comps = DateComponents()
        comps.calendar = cal
        comps.timeZone = timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        guard comps.isValidDate(in: cal) else { return nil }
        return cal.date(from: comps)
    }

    // MARK: - Helpers

    public static func parseOpenCodeModelLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty else {
            return trimmed
        }
        return id
    }

    public static func normalizeEpoch(_ value: Int64) -> Date {
        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: Double(value) / 1000.0)
        }
        return Date(timeIntervalSince1970: Double(value))
    }

    private static func cleanProjectLabel(from folderName: String) -> String {
        if let range = folderName.range(of: "-Projects-", options: .backwards) {
            return String(folderName[range.upperBound...])
        }
        let parts = folderName.split(separator: "-").filter { !$0.isEmpty }
        return parts.last.map(String.init) ?? folderName
    }

    private static func nonEmptyString(_ any: Any?) -> String? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }

    private static func intVal(_ any: Any?) -> Int {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let v = Int(s) { return v }
        return 0
    }

    private static func int64Val(_ any: Any?) -> Int64? {
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let v = Int64(s) { return v }
        return nil
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private static func tableExists(db: OpaquePointer, table: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        _ = table.withCString { cStr in
            sqlite3_bind_text(stmt, 1, cStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func tableHasColumn(db: OpaquePointer, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnText(stmt, 1) == column { return true }
        }
        return false
    }
}
