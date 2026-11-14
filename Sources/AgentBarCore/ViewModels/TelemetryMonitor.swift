import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

public enum DemoSnapshotFactory {
    public static func makePreviewSnapshot() -> TelemetrySnapshot {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_794_560_400)
        let startToday = cal.startOfDay(for: now)

        func fullWindows(
            source: String,
            tok5h: Int, cost5h: Double,
            tokToday: Int, costToday: Double,
            tok7d: Int, cost7d: Double,
            tok30d: Int, cost30d: Double,
            rec30d: Int, hit: Double, unknownModels: Int = 0
        ) -> [TelemetryWindow: VendorWindowMetrics] {
            let cr30 = Int(Double(tok30d) * hit * 0.92)
            let out30 = max(1_000, Int(Double(tok30d) * 0.04))
            let inp30 = max(1_000, tok30d - cr30 - out30)
            let rec5h = max(1, rec30d / 12)
            let recToday = max(1, rec30d / 8)
            let rec7d = max(1, rec30d / 3)
            return [
                .fiveHours: VendorWindowMetrics(
                    inputTokens: max(0, tok5h / 10),
                    outputTokens: max(0, tok5h / 20),
                    cacheReadTokens: max(0, tok5h - (tok5h / 10) - (tok5h / 20)),
                    cacheWriteTokens: 0,
                    totalTokens: tok5h,
                    recordCount: rec5h,
                    pricedRecordCount: rec5h,
                    estimatedCostUSD: cost5h,
                    unknownModelRecordCount: 0,
                    cacheHitRate: hit,
                    dataSource: source,
                    completeness: .complete
                ),
                .today: VendorWindowMetrics(
                    inputTokens: max(0, tokToday / 10),
                    outputTokens: max(0, tokToday / 20),
                    cacheReadTokens: max(0, tokToday - (tokToday / 10) - (tokToday / 20)),
                    cacheWriteTokens: 0,
                    totalTokens: tokToday,
                    recordCount: recToday,
                    pricedRecordCount: recToday,
                    estimatedCostUSD: costToday,
                    unknownModelRecordCount: 0,
                    cacheHitRate: hit,
                    dataSource: source,
                    completeness: .complete
                ),
                .sevenDays: VendorWindowMetrics(
                    inputTokens: max(0, tok7d / 10),
                    outputTokens: max(0, tok7d / 20),
                    cacheReadTokens: max(0, tok7d - (tok7d / 10) - (tok7d / 20)),
                    cacheWriteTokens: 0,
                    totalTokens: tok7d,
                    recordCount: rec7d,
                    pricedRecordCount: max(0, rec7d - unknownModels),
                    estimatedCostUSD: cost7d,
                    unknownModelRecordCount: unknownModels,
                    cacheHitRate: hit,
                    dataSource: source,
                    completeness: .complete
                ),
                .thirtyDays: VendorWindowMetrics(
                    inputTokens: inp30,
                    outputTokens: out30,
                    cacheReadTokens: cr30,
                    cacheWriteTokens: 0,
                    totalTokens: tok30d,
                    recordCount: rec30d,
                    pricedRecordCount: max(0, rec30d - unknownModels),
                    estimatedCostUSD: cost30d,
                    unknownModelRecordCount: unknownModels,
                    cacheHitRate: hit,
                    dataSource: source,
                    completeness: .complete
                )
            ]
        }

        let claudeSource = LocalTelemetryCollector.defaultDataSourceDescription(for: .claudeCode)
        let codexSource = LocalTelemetryCollector.defaultDataSourceDescription(for: .codex)
        let openCodeSource = LocalTelemetryCollector.defaultDataSourceDescription(for: .openCode)
        let vibeSource = LocalTelemetryCollector.defaultDataSourceDescription(for: .mistralVibe)
        let agySource = LocalTelemetryCollector.defaultDataSourceDescription(for: .antigravity)

        let summaries: [VendorSummary] = [
            VendorSummary(
                vendor: .claudeCode,
                sourceAvailable: true,
                dataSource: claudeSource,
                completeness: .complete,
                windows: fullWindows(
                    source: claudeSource,
                    tok5h: 910_000, cost5h: 4.18,
                    tokToday: 1_420_000, costToday: 6.84,
                    tok7d: 9_600_000, cost7d: 31.40,
                    tok30d: 28_400_000, cost30d: 94.20,
                    rec30d: 186, hit: 0.94, unknownModels: 4
                ),
                sessionCount30d: 64,
                activeModel: "claude-opus-5-5",
                lastActive: now.addingTimeInterval(-420),
                rateLimitHits24h: 0
            ),
            VendorSummary(
                vendor: .codex,
                sourceAvailable: true,
                dataSource: codexSource,
                completeness: .complete,
                windows: fullWindows(
                    source: codexSource,
                    tok5h: 640_000, cost5h: 0.52,
                    tokToday: 980_000, costToday: 0.89,
                    tok7d: 6_800_000, cost7d: 5.40,
                    tok30d: 19_200_000, cost30d: 14.60,
                    rec30d: 41, hit: 0.97
                ),
                sessionCount30d: 41,
                activeModel: "gpt-6.1-sol",
                lastActive: now.addingTimeInterval(-1_380),
                rateLimitHits24h: 0
            ),
            VendorSummary(
                vendor: .openCode,
                sourceAvailable: true,
                dataSource: openCodeSource,
                completeness: .complete,
                windows: fullWindows(
                    source: openCodeSource,
                    tok5h: 1_480_000, cost5h: 0.34,
                    tokToday: 2_310_000, costToday: 0.56,
                    tok7d: 16_200_000, cost7d: 3.90,
                    tok30d: 48_900_000, cost30d: 11.80,
                    rec30d: 83, hit: 0.96
                ),
                sessionCount30d: 83,
                activeModel: "deepseek-v4.1-flash",
                lastActive: now.addingTimeInterval(-190),
                rateLimitHits24h: 0
            ),
            VendorSummary(
                vendor: .mistralVibe,
                sourceAvailable: true,
                dataSource: vibeSource,
                completeness: .complete,
                windows: fullWindows(
                    source: vibeSource,
                    tok5h: 520_000, cost5h: 0.14,
                    tokToday: 1_180_000, costToday: 0.31,
                    tok7d: 14_200_000, cost7d: 3.85,
                    tok30d: 20_400_000, cost30d: 5.50,
                    rec30d: 94, hit: 0.91, unknownModels: 3
                ),
                sessionCount30d: 21,
                activeModel: "deepseek-v4-1-flash-1017",
                lastActive: now.addingTimeInterval(-2_400),
                rateLimitHits24h: 0
            ),
            VendorSummary(
                vendor: .antigravity,
                sourceAvailable: true,
                dataSource: agySource,
                completeness: .relayOnly,
                windows: [
                    .fiveHours: VendorWindowMetrics(
                        inputTokens: nil, outputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil,
                        totalTokens: 392_854, recordCount: 1, estimatedCostUSD: nil, unknownModelRecordCount: 0,
                        cacheHitRate: nil, dataSource: agySource, completeness: .relayOnly
                    ),
                    .today: VendorWindowMetrics(
                        inputTokens: nil, outputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil,
                        totalTokens: 722_000, recordCount: 2, estimatedCostUSD: nil, unknownModelRecordCount: 0,
                        cacheHitRate: nil, dataSource: agySource, completeness: .relayOnly
                    ),
                    .sevenDays: VendorWindowMetrics(
                        inputTokens: nil, outputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil,
                        totalTokens: 11_230_126, recordCount: 14, estimatedCostUSD: nil, unknownModelRecordCount: 0,
                        cacheHitRate: nil, dataSource: agySource, completeness: .relayOnly
                    ),
                    .thirtyDays: VendorWindowMetrics(
                        inputTokens: nil, outputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil,
                        totalTokens: 11_230_126, recordCount: 14, estimatedCostUSD: nil, unknownModelRecordCount: 0,
                        cacheHitRate: nil, dataSource: agySource, completeness: .relayOnly
                    )
                ],
                sessionCount30d: 14,
                activeModel: "gemini-4-carbon-high",
                lastActive: now.addingTimeInterval(-95),
                rateLimitHits24h: 0
            )
        ]

        let dailyProfile: [(Double, Double, Double, Double, Double)] = [
            (4.2, 0.9, 0.5, 0.0, 0.0),
            (5.8, 1.2, 0.7, 0.4, 0.0),
            (3.1, 0.7, 0.4, 0.0, 0.0),
            (7.4, 1.5, 0.9, 0.8, 0.0),
            (6.2, 1.3, 0.8, 0.5, 0.0),
            (2.8, 0.5, 0.4, 0.0, 0.0),
            (4.9, 1.0, 0.6, 0.4, 0.0),
            (8.6, 1.8, 1.1, 1.2, 0.0),
            (6.5, 1.3, 0.8, 0.5, 0.0),
            (5.1, 0.9, 0.7, 0.0, 0.0),
            (7.9, 1.6, 1.0, 0.9, 0.0),
            (9.1, 1.9, 1.2, 0.5, 0.0),
            (6.0, 1.2, 0.8, 0.0, 0.0),
            (6.84, 0.89, 0.56, 0.31, 0.0)
        ]

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = cal
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)!
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var buckets: [DailyVendorBucket] = []
        var demoDailyBreakdown: [DailyLedgerDay] = []
        for (idx, tuple) in dailyProfile.enumerated() {
            let dayDate = cal.date(byAdding: .day, value: idx - 13, to: startToday) ?? startToday
            let costs = [tuple.0, tuple.1, tuple.2, tuple.3, tuple.4]
            var vMap: [AgentVendor: DailyVendorMetrics] = [:]
            var dTot = 0
            var dCost = 0.0
            var dRec = 0
            var dPriced = 0
            for (vIdx, vendor) in AgentVendor.allCases.enumerated() {
                let c = costs[vIdx]
                let tok = (vendor == .antigravity) ? (idx >= 10 ? 950_000 : 0) : Int(c * 240_000)
                let sess = tok > 0 || c > 0 ? max(1, Int(c * 1.5)) : 0
                buckets.append(
                    DailyVendorBucket(
                        date: dayDate,
                        vendor: vendor,
                        tokens: tok,
                        costUSD: c,
                        sessions: sess
                    )
                )
                let pricedCnt = (vendor != .antigravity && c > 0) ? sess : 0
                vMap[vendor] = DailyVendorMetrics(
                    uncachedInputTokens: vendor == .antigravity ? 0 : tok / 10,
                    cachedInputTokens: vendor == .antigravity ? 0 : (tok - tok / 10 - tok / 20),
                    cacheWriteTokens: 0,
                    outputTokens: vendor == .antigravity ? 0 : tok / 20,
                    totalTokens: tok,
                    recordCount: sess,
                    pricedRecordCount: pricedCnt,
                    unmatchedModelCount: 0,
                    estimatedCostUSD: c > 0 ? c : (sess == 0 ? 0.0 : nil),
                    completeness: sess == 0 ? .noData : (vendor == .antigravity ? .relayOnly : .complete)
                )
                dTot += tok
                dCost += c
                dRec += sess
                dPriced += pricedCnt
            }
            demoDailyBreakdown.append(
                DailyLedgerDay(
                    dateString: dayFormatter.string(from: dayDate),
                    dayStart: dayDate,
                    uncachedInputTokens: dTot / 10,
                    cachedInputTokens: dTot - dTot / 10 - dTot / 20,
                    cacheWriteTokens: 0,
                    outputTokens: dTot / 20,
                    totalTokens: dTot,
                    recordCount: dRec,
                    pricedRecordCount: dPriced,
                    unmatchedModelCount: 0,
                    estimatedCostUSD: dPriced > 0 ? dCost : 0.0,
                    vendors: vMap
                )
            )
        }

        let relay = RelayRunSummary(
            projectName: "shader-pipeline",
            logPath: "~/Projects/shader-pipeline/.relay/LOG.md",
            updatedAt: now.addingTimeInterval(-300),
            steps: [
                RelayBatonStep(stepID: "01-claude", vendor: .claudeCode, status: "ok", durationSeconds: 48, timestampString: "2026-11-13 07:12", model: "claude-opus-5-5", costUSD: 0.42, tokens: nil),
                RelayBatonStep(stepID: "02-codex", vendor: .codex, status: "ok", durationSeconds: 63, timestampString: "2026-11-13 07:14", model: "gpt-6.1-sol", costUSD: nil, tokens: 112_400),
                RelayBatonStep(stepID: "03-vibe", vendor: .mistralVibe, status: "ok", durationSeconds: 27, timestampString: "2026-11-13 07:15", model: "deepseek-v4-1-flash-1017", costUSD: 0.058, tokens: nil),
                RelayBatonStep(stepID: "04-verify", vendor: nil, status: "passed", durationSeconds: 9, timestampString: "2026-11-13 07:16", model: "default", costUSD: nil, tokens: nil)
            ]
        )

        let sessions: [UsageSample] = [
            UsageSample(unsplitID: "s1", vendor: .antigravity, origin: .relayLog, timestamp: now.addingTimeInterval(-95), sessionID: "agy-98", projectName: "shader-pipeline", model: "gemini-4-carbon-high", rawTotalTokens: 392_854, recordedCostUSD: nil),
            UsageSample(id: "s2", vendor: .openCode, timestamp: now.addingTimeInterval(-190), sessionID: "ses-441", projectName: "kernel-bench", model: "deepseek-v4.1-flash", inputTokens: 64_000, outputTokens: 19_800, cacheReadTokens: 780_000, recordedCostUSD: 0.21),
            UsageSample(id: "s3", vendor: .claudeCode, timestamp: now.addingTimeInterval(-420), sessionID: "cld-772", projectName: "shader-pipeline", model: "claude-opus-5-5", inputTokens: 48_000, outputTokens: 11_400, cacheReadTokens: 420_000, cacheWriteTokens: 22_000),
            UsageSample(id: "s4", vendor: .codex, timestamp: now.addingTimeInterval(-1380), sessionID: "cdx-118", projectName: "wasm-guard", model: "gpt-6.1-sol", inputTokens: 18_000, outputTokens: 3_400, cacheReadTokens: 460_000),
            UsageSample(id: "s5", vendor: .mistralVibe, timestamp: now.addingTimeInterval(-2400), sessionID: "vib-305", projectName: "shader-pipeline", model: "deepseek-v4-1-flash-1017", inputTokens: 28_000, outputTokens: 6_200, cacheReadTokens: 290_000)
        ]

        return TelemetrySnapshot(
            capturedAt: now,
            timeZoneIdentifier: "GMT",
            isDemoData: true,
            vendorSummaries: summaries,
            dailyBuckets: buckets,
            dailyBreakdown: demoDailyBreakdown,
            recentSessions: sessions,
            relayRuns: [relay]
        )
    }
}

@MainActor
public final class TelemetryMonitor: ObservableObject {
    @Published public private(set) var snapshot: TelemetrySnapshot
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var hasLoadedInitialSnapshot: Bool
    @Published public var labelMode: MenuBarLabelMode {
        didSet {
            guard !isPreviewInstance else { return }
            preferenceStore.set(labelMode.rawValue, forKey: "agentbar.labelMode")
        }
    }
    @Published public var refreshIntervalSeconds: Int {
        didSet {
            guard !isPreviewInstance else { return }
            preferenceStore.set(refreshIntervalSeconds, forKey: "agentbar.refreshSeconds")
            scheduleTimer()
        }
    }
    @Published public var workspacePath: String {
        didSet {
            guard !isPreviewInstance else { return }
            preferenceStore.set(workspacePath, forKey: "agentbar.workspacePath")
        }
    }

    private let isPreviewInstance: Bool
    private let preferenceStore: PreferenceStore
    private var timer: Timer?

    public init(
        previewSnapshot: TelemetrySnapshot? = nil,
        startImmediately: Bool = true,
        preferenceStore: PreferenceStore? = nil
    ) {
        let resolvedStore: PreferenceStore = preferenceStore ?? (previewSnapshot != nil ? InMemoryPreferenceStore() : UserDefaults.standard)
        self.preferenceStore = resolvedStore
        let savedMode = resolvedStore.string(forKey: "agentbar.labelMode")
            .flatMap(MenuBarLabelMode.init(rawValue:)) ?? .todayCost
        let savedRefresh = resolvedStore.integer(forKey: "agentbar.refreshSeconds")
        let defaultWorkspace = CollectorPaths.resolveDefaultHomeDirectory()
            .appendingPathComponent("Projects").path
        let savedWorkspace = resolvedStore.string(forKey: "agentbar.workspacePath") ?? defaultWorkspace

        self.labelMode = savedMode
        self.refreshIntervalSeconds = savedRefresh > 0 ? savedRefresh : 30
        self.workspacePath = savedWorkspace

        if let previewSnapshot {
            self.isPreviewInstance = true
            self.hasLoadedInitialSnapshot = true
            self.snapshot = previewSnapshot
        } else {
            self.isPreviewInstance = false
            self.hasLoadedInitialSnapshot = false
            self.snapshot = TelemetrySnapshot(
                capturedAt: Date(),
                isDemoData: false,
                vendorSummaries: AgentVendor.allCases.map { vendor in
                    let src = LocalTelemetryCollector.defaultDataSourceDescription(for: vendor)
                    return VendorSummary(
                        vendor: vendor,
                        sourceAvailable: false,
                        dataSource: src,
                        completeness: .noData,
                        windows: Dictionary(uniqueKeysWithValues: TelemetryWindow.allCases.map {
                            ($0, VendorWindowMetrics.empty(dataSource: src, completeness: .noData))
                        }),
                        sessionCount30d: 0,
                        activeModel: "—",
                        lastActive: nil,
                        rateLimitHits24h: 0
                    )
                },
                dailyBuckets: [],
                recentSessions: [],
                relayRuns: []
            )
            if startImmediately {
                refreshNow()
                scheduleTimer()
            }
        }
    }

    public var menuBarText: String? {
        if !hasLoadedInitialSnapshot {
            return labelMode == .iconOnly ? nil : "…"
        }
        switch labelMode {
        case .todayCost:
            if snapshot.activeVendorCount == 0 {
                return "—"
            }
            return TelemetryFormatter.usd(snapshot.todayTotalCostUSD)
        case .fiveHourTokens:
            if snapshot.activeVendorCount == 0 {
                return "—"
            }
            return TelemetryFormatter.compactTokens(snapshot.fiveHourTotalTokens)
        case .iconOnly:
            return nil
        }
    }

    public func statusSummaryLabel(in language: AppLanguage) -> String {
        if !hasLoadedInitialSnapshot {
            return language == .zhHans ? "刷新中…" : "Refreshing…"
        }
        if snapshot.activeVendorCount == 0 {
            return language == .zhHans ? "没有数据" : "No data"
        }
        return PriceCatalog.costDisclaimer(in: language)
    }

    public func refreshNow() {
        guard !isPreviewInstance, !isRefreshing else { return }
        isRefreshing = true
        let wsURL = URL(fileURLWithPath: workspacePath)
        Task.detached(priority: .utility) {
            let paths = CollectorPaths.liveDefault(workspaceRoot: wsURL)
            let collected = LocalTelemetryCollector.collectSnapshot(paths: paths)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.snapshot = collected
                self.hasLoadedInitialSnapshot = true
                self.isRefreshing = false
            }
        }
    }

    public var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            objectWillChange.send()
        } catch {
            // Non-fatal in unsigned dev runs
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard !isPreviewInstance else { return }
        let interval = TimeInterval(max(10, refreshIntervalSeconds))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
    }

    // MARK: - Deterministic Preview / Screenshot Fixture (Explicit Demo Mode Only)

    public static var preview: TelemetryMonitor {
        TelemetryMonitor(previewSnapshot: makePreviewSnapshot())
    }

    public static func makePreviewSnapshot() -> TelemetrySnapshot {
        DemoSnapshotFactory.makePreviewSnapshot()
    }
}

public enum ScreenshotExporter {
    @MainActor
    public static func renderPNG<V: View>(view: V, size: CGSize, scale: CGFloat = 2.0) -> Data? {
        let framed = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    public static func exportMarketingScreenshots(
        to directory: URL,
        language: AppLanguage = .en
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let monitor = TelemetryMonitor.preview
        let localizer = AppLocalizer(fixedLanguage: language)
        let suffix = (language == .zhHans) ? "-zh" : ""

        let dashView = DashboardView(monitor: monitor, localizer: localizer)
            .environment(\.locale, language.locale)
            .background(AgentBarPalette.canvas)
        if let dashPNG = renderPNG(view: dashView, size: CGSize(width: 1020, height: 748)) {
            try dashPNG.write(to: directory.appendingPathComponent("screenshot-dashboard\(suffix).png"))
        }

        let popView = MenuBarPopoverView(
            monitor: monitor,
            localizer: localizer,
            onOpenDashboard: {},
            onOpenSettings: {}
        )
        .environment(\.locale, language.locale)
        .background(AgentBarPalette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AgentBarPalette.rule, lineWidth: 1)
        )
        .padding(16)
        .frame(width: 440, height: 590)
        .background(Color(red: 0.055, green: 0.050, blue: 0.046))
        if let popPNG = renderPNG(view: popView, size: CGSize(width: 440, height: 590)) {
            try popPNG.write(to: directory.appendingPathComponent("screenshot-menubar\(suffix).png"))
        }
    }
}
