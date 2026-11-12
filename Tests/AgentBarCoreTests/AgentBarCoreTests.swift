import Foundation
import SQLite3
import Testing
@testable import AgentBarCore

@Suite("AgentBarCore Telemetry & Collector Tests")
struct AgentBarCoreTests {

    @Test("Parses OpenCode JSON model string and plain fallback")
    func openCodeModelLabelParsing() {
        let jsonModel = #"{"id":"deepseek-v4.1-flash","providerID":"opencode-go","variant":"max"}"#
        #expect(LocalTelemetryCollector.parseOpenCodeModelLabel(jsonModel) == "deepseek-v4.1-flash")
        #expect(LocalTelemetryCollector.parseOpenCodeModelLabel("claude-opus-5-5") == "claude-opus-5-5")
    }

    @Test("Normalizes both epoch seconds and epoch milliseconds")
    func epochNormalization() {
        let secDate = LocalTelemetryCollector.normalizeEpoch(1_794_489_258)
        let msDate = LocalTelemetryCollector.normalizeEpoch(1_794_489_258_000)
        #expect(abs(secDate.timeIntervalSince(msDate)) < 0.001)
    }

    @Test("Reads Claude JSONL usage without reading prompt bodies")
    func claudeJSONLCollector() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-claude-\(UUID().uuidString)")
        let projDir = tmp.appendingPathComponent("-Users-alice-Projects-demo-app")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let nowISO = ISO8601DateFormatter().string(from: Date())
        let jsonl = """
        {"type":"user","timestamp":"\(nowISO)","sessionId":"s-1","message":{"content":"DO NOT READ SECRET PROMPT"}}
        {"type":"assistant","timestamp":"\(nowISO)","sessionId":"s-1","cwd":"/Users/alice/Projects/demo-app","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10000,"output_tokens":2000,"cache_read_input_tokens":90000,"cache_creation_input_tokens":0}}}
        """
        try jsonl.write(to: projDir.appendingPathComponent("s-1.jsonl"), atomically: true, encoding: .utf8)

        let res = LocalTelemetryCollector.collectClaudeSamples(dir: tmp, since: Date().addingTimeInterval(-3600))
        #expect(res.samples.count == 1)
        let sample = try #require(res.samples.first)
        #expect(sample.projectName == "demo-app")
        #expect(sample.model == "claude-opus-5-5")
        #expect(sample.totalTokens == 102_000)
        #expect(sample.effectiveCostUSD > 0.40)
    }

    @Test("Reads Codex & OpenCode SQLite databases in read-only mode")
    func sqliteCollectors() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let codexDB = tmp.appendingPathComponent("codex.sqlite")
        let openCodeDB = tmp.appendingPathComponent("opencode.sqlite")
        let nowSec = Int64(Date().timeIntervalSince1970)
        let nowMs = nowSec * 1000

        try execSQL(at: codexDB, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT);
        INSERT INTO threads VALUES ('th-1', '/tmp/engine', 200000, \(nowSec), 'gpt-6.1-codex');
        """)

        try execSQL(at: openCodeDB, sql: """
        CREATE TABLE session_v2 (
            id TEXT PRIMARY KEY, directory TEXT, cost REAL,
            tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
            tokens_cache_read INTEGER, tokens_cache_write INTEGER,
            model TEXT, time_updated INTEGER
        );
        INSERT INTO session_v2 VALUES (
            'oc-1', '/tmp/web', 0.42,
            50000, 12000, 3000, 150000, 0,
            '{"id":"deepseek-v4.1-flash"}', \(nowMs)
        );
        """)

        let codexSamples = LocalTelemetryCollector.collectCodexSamples(dbURL: codexDB, since: Date().addingTimeInterval(-3600))
        let ocSamples = LocalTelemetryCollector.collectOpenCodeSamples(dbURL: openCodeDB, since: Date().addingTimeInterval(-3600))

        #expect(codexSamples.count == 1)
        #expect(codexSamples.first?.totalTokens == 200_000)
        #expect(codexSamples.first?.projectName == "engine")

        #expect(ocSamples.count == 1)
        #expect(ocSamples.first?.model == "deepseek-v4.1-flash")
        #expect(ocSamples.first?.recordedCostUSD == 0.42)
        #expect(ocSamples.first?.outputTokens == 15_000)
    }

    @Test("Parses agent-relay .relay/LOG.md batons and costs")
    func relayLogParser() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-relay-\(UUID().uuidString)")
        let relayDir = tmp.appendingPathComponent("arcade/.relay")
        try FileManager.default.createDirectory(at: relayDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logContent = """
        # Agent Relay Log

        ## 01-claude: ok, 41s, 2026-11-13 06:10
        - claude: model claude-opus-5-5, cost $0.3800, session abc

        ## 02-vibe: ok, 24s, 2026-11-13 06:12
        - vibe: model deepseek-v4-1-flash-1017, cost $0.0250, tokens 64,200
        """
        let logFile = relayDir.appendingPathComponent("LOG.md")
        try logContent.write(to: logFile, atomically: true, encoding: .utf8)

        let runs = LocalTelemetryCollector.collectRelayRuns(workspaceRoot: tmp)
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.projectName == "arcade")
        #expect(run.steps.count == 2)
        #expect(abs(run.totalCostUSD - 0.405) < 0.0001)
        #expect(run.steps[1].tokens == 64_200)
    }

    @Test("Renders non-empty 2x Retina PNG screenshots via ImageRenderer")
    @MainActor
    func rendersRetinaScreenshots() throws {
        let monitor = TelemetryMonitor.preview
        let dashData = ScreenshotExporter.renderPNG(
            view: DashboardView(monitor: monitor),
            size: CGSize(width: 980, height: 640),
            scale: 2.0
        )
        let popData = ScreenshotExporter.renderPNG(
            view: MenuBarPopoverView(monitor: monitor, onOpenDashboard: {}, onOpenSettings: {}),
            size: CGSize(width: 388, height: 480),
            scale: 2.0
        )
        #expect((dashData?.count ?? 0) > 20_000)
        #expect((popData?.count ?? 0) > 10_000)
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
