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

    public static func liveDefault(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CollectorPaths {
        CollectorPaths(
            claudeProjectsDir: home.appendingPathComponent(".claude/projects"),
            codexSQLiteFile: home.appendingPathComponent(".codex/state_5.sqlite"),
            openCodeSQLiteFile: home.appendingPathComponent(".local/share/opencode/opencode.db"),
            vibeSessionsDir: home.appendingPathComponent(".vibe/logs/session/unified"),
            antigravityLogsDir: home.appendingPathComponent(".gemini/antigravity-cli/log"),
            workspaceRootDir: home.appendingPathComponent("Projects")
        )
    }
}

public enum LocalTelemetryCollector {

    public static func collectSnapshot(
        paths: CollectorPaths = .liveDefault(),
        now: Date = Date(),
        lookbackDays: Int = 30
    ) -> TelemetrySnapshot {
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400.0)
        let fm = FileManager.default

        let claudeAvailable = fm.fileExists(atPath: paths.claudeProjectsDir.path)
        let codexAvailable = fm.fileExists(atPath: paths.codexSQLiteFile.path)
        let openCodeAvailable = fm.fileExists(atPath: paths.openCodeSQLiteFile.path)
        let vibeAvailable = fm.fileExists(atPath: paths.vibeSessionsDir.path)
        let agyAvailable = fm.fileExists(atPath: paths.antigravityLogsDir.path)

        let claudeResult = collectClaudeSamples(dir: paths.claudeProjectsDir, since: cutoff)
        let codexSamples = collectCodexSamples(dbURL: paths.codexSQLiteFile, since: cutoff)
        let openCodeSamples = collectOpenCodeSamples(dbURL: paths.openCodeSQLiteFile, since: cutoff)
        let relayRuns = collectRelayRuns(workspaceRoot: paths.workspaceRootDir)
        let vibeSamples = collectVibeSamples(vibeDir: paths.vibeSessionsDir, relayRuns: relayRuns, since: cutoff)
        let agyResult = collectAntigravitySamples(logDir: paths.antigravityLogsDir, relayRuns: relayRuns, since: cutoff)

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
        let twentyFourHoursAgo = now.addingTimeInterval(-24.0 * 3600.0)
        let fourteenDaysAgo = cal.date(byAdding: .day, value: -13, to: startOfToday) ?? startOfToday

        var summaries: [VendorSummary] = []
        for vendor in AgentVendor.allCases {
            let vSamples = samples.filter { $0.vendor == vendor }.sorted { $0.timestamp < $1.timestamp }
            let todaySlice = vSamples.filter { $0.timestamp >= startOfToday }
            let fiveHourSlice = vSamples.filter { $0.timestamp >= fiveHoursAgo }

            let todayCost = todaySlice.map(\.effectiveCostUSD).reduce(0, +)
            let todayTok = todaySlice.map(\.totalTokens).reduce(0, +)
            let fiveTok = fiveHourSlice.map(\.totalTokens).reduce(0, +)
            let fiveCost = fiveHourSlice.map(\.effectiveCostUSD).reduce(0, +)
            let thirtyCost = vSamples.map(\.effectiveCostUSD).reduce(0, +)
            let thirtyTok = vSamples.map(\.totalTokens).reduce(0, +)

            let distinctSessions = Set(vSamples.map(\.sessionID)).count
            let totalPromptSide = vSamples.map { $0.inputTokens + $0.cacheReadTokens + $0.cacheWriteTokens }.reduce(0, +)
            let totalCacheRead = vSamples.map(\.cacheReadTokens).reduce(0, +)
            let hitRatio = totalPromptSide > 0 ? Double(totalCacheRead) / Double(totalPromptSide) : 0.0

            let latestSample = vSamples.last
            let modelName = latestSample?.model.isEmpty == false
                ? latestSample!.model
                : (extraActiveModels[vendor] ?? "—")

            let sample429 = vSamples.filter { $0.isRateLimited && $0.timestamp >= twentyFourHoursAgo }.count
            let hits429 = sample429 + (extraRateLimits[vendor] ?? 0)

            summaries.append(
                VendorSummary(
                    vendor: vendor,
                    sourceAvailable: availability[vendor] ?? !vSamples.isEmpty,
                    todayCostUSD: todayCost,
                    todayTokens: todayTok,
                    fiveHourTokens: fiveTok,
                    fiveHourCostUSD: fiveCost,
                    thirtyDayCostUSD: thirtyCost,
                    thirtyDayTokens: thirtyTok,
                    sessionCount30d: distinctSessions,
                    cacheHitRatio: hitRatio,
                    activeModel: modelName,
                    lastActive: latestSample?.timestamp,
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
                let cost = vs.map(\.effectiveCostUSD).reduce(0, +)
                let sess = Set(vs.map(\.sessionID)).count
                dailyBuckets.append(DailyVendorBucket(date: dayStart, vendor: vendor, tokens: tok, costUSD: cost, sessions: sess))
            }
        }

        // Roll up recent sessions by (vendor, sessionID)
        var groupedSessions: [String: UsageSample] = [:]
        for sample in samples {
            let key = "\(sample.vendor.rawValue)::\(sample.sessionID)"
            if var existing = groupedSessions[key] {
                if sample.timestamp > existing.timestamp {
                    existing.timestamp = sample.timestamp
                    if !sample.model.isEmpty && sample.model != "—" {
                        existing.model = sample.model
                    }
                }
                let combinedRecorded: Double? = {
                    switch (existing.recordedCostUSD, sample.recordedCostUSD) {
                    case let (a?, b?): return a + b
                    case let (a?, nil): return a
                    case let (nil, b?): return b
                    case (nil, nil): return nil
                    }
                }()
                existing = UsageSample(
                    id: existing.id,
                    vendor: existing.vendor,
                    timestamp: existing.timestamp,
                    sessionID: existing.sessionID,
                    projectName: existing.projectName,
                    model: existing.model,
                    inputTokens: existing.inputTokens + sample.inputTokens,
                    outputTokens: existing.outputTokens + sample.outputTokens,
                    cacheReadTokens: existing.cacheReadTokens + sample.cacheReadTokens,
                    cacheWriteTokens: existing.cacheWriteTokens + sample.cacheWriteTokens,
                    recordedCostUSD: combinedRecorded,
                    isRateLimited: existing.isRateLimited || sample.isRateLimited
                )
                groupedSessions[key] = existing
            } else {
                groupedSessions[key] = sample
            }
        }

        let recentSessions = groupedSessions.values
            .filter { $0.totalTokens > 0 || ($0.recordedCostUSD ?? 0) > 0 }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(30)
            .map { $0 }

        return TelemetrySnapshot(
            capturedAt: now,
            vendorSummaries: summaries,
            dailyBuckets: dailyBuckets,
            recentSessions: recentSessions,
            relayRuns: relayRuns.sorted { $0.updatedAt > $1.updatedAt }
        )
    }

    // MARK: - 1. Claude Code JSONL Reader (Read-Only, Metadata Keys Only)

    public static func collectClaudeSamples(dir: URL, since: Date) -> (samples: [UsageSample], rateLimitHits24h: Int) {
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

        let dayAgo = Date().addingTimeInterval(-86_400)
        var samples: [UsageSample] = []
        var rateLimits = 0

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let mod = vals.contentModificationDate,
               mod < since {
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
                let ts = isoFrac.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                if let ts, ts < since { return }

                if let isApiErr = obj["isApiErrorMessage"] as? Bool, isApiErr {
                    if let ts, ts >= dayAgo, (line.contains("429") || line.localizedCaseInsensitiveContains("rate")) {
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

                let model = (msg["model"] as? String) ?? "claude"
                let sessID = (obj["sessionId"] as? String) ?? fileURL.deletingPathExtension().lastPathComponent
                let cwd = (obj["cwd"] as? String)
                let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallbackProject

                samples.append(
                    UsageSample(
                        id: "claude-\(sessID)-\(lineIdx)",
                        vendor: .claudeCode,
                        timestamp: ts ?? Date(),
                        sessionID: sessID,
                        projectName: project,
                        model: model,
                        inputTokens: inp,
                        outputTokens: out,
                        cacheReadTokens: cr,
                        cacheWriteTokens: cw,
                        recordedCostUSD: cost
                    )
                )
            }
        }
        return (samples, rateLimits)
    }

    // MARK: - 2. Codex SQLite Reader (SQLITE_OPEN_READONLY)

    public static func collectCodexSamples(dbURL: URL, since: Date) -> [UsageSample] {
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
        let sql = hasModelCol
            ? "SELECT id, cwd, tokens_used, updated_at, model FROM threads WHERE tokens_used > 0;"
            : "SELECT id, cwd, tokens_used, updated_at, model_provider FROM threads WHERE tokens_used > 0;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [UsageSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, 0) ?? UUID().uuidString
            let cwd = columnText(stmt, 1) ?? ""
            let totalTok = Int(sqlite3_column_int64(stmt, 2))
            let rawEpoch = sqlite3_column_int64(stmt, 3)
            let modelRaw = columnText(stmt, 4) ?? "gpt-codex"

            let ts = normalizeEpoch(rawEpoch)
            if ts < since { continue }

            // Codex `threads.tokens_used` is cumulative per thread; attribute ~85% input / 15% output when split isn't stored
            let estInput = Int(Double(totalTok) * 0.85)
            let estOutput = max(0, totalTok - estInput)
            let proj = cwd.isEmpty ? "codex" : URL(fileURLWithPath: cwd).lastPathComponent

            results.append(
                UsageSample(
                    id: "codex-\(id)",
                    vendor: .codex,
                    timestamp: ts,
                    sessionID: id,
                    projectName: proj,
                    model: modelRaw.isEmpty ? "gpt-codex" : modelRaw,
                    inputTokens: estInput,
                    outputTokens: estOutput
                )
            )
        }
        return results
    }

    // MARK: - 3. OpenCode SQLite Reader (SQLITE_OPEN_READONLY)

    public static func collectOpenCodeSamples(dbURL: URL, since: Date) -> [UsageSample] {
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

        var results: [UsageSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, 0) ?? UUID().uuidString
            let dir = columnText(stmt, 1) ?? ""
            let cost = sqlite3_column_double(stmt, 2)
            let tIn = Int(sqlite3_column_int64(stmt, 3))
            let tOut = Int(sqlite3_column_int64(stmt, 4)) + Int(sqlite3_column_int64(stmt, 5))
            let tCR = Int(sqlite3_column_int64(stmt, 6))
            let tCW = Int(sqlite3_column_int64(stmt, 7))
            let rawModel = columnText(stmt, 8) ?? "opencode"
            let rawUpdated = sqlite3_column_int64(stmt, 9)

            if tIn == 0 && tOut == 0 && tCR == 0 && tCW == 0 && cost <= 0 { continue }
            let ts = normalizeEpoch(rawUpdated)
            if ts < since { continue }

            let cleanModel = parseOpenCodeModelLabel(rawModel)
            let proj = dir.isEmpty ? "opencode" : URL(fileURLWithPath: dir).lastPathComponent

            results.append(
                UsageSample(
                    id: "opencode-\(id)",
                    vendor: .openCode,
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

    // MARK: - 4. Agent-Relay `.relay/LOG.md` Scanner

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
            for child in children {
                let candidate = child.appendingPathComponent(".relay/LOG.md")
                if fm.fileExists(atPath: candidate.path) {
                    logFiles.append(candidate)
                }
            }
        }

        return logFiles.compactMap { parseRelayLogFile(at: $0) }
    }

    public static func parseRelayLogFile(at logURL: URL) -> RelayRunSummary? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        let modDate = (try? logURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let projectDir = logURL.deletingLastPathComponent().deletingLastPathComponent()
        let projectName = projectDir.lastPathComponent

        // Heading format: `## 01-claude: ok, 42s, 2026-11-10 14:22`
        let headerRegex = try? NSRegularExpression(pattern: #"^##\s+([^\s:]+):\s*([^,]+),\s*(\d+)s,\s*(.+)$"#)
        let costRegex = try? NSRegularExpression(pattern: #"cost\s+\$([0-9]+(?:\.[0-9]+)?)"#)
        let tokensRegex = try? NSRegularExpression(pattern: #"tokens\s+([0-9,]+)"#)
        let modelRegex = try? NSRegularExpression(pattern: #"model\s+([^,\n]+)"#)

        var steps: [RelayBatonStep] = []
        var currentHeader: (step: String, status: String, secs: Int, ts: String)?
        var currentModel = "default"
        var currentCost: Double?
        var currentTokens: Int?
        var currentVendor: AgentVendor?

        func flushStep() {
            guard let hdr = currentHeader else { return }
            steps.append(
                RelayBatonStep(
                    stepID: hdr.step,
                    vendor: currentVendor ?? inferVendor(from: hdr.step),
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
            currentVendor = nil
        }

        text.enumerateLines { line, _ in
            let ns = line as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            if let m = headerRegex?.firstMatch(in: line, range: fullRange), m.numberOfRanges == 5 {
                flushStep()
                let step = ns.substring(with: m.range(at: 1))
                let status = ns.substring(with: m.range(at: 2))
                let secs = Int(ns.substring(with: m.range(at: 3))) ?? 0
                let ts = ns.substring(with: m.range(at: 4))
                currentHeader = (step, status, secs, ts)
            } else if currentHeader != nil && line.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                if let vm = inferVendor(from: line) {
                    currentVendor = vm
                }
                if let mm = modelRegex?.firstMatch(in: line, range: fullRange) {
                    currentModel = ns.substring(with: mm.range(at: 1)).trimmingCharacters(in: .whitespaces)
                }
                if let cm = costRegex?.firstMatch(in: line, range: fullRange) {
                    currentCost = Double(ns.substring(with: cm.range(at: 1)))
                }
                if let tm = tokensRegex?.firstMatch(in: line, range: fullRange) {
                    let digits = ns.substring(with: tm.range(at: 1)).replacingOccurrences(of: ",", with: "")
                    currentTokens = Int(digits)
                }
            }
        }
        flushStep()
        guard !steps.isEmpty else { return nil }
        return RelayRunSummary(projectName: projectName, logPath: logURL.path, updatedAt: modDate, steps: steps)
    }

    // MARK: - 5. Mistral Vibe & Antigravity Metadata Readers

    public static func collectVibeSamples(vibeDir: URL, relayRuns: [RelayRunSummary], since: Date) -> [UsageSample] {
        var samples: [UsageSample] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")

        // Include cost/token batons logged by agent-relay for Vibe
        for run in relayRuns {
            for step in run.steps where step.vendor == .mistralVibe {
                let ts = df.date(from: step.timestampString) ?? run.updatedAt
                if ts < since { continue }
                let tok = step.tokens ?? 0
                samples.append(
                    UsageSample(
                        id: "vibe-relay-\(run.projectName)-\(step.id)",
                        vendor: .mistralVibe,
                        timestamp: ts,
                        sessionID: "\(run.projectName)-\(step.stepID)",
                        projectName: run.projectName,
                        model: step.model == "default" ? "deepseek-v4.1-flash" : step.model,
                        inputTokens: Int(Double(tok) * 0.8),
                        outputTokens: max(0, tok - Int(Double(tok) * 0.8)),
                        recordedCostUSD: step.costUSD
                    )
                )
            }
        }

        // Also scan ~/.vibe/logs/session/unified/*/meta.json for standalone Vibe sessions
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
                    ?? Date()
                if ts < since { continue }
                let origin = (obj["origin_directory"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "vibe"
                let stats = obj["stats"] as? [String: Any]
                let inTok = intVal(stats?["session_prompt_tokens"]) + intVal(stats?["prompt_tokens"])
                let outTok = intVal(stats?["session_completion_tokens"]) + intVal(stats?["completion_tokens"])
                let cost = (stats?["session_cost"] as? NSNumber)?.doubleValue
                if inTok > 0 || outTok > 0 || (cost ?? 0) > 0 {
                    samples.append(
                        UsageSample(
                            id: "vibe-meta-\(sessID)",
                            vendor: .mistralVibe,
                            timestamp: ts,
                            sessionID: sessID,
                            projectName: origin,
                            model: (obj["model"] as? String) ?? "deepseek-v4.1-flash",
                            inputTokens: inTok,
                            outputTokens: outTok,
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
        since: Date
    ) -> (samples: [UsageSample], latestModel: String?, rateLimitHits24h: Int) {
        var samples: [UsageSample] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")

        for run in relayRuns {
            for step in run.steps where step.vendor == .antigravity {
                let ts = df.date(from: step.timestampString) ?? run.updatedAt
                if ts < since { continue }
                let tok = step.tokens ?? 0
                samples.append(
                    UsageSample(
                        id: "agy-relay-\(run.projectName)-\(step.id)",
                        vendor: .antigravity,
                        timestamp: ts,
                        sessionID: "\(run.projectName)-\(step.stepID)",
                        projectName: run.projectName,
                        model: step.model == "default" ? "gemini-4-carbon-high" : step.model,
                        inputTokens: Int(Double(tok) * 0.8),
                        outputTokens: max(0, tok - Int(Double(tok) * 0.8)),
                        recordedCostUSD: step.costUSD
                    )
                )
            }
        }

        var latestModel: String?
        var latestDate: Date = .distantPast
        var rateLimits24h = 0
        let dayAgo = Date().addingTimeInterval(-86_400)
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

    // MARK: - Private Helpers

    public static func parseOpenCodeModelLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty else {
            return trimmed.isEmpty ? "opencode" : trimmed
        }
        return id
    }

    public static func normalizeEpoch(_ value: Int64) -> Date {
        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: Double(value) / 1000.0)
        }
        return Date(timeIntervalSince1970: Double(value))
    }

    private static func inferVendor(from text: String) -> AgentVendor? {
        let lower = text.lowercased()
        if lower.contains("claude") { return .claudeCode }
        if lower.contains("codex") { return .codex }
        if lower.contains("opencode") { return .openCode }
        if lower.contains("vibe") { return .mistralVibe }
        if lower.contains("agy") || lower.contains("antigravity") { return .antigravity }
        return nil
    }

    private static func cleanProjectLabel(from folderName: String) -> String {
        // Claude encodes `/Users/xu/Projects/foo` as `-Users-xu-Projects-foo`
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
