import Foundation
import SQLite3
import Testing
@testable import AgentBarCore

@Suite("CLI Scoped Tests", .timeLimit(.minutes(1)))
struct CLITests {

    @Test("Headless --cli snapshot --json outputs exact schema, explicit JSON nulls, and EN/ZH labels")
    func headlessSnapshotJSONBilingualAndNullHonesty() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-cli-\(UUID().uuidString)")
        let homeDir = tmp.appendingPathComponent("home")
        let wsDir = tmp.appendingPathComponent("workspace")
        let claudeProj = homeDir.appendingPathComponent(".claude/projects/-Users-test-Projects-app")
        let codexDir = homeDir.appendingPathComponent(".codex")
        let relayDir = wsDir.appendingPathComponent("pipe/.relay")

        try FileManager.default.createDirectory(at: claudeProj, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relayDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/local.xu.AgentBar.plist")
        let mtimeBefore = (try? FileManager.default.attributesOfItem(atPath: plistURL.path)[.modificationDate] as? Date)?.timeIntervalSince1970

        // Seed Claude turn (streaming 2 lines sharing msg_a + req_a) + user prompt sentinel that MUST NEVER leak
        let secretSentinel = "SUPER_SECRET_CONVERSATION_BODY_DO_NOT_LEAK_99182"
        let claudeJSONL = """
        {"type":"user","timestamp":"2026-11-14T00:50:00Z","sessionId":"s1","message":{"content":"\(secretSentinel)"}}
        {"type":"assistant","timestamp":"2026-11-14T00:55:00Z","sessionId":"s1","requestId":"req_a","cwd":"/Users/test/Projects/app","message":{"id":"msg_a","model":"claude-sonnet-5-5","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":3000,"cache_creation_input_tokens":1000}}}
        {"type":"assistant","timestamp":"2026-11-14T00:55:01Z","sessionId":"s1","requestId":"req_a","cwd":"/Users/test/Projects/app","message":{"id":"msg_a","model":"claude-sonnet-5-5","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":3000,"cache_creation_input_tokens":1000}}}
        """
        try claudeJSONL.write(to: claudeProj.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        // Seed Codex thread WITHOUT rollout file -> totalOnly
        let codexDB = codexDir.appendingPathComponent("state_5.sqlite")
        try execSQL(at: codexDB, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT);
        INSERT INTO threads VALUES ('th-only-total', '/tmp/app', 150000, 1794617000, 'gpt-6.1-sol', '/missing/rollout.jsonl');
        """)

        // Seed .relay/LOG.md with 1 Vibe step, 1 AGY step, 1 verify step
        let relayMD = """
        # Agent Relay Log

        ## 01-vibe: ok, 45s, 2026-11-14 00:40
        - vibe: model deepseek-v4-1-flash-1017, cost $0.1250

        ## 02-verify: passed, 4s, 2026-11-14 00:41
        - checks: claude codex vibe

        ## 03-agy: ok, 80s, 2026-11-14 00:42
        - agy: model gemini-4-carbon-high, tokens 420,000
        """
        try relayMD.write(to: relayDir.appendingPathComponent("LOG.md"), atomically: true, encoding: .utf8)

        let nowStr = "2026-11-14T01:00:00Z"

        // 1. Run English JSON snapshot
        let enRes = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--json", "--lang", "en",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(enRes.exitCode == 0)
        #expect(enRes.stderr.isEmpty)
        #expect(!enRes.stdout.contains(secretSentinel))

        let enData = try #require(enRes.stdout.data(using: .utf8))
        let enRoot = try #require(try JSONSerialization.jsonObject(with: enData) as? [String: Any])
        #expect(enRoot["pricingVersion"] as? String == "2026-11")
        #expect(enRoot["costDisclaimer"] as? String == "API-equivalent estimate (pricing 2026-11)")
        #expect(enRoot["isDemoData"] as? Bool == false)

        let vendors = try #require(enRoot["vendors"] as? [String: Any])
        let requiredWindowKeys: Set<String> = [
            "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens",
            "totalTokens", "recordCount", "estimatedCostUSD", "unknownModelRecordCount",
            "cacheHitRate", "dataSource", "completeness", "completenessLabel"
        ]

        // Verify Claude 30d window
        let claudeObj = try #require(vendors["claude"] as? [String: Any])
        #expect(claudeObj["completeness"] as? String == "complete")
        let claudeWins = try #require(claudeObj["windows"] as? [String: Any])
        let claude30 = try #require(claudeWins["thirtyDays"] as? [String: Any])
        #expect(requiredWindowKeys.isSubset(of: Set(claude30.keys)))
        #expect(claude30["recordCount"] as? Int == 1)
        #expect(claude30["inputTokens"] as? Int == 1_000)
        #expect(claude30["outputTokens"] as? Int == 500)
        #expect(claude30["cacheReadTokens"] as? Int == 3_000)
        #expect(claude30["cacheWriteTokens"] as? Int == 1_000)
        #expect(claude30["totalTokens"] as? Int == 5_500)
        let claudeHit = try #require(claude30["cacheHitRate"] as? Double)
        #expect(abs(claudeHit - 0.60) < 0.000_001)

        // Verify Codex missing-rollout window encodes explicit JSON nulls (NSNull)
        let codexObj = try #require(vendors["codex"] as? [String: Any])
        #expect(codexObj["completeness"] as? String == "totalOnly")
        #expect(codexObj["completenessLabel"] as? String == "Total only")
        let codexWins = try #require(codexObj["windows"] as? [String: Any])
        let codex30 = try #require(codexWins["thirtyDays"] as? [String: Any])
        #expect(codex30["totalTokens"] as? Int == 150_000)
        #expect(codex30["inputTokens"] is NSNull)
        #expect(codex30["outputTokens"] is NSNull)
        #expect(codex30["cacheReadTokens"] is NSNull)
        #expect(codex30["cacheWriteTokens"] is NSNull)
        #expect(codex30["estimatedCostUSD"] is NSNull)
        #expect(codex30["cacheHitRate"] is NSNull)

        // Verify Vibe & Antigravity completeness != "complete"
        let vibeObj = try #require(vendors["vibe"] as? [String: Any])
        let agyObj = try #require(vendors["agy"] as? [String: Any])
        let ocObj = try #require(vendors["opencode"] as? [String: Any])
        #expect(vibeObj["completeness"] as? String == "relayOnly")
        #expect(vibeObj["completeness"] as? String != "complete")
        #expect(agyObj["completeness"] as? String == "relayOnly")
        #expect(agyObj["completeness"] as? String != "complete")
        #expect(ocObj["completeness"] as? String == "noData")

        // 2. Run Chinese JSON & human-readable snapshots
        let zhRes = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--json", "--lang", "zh",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(zhRes.exitCode == 0)
        let zhData = try #require(zhRes.stdout.data(using: .utf8))
        let zhRoot = try #require(try JSONSerialization.jsonObject(with: zhData) as? [String: Any])
        #expect(zhRoot["costDisclaimer"] as? String == "按 API 价折算（价格表 2026-11）")
        let zhVendors = try #require(zhRoot["vendors"] as? [String: Any])
        #expect((zhVendors["claude"] as? [String: Any])?["completenessLabel"] as? String == "完整")
        #expect((zhVendors["codex"] as? [String: Any])?["completenessLabel"] as? String == "只有总量")
        #expect((zhVendors["vibe"] as? [String: Any])?["completenessLabel"] as? String == "只有接力里的部分")
        #expect((zhVendors["opencode"] as? [String: Any])?["completenessLabel"] as? String == "没有数据")

        let humanEN = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--lang", "en",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(humanEN.exitCode == 0)
        #expect(humanEN.stdout.contains("API-equivalent estimate (pricing 2026-11)"))
        #expect(humanEN.stdout.contains("Total only"))
        #expect(humanEN.stdout.contains("Relay logs only"))
        #expect(humanEN.stdout.contains("No data"))
        #expect(!humanEN.stdout.contains(secretSentinel))

        let humanZH = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--lang", "zh",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(humanZH.exitCode == 0)
        #expect(humanZH.stdout.contains("按 API 价折算（价格表 2026-11）"))
        #expect(humanZH.stdout.contains("只有总量"))
        #expect(humanZH.stdout.contains("只有接力里的部分"))
        #expect(humanZH.stdout.contains("没有数据"))
        #expect(!humanZH.stdout.contains(secretSentinel))

        let mtimeAfter = (try? FileManager.default.attributesOfItem(atPath: plistURL.path)[.modificationDate] as? Date)?.timeIntervalSince1970
        #expect(mtimeBefore == mtimeAfter)
    }

    @Test("Exits with code 2 on unknown subcommands, missing subcommand, or unknown flags; marks --demo explicitly")
    func errorExitCodesAndDemoMode() throws {
        let rUnknownSub = CLIRunner.execute(arguments: ["AgentBar", "--cli", "unknown-cmd"])
        #expect(rUnknownSub.exitCode == 2)
        #expect(!rUnknownSub.stderr.isEmpty)

        let rMissingSub = CLIRunner.execute(arguments: ["AgentBar", "--cli"])
        #expect(rMissingSub.exitCode == 2)

        let rUnknownFlag = CLIRunner.execute(arguments: ["AgentBar", "--cli", "snapshot", "--bogus-flag"])
        #expect(rUnknownFlag.exitCode == 2)

        let rBadLang = CLIRunner.execute(arguments: ["AgentBar", "--cli", "snapshot", "--lang", "de"])
        #expect(rBadLang.exitCode == 2)

        let rDemoEN = CLIRunner.execute(arguments: ["AgentBar", "--cli", "snapshot", "--demo", "--lang", "en"])
        #expect(rDemoEN.exitCode == 0)
        #expect(rDemoEN.stdout.contains("[DEMO]"))

        let rDemoZH = CLIRunner.execute(arguments: ["AgentBar", "--cli", "snapshot", "--demo", "--lang", "zh"])
        #expect(rDemoZH.exitCode == 0)
        #expect(rDemoZH.stdout.contains("[DEMO / 演示数据]"))
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
