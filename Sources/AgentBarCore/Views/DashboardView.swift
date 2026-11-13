import Charts
import SwiftUI

public enum AgentBarPalette {
    public static let canvas = Color(red: 0.082, green: 0.076, blue: 0.070)       // Warm Carbon #151312
    public static let well = Color(red: 0.114, green: 0.106, blue: 0.098)         // Elevated Stone #1D1B19
    public static let raised = Color(red: 0.145, green: 0.135, blue: 0.125)       // Active Tab #252220
    public static let rule = Color(red: 0.205, green: 0.190, blue: 0.175)         // Hairline #34302C
    public static let ink = Color(red: 0.945, green: 0.928, blue: 0.898)          // Warm Bone #F1EDE5
    public static let muted = Color(red: 0.635, green: 0.605, blue: 0.568)        // Warm Taupe #A29A91
    public static let copper = Color(red: 0.88, green: 0.48, blue: 0.28)          // Burnished Copper Signal
    public static let jade = Color(red: 0.29, green: 0.62, blue: 0.51)            // Mineral Jade
}

public struct DashboardView: View {
    @ObservedObject public var monitor: TelemetryMonitor
    @ObservedObject public var localizer: AppLocalizer
    @State private var chartMetric: ChartMetric = .cost

    public enum ChartMetric: String, CaseIterable, Identifiable {
        case cost = "cost"
        case tokens = "tokens"
        public var id: String { rawValue }

        @MainActor
        public func localizedTitle(_ localizer: AppLocalizer) -> String {
            switch self {
            case .cost: return localizer.L("API-eq spend ($)", "API 等效开销 ($)")
            case .tokens: return localizer.L("Tokens", "Token 用量")
            }
        }
    }

    @MainActor
    public init(monitor: TelemetryMonitor, localizer: AppLocalizer? = nil) {
        self.monitor = monitor
        self.localizer = localizer ?? .shared
    }

    private var snap: TelemetrySnapshot { monitor.snapshot }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topMasthead
                .padding(.bottom, 16)

            Rectangle().fill(AgentBarPalette.rule).frame(height: 1)

            ledgerStatStrip
                .padding(.vertical, 16)

            Rectangle().fill(AgentBarPalette.rule).frame(height: 1)

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    dailyVelocitySection
                    Rectangle().fill(AgentBarPalette.rule).frame(height: 1)
                    recentSessionsSection
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                Rectangle()
                    .fill(AgentBarPalette.rule)
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 20) {
                    vendorBreakdownSection
                    Rectangle().fill(AgentBarPalette.rule).frame(height: 1)
                    relayInspectorSection
                }
                .frame(width: 332, alignment: .topLeading)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(minWidth: 960, minHeight: 640, alignment: .top)
        .background(AgentBarPalette.canvas)
        .environment(\.locale, localizer.language.locale)
        .preferredColorScheme(.dark)
    }

    private var topMasthead: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AgentBarPalette.ink)
                        .frame(width: 30, height: 30)
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AgentBarPalette.canvas)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("AgentBar")
                        .font(.system(size: 18, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(AgentBarPalette.ink)
                    Text(localizer.L(
                        "Local read-only multi-CLI token & spend ledger",
                        "本地只读 · 多智能体 CLI 用量与开销账本"
                    ))
                    .font(.system(size: 13))
                    .foregroundStyle(AgentBarPalette.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 2) {
                ForEach(ChartMetric.allCases) { m in
                    Button {
                        chartMetric = m
                    } label: {
                        Text(m.localizedTitle(localizer))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(chartMetric == m ? AgentBarPalette.ink : AgentBarPalette.muted)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .fixedSize(horizontal: true, vertical: false)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(chartMetric == m ? AgentBarPalette.raised : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(chartMetric == m ? AgentBarPalette.rule : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(AgentBarPalette.well)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)

            LanguageTogglePill(localizer: localizer)

            Button {
                monitor.refreshNow()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text(monitor.isRefreshing
                         ? localizer.L("Scanning…", "扫描中…")
                         : localizer.L("Refresh", "刷新"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(AgentBarPalette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .fixedSize(horizontal: true, vertical: false)
                .background(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AgentBarPalette.rule, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var ledgerStatStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            statCell(
                value: TelemetryFormatter.usd(snap.todayTotalCostUSD),
                label: localizer.L("Today's API-eq spend", "今日 API 等效开销"),
                detail: localizer.L(
                    "\(TelemetryFormatter.compactTokens(snap.todayTotalTokens)) tokens today",
                    "今日累计 \(TelemetryFormatter.compactTokens(snap.todayTotalTokens)) Token"
                ),
                highlight: true,
                isFirst: true
            )
            verticalHairline
            statCell(
                value: TelemetryFormatter.compactTokens(snap.fiveHourTotalTokens),
                label: localizer.L("5-hour rolling burst", "5 小时滚动突发"),
                detail: localizer.L(
                    "\(TelemetryFormatter.usd(snap.fiveHourTotalCostUSD)) across \(snap.activeVendorCount) harnesses",
                    "跨 \(snap.activeVendorCount) 个 CLI · 折合 \(TelemetryFormatter.usd(snap.fiveHourTotalCostUSD))"
                )
            )
            verticalHairline
            statCell(
                value: TelemetryFormatter.usd(snap.thirtyDayTotalCostUSD),
                label: localizer.L("30-day cumulative", "30 天累计开销"),
                detail: localizer.L(
                    "\(TelemetryFormatter.compactTokens(snap.thirtyDayTotalTokens)) total tokens",
                    "30 天总计 \(TelemetryFormatter.compactTokens(snap.thirtyDayTotalTokens)) Token"
                )
            )
            verticalHairline
            statCell(
                value: "\(snap.activeVendorCount) / \(AgentVendor.allCases.count)",
                label: localizer.L("Active local harnesses", "本地活跃 CLI 工具"),
                detail: snap.rateLimitHits24h == 0
                    ? localizer.L("Zero 429 hits in 24h", "24 小时内 0 次 429 限流")
                    : localizer.L(
                        "\(snap.rateLimitHits24h) rate-limit \(snap.rateLimitHits24h == 1 ? "hit" : "hits") in 24h",
                        "24 小时内 \(snap.rateLimitHits24h) 次 429 限流"
                    )
            )
        }
    }

    private var verticalHairline: some View {
        Rectangle()
            .fill(AgentBarPalette.rule)
            .frame(width: 1, height: 54)
            .padding(.horizontal, 18)
    }

    private func statCell(
        value: String,
        label: String,
        detail: String,
        highlight: Bool = false,
        isFirst: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 27, weight: .bold))
                .tracking(-0.7)
                .monospacedDigit()
                .foregroundStyle(highlight ? AgentBarPalette.copper : AgentBarPalette.ink)
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(AgentBarPalette.ink.opacity(0.88))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(AgentBarPalette.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dailyVelocitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(localizer.L("14-day multi-CLI velocity", "14 天多 CLI 吞吐趋势"))
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(localizer.isChinese ? 0 : -0.2)
                    .foregroundStyle(AgentBarPalette.ink)
                Spacer()
                HStack(spacing: 12) {
                    ForEach(AgentVendor.allCases) { v in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(v.color)
                                .frame(width: 8, height: 8)
                            Text(v.shortLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(AgentBarPalette.muted)
                        }
                    }
                }
            }

            Chart(snap.dailyBuckets) { bucket in
                BarMark(
                    x: .value(localizer.L("Day", "日期"), bucket.date, unit: .day),
                    y: .value(
                        chartMetric.localizedTitle(localizer),
                        chartMetric == .cost ? bucket.costUSD : Double(bucket.tokens) / 1_000_000.0
                    )
                )
                .foregroundStyle(bucket.vendor.color)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { val in
                    AxisValueLabel {
                        if let date = val.as(Date.self) {
                            Text(formatAxisDate(date))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.muted)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { val in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(AgentBarPalette.rule)
                    AxisValueLabel {
                        if let d = val.as(Double.self) {
                            Text(chartMetric == .cost ? String(format: "$%.0f", d) : String(format: "%.1fM", d))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.muted)
                        }
                    }
                }
            }
            .frame(height: 204)
        }
    }

    private func formatAxisDate(_ date: Date) -> String {
        let df = DateFormatter()
        if localizer.isChinese {
            df.locale = Locale(identifier: "zh-Hans")
            df.dateFormat = "M月d日"
        } else {
            df.locale = Locale(identifier: "en_GB")
            df.dateFormat = "d MMM"
        }
        return df.string(from: date)
    }

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(localizer.L("Recent local sessions", "最近本地会话"))
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(localizer.isChinese ? 0 : -0.2)
                    .foregroundStyle(AgentBarPalette.ink)
                Text(localizer.L("metadata only, zero prompts read", "仅读取元数据 · 零提示词采集"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(AgentBarPalette.muted)
                Spacer()
                Text(localizer.L(
                    "\(snap.recentSessions.count) active",
                    "\(snap.recentSessions.count) 个活跃会话"
                ))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(AgentBarPalette.muted)
            }

            if snap.recentSessions.isEmpty {
                Text(localizer.L(
                    "No local CLI sessions detected in the last 30 days.",
                    "近 30 天未检测到本地 CLI 会话记录。"
                ))
                .font(.system(size: 12))
                .foregroundStyle(AgentBarPalette.muted)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snap.recentSessions.prefix(5).enumerated()), id: \.element.id) { idx, sess in
                        if idx > 0 {
                            Rectangle().fill(AgentBarPalette.rule.opacity(0.65)).frame(height: 1)
                        }
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(sess.vendor.color)
                                .frame(width: 8, height: 8)
                            Text(sess.vendor.shortLabel)
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.ink)
                                .frame(width: 66, alignment: .leading)
                            Text(sess.projectName)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(AgentBarPalette.ink)
                                .frame(width: 124, alignment: .leading)
                                .lineLimit(1)
                            Text(sess.model)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.muted)
                                .lineLimit(1)
                            Spacer()
                            Text(TelemetryFormatter.compactTokens(sess.totalTokens))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.muted)
                            Text(TelemetryFormatter.usd(sess.effectiveCostUSD))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.ink)
                                .frame(width: 60, alignment: .trailing)
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    private var vendorBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(localizer.L("Harness share & cache hit", "各工具占比与缓存命中率"))
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(localizer.isChinese ? 0 : -0.2)
                    .foregroundStyle(AgentBarPalette.ink)
                Spacer()
                Text(localizer.L("30d / cache", "30天 / 缓存"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(AgentBarPalette.muted)
            }

            VStack(spacing: 0) {
                ForEach(Array(snap.vendorSummaries.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 {
                        Rectangle().fill(AgentBarPalette.rule.opacity(0.65)).frame(height: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(item.vendor.color)
                                .frame(width: 8, height: 8)
                            Text(item.vendor.displayName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(AgentBarPalette.ink)
                            Spacer()
                            Text(TelemetryFormatter.usd(item.thirtyDayCostUSD))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.ink)
                            Text(TelemetryFormatter.percent(item.cacheHitRatio))
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AgentBarPalette.well)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(AgentBarPalette.muted)
                        }
                        HStack {
                            Text(item.activeModel)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.muted)
                                .lineLimit(1)
                            Spacer()
                            Text(localizer.L(
                                "\(item.sessionCount30d) sess · 5h \(TelemetryFormatter.compactTokens(item.fiveHourTokens))",
                                "\(item.sessionCount30d) 次会话 · 5h \(TelemetryFormatter.compactTokens(item.fiveHourTokens))"
                            ))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(AgentBarPalette.muted)
                        }
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private var relayInspectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(localizer.L("Cross-vendor relay batons", "跨厂商接力流水线"))
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(localizer.isChinese ? 0 : -0.2)
                    .foregroundStyle(AgentBarPalette.ink)
                Spacer()
                if let first = snap.relayRuns.first {
                    Text(first.projectName)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(AgentBarPalette.copper)
                }
            }

            if let run = snap.relayRuns.first {
                VStack(spacing: 0) {
                    ForEach(Array(run.steps.suffix(4).enumerated()), id: \.element.id) { idx, step in
                        if idx > 0 {
                            Rectangle().fill(AgentBarPalette.rule.opacity(0.65)).frame(height: 1)
                        }
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(step.vendor?.color ?? AgentBarPalette.copper)
                                .frame(width: 7, height: 7)
                            Text(step.stepID)
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.ink)
                            Spacer()
                            Text(localizer.L("\(step.durationSeconds)s", "\(step.durationSeconds)秒"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.muted)
                            if let cost = step.costUSD {
                                Text(TelemetryFormatter.usd(cost))
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(AgentBarPalette.ink)
                            } else if let tok = step.tokens {
                                Text(TelemetryFormatter.compactTokens(tok))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(AgentBarPalette.muted)
                            }
                            Text(step.localizedStatus(localizer))
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .fixedSize(horizontal: true, vertical: false)
                                .background(AgentBarPalette.jade.opacity(0.18))
                                .foregroundStyle(AgentBarPalette.jade)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(10)
                .background(AgentBarPalette.well)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text(localizer.L(
                    "No .relay/LOG.md pipelines recorded in workspace.",
                    "当前工作区暂未记录 .relay/LOG.md 接力流水线。"
                ))
                .font(.system(size: 12))
                .foregroundStyle(AgentBarPalette.muted)
                .padding(.vertical, 8)
            }
        }
    }
}
