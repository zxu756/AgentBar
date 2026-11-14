import Foundation
import Testing
@testable import AgentBarCore

@Suite("RelayLog Scoped Tests", .timeLimit(.minutes(1)))
struct RelayLogTests {

    @Test("Parses all 126 realistic .relay/LOG.md steps with zero dropped steps, zero bleed, and zero guessed vendors")
    func parses126StepsWithZeroBleedAndStrictHeadingVendors() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-relay126-\(UUID().uuidString)")
        let relayDir = tmp.appendingPathComponent("synth-pipeline/.relay")
        try FileManager.default.createDirectory(at: relayDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var expectedVendors: [AgentVendor?] = []
        var expectedTokens: [Int?] = []
        var expectedCosts: [Double?] = []
        var lines: [String] = ["# Agent Relay Log", ""]

        // Build 126 realistic steps mirroring real relay.sh output patterns:
        // - standard `<NN>-codex: ok, 403s, ...`
        // - conductor `<NN>-claude: ok, done in-session by the conductor, ...`
        // - comma-inside-parens `<NN>-agy: failed (exit 1: agy denied [{"action": "command", "display_name": "RunCommand"}]), 1378s, ...`
        // - deadline `<NN>-vibe: failed (exit 3: outcome deadline, stop_reason interrupted), 1771s, ...`
        // - timeout `<NN>-agy: timeout after 3000s, 3005s, ...`
        // - partial `<NN>-vibe: partial (the worker reported STATUS: partial), 103s, ...`
        // - `<NN>-verify: passed, 8s, ...` (including step 88-verify followed by 89-agy touching .claude/launch.json!)
        for idx in 1...126 {
            let num = String(format: "%02d", idx)
            let ts = String(format: "2026-11-11 %02d:%02d", (idx / 6) % 24, (idx * 7) % 60)

            if idx == 88 {
                lines.append("## 88-verify: passed, 9s, \(ts)")
                lines.append("")
                lines.append("- checks: unit suite and claude config schema")
                lines.append("- command: bash Scripts/verify.sh")
                lines.append("- workspace: HEAD a1b2c3d, tree digest 0123456789abcdef")
                lines.append("- output (last 15 lines of .relay/88-verify.log):")
                lines.append("")
                lines.append("> ok")
                lines.append("")
                expectedVendors.append(nil)
                expectedTokens.append(nil)
                expectedCosts.append(nil)
            } else if idx == 89 {
                let tok = 1_896_247
                lines.append(#"## 89-agy: failed (exit 1: agy denied [{"action": "command", "display_name": "RunCommand"}]), 1378s, \#(ts)"#)
                lines.append("")
                lines.append("- prompt: .relay/89-agy.prompt.md, log: .relay/89-agy.log")
                lines.append("- agy: model Gemini 4 Carbon (High) (asked for gemini-4-carbon-high), tokens 1,896,247")
                lines.append("- files changed:")
                lines.append("  - .claude/launch.json")
                lines.append("- final message:")
                lines.append("")
                lines.append("> (empty; see the log)")
                lines.append("")
                expectedVendors.append(.antigravity)
                expectedTokens.append(tok)
                expectedCosts.append(nil)
            } else if idx % 5 == 0 {
                lines.append("## \(num)-verify: passed, \(5 + (idx % 11))s, \(ts)")
                lines.append("")
                lines.append("- checks: check claude codex vibe agy keywords do not infer vendor")
                lines.append("- command: swift test")
                lines.append("")
                expectedVendors.append(nil)
                expectedTokens.append(nil)
                expectedCosts.append(nil)
            } else if idx % 5 == 1 {
                // Conductor in-session note (no `\d+s` duration!)
                lines.append("## \(num)-claude: ok, done in-session by the conductor, \(ts)")
                lines.append("")
                lines.append("> Coordinated step \(num)")
                lines.append("")
                expectedVendors.append(.claudeCode)
                expectedTokens.append(nil)
                expectedCosts.append(nil)
            } else if idx % 5 == 2 {
                let tok = 40_000 + idx * 100
                lines.append("## \(num)-codex: ok, \(120 + idx)s, \(ts)")
                lines.append("")
                lines.append("- prompt: .relay/\(num)-codex.prompt.md, log: .relay/\(num)-codex.log")
                lines.append("- codex: tokens \(tok), session sess-\(num)")
                lines.append("- files changed:")
                lines.append("  - src/module_\(num).swift")
                lines.append("")
                expectedVendors.append(.codex)
                expectedTokens.append(tok)
                expectedCosts.append(nil)
            } else if idx % 5 == 3 {
                let cost = Double(idx) * 0.0125
                let costStr = String(format: "%.4f", cost)
                let status = (idx % 2 == 0)
                    ? "failed (exit 3: outcome deadline, stop_reason interrupted)"
                    : "partial (the worker reported STATUS: partial)"
                lines.append("## \(num)-vibe: \(status), \(300 + idx)s, \(ts)")
                lines.append("")
                lines.append("- prompt: .relay/\(num)-vibe.prompt.md, log: .relay/\(num)-vibe.log")
                lines.append("- vibe: model deepseek-v4-1-flash-1017, cost $\(costStr), outcome finished; messages and export.json in .relay/\(num)-vibe.vibe/")
                lines.append("")
                expectedVendors.append(.mistralVibe)
                expectedTokens.append(nil)
                expectedCosts.append(Double(costStr)!)
            } else {
                let tok = 250_000 + idx * 1_000
                let status = (idx % 3 == 0) ? "timeout after 1800s" : "ok"
                lines.append("## \(num)-agy: \(status), \(400 + idx)s, \(ts)")
                lines.append("")
                lines.append("- prompt: .relay/\(num)-agy.prompt.md, log: .relay/\(num)-agy.log")
                lines.append("- agy: tokens \(tok)")
                lines.append("")
                expectedVendors.append(.antigravity)
                expectedTokens.append(tok)
                expectedCosts.append(nil)
            }
        }

        // Also append an unrecognized section heading at the end containing `- cost $999.00, tokens 9,999,999`
        // to ensure unrecognized headings immediately terminate step 126 without bleeding!
        lines.append("## Appendix Manual Notes")
        lines.append("- vibe: cost $999.00, tokens 9,999,999")

        let logURL = relayDir.appendingPathComponent("LOG.md")
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let summary = try #require(LocalTelemetryCollector.parseRelayLogFile(at: logURL))
        #expect(summary.steps.count == 126)
        guard summary.steps.count == 126 else { return }

        for i in 0..<126 {
            let step = summary.steps[i]
            #expect(step.vendor == expectedVendors[i], "Step \(i + 1) (\(step.stepID)) vendor mismatch")
            #expect(step.tokens == expectedTokens[i], "Step \(i + 1) (\(step.stepID)) tokens mismatch")
            switch (step.costUSD, expectedCosts[i]) {
            case (nil, nil):
                break
            case let (a?, b?):
                #expect(abs(a - b) < 0.000_001, "Step \(i + 1) (\(step.stepID)) cost mismatch")
            default:
                Issue.record("Step \(i + 1) (\(step.stepID)) cost nil mismatch: got \(String(describing: step.costUSD)), expected \(String(describing: expectedCosts[i]))")
            }
        }

        // Specifically verify step 88-verify was NEVER guessed as claude and step 89-agy kept its 1,896,247 tokens
        #expect(summary.steps[87].stepID == "88-verify")
        #expect(summary.steps[87].vendor == nil)
        #expect(summary.steps[87].tokens == nil)
        #expect(summary.steps[88].stepID == "89-agy")
        #expect(summary.steps[88].vendor == .antigravity)
        #expect(summary.steps[88].tokens == 1_896_247)

        // Verify Vibe & Antigravity relay samples never fabricate 0.8/0.2 input/output breakdowns
        let now = Date(timeIntervalSince1970: 1_794_600_000)
        let vibeSamples = LocalTelemetryCollector.collectVibeSamples(
            vibeDir: tmp.appendingPathComponent("empty-vibe"),
            relayRuns: [summary],
            since: now.addingTimeInterval(-30 * 86_400),
            now: now
        )
        #expect(!vibeSamples.isEmpty)
        #expect(vibeSamples.allSatisfy { !$0.hasTokenBreakdown && $0.knownTotalTokens == nil && $0.inputTokens == 0 && $0.outputTokens == 0 })

        let agyRes = LocalTelemetryCollector.collectAntigravitySamples(
            logDir: tmp.appendingPathComponent("empty-agy"),
            relayRuns: [summary],
            since: now.addingTimeInterval(-30 * 86_400),
            now: now
        )
        #expect(!agyRes.samples.isEmpty)
        #expect(agyRes.samples.allSatisfy { !$0.hasTokenBreakdown && $0.effectiveCostUSD == nil && $0.inputTokens == 0 && $0.outputTokens == 0 })
    }
}
