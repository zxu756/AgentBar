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
        let now = Date(timeIntervalSince1970: 1_794_622_200) // 2026-11-14T02:10:00Z
        let nowSec = Int64(now.timeIntervalSince1970)
        try execSQL(at: codexDB, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT);
        INSERT INTO threads VALUES ('th-real', '/tmp/proj-a', 505000, \(nowSec), 'gpt-6.1-sol', '\(rolloutURL.path)');
        """)

        let samples = LocalTelemetryCollector.collectCodexSamples(dbURL: codexDB, since: now.addingTimeInterval(-7200), now: now)
        #expect(samples.count == 2)
        #expect(samples.allSatisfy { $0.hasTokenBreakdown })
        #expect(samples.map(\.inputTokens).reduce(0, +) == 20_000)
        #expect(samples.map(\.cacheReadTokens).reduce(0, +) == 480_000)
        #expect(samples.map(\.cacheWriteTokens).reduce(0, +) == 0)
        #expect(samples.map(\.outputTokens).reduce(0, +) == 5_000)
        #expect(samples.map(\.totalTokens).reduce(0, +) == 505_000)

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
        let now = Date(timeIntervalSince1970: 1_794_622_200) // 2026-11-14T02:10:00Z
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

    @Test("M1 B3+B15: Codex cross-day rollout splits turns by event timestamp, skips zero-delta duplicates, tracks turn_context models, and flags per-day mismatch")
    func codexCrossDayRolloutEventsAndPerDayMismatch() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-m1-codex-3day-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let utc = TimeZone(secondsFromGMT: 0)!
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = try #require(iso.date(from: "2026-11-14T12:00:00Z"))
        let nowSec = Int64(now.timeIntervalSince1970)

        // Thread 1 (th-3day): spans 2026-11-12, 2026-11-13, 2026-11-14; includes a duplicate consecutive token_count event and mid-thread model switch.
        // Day 1 (2026-11-12): raw_in=100k, cached=80k -> uncached=20k, out=5k -> delta=105k (gpt-6-luna)
        // Day 2 (2026-11-13): cum raw_in=250k, cached=200k -> uncached=50k (+30k), cached (+120k), out=12k (+7k) -> delta=157k (gpt-6.1-sol)
        // Day 3 (2026-11-14): cum raw_in=310k, cached=240k -> uncached=70k (+20k), cached (+40k), out=15k (+3k) -> delta=63k (gpt-6.1-sol)
        // Total = 325,000 == threads.tokens_used (exact match).
        let roll3Day = tmp.appendingPathComponent("rollout-3day.jsonl")
        try """
        {"timestamp":"2026-11-12T08:00:00Z","type":"turn_context","payload":{"model":"gpt-6-luna"}}
        {"timestamp":"2026-11-12T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":80000,"cache_write_input_tokens":0,"output_tokens":5000,"total_tokens":105000}}}}
        {"timestamp":"2026-11-12T08:01:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":80000,"cache_write_input_tokens":0,"output_tokens":5000,"total_tokens":105000}}}}
        {"timestamp":"2026-11-13T14:29:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-13T14:30:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250000,"cached_input_tokens":200000,"cache_write_input_tokens":0,"output_tokens":12000,"total_tokens":262000}}}}
        {"timestamp":"2026-11-14T09:15:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":310000,"cached_input_tokens":240000,"cache_write_input_tokens":0,"output_tokens":15000,"total_tokens":325000}}}}
        """.write(to: roll3Day, atomically: true, encoding: .utf8)

        // Thread 2 (th-mis-2day): rollout sums to 20,000 across 2026-11-13 (12k) and 2026-11-14 (8k), while threads.tokens_used = 99,000.
        let rollMis = tmp.appendingPathComponent("rollout-mis-2day.jsonl")
        try """
        {"timestamp":"2026-11-13T18:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-13T18:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":8000,"cache_write_input_tokens":0,"output_tokens":2000,"total_tokens":12000}}}}
        {"timestamp":"2026-11-14T10:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":17000,"cached_input_tokens":14000,"cache_write_input_tokens":0,"output_tokens":3000,"total_tokens":20000}}}}
        """.write(to: rollMis, atomically: true, encoding: .utf8)

        let codexDB = tmp.appendingPathComponent("state_5.sqlite")
        try execSQL(at: codexDB, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT);
        INSERT INTO threads VALUES ('th-3day', '/tmp/proj-3day', 325000, \(nowSec - 600), 'gpt-6.1-sol', '\(roll3Day.path)');
        INSERT INTO threads VALUES ('th-mis-2day', '/tmp/proj-mis', 99000, \(nowSec - 300), 'gpt-6.1-sol', '\(rollMis.path)');
        """)

        let samples = LocalTelemetryCollector.collectCodexSamples(
            dbURL: codexDB,
            since: now.addingTimeInterval(-30 * 86_400),
            now: now
        )
        // 3 non-zero turns from th-3day + 2 turns from th-mis-2day = 5 samples (duplicate 0-delta skipped!)
        #expect(samples.count == 5)
        let firstTurn = try #require(samples.first(where: { $0.sessionID == "th-3day" && $0.totalTokens == 105_000 }))
        #expect(firstTurn.model == "gpt-6-luna")

        let snap = LocalTelemetryCollector.buildSnapshot(
            samples: samples,
            relayRuns: [],
            availability: [.codex: true],
            now: now,
            timeZone: utc
        )
        let byDay = Dictionary(uniqueKeysWithValues: snap.dailyBreakdown.map { ($0.dateString, $0) })

        let d12 = try #require(byDay["2026-11-12"])
        #expect(d12.metrics(for: .codex).totalTokens == 105_000)
        #expect(d12.hasCodexRolloutMismatch == false)
        #expect(d12.codexMismatchNote(in: .en) == nil)

        let d13 = try #require(byDay["2026-11-13"])
        #expect(d13.metrics(for: .codex).totalTokens == 157_000 + 12_000)
        #expect(d13.hasCodexRolloutMismatch == true)
        #expect(d13.codexMismatchNote(in: .en)?.contains("th-mis-2day: rollout=20000 vs sqlite=99000") == true)

        let d14 = try #require(byDay["2026-11-14"])
        #expect(d14.metrics(for: .codex).totalTokens == 63_000 + 8_000)
        #expect(d14.hasCodexRolloutMismatch == true)
        #expect(d14.codexMismatchNote(in: .zhHans)?.contains("th-mis-2day: rollout=20000 vs sqlite=99000") == true)
    }

    @Test("M1 B3: OpenCode cross-day session_message splits events by per-message timestamp and falls back to session_v2 only when session_message has 0 rows")
    func openCodeCrossDaySessionMessages() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-m1-opencode-3day-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let utc = TimeZone(secondsFromGMT: 0)!
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = try #require(iso.date(from: "2026-11-14T12:00:00Z"))

        let d11Ms = Int64(try #require(iso.date(from: "2026-11-11T12:00:00Z")).timeIntervalSince1970 * 1000)
        let d12Ms = Int64(try #require(iso.date(from: "2026-11-12T06:00:00Z")).timeIntervalSince1970 * 1000)
        let d13Ms = Int64(try #require(iso.date(from: "2026-11-13T11:00:00Z")).timeIntervalSince1970 * 1000)
        let d14Ms = Int64(try #require(iso.date(from: "2026-11-14T09:30:00Z")).timeIntervalSince1970 * 1000)

        let ocDB = tmp.appendingPathComponent("opencode.db")
        try execSQL(at: ocDB, sql: """
        CREATE TABLE session_v2 (
            id TEXT PRIMARY KEY, directory TEXT, cost REAL,
            tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
            tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER
        );
        CREATE TABLE session_message (
            id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
            time_created INTEGER, time_updated INTEGER, data TEXT
        );
        INSERT INTO session_v2 VALUES ('ses-cross', '/tmp/proj-oc', 0.45, 45000, 11000, 1000, 250000, 5000, 'deepseek-v4.1-flash', \(d14Ms));
        INSERT INTO session_v2 VALUES ('ses-fallback', '/tmp/proj-legacy', 0.12, 10000, 2000, 0, 38000, 0, 'deepseek-v4.1-flash', \(d11Ms));

        INSERT INTO session_message VALUES ('m1', 'ses-cross', 'assistant', 1, \(d12Ms), \(d12Ms),
            '{"model":{"id":"deepseek-v4.1-flash","providerID":"opencode-go"},"cost":0.10,"time":{"created":\(d12Ms)},"tokens":{"input":10000,"output":4000,"reasoning":1000,"cache":{"read":90000,"write":0}}}');
        INSERT INTO session_message VALUES ('m2', 'ses-cross', 'compaction', 2, \(d13Ms), \(d13Ms),
            '{"model":{"id":"claude-sonnet-5-5","providerID":"anthropic"},"cost":0.35,"time":{"created":\(d13Ms)},"tokens":{"input":20000,"output":2000,"reasoning":0,"cache":{"read":80000,"write":5000}}}');
        INSERT INTO session_message VALUES ('m3', 'ses-cross', 'assistant', 3, \(d14Ms), \(d14Ms),
            '{"model":{"id":"glm-5-3","providerID":"zai"},"cost":0.0,"time":{"created":\(d14Ms)},"tokens":{"input":15000,"output":5000,"reasoning":0,"cache":{"read":80000,"write":0}}}');
        """)

        let samples = LocalTelemetryCollector.collectOpenCodeSamples(
            dbURL: ocDB,
            since: now.addingTimeInterval(-30 * 86_400),
            now: now
        )
        #expect(samples.count == 4)

        let snap = LocalTelemetryCollector.buildSnapshot(
            samples: samples,
            relayRuns: [],
            availability: [.openCode: true],
            now: now,
            timeZone: utc
        )
        let byDay = Dictionary(uniqueKeysWithValues: snap.dailyBreakdown.map { ($0.dateString, $0) })
        #expect(byDay["2026-11-11"]?.metrics(for: .openCode).totalTokens == 50_000)
        #expect(byDay["2026-11-12"]?.metrics(for: .openCode).totalTokens == 105_000)
        #expect(byDay["2026-11-13"]?.metrics(for: .openCode).totalTokens == 107_000)
        #expect(byDay["2026-11-14"]?.metrics(for: .openCode).totalTokens == 100_000)
        #expect(byDay["2026-11-14"]?.metrics(for: .openCode).unmatchedModelCount == 1)
    }

    @Test("M1 Row 3: fiveHours rolling window includes only events inside [now - 5h, now] even when session updated_at is 10m ago")
    func fiveHourRollingWindowUsesEventTimestamps() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-m1-5h-\(UUID().uuidString)")
        let homeDir = tmp.appendingPathComponent("home")
        let wsDir = tmp.appendingPathComponent("ws")
        let codexDir = homeDir.appendingPathComponent(".codex")
        let ocDir = homeDir.appendingPathComponent(".local/share/opencode")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ocDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let utc = TimeZone(secondsFromGMT: 0)!
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = try #require(iso.date(from: "2026-11-14T10:00:00Z"))
        let t8hAgo = now.addingTimeInterval(-8 * 3600) // 02:00Z (outside 5h, inside UTC today)
        let t7hAgo = now.addingTimeInterval(-7 * 3600) // 03:00Z (outside 5h, inside UTC today)
        let t1hAgo = now.addingTimeInterval(-1 * 3600) // 09:00Z (inside 5h)
        let updated10mAgo = Int64(now.addingTimeInterval(-600).timeIntervalSince1970)

        let rolloutURL = codexDir.appendingPathComponent("rollout-5h.jsonl")
        try """
        {"timestamp":"\(iso.string(from: t8hAgo))","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"\(iso.string(from: t8hAgo))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50000,"cached_input_tokens":40000,"cache_write_input_tokens":0,"output_tokens":2000,"total_tokens":52000}}}}
        {"timestamp":"\(iso.string(from: t7hAgo))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":80000,"cache_write_input_tokens":0,"output_tokens":4000,"total_tokens":104000}}}}
        {"timestamp":"\(iso.string(from: t1hAgo))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":130000,"cached_input_tokens":105000,"cache_write_input_tokens":0,"output_tokens":5000,"total_tokens":135000}}}}
        """.write(to: rolloutURL, atomically: true, encoding: .utf8)

        try execSQL(at: codexDir.appendingPathComponent("state_5.sqlite"), sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT);
        INSERT INTO threads VALUES ('th-5h', '/tmp/p', 135000, \(updated10mAgo), 'gpt-6.1-sol', '\(rolloutURL.path)');
        """)

        let ms8h = Int64(t8hAgo.timeIntervalSince1970 * 1000)
        let ms7h = Int64(t7hAgo.timeIntervalSince1970 * 1000)
        let ms1h = Int64(t1hAgo.timeIntervalSince1970 * 1000)
        let msUpd = updated10mAgo * 1000
        try execSQL(at: ocDir.appendingPathComponent("opencode.db"), sql: """
        CREATE TABLE session_v2 (
            id TEXT PRIMARY KEY, directory TEXT, cost REAL,
            tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
            tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER
        );
        CREATE TABLE session_message (
            id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
            time_created INTEGER, time_updated INTEGER, data TEXT
        );
        INSERT INTO session_v2 VALUES ('ses-5h', '/tmp/p', 0.30, 30000, 6000, 0, 90000, 0, 'deepseek-v4.1-flash', \(msUpd));
        INSERT INTO session_message VALUES ('m1', 'ses-5h', 'assistant', 1, \(ms8h), \(ms8h),
            '{"model":{"id":"deepseek-v4.1-flash"},"cost":0.10,"time":{"created":\(ms8h)},"tokens":{"input":10000,"output":2000,"reasoning":0,"cache":{"read":30000,"write":0}}}');
        INSERT INTO session_message VALUES ('m2', 'ses-5h', 'assistant', 2, \(ms7h), \(ms7h),
            '{"model":{"id":"deepseek-v4.1-flash"},"cost":0.10,"time":{"created":\(ms7h)},"tokens":{"input":10000,"output":2000,"reasoning":0,"cache":{"read":30000,"write":0}}}');
        INSERT INTO session_message VALUES ('m3', 'ses-5h', 'assistant', 3, \(ms1h), \(ms1h),
            '{"model":{"id":"deepseek-v4.1-flash"},"cost":0.10,"time":{"created":\(ms1h)},"tokens":{"input":10000,"output":2000,"reasoning":0,"cache":{"read":30000,"write":0}}}');
        """)

        let snap = LocalTelemetryCollector.collectSnapshot(
            paths: .liveDefault(home: homeDir, workspaceRoot: wsDir),
            now: now,
            timeZone: utc
        )
        let codex = try #require(snap.vendorSummaries.first(where: { $0.vendor == .codex }))
        // Only the 1h-ago turn (135k - 104k = 31k) belongs in fiveHours; all 3 turns (135k) belong in UTC today!
        #expect(codex.metrics(for: .fiveHours).totalTokens == 31_000)
        #expect(codex.metrics(for: .fiveHours).recordCount == 1)
        #expect(codex.metrics(for: .today).totalTokens == 135_000)

        let oc = try #require(snap.vendorSummaries.first(where: { $0.vendor == .openCode }))
        // Only m3 (42k) belongs in fiveHours; m1+m2+m3 (126k) belong in UTC today!
        #expect(oc.metrics(for: .fiveHours).totalTokens == 42_000)
        #expect(oc.metrics(for: .fiveHours).recordCount == 1)
        #expect(oc.metrics(for: .today).totalTokens == 126_000)
    }

    @Test("M1 B5: Mistral Vibe unified journal multi-segment reader deduplicates action_id, uncached=input-cached, uses config.toml model fallback, and avoids relay double-counting")
    func vibeUnifiedJournalMultiSegmentAndActionDedup() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-m1-vibe-\(UUID().uuidString)")
        let homeDir = tmp.appendingPathComponent("home")
        let wsDir = tmp.appendingPathComponent("ws")
        let vibeRoot = homeDir.appendingPathComponent(".vibe")
        let sessFolder = vibeRoot.appendingPathComponent("logs/session/unified/sess-vibe-001")
        let journalDir = sessFolder.appendingPathComponent("journal")
        let relayDir = wsDir.appendingPathComponent("demo-proj/.relay")
        let relayVibeOut = relayDir.appendingPathComponent("04-vibe.vibe")

        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relayVibeOut, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let utc = TimeZone(secondsFromGMT: 0)!
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = try #require(iso.date(from: "2026-11-14T12:00:00Z"))
        let day1Ms = Int64(try #require(iso.date(from: "2026-11-13T15:00:00Z")).timeIntervalSince1970 * 1000)
        let day2Ms = Int64(try #require(iso.date(from: "2026-11-14T08:00:00Z")).timeIntervalSince1970 * 1000)

        try """
        active_model = "deepseek-v4-1-flash-1017"
        """.write(to: vibeRoot.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        // meta.json omits active_model to verify config.toml fallback
        try """
        {"session_id":"sess-vibe-001","start_time":"2026-11-13T14:59:00Z","end_time":"2026-11-14T08:01:00Z","origin_directory":"/tmp/demo-proj","config":{}}
        """.write(to: sessFolder.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

        // Segment 1 (Day 1): act-1 -> input_tokens=12000 (includes cached=8000 -> uncached=4000), output=500 -> total=12500
        try """
        {"sequence":1,"type":"core_input","payload":{"input":{"determinism":{"time_unix_ms":\(day1Ms)}}}}
        {"sequence":2,"type":"action_result","payload":{"action_id":"act-1","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":12000,"cached_input_tokens":8000,"cache_write_tokens":0,"output_tokens":500,"reasoning_tokens":120,"total_tokens":12500}}}}}
        """.write(to: journalDir.appendingPathComponent("0000000000000001.jsonl"), atomically: true, encoding: .utf8)

        // Segment 2 (Day 2): replays duplicate act-1 (must be deduplicated!) + new act-2 -> input=20000 (cached=15000 -> uncached=5000), cw=1000, out=1000 -> total=22000
        try """
        {"sequence":35,"type":"action_result","payload":{"action_id":"act-1","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":12000,"cached_input_tokens":8000,"cache_write_tokens":0,"output_tokens":500,"reasoning_tokens":120,"total_tokens":12500}}}}}
        {"sequence":36,"type":"projection_delta","payload":{"delta":[{"entry":{"updatedAt":\(day2Ms),"createdAt":\(day2Ms)}}]}}
        {"sequence":37,"type":"action_result","payload":{"action_id":"act-2","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":20000,"cached_input_tokens":15000,"cache_write_tokens":1000,"output_tokens":1000,"reasoning_tokens":200,"total_tokens":22000}}}}}
        """.write(to: journalDir.appendingPathComponent("0000000000000035.jsonl"), atomically: true, encoding: .utf8)

        // Relay LOG.md references 04-vibe whose 04-vibe.vibe/export.json points to sess-vibe-001 -> must NOT double-count!
        try """
        # Agent Relay Log

        ## 04-vibe: ok, 45s, 2026-11-14 08:01
        - vibe: model deepseek-v4-1-flash-1017, tokens 34,500, cost $0.0500
        """.write(to: relayDir.appendingPathComponent("LOG.md"), atomically: true, encoding: .utf8)
        try """
        {"session_id":"sess-vibe-001"}
        """.write(to: relayVibeOut.appendingPathComponent("export.json"), atomically: true, encoding: .utf8)

        let snap = LocalTelemetryCollector.collectSnapshot(
            paths: .liveDefault(home: homeDir, workspaceRoot: wsDir),
            now: now,
            timeZone: utc
        )
        let vibe = try #require(snap.vendorSummaries.first(where: { $0.vendor == .mistralVibe }))
        #expect(vibe.completeness == .complete)
        #expect(vibe.activeModel == "deepseek-v4-1-flash-1017")

        let w30 = vibe.metrics(for: .thirtyDays)
        #expect(w30.recordCount == 2)
        #expect(w30.inputTokens == 9_000)       // 4,000 + 5,000 uncached
        #expect(w30.cacheReadTokens == 23_000)  // 8,000 + 15,000
        #expect(w30.cacheWriteTokens == 1_000)
        #expect(w30.outputTokens == 1_500)      // 500 + 1,000
        #expect(w30.totalTokens == 34_500)      // 12,500 + 22,000 (not 47,000 and not +34,500 from relay!)

        let byDay = Dictionary(uniqueKeysWithValues: snap.dailyBreakdown.map { ($0.dateString, $0) })
        #expect(byDay["2026-11-13"]?.metrics(for: .mistralVibe).totalTokens == 12_500)
        #expect(byDay["2026-11-14"]?.metrics(for: .mistralVibe).totalTokens == 22_000)
    }

    @Test("M1 B7: Counts 429 rate limits strictly from structured status/error codes and ignores free-form prose containing 'rate' or '429'")
    func structured429RateLimitCountingIgnoresProse() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-m1-429-\(UUID().uuidString)")
        let homeDir = tmp.appendingPathComponent("home")
        let wsDir = tmp.appendingPathComponent("ws")
        let claudeProj = homeDir.appendingPathComponent(".claude/projects/-tmp-prose")
        let codexDir = homeDir.appendingPathComponent(".codex")
        let ocDir = homeDir.appendingPathComponent(".local/share/opencode")
        let vibeJournal = homeDir.appendingPathComponent(".vibe/logs/session/unified/s-vibe/journal")
        let agyLogDir = homeDir.appendingPathComponent(".gemini/antigravity-cli/log")

        for d in [claudeProj, codexDir, ocDir, vibeJournal, agyLogDir, wsDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let utc = TimeZone(secondsFromGMT: 0)!
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = try #require(iso.date(from: "2026-11-14T12:00:00Z"))
        let tRecent = "2026-11-14T10:00:00Z"
        let recentSec = Int64(try #require(iso.date(from: tRecent)).timeIntervalSince1970)
        let recentMs = recentSec * 1000

        // Phase 1: Prose traps ("frame rate is 429 fps", "corporate tax rate limit discussion", non-429 API error) -> MUST yield 0!
        try """
        {"type":"assistant","timestamp":"\(tRecent)","sessionId":"s1","requestId":"r1","cwd":"/tmp/rate_limit_429","message":{"id":"m1","model":"claude-sonnet-5-5","content":[{"type":"text","text":"frame rate is 429 fps and corporate tax rate limit discussion"}],"usage":{"input_tokens":100,"output_tokens":50}}}
        {"type":"assistant","isApiErrorMessage":true,"error":"invalid_request_error","timestamp":"\(tRecent)","sessionId":"s1","message":{"id":"m2","content":[{"type":"text","text":"port 4290 rate limit note"}]}}
        """.write(to: claudeProj.appendingPathComponent("prose.jsonl"), atomically: true, encoding: .utf8)

        let rollProse = codexDir.appendingPathComponent("rollout-prose.jsonl")
        try """
        {"timestamp":"\(tRecent)","type":"turn_context","payload":{"model":"gpt-6.1-sol","summary":"frame rate is 429 fps"}}
        {"timestamp":"\(tRecent)","type":"event_msg","payload":{"type":"agent_message","message":"corporate tax rate limit 429"}}
        {"timestamp":"\(tRecent)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":100,"total_tokens":1100}}}}
        """.write(to: rollProse, atomically: true, encoding: .utf8)
        try execSQL(at: codexDir.appendingPathComponent("state_5.sqlite"), sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT);
        INSERT INTO threads VALUES ('th-prose', '/tmp/rate_429', 1100, \(recentSec), 'gpt-6.1-sol', '\(rollProse.path)');
        """)

        try execSQL(at: ocDir.appendingPathComponent("opencode.db"), sql: """
        CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER);
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT);
        INSERT INTO session_v2 VALUES ('ses-p', '/tmp/rate_429', 0.01, 500, 100, 0, 0, 0, 'deepseek-v4.1-flash', \(recentMs));
        INSERT INTO session_message VALUES ('m-p', 'ses-p', 'assistant', 1, \(recentMs), \(recentMs),
            '{"model":{"id":"deepseek-v4.1-flash"},"content":"frame rate is 429 fps; tax rate limit","time":{"created":\(recentMs)},"tokens":{"input":500,"output":100,"reasoning":0,"cache":{"read":0,"write":0}}}');
        """)

        try """
        {"session_id":"s-vibe","start_time":"\(tRecent)","config":{"active_model":"deepseek-v4-1-flash-1017"}}
        """.write(to: vibeJournal.deletingLastPathComponent().appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        try """
        {"sequence":1,"type":"core_input","payload":{"input":{"determinism":{"time_unix_ms":\(recentMs)},"prompt":"frame rate is 429 fps"}}}
        {"sequence":2,"type":"action_result","payload":{"action_id":"a1","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":1000,"cached_input_tokens":0,"cache_write_tokens":0,"output_tokens":100,"total_tokens":1100}}}}}
        """.write(to: vibeJournal.appendingPathComponent("0000000000000001.jsonl"), atomically: true, encoding: .utf8)

        try """
        2026-11-14T10:00:00Z INFO frame rate is 429 fps and corporate tax rate limit discussion
        """.write(to: agyLogDir.appendingPathComponent("cli-1.log"), atomically: true, encoding: .utf8)

        let snapProse = LocalTelemetryCollector.collectSnapshot(
            paths: .liveDefault(home: homeDir, workspaceRoot: wsDir),
            now: now,
            timeZone: utc
        )
        #expect(snapProse.rateLimitHits24h == 0)
        let d14Prose = try #require(snapProse.dailyBreakdown.first(where: { $0.dateString == "2026-11-14" }))
        #expect(d14Prose.rateLimit429Count == 0)

        // Phase 2: Add structured 429 error records across Claude, Codex, OpenCode, and Vibe -> exact count = 4!
        try """
        {"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"\(tRecent)","sessionId":"s2","requestId":"req-429"}
        """.write(to: claudeProj.appendingPathComponent("err429.jsonl"), atomically: true, encoding: .utf8)

        try """
        {"timestamp":"\(tRecent)","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"\(tRecent)","type":"event_msg","payload":{"type":"error","error":{"type":"rate_limit_error","status":429}}}
        {"timestamp":"\(tRecent)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":100,"total_tokens":1100}}}}
        """.write(to: rollProse, atomically: true, encoding: .utf8)

        try execSQL(at: ocDir.appendingPathComponent("opencode.db"), sql: """
        INSERT INTO session_message VALUES ('m-err', 'ses-p', 'assistant', 2, \(recentMs), \(recentMs),
            '{"model":{"id":"deepseek-v4.1-flash"},"error":{"name":"APIError","data":{"statusCode":429,"type":"rate_limit_error"}},"time":{"created":\(recentMs)}}');
        """)

        try """
        {"sequence":3,"type":"action_result","payload":{"action_id":"a-429","state":"failed","result":{"error":{"code":"rate_limit_exceeded","status":429}}}}
        """.write(to: vibeJournal.appendingPathComponent("0000000000000002.jsonl"), atomically: true, encoding: .utf8)

        let snap429 = LocalTelemetryCollector.collectSnapshot(
            paths: .liveDefault(home: homeDir, workspaceRoot: wsDir),
            now: now,
            timeZone: utc
        )
        #expect(snap429.rateLimitHits24h == 4)
        let d14With429 = try #require(snap429.dailyBreakdown.first(where: { $0.dateString == "2026-11-14" }))
        #expect(d14With429.rateLimit429Count == 4)
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
