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
        let claudeProj = homeDir.appendingPathComponent(".claude/projects/-tmp-test-Projects-app")
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
        {"type":"assistant","timestamp":"2026-11-14T00:55:00Z","sessionId":"s1","requestId":"req_a","cwd":"/tmp/test/Projects/app","message":{"id":"msg_a","model":"claude-sonnet-5-5","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":3000,"cache_creation_input_tokens":1000}}}
        {"type":"assistant","timestamp":"2026-11-14T00:55:01Z","sessionId":"s1","requestId":"req_a","cwd":"/tmp/test/Projects/app","message":{"id":"msg_a","model":"claude-sonnet-5-5","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":3000,"cache_creation_input_tokens":1000}}}
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
        #expect(enRoot["pricingVersion"] as? String == "unverified")
        #expect(enRoot["costDisclaimer"] as? String == "API-equivalent estimate (rates unverified; covers priced records only, unknown models excluded)")
        #expect(enRoot["isDemoData"] as? Bool == false)

        let vendors = try #require(enRoot["vendors"] as? [String: Any])
        let requiredWindowKeys: Set<String> = [
            "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens",
            "totalTokens", "recordCount", "pricedRecordCount", "estimatedCostUSD",
            "unknownModelRecordCount", "unmatchedModelCount", "costNote",
            "cacheHitRate", "dataSource", "completeness", "completenessLabel",
            "hasRolloutMismatch", "rolloutMismatchCount", "mismatchNote"
        ]

        // Verify Claude 30d window
        let claudeObj = try #require(vendors["claude"] as? [String: Any])
        #expect(claudeObj["completeness"] as? String == "complete")
        let claudeWins = try #require(claudeObj["windows"] as? [String: Any])
        let claude30 = try #require(claudeWins["thirtyDays"] as? [String: Any])
        #expect(requiredWindowKeys.isSubset(of: Set(claude30.keys)))
        #expect(claude30["recordCount"] as? Int == 1)
        #expect(claude30["pricedRecordCount"] as? Int == 1)
        #expect(claude30["unmatchedModelCount"] as? Int == 0)
        #expect(claude30["costNote"] as? String == "Covers 1 priced records only; 0 unknown-model records excluded")
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
        #expect(codex30["costNote"] is NSNull)
        #expect(codex30["mismatchNote"] is NSNull)

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
        #expect(zhRoot["costDisclaimer"] as? String == "按 API 价折算（单价未核对；只含已计价记录，未知型号未计入）")
        let zhVendors = try #require(zhRoot["vendors"] as? [String: Any])
        #expect((zhVendors["claude"] as? [String: Any])?["completenessLabel"] as? String == "完整")
        #expect((zhVendors["codex"] as? [String: Any])?["completenessLabel"] as? String == "只有总量")
        #expect((zhVendors["vibe"] as? [String: Any])?["completenessLabel"] as? String == "只有接力里的部分")
        #expect((zhVendors["opencode"] as? [String: Any])?["completenessLabel"] as? String == "没有数据")
        #expect((zhVendors["vibe"] as? [String: Any])?["dataSource"] as? String == "~/.vibe/logs/session/unified/*/journal/*.jsonl + .relay/LOG.md")
        #expect((zhVendors["agy"] as? [String: Any])?["dataSource"] as? String == "~/Projects/*/.relay/LOG.md（cli-*.log 无 Token 统计）")
        #expect((zhVendors["opencode"] as? [String: Any])?["dataSource"] as? String == "~/.local/share/opencode/opencode.db（session_message 逐事件 + session_v2 兜底）")

        let humanEN = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--lang", "en",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(humanEN.exitCode == 0)
        #expect(humanEN.stdout.contains("API-equivalent estimate (rates unverified; covers priced records only, unknown models excluded)"))
        #expect(humanEN.stdout.contains("Total only"))
        #expect(humanEN.stdout.contains("Relay logs only"))
        #expect(humanEN.stdout.contains("No data"))
        #expect(!humanEN.stdout.contains(secretSentinel))

        let humanZH = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--lang", "zh",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(humanZH.exitCode == 0)
        #expect(humanZH.stdout.contains("按 API 价折算（单价未核对；只含已计价记录，未知型号未计入）"))
        #expect(humanZH.stdout.contains("只有总量"))
        #expect(humanZH.stdout.contains("只有接力里的部分"))
        #expect(humanZH.stdout.contains("没有数据"))
        #expect(humanZH.stdout.contains("journal/*.jsonl"))
        #expect(humanZH.stdout.contains("cli-*.log 无 Token 统计"))
        #expect(!humanZH.stdout.contains("lacks token stats"))
        #expect(!humanZH.stdout.contains(secretSentinel))

        let mtimeAfter = (try? FileManager.default.attributesOfItem(atPath: plistURL.path)[.modificationDate] as? Date)?.timeIntervalSince1970
        #expect(mtimeBefore == mtimeAfter)
    }

    @Test("Exits non-zero with stderr message when explicit --home or --workspace path does not exist or is not a directory")
    func nonexistentHomeOrWorkspaceExitsNonZeroWithError() throws {
        let missingPath = "/nonexistent_agentbar_path_\(UUID().uuidString)"
        let rMissingHomeEN = CLIRunner.execute(arguments: ["AgentBar", "--cli", "snapshot", "--lang", "en", "--home", missingPath])
        #expect(rMissingHomeEN.exitCode == 2)
        #expect(rMissingHomeEN.stdout.isEmpty)
        #expect(rMissingHomeEN.stderr.contains("--home"))
        #expect(rMissingHomeEN.stderr.contains(missingPath))

        let rMissingHomeZH = CLIRunner.execute(arguments: ["AgentBar", "--cli", "snapshot", "--lang", "zh", "--home", missingPath])
        #expect(rMissingHomeZH.exitCode == 2)
        #expect(rMissingHomeZH.stdout.isEmpty)
        #expect(rMissingHomeZH.stderr.contains("--home"))
        #expect(rMissingHomeZH.stderr.contains("不存在"))

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-b16-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rMissingWS = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--lang", "en",
            "--home", tmp.path, "--workspace", missingPath
        ])
        #expect(rMissingWS.exitCode == 2)
        #expect(rMissingWS.stdout.isEmpty)
        #expect(rMissingWS.stderr.contains("--workspace"))

        // Passing a regular file instead of a directory must also fail with exit code 2
        let regularFile = tmp.appendingPathComponent("not-a-dir.txt")
        try "hello".write(to: regularFile, atomically: true, encoding: .utf8)
        let rFileAsHome = CLIRunner.execute(arguments: ["AgentBar", "--cli", "snapshot", "--home", regularFile.path])
        #expect(rFileAsHome.exitCode == 2)
        #expect(!rFileAsHome.stderr.isEmpty)

        // Existing empty directory still exits 0 and shows No data / 没有数据
        let rEmptyDir = CLIRunner.execute(arguments: ["AgentBar", "--cli", "snapshot", "--lang", "zh", "--home", tmp.path, "--workspace", tmp.path])
        #expect(rEmptyDir.exitCode == 0)
        #expect(rEmptyDir.stdout.contains("没有数据"))
    }

    @Test("Formats explicit priced N vs excluded unknown-model M beside cost and surfaces Codex rollout mismatch in EN/ZH CLI")
    func costCoverageNoteAndCodexMismatchInCLI() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-b14-b15-\(UUID().uuidString)")
        let homeDir = tmp.appendingPathComponent("home")
        let wsDir = tmp.appendingPathComponent("ws")
        let claudeProj = homeDir.appendingPathComponent(".claude/projects/-tmp-app")
        let codexDir = homeDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: claudeProj, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 1 priced Sonnet turn ($4.50) + 2 unknown-model turns
        let claudeJSONL = """
        {"type":"assistant","timestamp":"2026-11-14T00:50:00Z","sessionId":"s-mix","requestId":"r1","cwd":"/tmp/app","message":{"id":"m1","model":"claude-sonnet-5-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"type":"assistant","timestamp":"2026-11-14T00:51:00Z","sessionId":"s-mix","requestId":"r2","cwd":"/tmp/app","message":{"id":"m2","model":"claude-fable-5-1","usage":{"input_tokens":500000,"output_tokens":50000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"type":"assistant","timestamp":"2026-11-14T00:52:00Z","sessionId":"s-mix","requestId":"r3","cwd":"/tmp/app","message":{"id":"m3","model":"custom-local-llm","usage":{"input_tokens":200000,"output_tokens":20000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
        try claudeJSONL.write(to: claudeProj.appendingPathComponent("mix.jsonl"), atomically: true, encoding: .utf8)

        // Codex mismatch: sqlite tokens_used = 50000, rollout total = 12000
        let rolloutURL = codexDir.appendingPathComponent("rollout-mis.jsonl")
        let rolloutJSONL = """
        {"timestamp":"2026-11-14T00:40:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-14T00:42:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":8000,"cache_write_input_tokens":0,"output_tokens":2000,"total_tokens":12000}}}}
        """
        try rolloutJSONL.write(to: rolloutURL, atomically: true, encoding: .utf8)
        let codexDB = codexDir.appendingPathComponent("state_5.sqlite")
        try execSQL(at: codexDB, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT);
        INSERT INTO threads VALUES ('th-mis', '/tmp/app', 50000, 1794617000, 'gpt-6.1-sol', '\(rolloutURL.path)');
        """)

        let nowStr = "2026-11-14T01:00:00Z"

        let zhHuman = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--lang", "zh",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(zhHuman.exitCode == 0)
        #expect(zhHuman.stdout.contains("$4.50（只含已计价的 1 条，另有 2 条未知型号未计入）"))
        #expect(zhHuman.stdout.contains("[Codex CLI] (总量不一致)"))
        #expect(zhHuman.stdout.contains("rollout=12000 vs sqlite=50000"))
        #expect(!zhHuman.stdout.contains("lacks token stats"))

        let enHuman = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--lang", "en",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(enHuman.exitCode == 0)
        #expect(enHuman.stdout.contains("$4.50 (Covers 1 priced records only; 2 unknown-model records excluded)"))
        #expect(enHuman.stdout.contains("[Codex CLI] (Total mismatch)"))
        #expect(enHuman.stdout.contains("rollout=12000 vs sqlite=50000"))

        let zhJSONRes = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--json", "--lang", "zh",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        let zhObj = try #require(try JSONSerialization.jsonObject(with: Data(zhJSONRes.stdout.utf8)) as? [String: Any])
        let zhVendors = try #require(zhObj["vendors"] as? [String: Any])
        let claude30 = try #require(((zhVendors["claude"] as? [String: Any])?["windows"] as? [String: Any])?["thirtyDays"] as? [String: Any])
        #expect(claude30["pricedRecordCount"] as? Int == 1)
        #expect(claude30["unmatchedModelCount"] as? Int == 2)
        #expect(claude30["costNote"] as? String == "只含已计价的 1 条，另有 2 条未知型号未计入")

        let codexVendor = try #require(zhVendors["codex"] as? [String: Any])
        #expect(codexVendor["completeness"] as? String == "mismatch")
        #expect(codexVendor["completeness"] as? String != "complete")
        #expect(codexVendor["completenessLabel"] as? String == "总量不一致")
        let codex30 = try #require((codexVendor["windows"] as? [String: Any])?["thirtyDays"] as? [String: Any])
        #expect(codex30["hasRolloutMismatch"] as? Bool == true)
        #expect(codex30["rolloutMismatchCount"] as? Int == 1)
        #expect((codex30["mismatchNote"] as? String)?.contains("rollout=12000 vs sqlite=50000") == true)
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
        #expect(!rDemoZH.stdout.contains("lacks token stats"))
    }

    @Test("M1 Part 2: Exposes 14-day dailyBreakdown in --cli snapshot and --cli daily with per-day B14 pricing counts, B15 Codex mismatch, B7 429s, and --tz UTC")
    func dailyBreakdownCarriesPerDayB14PricingAndB15Mismatch() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-m1-cli-daily-\(UUID().uuidString)")
        let homeDir = tmp.appendingPathComponent("home")
        let wsDir = tmp.appendingPathComponent("ws")
        let claudeProj = homeDir.appendingPathComponent(".claude/projects/-tmp-daily")
        let codexDir = homeDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: claudeProj, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Day 2026-11-13: 1 priced Sonnet turn ($4.50) + 2 unknown-model turns; 0 rate limits, 0 Codex mismatch
        try """
        {"type":"assistant","timestamp":"2026-11-13T10:00:00Z","sessionId":"sd1","requestId":"r1","cwd":"/tmp/app","message":{"id":"m1","model":"claude-sonnet-5-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"type":"assistant","timestamp":"2026-11-13T10:05:00Z","sessionId":"sd1","requestId":"r2","cwd":"/tmp/app","message":{"id":"m2","model":"claude-fable-5-1","usage":{"input_tokens":50000,"output_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"type":"assistant","timestamp":"2026-11-13T10:10:00Z","sessionId":"sd1","requestId":"r3","cwd":"/tmp/app","message":{"id":"m3","model":"custom-local-llm","usage":{"input_tokens":50000,"output_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"2026-11-14T08:30:00Z","sessionId":"sd2","requestId":"r429"}
        """.write(to: claudeProj.appendingPathComponent("daily.jsonl"), atomically: true, encoding: .utf8)

        // Day 2026-11-14: Codex rollout mismatch (12,000 vs sqlite 50,000)
        let rolloutURL = codexDir.appendingPathComponent("rollout-d14.jsonl")
        try """
        {"timestamp":"2026-11-14T08:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-14T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":8000,"cache_write_input_tokens":0,"output_tokens":2000,"total_tokens":12000}}}}
        """.write(to: rolloutURL, atomically: true, encoding: .utf8)
        try execSQL(at: codexDir.appendingPathComponent("state_5.sqlite"), sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT);
        INSERT INTO threads VALUES ('th-d14', '/tmp/app', 50000, 1794645000, 'gpt-6.1-sol', '\(rolloutURL.path)');
        """)

        let nowStr = "2026-11-14T12:00:00Z"

        let snapEN = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--json", "--lang", "en", "--tz", "UTC",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(snapEN.exitCode == 0)
        let snapObj = try #require(try JSONSerialization.jsonObject(with: Data(snapEN.stdout.utf8)) as? [String: Any])
        let dailyArr = try #require(snapObj["dailyBreakdown"] as? [[String: Any]])
        #expect(dailyArr.count == 14)

        let d13 = try #require(dailyArr.first(where: { $0["date"] as? String == "2026-11-13" }))
        #expect(d13["pricedRecordCount"] as? Int == 1)
        #expect(d13["unmatchedModelCount"] as? Int == 2)
        #expect(d13["costNote"] as? String == "Covers 1 priced records only; 2 unknown-model records excluded")
        #expect(d13["hasCodexRolloutMismatch"] as? Bool == false)
        #expect(d13["codexMismatchNote"] is NSNull)
        #expect(d13["rateLimit429Count"] as? Int == 0)

        let d14 = try #require(dailyArr.first(where: { $0["date"] as? String == "2026-11-14" }))
        #expect(d14["pricedRecordCount"] as? Int == 1)
        #expect(d14["unmatchedModelCount"] as? Int == 0)
        #expect(d14["hasCodexRolloutMismatch"] as? Bool == true)
        #expect((d14["codexMismatchNote"] as? String)?.contains("th-d14: rollout=12000 vs sqlite=50000") == true)
        #expect(d14["rateLimit429Count"] as? Int == 1)

        // Verify `--cli daily --json --lang zh --tz UTC` and human-readable `--cli daily`
        let dailyZH = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "daily", "--json", "--lang", "zh", "--tz", "UTC",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(dailyZH.exitCode == 0)
        let dailyZHObj = try #require(try JSONSerialization.jsonObject(with: Data(dailyZH.stdout.utf8)) as? [String: Any])
        let zhDays = try #require(dailyZHObj["dailyBreakdown"] as? [[String: Any]])
        let zhD13 = try #require(zhDays.first(where: { $0["date"] as? String == "2026-11-13" }))
        #expect(zhD13["costNote"] as? String == "只含已计价的 1 条，另有 2 条未知型号未计入")
        let zhD14 = try #require(zhDays.first(where: { $0["date"] as? String == "2026-11-14" }))
        #expect((zhD14["codexMismatchNote"] as? String)?.contains("th-d14: rollout=12000 vs sqlite=50000") == true)

        let dailyHumanZH = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "daily", "--lang", "zh", "--tz", "UTC",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(dailyHumanZH.exitCode == 0)
        #expect(dailyHumanZH.stdout.contains("2026-11-13"))
        #expect(dailyHumanZH.stdout.contains("只含已计价的 1 条，另有 2 条未知型号未计入"))
        #expect(dailyHumanZH.stdout.contains("2026-11-14"))
        #expect(dailyHumanZH.stdout.contains("th-d14: rollout=12000 vs sqlite=50000"))
        #expect(!dailyHumanZH.stdout.contains("没有时间 |"))
    }

    @Test("M1 BR1: CLI --json and EN/ZH text surface untimestamped ('No timestamp' / '没有时间') separately from all windows and dated rows")
    func cliSurfacesUntimestampedBucketInJSONAndBilingualText() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-cli-br1-\(UUID().uuidString)")
        let homeDir = tmp.appendingPathComponent("home")
        let wsDir = tmp.appendingPathComponent("ws")
        let claudeProj = homeDir.appendingPathComponent(".claude/projects/-tmp-br1")
        let codexDir = homeDir.appendingPathComponent(".codex")
        let ocDir = homeDir.appendingPathComponent(".local/share/opencode")
        let vibeJournal = homeDir.appendingPathComponent(".vibe/logs/session/unified/s-vibe-br1/journal")
        let relayDir = wsDir.appendingPathComponent("pipe/.relay")

        for d in [claudeProj, codexDir, ocDir, vibeJournal, relayDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Claude: 1 missing timestamp (1000 tok) + 1 malformed timestamp (1310 tok) = 2310 untimestamped; 0 dated
        try """
        {"type":"assistant","sessionId":"sc1","requestId":"r1","cwd":"/tmp/br1","message":{"id":"m1","model":"claude-sonnet-4-6","usage":{"input_tokens":800,"output_tokens":200}}}
        {"type":"assistant","timestamp":"not-a-date","sessionId":"sc1","requestId":"r2","cwd":"/tmp/br1","message":{"id":"m2","model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":310}}}
        """.write(to: claudeProj.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        // Codex: rollout event missing timestamp (1100 tok; thread updated_at = 2026-11-14T12:00:00Z = 1794657600)
        let rolloutURL = codexDir.appendingPathComponent("rollout-br1.jsonl")
        try """
        {"type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":100,"total_tokens":1100}}}}
        """.write(to: rolloutURL, atomically: true, encoding: .utf8)
        try execSQL(at: codexDir.appendingPathComponent("state_5.sqlite"), sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT);
        INSERT INTO threads VALUES ('th-br1', '/tmp/br1', 1100, 1794657600, 'gpt-5.4', '\(rolloutURL.path)');
        """)

        // OpenCode: session_message missing timestamp (77 tok; session_v2.time_updated = 2026-11-13T12:00:00Z = 1794571200000)
        try execSQL(at: ocDir.appendingPathComponent("opencode.db"), sql: """
        CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER);
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT);
        INSERT INTO session_v2 VALUES ('oc-br1', '/tmp/br1', 0.01, 50, 27, 0, 0, 0, 'claude-sonnet-4-6', 1794571200000);
        INSERT INTO session_message VALUES ('m-br1', 'oc-br1', 'assistant', 1, 0, 0,
            '{"model":{"id":"claude-sonnet-4-6"},"tokens":{"input":50,"output":27,"reasoning":0,"cache":{"read":0,"write":0}}}');
        """)

        // Vibe: journal action_result without preceding timestamp (500 tok)
        try """
        {"session_id":"s-vibe-br1","start_time":"2026-11-12T12:00:00Z","config":{"active_model":"deepseek-v4"}}
        """.write(to: vibeJournal.deletingLastPathComponent().appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        try """
        {"sequence":1,"type":"action_result","payload":{"action_id":"a-br1","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":400,"cached_input_tokens":0,"cache_write_tokens":0,"output_tokens":100,"total_tokens":500}}}}}
        """.write(to: vibeJournal.appendingPathComponent("0000000000000001.jsonl"), atomically: true, encoding: .utf8)

        // Relay LOG.md: AGY step without timestamp (900 tok)
        try """
        # Agent Relay Log

        ## 01-agy: ok, 30s
        - agy: model gemini-2.5-pro, tokens 900, cost $0.0300
        """.write(to: relayDir.appendingPathComponent("LOG.md"), atomically: true, encoding: .utf8)

        let nowStr = "2026-11-15T12:00:00Z"

        let jsonEN = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--json", "--lang", "en", "--tz", "UTC",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(jsonEN.exitCode == 0)
        let rootEN = try #require(try JSONSerialization.jsonObject(with: Data(jsonEN.stdout.utf8)) as? [String: Any])
        let vendorsEN = try #require(rootEN["vendors"] as? [String: Any])

        let expectedUntimestamped: [String: (tok: Int, rec: Int)] = [
            "claude": (2_310, 2),
            "codex": (1_100, 1),
            "opencode": (77, 1),
            "vibe": (500, 1),
            "agy": (900, 1)
        ]
        for (vKey, exp) in expectedUntimestamped {
            let vObj = try #require(vendorsEN[vKey] as? [String: Any])
            let wins = try #require(vObj["windows"] as? [String: Any])
            for wKey in ["fiveHours", "today", "sevenDays", "thirtyDays"] {
                let wObj = try #require(wins[wKey] as? [String: Any])
                let wTok = (wObj["totalTokens"] as? Int) ?? 0
                #expect(wTok == 0, "\(vKey).windows.\(wKey) leaked \(wTok) tokens")
                #expect(wObj["recordCount"] as? Int == 0)
            }
            let uObj = try #require(vObj["untimestamped"] as? [String: Any])
            #expect(uObj["totalTokens"] as? Int == exp.tok)
            #expect(uObj["recordCount"] as? Int == exp.rec)
        }

        let dailyArr = try #require(rootEN["dailyBreakdown"] as? [[String: Any]])
        #expect(dailyArr.count == 14)
        for dRow in dailyArr {
            #expect(dRow["totalTokens"] as? Int == 0)
            #expect(dRow["recordCount"] as? Int == 0)
        }

        let topUntimestampedEN = try #require(rootEN["untimestamped"] as? [String: Any])
        #expect(topUntimestampedEN["date"] as? String == "No timestamp")
        // 2310 + 1100 + 77 + 500 + 900 = 4887 tokens across 6 records
        #expect(topUntimestampedEN["totalTokens"] as? Int == 4_887)
        #expect(topUntimestampedEN["recordCount"] as? Int == 6)

        let jsonZH = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "daily", "--json", "--lang", "zh", "--tz", "UTC",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(jsonZH.exitCode == 0)
        let rootZH = try #require(try JSONSerialization.jsonObject(with: Data(jsonZH.stdout.utf8)) as? [String: Any])
        let topUntimestampedZH = try #require(rootZH["untimestamped"] as? [String: Any])
        #expect(topUntimestampedZH["date"] as? String == "没有时间")
        #expect(topUntimestampedZH["totalTokens"] as? Int == 4_887)

        let snapTextZH = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--lang", "zh", "--tz", "UTC",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(snapTextZH.exitCode == 0)
        #expect(snapTextZH.stdout.contains("没有时间:"))

        let snapTextEN = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "snapshot", "--lang", "en", "--tz", "UTC",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(snapTextEN.exitCode == 0)
        #expect(snapTextEN.stdout.contains("No timestamp:"))

        let dailyTextZH = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "daily", "--lang", "zh", "--tz", "UTC",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(dailyTextZH.exitCode == 0)
        #expect(dailyTextZH.stdout.contains("没有时间 |"))

        let dailyTextEN = CLIRunner.execute(arguments: [
            "AgentBar", "--cli", "daily", "--lang", "en", "--tz", "UTC",
            "--home", homeDir.path, "--workspace", wsDir.path, "--now", nowStr
        ])
        #expect(dailyTextEN.exitCode == 0)
        #expect(dailyTextEN.stdout.contains("No timestamp |"))
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
