import Foundation
import SQLite3
import Testing
@testable import AgentBarCore

@Suite("Collectors Scoped Tests", .timeLimit(.minutes(1)))
struct CollectorsTests {

    @Test("Deduplicates multi-block streaming Claude JSONL lines sharing (message.id, requestId) and takes max usage")
    func claudeStreamingDeduplication() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-claude-dedup-\(UUID().uuidString)")
        let projDir = tmp.appendingPathComponent("-tmp-dev-Projects-synth-repo")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let now = Date(timeIntervalSince1970: 1_794_600_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let t1 = iso.string(from: now.addingTimeInterval(-600))
        let t2 = iso.string(from: now.addingTimeInterval(-300))

        // Turn 1: 3 content-block lines (thinking, text, tool_use) with identical (msg_01, req_01)
        // Output tokens grow from 120 -> 450 -> 800 across streaming chunks; must count ONCE with max=800.
        // Turn 2: 2 content-block lines with msg_02 and missing requestId (fallback to message.id).
        let jsonl = """
        {"type":"assistant","timestamp":"\(t1)","sessionId":"sess-a","requestId":"req_01","cwd":"/tmp/dev/Projects/synth-repo","message":{"id":"msg_01","model":"claude-opus-5-5","usage":{"input_tokens":200,"output_tokens":120,"cache_read_input_tokens":8000,"cache_creation_input_tokens":1000}}}
        {"type":"assistant","timestamp":"\(t1)","sessionId":"sess-a","requestId":"req_01","cwd":"/tmp/dev/Projects/synth-repo","message":{"id":"msg_01","model":"claude-opus-5-5","usage":{"input_tokens":200,"output_tokens":450,"cache_read_input_tokens":8000,"cache_creation_input_tokens":1000}}}
        {"type":"assistant","timestamp":"\(t1)","sessionId":"sess-a","requestId":"req_01","cwd":"/tmp/dev/Projects/synth-repo","message":{"id":"msg_01","model":"claude-opus-5-5","usage":{"input_tokens":200,"output_tokens":800,"cache_read_input_tokens":8000,"cache_creation_input_tokens":1000}}}
        {"type":"assistant","timestamp":"\(t2)","sessionId":"sess-a","cwd":"/tmp/dev/Projects/synth-repo","message":{"id":"msg_02","model":"claude-sonnet-5-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":4000,"cache_creation_input_tokens":500}}}
        {"type":"assistant","timestamp":"\(t2)","sessionId":"sess-a","cwd":"/tmp/dev/Projects/synth-repo","message":{"id":"msg_02","model":"claude-sonnet-5-5","usage":{"input_tokens":100,"output_tokens":300,"cache_read_input_tokens":4000,"cache_creation_input_tokens":500}}}
        """
        try jsonl.write(to: projDir.appendingPathComponent("sess-a.jsonl"), atomically: true, encoding: .utf8)

        let res = LocalTelemetryCollector.collectClaudeSamples(dir: tmp, since: now.addingTimeInterval(-3600), now: now)
        #expect(res.samples.count == 2)
        guard res.samples.count == 2 else { return }

        let opus = try #require(res.samples.first(where: { $0.model == "claude-opus-5-5" }))
        #expect(opus.inputTokens == 200)
        #expect(opus.outputTokens == 800)
        #expect(opus.cacheReadTokens == 8_000)
        #expect(opus.cacheWriteTokens == 1_000)
        #expect(opus.totalTokens == 10_000)

        let sonnet = try #require(res.samples.first(where: { $0.model == "claude-sonnet-5-5" }))
        #expect(sonnet.inputTokens == 100)
        #expect(sonnet.outputTokens == 300)
        #expect(sonnet.cacheReadTokens == 4_000)
        #expect(sonnet.cacheWriteTokens == 500)
        #expect(sonnet.totalTokens == 4_900)
    }

    @Test("Codex reads real rollout token_count breakdown and never fabricates 85/15 splits")
    func codexRolloutBreakdownAndMissingRolloutHonesty() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-codex-rollout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rolloutURL = tmp.appendingPathComponent("rollout-th-real.jsonl")
        // Realistic Codex rollout structure: input_tokens includes cached_input_tokens; output_tokens includes reasoning_output_tokens.
        // Uncached input = 500_000 - 480_000 = 20_000; cached = 480_000; output = 5_000; total = 505_000.
        let rolloutContent = """
        {"timestamp":"2026-11-14T01:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-14T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200000,"cached_input_tokens":190000,"cache_write_input_tokens":0,"output_tokens":2000,"reasoning_output_tokens":400,"total_tokens":202000}}}}
        {"timestamp":"2026-11-14T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500000,"cached_input_tokens":480000,"cache_write_input_tokens":0,"output_tokens":5000,"reasoning_output_tokens":900,"total_tokens":505000}}}}
        """
        try rolloutContent.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let codexDB = tmp.appendingPathComponent("state_5.sqlite")
        let now = Date(timeIntervalSince1970: 1_794_600_000)
        let nowSec = Int64(now.timeIntervalSince1970)
        try execSQL(at: codexDB, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT);
        INSERT INTO threads VALUES ('th-real', '/tmp/proj-a', 505000, \(nowSec), 'gpt-6.1-sol', '\(rolloutURL.path)');
        """)

        let samples = LocalTelemetryCollector.collectCodexSamples(dbURL: codexDB, since: now.addingTimeInterval(-3600), now: now)
        #expect(samples.count == 1)
        let real = try #require(samples.first)
        #expect(real.hasTokenBreakdown == true)
        #expect(real.inputTokens == 20_000)
        #expect(real.cacheReadTokens == 480_000)
        #expect(real.cacheWriteTokens == 0)
        #expect(real.outputTokens == 5_000)
        #expect(real.totalTokens == 505_000)

        let snap = LocalTelemetryCollector.buildSnapshot(
            samples: samples,
            relayRuns: [],
            availability: [.codex: true],
            now: now
        )
        let codexSummary = try #require(snap.vendorSummaries.first(where: { $0.vendor == .codex }))
        #expect(codexSummary.completeness == .complete)
        let hitRate = try #require(codexSummary.cacheHitRatio)
        // Cache hit ratio = 480_000 / (20_000 + 480_000 + 0) = 0.96
        #expect(abs(hitRate - 0.96) < 0.0001)
        // Cost = (20k/1M)*$2 + (5k/1M)*$8 + (480k/1M)*$0.50 = $0.04 + $0.04 + $0.24 = $0.32
        let cost30 = try #require(codexSummary.thirtyDayCostUSD)
        #expect(abs(cost30 - 0.32) < 0.000_001)
    }

    @Test("Codex thread without rollout file reports totalOnly with nil breakdown, nil cost, and nil cacheHitRate")
    func codexMissingRolloutReportsTotalOnlyAndNilBreakdown() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-codex-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let codexDB = tmp.appendingPathComponent("state_5.sqlite")
        let now = Date(timeIntervalSince1970: 1_794_600_000)
        let nowSec = Int64(now.timeIntervalSince1970)
        try execSQL(at: codexDB, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT);
        INSERT INTO threads VALUES ('th-no-rollout', '/tmp/proj-b', 345678, \(nowSec), 'gpt-6.1-sol', '/nonexistent/rollout-missing.jsonl');
        """)

        let samples = LocalTelemetryCollector.collectCodexSamples(dbURL: codexDB, since: now.addingTimeInterval(-3600), now: now)
        #expect(samples.count == 1)
        let item = try #require(samples.first)
        #expect(item.hasTokenBreakdown == false)
        #expect(item.totalTokens == 345_678)
        #expect(item.effectiveCostUSD == nil)

        let snap = LocalTelemetryCollector.buildSnapshot(
            samples: samples,
            relayRuns: [],
            availability: [.codex: true],
            now: now
        )
        let codexSummary = try #require(snap.vendorSummaries.first(where: { $0.vendor == .codex }))
        #expect(codexSummary.completeness == .totalOnly)
        let w30 = codexSummary.metrics(for: .thirtyDays)
        #expect(w30.completeness == .totalOnly)
        #expect(w30.totalTokens == 345_678)
        #expect(w30.inputTokens == nil)
        #expect(w30.outputTokens == nil)
        #expect(w30.cacheReadTokens == nil)
        #expect(w30.cacheWriteTokens == nil)
        #expect(w30.estimatedCostUSD == nil)
        #expect(w30.cacheHitRate == nil)
        #expect(TelemetryFormatter.optionalUSD(w30.estimatedCostUSD, completeness: w30.completeness, language: .en) == "Unknown")
        #expect(TelemetryFormatter.optionalUSD(w30.estimatedCostUSD, completeness: w30.completeness, language: .zhHans) == "未知")
    }

    @Test("Codex rollout total_token_usage mismatch against threads.tokens_used is flagged and downgrades completeness from complete")
    func codexRolloutTotalMismatchFlagsAndDowngradesCompleteness() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-codex-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rolloutURL = tmp.appendingPathComponent("rollout-th-mis.jsonl")
        // Rollout sums to 12_000 tokens (input_tokens=10_000 including cached=8_000 -> uncached=2_000, output=2_000),
        // while state_5.sqlite threads.tokens_used records 50_000.
        let rolloutContent = """
        {"timestamp":"2026-11-14T02:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-14T02:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":8000,"cache_write_input_tokens":0,"output_tokens":2000,"reasoning_output_tokens":300,"total_tokens":12000}}}}
        """
        try rolloutContent.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let codexDB = tmp.appendingPathComponent("state_5.sqlite")
        let now = Date(timeIntervalSince1970: 1_794_600_000)
        let nowSec = Int64(now.timeIntervalSince1970)
        try execSQL(at: codexDB, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT);
        INSERT INTO threads VALUES ('th-mis', '/tmp/proj-mismatch', 50000, \(nowSec), 'gpt-6.1-sol', '\(rolloutURL.path)');
        """)

        let samples = LocalTelemetryCollector.collectCodexSamples(dbURL: codexDB, since: now.addingTimeInterval(-3600), now: now)
        #expect(samples.count == 1)
        let sample = try #require(samples.first)
        #expect(sample.hasRolloutMismatch == true)
        #expect(sample.expectedTotalTokens == 50_000)
        #expect(sample.mismatchNote == "th-mis: rollout=12000 vs sqlite=50000")

        let snap = LocalTelemetryCollector.buildSnapshot(
            samples: samples,
            relayRuns: [],
            availability: [.codex: true],
            now: now
        )
        let codexSummary = try #require(snap.vendorSummaries.first(where: { $0.vendor == .codex }))
        #expect(codexSummary.completeness == .mismatch)
        #expect(codexSummary.completeness != .complete)
        #expect(codexSummary.completeness.label(in: .en) == "Total mismatch")
        #expect(codexSummary.completeness.label(in: .zhHans) == "总量不一致")

        let w30 = codexSummary.metrics(for: .thirtyDays)
        #expect(w30.completeness == .mismatch)
        #expect(w30.completeness != .complete)
        #expect(w30.hasRolloutMismatch == true)
        #expect(w30.rolloutMismatchCount == 1)
        #expect(w30.mismatchDetails == ["th-mis: rollout=12000 vs sqlite=50000"])
        #expect(w30.mismatchNote(in: .en)?.contains("rollout=12000 vs sqlite=50000") == true)
        #expect(w30.mismatchNote(in: .zhHans)?.contains("rollout=12000 vs sqlite=50000") == true)
    }

    @Test("Collector and estimation code contains zero 0.85/0.15 split literals while mistralVibe UI color stays 0.85")
    func zeroFixedRatiosInSources() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let collectorsDir = repoRoot.appendingPathComponent("Sources/AgentBarCore/Collectors")
        let cliDir = repoRoot.appendingPathComponent("Sources/AgentBarCore/CLI")
        let modelsFile = repoRoot.appendingPathComponent("Sources/AgentBarCore/Models/TelemetryModels.swift")
        let forbidden = try NSRegularExpression(pattern: #"\b0\.(?:85|15)\b"#)

        var hits: [String] = []
        for dir in [collectorsDir, cliDir] {
            let enumerator = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                let ns = content as NSString
                if forbidden.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)) != nil {
                    hits.append(fileURL.lastPathComponent)
                }
            }
        }

        // Check non-UI lines in TelemetryModels.swift (pricing & sample models) for 0.85/0.15
        let modelsContent = try String(contentsOf: modelsFile, encoding: .utf8)
        for (idx, line) in modelsContent.components(separatedBy: .newlines).enumerated() {
            if line.contains("Color(red:") { continue }
            let ns = line as NSString
            if forbidden.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
                hits.append("TelemetryModels.swift:\(idx + 1)")
            }
        }
        #expect(hits.isEmpty, "Found forbidden 0.85/0.15 literals in collector/pricing code: \(hits)")

        // W4: mistralVibe UI color must use its natural 0.85 red component, never artificial 0.848
        #expect(modelsContent.contains("Color(red: 0.85, green: 0.64, blue: 0.25)"))
        let dashboardContent = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/AgentBarCore/Views/DashboardView.swift"),
            encoding: .utf8
        )
        #expect(!modelsContent.contains("0.848"))
        #expect(!dashboardContent.contains("0.848"))
    }

    @Test("Cache hit ratio formula strictly divides cache_read by (input + cache_read + cache_write)")
    func cacheHitRateFormulaIncludesAllThreeDenominatorTerms() throws {
        let now = Date(timeIntervalSince1970: 1_794_600_000)
        // input = 2_000, cache_read = 6_000, cache_write = 2_000, output = 1_000
        // Exact cache hit rate = 6_000 / (2_000 + 6_000 + 2_000) = 0.60.
        // Removing ANY of input, cache_read, or cache_write from denominator yields 0.75 or 1.50 != 0.60!
        let sample = UsageSample(
            id: "s-hit",
            vendor: .claudeCode,
            timestamp: now.addingTimeInterval(-60),
            sessionID: "sess-hit",
            projectName: "math-check",
            model: "claude-sonnet-5-5",
            inputTokens: 2_000,
            outputTokens: 1_000,
            cacheReadTokens: 6_000,
            cacheWriteTokens: 2_000
        )
        let snap = LocalTelemetryCollector.buildSnapshot(
            samples: [sample],
            relayRuns: [],
            availability: [.claudeCode: true],
            now: now
        )
        let claude = try #require(snap.vendorSummaries.first(where: { $0.vendor == .claudeCode }))
        let ratio = try #require(claude.cacheHitRatio)
        #expect(abs(ratio - 0.60) < 0.000_001)
    }

    @Test("Classifies all 4 completeness levels accurately in EN/ZH and never marks Vibe or Antigravity as complete")
    func completenessFourLevelsAndVibeAgyNeverComplete() throws {
        let now = Date(timeIntervalSince1970: 1_794_600_000)
        let claudeSample = UsageSample(
            id: "c1", vendor: .claudeCode, timestamp: now.addingTimeInterval(-100),
            sessionID: "sc1", projectName: "p", model: "claude-sonnet-5-5",
            inputTokens: 1_000, outputTokens: 200, cacheReadTokens: 4_000, cacheWriteTokens: 0
        )
        let codexTotalOnly = UsageSample(
            unsplitID: "cx1", vendor: .codex, origin: .standalone, timestamp: now.addingTimeInterval(-100),
            sessionID: "scx1", projectName: "p", model: "gpt-6.1-sol", rawTotalTokens: 50_000
        )
        let vibeRelay = UsageSample(
            unsplitID: "vb1", vendor: .mistralVibe, origin: .relayLog, timestamp: now.addingTimeInterval(-100),
            sessionID: "svb1", projectName: "p", model: "deepseek-v4-1-flash-1017", rawTotalTokens: nil, recordedCostUSD: 0.12
        )
        let agyRelay = UsageSample(
            unsplitID: "ag1", vendor: .antigravity, origin: .relayLog, timestamp: now.addingTimeInterval(-100),
            sessionID: "sag1", projectName: "p", model: "gemini-4-carbon-high", rawTotalTokens: 300_000, recordedCostUSD: nil
        )

        let snap = LocalTelemetryCollector.buildSnapshot(
            samples: [claudeSample, codexTotalOnly, vibeRelay, agyRelay],
            relayRuns: [],
            availability: [.claudeCode: true, .codex: true, .openCode: false, .mistralVibe: true, .antigravity: true],
            now: now
        )
        let byVendor = Dictionary(uniqueKeysWithValues: snap.vendorSummaries.map { ($0.vendor, $0) })

        #expect(byVendor[.claudeCode]?.completeness == .complete)
        #expect(byVendor[.claudeCode]?.completeness.label(in: .en) == "Complete")
        #expect(byVendor[.claudeCode]?.completeness.label(in: .zhHans) == "完整")

        #expect(byVendor[.codex]?.completeness == .totalOnly)
        #expect(byVendor[.codex]?.completeness.label(in: .en) == "Total only")
        #expect(byVendor[.codex]?.completeness.label(in: .zhHans) == "只有总量")

        #expect(byVendor[.openCode]?.completeness == .noData)
        #expect(byVendor[.openCode]?.completeness.label(in: .en) == "No data")
        #expect(byVendor[.openCode]?.completeness.label(in: .zhHans) == "没有数据")

        #expect(byVendor[.mistralVibe]?.completeness == .relayOnly)
        #expect(byVendor[.mistralVibe]?.completeness != .complete)
        #expect(byVendor[.mistralVibe]?.completeness.label(in: .en) == "Relay logs only")
        #expect(byVendor[.mistralVibe]?.completeness.label(in: .zhHans) == "只有接力里的部分")

        #expect(byVendor[.antigravity]?.completeness == .relayOnly)
        #expect(byVendor[.antigravity]?.completeness != .complete)
    }

    @Test("Distinguishes initial Refreshing state from post-scan No data state without touching standard UserDefaults")
    @MainActor
    func monitorDistinguishesRefreshingFromNoData() throws {
        let defaults = InMemoryPreferenceStore()

        let pendingMonitor = TelemetryMonitor(previewSnapshot: nil, startImmediately: false, preferenceStore: defaults)
        #expect(pendingMonitor.hasLoadedInitialSnapshot == false)
        #expect(pendingMonitor.statusSummaryLabel(in: .en) == "Refreshing…")
        #expect(pendingMonitor.statusSummaryLabel(in: .zhHans) == "刷新中…")
        #expect(pendingMonitor.menuBarText == "…")

        let emptySnap = LocalTelemetryCollector.buildSnapshot(
            samples: [],
            relayRuns: [],
            availability: [:],
            now: Date(timeIntervalSince1970: 1_794_600_000)
        )
        let loadedEmptyMonitor = TelemetryMonitor(previewSnapshot: emptySnap, startImmediately: false, preferenceStore: defaults)
        #expect(loadedEmptyMonitor.hasLoadedInitialSnapshot == true)
        #expect(loadedEmptyMonitor.statusSummaryLabel(in: .en) == "No data")
        #expect(loadedEmptyMonitor.statusSummaryLabel(in: .zhHans) == "没有数据")
        #expect(loadedEmptyMonitor.menuBarText == "—")
    }

    private func execSQL(at url: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "SQLiteTest", code: 1)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "sql error"
            throw NSError(domain: "SQLiteTest", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
