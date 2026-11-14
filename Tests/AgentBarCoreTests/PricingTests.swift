import Foundation
import Testing
@testable import AgentBarCore

@Suite("Pricing Scoped Tests", .timeLimit(.minutes(1)))
struct PricingTests {

    @Test("Does not silently price unrecognized or substring-colliding models")
    func unrecognizedModelsAreNotSilentlyPriced() {
        let now = Date(timeIntervalSince1970: 1_794_600_000)
        let sUnknown = UsageSample(
            id: "u1",
            vendor: .claudeCode,
            timestamp: now,
            sessionID: "sess-u1",
            projectName: "demo",
            model: "unknown-private-llm",
            inputTokens: 100_000,
            outputTokens: 10_000
        )
        let sProCollision = UsageSample(
            id: "u2",
            vendor: .openCode,
            timestamp: now,
            sessionID: "sess-u2",
            projectName: "demo",
            model: "my-pro-tool",
            inputTokens: 100_000,
            outputTokens: 10_000
        )
        let sFable = UsageSample(
            id: "u3",
            vendor: .claudeCode,
            timestamp: now,
            sessionID: "sess-u3",
            projectName: "demo",
            model: "claude-fable-5-2",
            inputTokens: 100_000,
            outputTokens: 10_000
        )

        #expect(sUnknown.effectiveCostUSD == nil)
        #expect(sUnknown.unmatchedModelCount == 1)
        #expect(sProCollision.effectiveCostUSD == nil)
        #expect(sProCollision.unmatchedModelCount == 1)
        #expect(sFable.effectiveCostUSD == nil)
        #expect(sFable.unmatchedModelCount == 1)
    }

    @Test("Every PriceCatalog model row carries per-1M rates, official sourceURL, and honest unverified status")
    func pricingCatalog2026_11ExactArithmeticAndDisclaimer() throws {
        #expect(PriceCatalog.pricingVersion == "unverified")
        #expect(PriceCatalog.localizedPricingVersion(in: .en) == "unverified")
        #expect(PriceCatalog.localizedPricingVersion(in: .zhHans) == "未核对")

        let enDisclaimer = PriceCatalog.costDisclaimer(in: .en)
        let zhDisclaimer = PriceCatalog.costDisclaimer(in: .zhHans)
        #expect(enDisclaimer == "API-equivalent estimate (rates unverified; covers priced records only, unknown models excluded)")
        #expect(zhDisclaimer == "按 API 价折算（单价未核对；只含已计价记录，未知型号未计入）")
        #expect(!enDisclaimer.contains("2026-11"))
        #expect(!zhDisclaimer.contains("2026-11"))

        #expect(PriceCatalog.entries.count >= 25)
        for entry in PriceCatalog.entries {
            #expect(!entry.modelPrefix.isEmpty)
            #expect(entry.inputPerMillion > 0)
            #expect(entry.cachedInputPerMillion >= 0)
            #expect(entry.cacheWritePerMillion >= 0)
            #expect(entry.outputPerMillion > 0)
            #expect(entry.sourceURL.hasPrefix("https://"))
            #expect(entry.verifiedAt == "unverified")
            #expect(entry.localizedVerifiedAt(in: .en) == "unverified")
            #expect(entry.localizedVerifiedAt(in: .zhHans) == "未核对")
        }

        // Claude Opus: $15 in, $75 out, $1.50 cache read, $18.75 cache write per 1M
        let opusRates = try #require(PriceCatalog.rates(for: "claude-opus-5-5"))
        #expect(opusRates.sourceURL == "https://docs.anthropic.com/en/docs/about-claude/pricing")
        #expect(opusRates.verifiedAt == "unverified")
        let opusCost = try #require(PriceCatalog.estimateUSD(
            model: "claude-opus-5-5",
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheWrite: 1_000_000
        ))
        #expect(abs(opusCost - (15.0 + 75.0 + 1.50 + 18.75)) < 0.000_001)

        // OpenAI GPT-6 / Codex: $2.00 in, $8.00 out, $0.50 cache read, $2.00 cache write per 1M
        let gptRates = try #require(PriceCatalog.rates(for: "openai/gpt-6.1-sol"))
        #expect(gptRates.sourceURL == "https://platform.openai.com/docs/pricing")
        let gptCost = try #require(PriceCatalog.estimateUSD(
            model: "openai/gpt-6.1-sol",
            input: 500_000,
            output: 250_000,
            cacheRead: 2_000_000,
            cacheWrite: 0
        ))
        #expect(abs(gptCost - (1.0 + 2.0 + 1.0)) < 0.000_001)

        // Gemini 4 Carbon relay label normalization
        let geminiRates = try #require(PriceCatalog.rates(for: "Gemini 4 Carbon (High) (asked for gemini-4-carbon-high)"))
        #expect(geminiRates.sourceURL == "https://ai.google.dev/gemini-api/docs/pricing")
        let geminiCost = try #require(PriceCatalog.estimateUSD(
            model: "Gemini 4 Carbon (High) (asked for gemini-4-carbon-high)",
            input: 1_000_000,
            output: 200_000,
            cacheRead: 0,
            cacheWrite: 0
        ))
        #expect(abs(geminiCost - (1.25 + 1.0)) < 0.000_001)
    }

    @Test("Counts priced N and excluded unknown-model M separately and formats explicit bilingual cost coverage notes")
    func unknownModelRecordCountAggregatedSeparatelyInWindows() throws {
        let now = Date(timeIntervalSince1970: 1_794_600_000)
        // Priced Sonnet turn: 1M input ($3.00) + 100k output ($1.50) = $4.50
        let priced = UsageSample(
            id: "p1", vendor: .claudeCode, timestamp: now.addingTimeInterval(-120),
            sessionID: "s1", projectName: "repo", model: "claude-sonnet-5-5",
            inputTokens: 1_000_000, outputTokens: 100_000
        )
        let unpriced1 = UsageSample(
            id: "u1", vendor: .claudeCode, timestamp: now.addingTimeInterval(-90),
            sessionID: "s1", projectName: "repo", model: "claude-fable-5-1",
            inputTokens: 500_000, outputTokens: 50_000
        )
        let unpriced2 = UsageSample(
            id: "u2", vendor: .claudeCode, timestamp: now.addingTimeInterval(-60),
            sessionID: "s2", projectName: "repo", model: "local-qwen-coder",
            inputTokens: 200_000, outputTokens: 20_000
        )

        let snap = LocalTelemetryCollector.buildSnapshot(
            samples: [priced, unpriced1, unpriced2],
            relayRuns: [],
            availability: [.claudeCode: true],
            now: now
        )
        let claude = try #require(snap.vendorSummaries.first(where: { $0.vendor == .claudeCode }))
        let w30 = claude.metrics(for: .thirtyDays)
        #expect(w30.recordCount == 3)
        #expect(w30.pricedRecordCount == 1)
        #expect(w30.unknownModelRecordCount == 2)
        let est = try #require(w30.estimatedCostUSD)
        #expect(abs(est - 4.50) < 0.000_001)
        #expect(w30.costNote(in: .zhHans) == "只含已计价的 1 条，另有 2 条未知型号未计入")
        #expect(w30.costNote(in: .en) == "Covers 1 priced records only; 2 unknown-model records excluded")
        #expect(snap.thirtyDayCostNote(in: .zhHans) == "只含已计价的 1 条，另有 2 条未知型号未计入")
        #expect(snap.thirtyDayCostNote(in: .en) == "Covers 1 priced records only; 2 unknown-model records excluded")

        // Also test M == 0 case (2 priced records, 0 unknown models)
        let priced2 = UsageSample(
            id: "p2", vendor: .claudeCode, timestamp: now.addingTimeInterval(-30),
            sessionID: "s3", projectName: "repo", model: "claude-haiku-4",
            inputTokens: 1_000_000, outputTokens: 0
        )
        let snapAllPriced = LocalTelemetryCollector.buildSnapshot(
            samples: [priced, priced2],
            relayRuns: [],
            availability: [.claudeCode: true],
            now: now
        )
        let wAllPriced = try #require(snapAllPriced.vendorSummaries.first(where: { $0.vendor == .claudeCode }))
            .metrics(for: .thirtyDays)
        #expect(wAllPriced.pricedRecordCount == 2)
        #expect(wAllPriced.unknownModelRecordCount == 0)
        #expect(wAllPriced.costNote(in: .zhHans) == "含已计价的 2 条，0 条未知型号未计入")
        #expect(wAllPriced.costNote(in: .en) == "Covers 2 priced records only; 0 unknown-model records excluded")

        // Empty window has nil costNote
        let codexEmpty = try #require(snapAllPriced.vendorSummaries.first(where: { $0.vendor == .codex }))
            .metrics(for: .thirtyDays)
        #expect(codexEmpty.costNote(in: .zhHans) == nil)
        #expect(codexEmpty.costNote(in: .en) == nil)
    }
}
