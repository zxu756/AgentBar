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

    public static func liveDefault(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
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
        let expectedTotalTokens: Int
    }

    struct Entry {
        let uncachedInput: Int
        let cachedInput: Int
        let cacheWrite: Int
        let output: Int
        let model: String?
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

    public static func defaultDataSourceDescription(for vendor: AgentVendor) -> String {
        switch vendor {
        case .claudeCode:
            return "~/.claude/projects/**/*.jsonl"
        case .codex:
            return "~/.codex/state_5.sqlite + rollout-*.jsonl"
        case .openCode:
            return "~/.local/share/opencode/opencode.db (session_v2)"
        case .mistralVibe:
            return "~/Projects/*/.relay/LOG.md (meta.json lacks token stats)"
        case .antigravity:
            return "~/Projects/*/.relay/LOG.md (cli-*.log lacks token stats)"
        }
    }

    public static func collectSnapshot(
        paths: CollectorPaths = .liveDefault(),
        now: Date = Date(),
        lookbackDays: Int = 30,
        allowZstdRollout: Bool = true
    ) -> TelemetrySnapshot {
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400.0)
        let fm = FileManager.default

        let claudeAvailable = fm.fileExists(atPath: paths.claudeProjectsDir.path)
        let codexAvailable = fm.fileExists(atPath: paths.codexSQLiteFile.path)
        let openCodeAvailable = fm.fileExists(atPath: paths.openCodeSQLiteFile.path)
        let vibeAvailable = fm.fileExists(atPath: paths.vibeSessionsDir.path)
        let agyAvailable = fm.fileExists(atPath: paths.antigravityLogsDir.path)

        let claudeResult = collectClaudeSamples(dir: paths.claudeProjectsDir, since: cutoff, now: now)
        let codexSamples = collectCodexSamples(dbURL: paths.codexSQLiteFile, since: cutoff, now: now, allowZstd: allowZstdRollout)
        let openCodeSamples = collectOpenCodeSamples(dbURL: paths.openCodeSQLiteFile, since: cutoff, now: now)
        let relayRuns = collectRelayRuns(workspaceRoot: paths.workspaceRootDir)
        let vibeSamples = collectVibeSamples(vibeDir: paths.vibeSessionsDir, relayRuns: relayRuns, since: cutoff, now: now)
        let agyResult = collectAntigravitySamples(logDir: paths.antigravityLogsDir, relayRuns: relayRuns, since: cutoff, now: now)

        let allTurnSamples = claudeResult.samples + codexSamples + openCodeSamples + vibeSamples + agyResult.samples

        let availability: [AgentVendor: Bool] = [
            .claudeCode: claudeAvailable,
            .codex: codexAvailable,
            .openCode: openCodeAvailable,
            .mistralVibe: vibeAvailable || !vibeSamples.isEmpty,
            .antigravity: agyAvailable || !agyResult.samples.isEmpty
        ]

        let extraActiveModels: [AgentVendor: String] = [
            .antigravity: agyResult.latestModel
        ].compactMapValues { $0 }

        let extraRateLimits: [AgentVendor: Int] = [
            .claudeCode: claudeResult.rateLimitHits24h,
            .antigravity: agyResult.rateLimitHits24h
        ]

        return buildSnapshot(
            samples: allTurnSamples,
            relayRuns: relayRuns,
            availability: availability,
            extraActiveModels: extraActiveModels,
            extraRateLimits: extraRateLimits,
            now: now
        )
    }

    public static func buildSnapshot(
        samples: [UsageSample],
        relayRuns: [RelayRunSummary],
        availability: [AgentVendor: Bool],
        extraActiveModels: [AgentVendor: String] = [:],
        extraRateLimits: [AgentVendor: Int] = [:],
        now: Date = Date()
    ) -> TelemetrySnapshot {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5.0 * 3600.0)
        let sevenDaysAgo = now.addingTimeInterval(-7.0 * 86_400.0)
        let twentyFourHoursAgo = now.addingTimeInterval(-24.0 * 3600.0)
        let fourteenDaysAgo = cal.date(byAdding: .day, value: -13, to: startOfToday) ?? startOfToday

        var summaries: [VendorSummary] = []
        for vendor in AgentVendor.allCases {
            let vSamples = samples.filter { $0.vendor == vendor }.sorted { $0.timestamp < $1.timestamp }
            let sourceAvail = availability[vendor] ?? !vSamples.isEmpty
            let dataSource = defaultDataSourceDescription(for: vendor)

            let overallCompleteness = classifyVendorCompleteness(
                vendor: vendor,
                samples: vSamples
            )

            let fiveHourSlice = vSamples.filter { $0.timestamp >= fiveHoursAgo }
            let todaySlice = vSamples.filter { $0.timestamp >= startOfToday }
            let sevenDaySlice = vSamples.filter { $0.timestamp >= sevenDaysAgo }
            let thirtyDaySlice = vSamples

            let windows: [TelemetryWindow: VendorWindowMetrics] = [
                .fiveHours: computeWindowMetrics(
                    vendor: vendor,
                    slice: fiveHourSlice,
                    overallCompleteness: overallCompleteness,
                    sourceAvailable: sourceAvail,
                    dataSource: dataSource
                ),
                .today: computeWindowMetrics(
                    vendor: vendor,
                    slice: todaySlice,
                    overallCompleteness: overallCompleteness,
                    sourceAvailable: sourceAvail,
                    dataSource: dataSource
                ),
                .sevenDays: computeWindowMetrics(
                    vendor: vendor,
                    slice: sevenDaySlice,
                    overallCompleteness: overallCompleteness,
                    sourceAvailable: sourceAvail,
                    dataSource: dataSource
                ),
                .thirtyDays: computeWindowMetrics(
                    vendor: vendor,
                    slice: thirtyDaySlice,
                    overallCompleteness: overallCompleteness,
                    sourceAvailable: sourceAvail,
                    dataSource: dataSource
                )
            ]

            let distinctSessions = Set(vSamples.map(\.sessionID)).count
            let latestSample = vSamples.last(where: { !$0.model.isEmpty && $0.model != "—" && $0.model != "unknown" }) ?? vSamples.last
            let modelName: String = {
                if let m = latestSample?.model, !m.isEmpty, m != "unknown" {
                    return m
                }
                return extraActiveModels[vendor] ?? "—"
            }()

            let sample429 = vSamples.filter { $0.isRateLimited && $0.timestamp >= twentyFourHoursAgo }.count
            let hits429 = sample429 + (extraRateLimits[vendor] ?? 0)

            summaries.append(
                VendorSummary(
                    vendor: vendor,
                    sourceAvailable: sourceAvail,
                    dataSource: dataSource,
                    completeness: overallCompleteness,
                    windows: windows,
                    sessionCount30d: distinctSessions,
                    activeModel: modelName,
                    lastActive: vSamples.last?.timestamp,
                    rateLimitHits24h: hits429
                )
            )
        }

        // Build 14-day daily buckets per vendor
        var dailyBuckets: [DailyVendorBucket] = []
        for dayOffset in 0..<14 {
            guard let dayStart = cal.date(byAdding: .day, value: dayOffset, to: fourteenDaysAgo),
                  let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let daySlice = samples.filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
            for vendor in AgentVendor.allCases {
                let vs = daySlice.filter { $0.vendor == vendor }
                let tok = vs.map(\.totalTokens).reduce(0, +)
                let cost = vs.compactMap(\.effectiveCostUSD).reduce(0, +)
                let sess = Set(vs.map(\.sessionID)).count
                dailyBuckets.append(DailyVendorBucket(date: dayStart, vendor: vendor, tokens: tok, costUSD: cost, sessions: sess))
            }
        }

        // Roll up recent sessions by (vendor, sessionID) preserving exact per-turn costs and breakdown honesty
        var groupedSessions: [String: UsageSample] = [:]
        for sample in samples {
            let key = "\(sample.vendor.rawValue)::\(sample.sessionID)"
            if let existing = groupedSessions[key] {
                let newerTS = max(existing.timestamp, sample.timestamp)
                let chosenModel: String = {
                    if sample.timestamp >= existing.timestamp, !sample.model.isEmpty, sample.model != "—" {
                        return sample.model
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
                    isRateLimited: existing.isRateLimited || sample.isRateLimited
                )
            } else {
                groupedSessions[key] = sample
            }
        }

        let recentSessions = groupedSessions.values
            .filter { $0.totalTokens > 0 || ($0.effectiveCostUSD ?? 0) > 0 }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(30)
            .map { $0 }

        return TelemetrySnapshot(
            capturedAt: now,
            isDemoData: false,
            vendorSummaries: summaries,
            dailyBuckets: dailyBuckets,
            recentSessions: recentSessions,
            relayRuns: relayRuns.sorted { $0.updatedAt > $1.updatedAt }
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
            // Standalone meta.json lacks prompt cache breakdown and misses journal/*.jsonl sessions in M0.
            return .totalOnly
        case .claudeCode, .codex, .openCode:
            if samples.allSatisfy(\.hasTokenBreakdown) {
                return .complete
            }
            return .totalOnly
        }
    }

    private static func computeWindowMetrics(
        vendor: AgentVendor,
        slice: [UsageSample],
        overallCompleteness: DataCompleteness,
        sourceAvailable: Bool,
        dataSource: String
    ) -> VendorWindowMetrics {
        if slice.isEmpty {
            // Vibe and Antigravity lack standalone token telemetry, so an empty slice means No Data (never 0 / complete).
            if vendor == .mistralVibe || vendor == .antigravity || !sourceAvailable || overallCompleteness == .noData {
                return .empty(dataSource: dataSource, completeness: .noData)
            }
            // Active standalone SQLite/JSONL store with 0 records in this shorter window:
            if overallCompleteness == .complete {
                return VendorWindowMetrics(
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    totalTokens: 0,
                    recordCount: 0,
                    estimatedCostUSD: 0.0,
                    unknownModelRecordCount: 0,
                    cacheHitRate: nil,
                    dataSource: dataSource,
                    completeness: .complete
                )
            }
            return VendorWindowMetrics(
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                totalTokens: 0,
                recordCount: 0,
                estimatedCostUSD: nil,
                unknownModelRecordCount: 0,
                cacheHitRate: nil,
                dataSource: dataSource,
                completeness: .totalOnly
            )
        }

        let completeness = classifyVendorCompleteness(vendor: vendor, samples: slice)
        let unknownModels = slice.map(\.unmatchedModelCount).reduce(0, +)

        if completeness == .complete {
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
                estimatedCostUSD: cost,
                unknownModelRecordCount: unknownModels,
                cacheHitRate: hitRate,
                dataSource: dataSource,
                completeness: .complete
            )
        } else {
            let knownTots = slice.compactMap(\.knownTotalTokens)
            let tot: Int? = knownTots.isEmpty ? nil : knownTots.reduce(0, +)
            let cost: Double? = {
                if completeness == .totalOnly {
                    // For totalOnly (e.g. Codex without rollout), cost is only known if explicitly recorded for all records.
                    let recs = slice.compactMap { ($0.recordedCostUSD ?? 0) > 0 ? $0.recordedCostUSD : nil }
                    return (recs.count == slice.count && !recs.isEmpty) ? recs.reduce(0, +) : nil
                }
                let priced = slice.compactMap(\.effectiveCostUSD)
                return priced.isEmpty ? nil : priced.reduce(0, +)
            }()

            return VendorWindowMetrics(
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                totalTokens: tot,
                recordCount: slice.count,
                estimatedCostUSD: cost,
                unknownModelRecordCount: unknownModels,
                cacheHitRate: nil,
                dataSource: dataSource,
                completeness: completeness
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

    // MARK: - 1. Claude Code JSONL Reader (Read-Only, Metadata Keys Only, Deduplicated by message.id + requestId)

    public static func collectClaudeSamples(
        dir: URL,
        since: Date,
        now: Date = Date()
    ) -> (samples: [UsageSample], rateLimitHits24h: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return ([], 0) }
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], 0) }

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        struct ClaudeAccumulator {
            var orderIndex: Int
            var id: String
            var timestamp: Date
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
        var rateLimits = 0

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let mod = vals.contentModificationDate,
               mod < since.addingTimeInterval(-3600) {
                continue
            }
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let fallbackProject = cleanProjectLabel(from: fileURL.deletingLastPathComponent().lastPathComponent)

            var lineIdx = 0
            text.enumerateLines { line, _ in
                lineIdx += 1
                guard line.contains("\"assistant\"") || line.contains("429") || line.contains("rate_limit") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

                let tsStr = obj["timestamp"] as? String ?? ""
                let parsedTS = isoFrac.date(from: tsStr) ?? isoPlain.date(from: tsStr)

                if let isApiErr = obj["isApiErrorMessage"] as? Bool, isApiErr {
                    if let parsedTS, parsedTS >= dayAgo, parsedTS <= upperBound,
                       (line.contains("429") || line.localizedCaseInsensitiveContains("rate")) {
                        rateLimits += 1
                    }
                }

                guard (obj["type"] as? String) == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { return }

                let inp = intVal(usage["input_tokens"])
                let out = intVal(usage["output_tokens"])
                let cr = intVal(usage["cache_read_input_tokens"])
                let cw = intVal(usage["cache_creation_input_tokens"])
                let cost = (obj["costUSD"] as? NSNumber)?.doubleValue
                if inp == 0 && out == 0 && cr == 0 && cw == 0 && (cost ?? 0) == 0 { return }

                let msgID = (msg["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let reqID = (obj["requestId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
                let sessID = (obj["sessionId"] as? String) ?? fileURL.deletingPathExtension().lastPathComponent
                let cwd = obj["cwd"] as? String
                let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallbackProject
                let eventTS = parsedTS ?? now

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
                    deduped[dedupKey] = existing
                } else {
                    nextOrder += 1
                    deduped[dedupKey] = ClaudeAccumulator(
                        orderIndex: nextOrder,
                        id: "claude-\(sessID)-\(nextOrder)",
                        timestamp: eventTS,
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
            .filter { $0.timestamp >= since && $0.timestamp <= upperBound }
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
        return (samples, rateLimits)
    }

    // MARK: - 2. Codex SQLite + Rollout JSONL Reader (SQLITE_OPEN_READONLY, Zero Fixed-Ratio Splits)

    public static func collectCodexSamples(
        dbURL: URL,
        since: Date,
        now: Date = Date(),
        allowZstd: Bool = true
    ) -> [UsageSample] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let hasModelCol = tableHasColumn(db: db, table: "threads", column: "model")
        let hasRolloutCol = tableHasColumn(db: db, table: "threads", column: "rollout_path")
        let modelExpr = hasModelCol ? "model" : "NULL"
        let rolloutExpr = hasRolloutCol ? "rollout_path" : "NULL"
        let sql = "SELECT id, cwd, tokens_used, updated_at, \(modelExpr), \(rolloutExpr) FROM threads WHERE tokens_used > 0;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        let upperBound = now
        var results: [UsageSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, 0) ?? UUID().uuidString
            let cwd = columnText(stmt, 1) ?? ""
            let totalTok = Int(sqlite3_column_int64(stmt, 2))
            let rawEpoch = sqlite3_column_int64(stmt, 3)
            let dbModel = (columnText(stmt, 4) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rolloutPath = (columnText(stmt, 5) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            let ts = normalizeEpoch(rawEpoch)
            if ts < since || ts > upperBound { continue }

            let proj = cwd.isEmpty ? "codex" : URL(fileURLWithPath: cwd).lastPathComponent

            if !rolloutPath.isEmpty,
               let breakdown = readCodexRolloutBreakdown(
                   rolloutPath: rolloutPath,
                   expectedTotalTokens: totalTok,
                   allowZstd: allowZstd
               ) {
                let effectiveModel = !dbModel.isEmpty ? dbModel : (breakdown.model ?? "")
                results.append(
                    UsageSample(
                        id: "codex-\(id)",
                        vendor: .codex,
                        origin: .standalone,
                        timestamp: ts,
                        sessionID: id,
                        projectName: proj,
                        model: effectiveModel,
                        inputTokens: breakdown.uncachedInput,
                        outputTokens: breakdown.output,
                        cacheReadTokens: breakdown.cachedInput,
                        cacheWriteTokens: breakdown.cacheWrite
                    )
                )
            } else {
                // No rollout breakdown available: report ONLY totalTokens = tokens_used, breakdown & cost = nil.
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
        return results
    }

    private static func readCodexRolloutBreakdown(
        rolloutPath: String,
        expectedTotalTokens: Int,
        allowZstd: Bool
    ) -> CodexRolloutCache.Entry? {
        let fm = FileManager.default
        if fm.fileExists(atPath: rolloutPath) {
            let attrs = try? fm.attributesOfItem(atPath: rolloutPath)
            let mod = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let cacheKey = CodexRolloutCache.Key(path: rolloutPath, modTime: mod, fileSize: size, expectedTotalTokens: expectedTotalTokens)
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
            let cacheKey = CodexRolloutCache.Key(path: zstPath, modTime: mod, fileSize: size, expectedTotalTokens: expectedTotalTokens)
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
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        let tailBytes: UInt64 = 512 * 1024
        let fileSize = (try? fh.seekToEnd()) ?? 0
        if fileSize > tailBytes {
            try? fh.seek(toOffset: fileSize - tailBytes)
            if let tailData = try? fh.readToEnd(),
               let tailText = String(data: tailData, encoding: .utf8),
               let entry = extractLastCodexUsage(from: tailText) {
                return entry
            }
        }

        try? fh.seek(toOffset: 0)
        guard let fullData = try? fh.readToEnd() else { return nil }
        let fullText = String(decoding: fullData, as: UTF8.self)
        return extractLastCodexUsage(from: fullText)
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
        return extractLastCodexUsage(from: text)
    }

    private static func extractLastCodexUsage(from text: String) -> CodexRolloutCache.Entry? {
        var lastUsage: [String: Any]?
        var latestModel: String?

        text.enumerateLines { line, _ in
            guard line.contains("\"token_count\"") || line.contains("\"turn_context\"") else { return }
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { return }
            let topType = obj["type"] as? String
            if topType == "turn_context", let m = payload["model"] as? String, !m.isEmpty {
                latestModel = m
            } else if topType == "event_msg",
                      (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let totalUsage = info["total_token_usage"] as? [String: Any] {
                if totalUsage["input_tokens"] != nil && totalUsage["output_tokens"] != nil {
                    lastUsage = totalUsage
                }
            }
        }

        guard let usage = lastUsage else { return nil }
        let rawInput = max(0, intVal(usage["input_tokens"]))
        let cachedInput = max(0, intVal(usage["cached_input_tokens"]))
        let cacheWrite = max(0, intVal(usage["cache_write_input_tokens"]))
        let output = max(0, intVal(usage["output_tokens"]))
        let uncachedInput = max(0, rawInput - cachedInput)
        guard (uncachedInput + cachedInput + cacheWrite + output) > 0 else { return nil }

        return CodexRolloutCache.Entry(
            uncachedInput: uncachedInput,
            cachedInput: cachedInput,
            cacheWrite: cacheWrite,
            output: output,
            model: latestModel
        )
    }

    // MARK: - 3. OpenCode SQLite Reader (SQLITE_OPEN_READONLY)

    public static func collectOpenCodeSamples(
        dbURL: URL,
        since: Date,
        now: Date = Date()
    ) -> [UsageSample] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
        SELECT id, directory, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, model, time_updated
        FROM session_v2;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        let upperBound = now
        var results: [UsageSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, 0) ?? UUID().uuidString
            let dir = columnText(stmt, 1) ?? ""
            let cost = sqlite3_column_double(stmt, 2)
            let tIn = Int(sqlite3_column_int64(stmt, 3))
            let tOut = Int(sqlite3_column_int64(stmt, 4)) + Int(sqlite3_column_int64(stmt, 5))
            let tCR = Int(sqlite3_column_int64(stmt, 6))
            let tCW = Int(sqlite3_column_int64(stmt, 7))
            let rawModel = columnText(stmt, 8) ?? ""
            let rawUpdated = sqlite3_column_int64(stmt, 9)

            if tIn == 0 && tOut == 0 && tCR == 0 && tCW == 0 && cost <= 0 { continue }
            let ts = normalizeEpoch(rawUpdated)
            if ts < since || ts > upperBound { continue }

            let cleanModel = parseOpenCodeModelLabel(rawModel)
            let proj = dir.isEmpty ? "opencode" : URL(fileURLWithPath: dir).lastPathComponent

            results.append(
                UsageSample(
                    id: "opencode-\(id)",
                    vendor: .openCode,
                    origin: .standalone,
                    timestamp: ts,
                    sessionID: id,
                    projectName: proj,
                    model: cleanModel,
                    inputTokens: tIn,
                    outputTokens: tOut,
                    cacheReadTokens: tCR,
                    cacheWriteTokens: tCW,
                    recordedCostUSD: cost > 0 ? cost : nil
                )
            )
        }
        return results
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
            // Every markdown heading immediately terminates any open step block so detail lines never bleed.
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

            // Only top-level `- ` metadata bullets inside an active step are inspected (never indented file paths or blockquotes).
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

    // MARK: - 5. Mistral Vibe & Antigravity Metadata Readers (Zero Ratio Fabrication)

    public static func collectVibeSamples(
        vibeDir: URL,
        relayRuns: [RelayRunSummary],
        since: Date,
        now: Date = Date()
    ) -> [UsageSample] {
        var samples: [UsageSample] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        let upperBound = now

        for run in relayRuns {
            for step in run.steps where step.vendor == .mistralVibe {
                guard (step.tokens ?? 0) > 0 || (step.costUSD ?? 0) > 0 else { continue }
                let ts = df.date(from: step.timestampString) ?? run.updatedAt
                if ts < since || ts > upperBound { continue }
                samples.append(
                    UsageSample(
                        unsplitID: "vibe-relay-\(run.projectName)-\(step.id)",
                        vendor: .mistralVibe,
                        origin: .relayLog,
                        timestamp: ts,
                        sessionID: "\(run.projectName)-\(step.stepID)",
                        projectName: run.projectName,
                        model: step.model == "default" ? "" : step.model,
                        rawTotalTokens: step.tokens,
                        recordedCostUSD: step.costUSD
                    )
                )
            }
        }

        // Check standalone ~/.vibe/logs/session/unified/*/meta.json if legacy numeric stats exist
        let fm = FileManager.default
        if fm.fileExists(atPath: vibeDir.path),
           let children = try? fm.contentsOfDirectory(at: vibeDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for folder in children {
                let metaURL = folder.appendingPathComponent("meta.json")
                guard let data = try? Data(contentsOf: metaURL),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let sessID = (obj["session_id"] as? String) ?? folder.lastPathComponent
                let startStr = (obj["start_time"] as? String) ?? ""
                let ts = iso.date(from: startStr)
                    ?? (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? now
                if ts < since || ts > upperBound { continue }
                let origin = (obj["origin_directory"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "vibe"
                let stats = obj["stats"] as? [String: Any]
                let inTok = intVal(stats?["session_prompt_tokens"]) + intVal(stats?["prompt_tokens"])
                let outTok = intVal(stats?["session_completion_tokens"]) + intVal(stats?["completion_tokens"])
                let cost = (stats?["session_cost"] as? NSNumber)?.doubleValue
                if inTok > 0 || outTok > 0 || (cost ?? 0) > 0 {
                    let rawTot = (inTok + outTok) > 0 ? (inTok + outTok) : nil
                    samples.append(
                        UsageSample(
                            unsplitID: "vibe-meta-\(sessID)",
                            vendor: .mistralVibe,
                            origin: .standalone,
                            timestamp: ts,
                            sessionID: sessID,
                            projectName: origin,
                            model: (obj["model"] as? String) ?? "",
                            rawTotalTokens: rawTot,
                            recordedCostUSD: cost
                        )
                    )
                }
            }
        }
        return samples
    }

    public static func collectAntigravitySamples(
        logDir: URL,
        relayRuns: [RelayRunSummary],
        since: Date,
        now: Date = Date()
    ) -> (samples: [UsageSample], latestModel: String?, rateLimitHits24h: Int) {
        var samples: [UsageSample] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        let upperBound = now

        for run in relayRuns {
            for step in run.steps where step.vendor == .antigravity {
                guard (step.tokens ?? 0) > 0 || (step.costUSD ?? 0) > 0 else { continue }
                let ts = df.date(from: step.timestampString) ?? run.updatedAt
                if ts < since || ts > upperBound { continue }
                samples.append(
                    UsageSample(
                        unsplitID: "agy-relay-\(run.projectName)-\(step.id)",
                        vendor: .antigravity,
                        origin: .relayLog,
                        timestamp: ts,
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
        var rateLimits24h = 0
        let dayAgo = now.addingTimeInterval(-86_400)
        let labelRegex = try? NSRegularExpression(pattern: #"label="([^"]+)""#)

        let fm = FileManager.default
        if fm.fileExists(atPath: logDir.path),
           let files = try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for file in files where file.pathExtension == "log" {
                let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if mod < since { continue }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                var fileModel: String?
                text.enumerateLines { line, _ in
                    if line.contains("override to backend: label=") {
                        let ns = line as NSString
                        if let m = labelRegex?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                            fileModel = ns.substring(with: m.range(at: 1))
                        }
                    }
                    if mod >= dayAgo && (line.contains("RESOURCE_EXHAUSTED") || line.contains("status=429")) {
                        rateLimits24h += 1
                    }
                }
                if let fileModel, mod >= latestDate {
                    latestDate = mod
                    latestModel = fileModel
                }
            }
        }

        return (samples, latestModel, rateLimits24h)
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

    private static func intVal(_ any: Any?) -> Int {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let v = Int(s) { return v }
        return 0
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
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
