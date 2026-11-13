import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
public final class TelemetryMonitor: ObservableObject {
    @Published public private(set) var snapshot: TelemetrySnapshot
    @Published public private(set) var isRefreshing: Bool = false
    @Published public var labelMode: MenuBarLabelMode {
        didSet { UserDefaults.standard.set(labelMode.rawValue, forKey: "agentbar.labelMode") }
    }
    @Published public var refreshIntervalSeconds: Int {
        didSet {
            UserDefaults.standard.set(refreshIntervalSeconds, forKey: "agentbar.refreshSeconds")
            scheduleTimer()
        }
    }
    @Published public var workspacePath: String {
        didSet { UserDefaults.standard.set(workspacePath, forKey: "agentbar.workspacePath") }
    }

    private let isPreviewInstance: Bool
    private var timer: Timer?

    public init(previewSnapshot: TelemetrySnapshot? = nil) {
        let savedMode = UserDefaults.standard.string(forKey: "agentbar.labelMode")
            .flatMap(MenuBarLabelMode.init(rawValue:)) ?? .todayCost
        let savedRefresh = UserDefaults.standard.integer(forKey: "agentbar.refreshSeconds")
        let defaultWorkspace = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects").path
        let savedWorkspace = UserDefaults.standard.string(forKey: "agentbar.workspacePath") ?? defaultWorkspace

        self.labelMode = savedMode
        self.refreshIntervalSeconds = savedRefresh > 0 ? savedRefresh : 30
        self.workspacePath = savedWorkspace

        if let previewSnapshot {
            self.isPreviewInstance = true
            self.snapshot = previewSnapshot
        } else {
            self.isPreviewInstance = false
            self.snapshot = TelemetrySnapshot(
                capturedAt: Date(),
                vendorSummaries: AgentVendor.allCases.map {
                    VendorSummary(
                        vendor: $0,
                        sourceAvailable: false,
                        todayCostUSD: 0,
                        todayTokens: 0,
                        fiveHourTokens: 0,
                        fiveHourCostUSD: 0,
                        thirtyDayCostUSD: 0,
                        thirtyDayTokens: 0,
                        sessionCount30d: 0,
                        cacheHitRatio: 0,
                        activeModel: "—",
                        lastActive: nil,
                        rateLimitHits24h: 0
                    )
                },
                dailyBuckets: [],
                recentSessions: [],
                relayRuns: []
            )
            refreshNow()
            scheduleTimer()
        }
    }

    public var menuBarText: String? {
        switch labelMode {
        case .todayCost:
            return TelemetryFormatter.usd(snapshot.todayTotalCostUSD)
        case .fiveHourTokens:
            return TelemetryFormatter.compactTokens(snapshot.fiveHourTotalTokens)
        case .iconOnly:
            return nil
        }
    }

    public func refreshNow() {
        guard !isPreviewInstance, !isRefreshing else { return }
        isRefreshing = true
        let wsURL = URL(fileURLWithPath: workspacePath)
        Task.detached(priority: .utility) {
            var paths = CollectorPaths.liveDefault()
            paths.workspaceRootDir = wsURL
            let collected = LocalTelemetryCollector.collectSnapshot(paths: paths)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.snapshot = collected
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

    // MARK: - Deterministic Preview / Screenshot Fixture

    public static var preview: TelemetryMonitor {
        TelemetryMonitor(previewSnapshot: makePreviewSnapshot())
    }

    public static func makePreviewSnapshot() -> TelemetrySnapshot {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_794_560_400) // Fixed reference timestamp
        let startToday = cal.startOfDay(for: now)

        let summaries: [VendorSummary] = [
            VendorSummary(
                vendor: .claudeCode,
                sourceAvailable: true,
                todayCostUSD: 6.84,
                todayTokens: 1_420_000,
                fiveHourTokens: 910_000,
                fiveHourCostUSD: 4.18,
                thirtyDayCostUSD: 94.20,
                thirtyDayTokens: 28_400_000,
                sessionCount30d: 64,
                cacheHitRatio: 0.89,
                activeModel: "claude-opus-5-5",
                lastActive: now.addingTimeInterval(-420),
                rateLimitHits24h: 0
            ),
            VendorSummary(
                vendor: .codex,
                sourceAvailable: true,
                todayCostUSD: 3.12,
                todayTokens: 980_000,
                fiveHourTokens: 640_000,
                fiveHourCostUSD: 1.95,
                thirtyDayCostUSD: 46.50,
                thirtyDayTokens: 19_200_000,
                sessionCount30d: 41,
                cacheHitRatio: 0.74,
                activeModel: "gpt-6.1-codex",
                lastActive: now.addingTimeInterval(-1_380),
                rateLimitHits24h: 0
            ),
            VendorSummary(
                vendor: .openCode,
                sourceAvailable: true,
                todayCostUSD: 1.46,
                todayTokens: 2_310_000,
                fiveHourTokens: 1_480_000,
                fiveHourCostUSD: 0.88,
                thirtyDayCostUSD: 27.80,
                thirtyDayTokens: 48_900_000,
                sessionCount30d: 83,
                cacheHitRatio: 0.93,
                activeModel: "deepseek-v4.1-flash",
                lastActive: now.addingTimeInterval(-190),
                rateLimitHits24h: 0
            ),
            VendorSummary(
                vendor: .mistralVibe,
                sourceAvailable: true,
                todayCostUSD: 0.54,
                todayTokens: 1_190_000,
                fiveHourTokens: 820_000,
                fiveHourCostUSD: 0.36,
                thirtyDayCostUSD: 7.31,
                thirtyDayTokens: 16_400_000,
                sessionCount30d: 37,
                cacheHitRatio: 0.81,
                activeModel: "deepseek-v4-1-flash",
                lastActive: now.addingTimeInterval(-2_400),
                rateLimitHits24h: 0
            ),
            VendorSummary(
                vendor: .antigravity,
                sourceAvailable: true,
                todayCostUSD: 2.28,
                todayTokens: 1_060_000,
                fiveHourTokens: 590_000,
                fiveHourCostUSD: 1.24,
                thirtyDayCostUSD: 33.10,
                thirtyDayTokens: 18_700_000,
                sessionCount30d: 29,
                cacheHitRatio: 0.78,
                activeModel: "gemini-4-carbon-high",
                lastActive: now.addingTimeInterval(-95),
                rateLimitHits24h: 1
            )
        ]

        let dailyProfile: [(Double, Double, Double, Double, Double)] = [
            (4.2, 1.9, 1.1, 0.3, 1.4),
            (5.8, 2.4, 1.5, 0.4, 1.8),
            (3.1, 1.4, 0.9, 0.2, 1.1),
            (7.4, 3.2, 1.8, 0.6, 2.5),
            (6.2, 2.9, 2.1, 0.5, 2.0),
            (2.8, 1.1, 0.8, 0.2, 0.9),
            (4.9, 2.2, 1.3, 0.4, 1.7),
            (8.6, 3.8, 2.4, 0.8, 2.9),
            (6.5, 2.7, 1.9, 0.5, 2.1),
            (5.1, 2.0, 1.6, 0.4, 1.6),
            (7.9, 3.5, 2.2, 0.7, 2.6),
            (9.1, 4.1, 2.5, 0.9, 3.1),
            (6.0, 2.8, 1.7, 0.5, 1.9),
            (6.84, 3.12, 1.46, 0.54, 2.28)
        ]

        var buckets: [DailyVendorBucket] = []
        for (idx, tuple) in dailyProfile.enumerated() {
            let dayDate = cal.date(byAdding: .day, value: idx - 13, to: startToday) ?? startToday
            let costs = [tuple.0, tuple.1, tuple.2, tuple.3, tuple.4]
            for (vIdx, vendor) in AgentVendor.allCases.enumerated() {
                let c = costs[vIdx]
                buckets.append(
                    DailyVendorBucket(
                        date: dayDate,
                        vendor: vendor,
                        tokens: Int(c * 240_000),
                        costUSD: c,
                        sessions: max(1, Int(c * 1.5))
                    )
                )
            }
        }

        let relay = RelayRunSummary(
            projectName: "shader-pipeline",
            logPath: "~/Projects/shader-pipeline/.relay/LOG.md",
            updatedAt: now.addingTimeInterval(-300),
            steps: [
                RelayBatonStep(stepID: "01-claude", vendor: .claudeCode, status: "ok", durationSeconds: 48, timestampString: "2026-11-13 07:12", model: "claude-opus-5-5", costUSD: 0.42, tokens: 84_200),
                RelayBatonStep(stepID: "02-codex", vendor: .codex, status: "ok", durationSeconds: 63, timestampString: "2026-11-13 07:14", model: "gpt-6.1-codex", costUSD: 0.29, tokens: 112_400),
                RelayBatonStep(stepID: "03-vibe", vendor: .mistralVibe, status: "ok", durationSeconds: 27, timestampString: "2026-11-13 07:15", model: "deepseek-v4-1-flash", costUSD: 0.031, tokens: 96_800),
                RelayBatonStep(stepID: "04-agy", vendor: .antigravity, status: "ok", durationSeconds: 34, timestampString: "2026-11-13 07:16", model: "gemini-4-carbon-high", costUSD: 0.18, tokens: 71_500)
            ]
        )

        let sessions: [UsageSample] = [
            UsageSample(id: "s1", vendor: .antigravity, timestamp: now.addingTimeInterval(-95), sessionID: "agy-901", projectName: "AgentBar", model: "gemini-4-carbon-high", inputTokens: 82_000, outputTokens: 14_200, cacheReadTokens: 310_000, recordedCostUSD: 0.44),
            UsageSample(id: "s2", vendor: .openCode, timestamp: now.addingTimeInterval(-190), sessionID: "ses-441", projectName: "kernel-bench", model: "deepseek-v4.1-flash", inputTokens: 64_000, outputTokens: 19_800, cacheReadTokens: 780_000, recordedCostUSD: 0.21),
            UsageSample(id: "s3", vendor: .claudeCode, timestamp: now.addingTimeInterval(-420), sessionID: "cld-772", projectName: "shader-pipeline", model: "claude-opus-5-5", inputTokens: 48_000, outputTokens: 11_400, cacheReadTokens: 420_000, cacheWriteTokens: 22_000, recordedCostUSD: 2.64),
            UsageSample(id: "s4", vendor: .codex, timestamp: now.addingTimeInterval(-1380), sessionID: "cdx-118", projectName: "wasm-guard", model: "gpt-6.1-codex", inputTokens: 195_000, outputTokens: 28_400, cacheReadTokens: 260_000, recordedCostUSD: 0.96),
            UsageSample(id: "s5", vendor: .mistralVibe, timestamp: now.addingTimeInterval(-2400), sessionID: "vib-305", projectName: "shader-pipeline", model: "deepseek-v4-1-flash", inputTokens: 142_000, outputTokens: 34_100, cacheReadTokens: 410_000, recordedCostUSD: 0.089)
        ]

        return TelemetrySnapshot(
            capturedAt: now,
            vendorSummaries: summaries,
            dailyBuckets: buckets,
            recentSessions: sessions,
            relayRuns: [relay]
        )
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
        if let dashPNG = renderPNG(view: dashView, size: CGSize(width: 980, height: 675)) {
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
        .frame(width: 428, height: 524)
        .background(Color(red: 0.055, green: 0.050, blue: 0.046))
        if let popPNG = renderPNG(view: popView, size: CGSize(width: 428, height: 524)) {
            try popPNG.write(to: directory.appendingPathComponent("screenshot-menubar\(suffix).png"))
        }
    }
}
