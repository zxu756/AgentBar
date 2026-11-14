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
            case .cost: return localizer.L("API-eq ($)", "API 折算 ($)")
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
    private var lang: AppLanguage { localizer.language }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topMasthead
                .padding(.bottom, 14)

            Rectangle().fill(AgentBarPalette.rule).frame(height: 1)

            ledgerStatStrip
                .padding(.vertical, 15)

            Rectangle().fill(AgentBarPalette.rule).frame(height: 1)

            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    dailyVelocitySection
                    Rectangle().fill(AgentBarPalette.rule).frame(height: 1)
                    recentSessionsSection
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                Rectangle()
                    .fill(AgentBarPalette.rule)
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 18) {
                    vendorBreakdownSection
                    Rectangle().fill(AgentBarPalette.rule).frame(height: 1)
                    relayInspectorSection
                }
                .frame(width: 388, alignment: .topLeading)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(minWidth: 960, minHeight: 650, alignment: .top)
        .background(AgentBarPalette.canvas)
        .environment(\.locale, localizer.language.locale)
        .preferredColorScheme(.dark)
    }

    private var topMasthead: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AgentBarPalette.ink)
                        .frame(width: 30, height: 30)
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AgentBarPalette.canvas)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("AgentBar")
                            .font(.system(size: 17.5, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(AgentBarPalette.ink)
                        if snap.isDemoData {
                            Text(localizer.L("DEMO", "DEMO · 演示数据"))
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(AgentBarPalette.copper.opacity(0.22))
                                .foregroundStyle(AgentBarPalette.copper)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Text(localizer.L(
                            "API-eq · rates \(PriceCatalog.localizedPricingVersion(in: .en))",
                            "按 API 价折算 · 单价\(PriceCatalog.localizedPricingVersion(in: .zhHans))"
                        ))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(AgentBarPalette.muted)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(localizer.L(
                        "Read-only local telemetry · priced records only (unknown models excluded) · M0 session last-updated",
                        "本地只读遥测 · 费用只含已计价记录（未知型号未计入）· M0 阶段 Codex/OpenCode 按会话最后更新时间归桶"
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AgentBarPalette.muted)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ForEach(ChartMetric.allCases) { m in
                    Button {
                        chartMetric = m
                    } label: {
                        Text(m.localizedTitle(localizer))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(chartMetric == m ? AgentBarPalette.ink : AgentBarPalette.muted)
                            .padding(.horizontal, 10)
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
                         ? localizer.L("Refreshing…", "刷新中…")
                         : localizer.L("Refresh", "刷新"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(AgentBarPalette.ink)
                .padding(.horizontal, 11)
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
        let initialPending = !monitor.hasLoadedInitialSnapshot
        let noAnyData = !initialPending && snap.activeVendorCount == 0

        let todayVal: String = {
            if initialPending { return localizer.L("Refreshing…", "刷新中…") }
            if noAnyData || !snap.hasKnownTodayCost {
                return noAnyData ? localizer.L("No data", "没有数据") : localizer.L("Unknown", "未知")
            }
            return TelemetryFormatter.usd(snap.todayTotalCostUSD)
        }()

        let fiveVal: String = {
            if initialPending { return localizer.L("Refreshing…", "刷新中…") }
            if noAnyData { return localizer.L("No data", "没有数据") }
            return TelemetryFormatter.compactTokens(snap.fiveHourTotalTokens)
        }()

        let thirtyVal: String = {
            if initialPending { return localizer.L("Refreshing…", "刷新中…") }
            if noAnyData || !snap.hasKnownThirtyDayCost {
                return noAnyData ? localizer.L("No data", "没有数据") : localizer.L("Unknown", "未知")
            }
            return TelemetryFormatter.usd(snap.thirtyDayTotalCostUSD)
        }()

        let thirtyDetail: String = {
            if initialPending {
                return localizer.L("Scanning local stores…", "正在扫描本地记录…")
            }
            if let note30 = snap.thirtyDayCostNote(in: lang) {
                return note30
            }
            return localizer.L(
                "\(TelemetryFormatter.compactTokens(snap.thirtyDayTotalTokens)) known tokens",
                "已知总计 \(TelemetryFormatter.compactTokens(snap.thirtyDayTotalTokens)) Token"
            )
        }()

        let todayDetail: String = {
            if initialPending {
                return localizer.L("Today window", "今日窗口")
            }
            if let noteToday = snap.todayCostNote(in: lang) {
                return noteToday
            }
            return localizer.L(
                "Today · \(TelemetryFormatter.compactTokens(snap.todayTotalTokens)) tok",
                "今日 · \(TelemetryFormatter.compactTokens(snap.todayTotalTokens)) Token"
            )
        }()

        return HStack(alignment: .top, spacing: 0) {
            statCell(
                value: todayVal,
                label: localizer.L(
                    "Today API-eq (rates \(PriceCatalog.localizedPricingVersion(in: .en)))",
                    "今日按 API 价折算（单价\(PriceCatalog.localizedPricingVersion(in: .zhHans))）"
                ),
                detail: todayDetail,
                highlight: true
            )
            verticalHairline
            statCell(
                value: fiveVal,
                label: localizer.L("5-hour rolling burst", "5 小时滚动突发"),
                detail: localizer.L(
                    "\(TelemetryFormatter.usd(snap.fiveHourTotalCostUSD)) priced across \(snap.activeVendorCount) CLIs",
                    "\(snap.activeVendorCount) 个有数据 CLI · 已计价 \(TelemetryFormatter.usd(snap.fiveHourTotalCostUSD))"
                )
            )
            verticalHairline
            statCell(
                value: thirtyVal,
                label: localizer.L(
                    "30-day API-eq (\(TelemetryFormatter.compactTokens(snap.thirtyDayTotalTokens)) tok)",
                    "30 天按 API 价折算（\(TelemetryFormatter.compactTokens(snap.thirtyDayTotalTokens)) Token）"
                ),
                detail: thirtyDetail
            )
            verticalHairline
            statCell(
                value: initialPending ? "…" : "\(snap.activeVendorCount) / \(AgentVendor.allCases.count)",
                label: localizer.L("CLIs with local records", "有本地记录的 CLI"),
                detail: snap.rateLimitHits24h == 0
                    ? localizer.L("0 rate-limit markers (24h)", "24 小时内 0 条限流标记")
                    : localizer.L(
                        "\(snap.rateLimitHits24h) rate-limit markers (24h)",
                        "24 小时内 \(snap.rateLimitHits24h) 条限流标记"
                    )
            )
        }
    }

    private var verticalHairline: some View {
        Rectangle()
            .fill(AgentBarPalette.rule)
            .frame(width: 1, height: 54)
            .padding(.horizontal, 16)
    }

    private func statCell(
        value: String,
        label: String,
        detail: String,
        highlight: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.6)
                .monospacedDigit()
                .foregroundStyle(highlight ? AgentBarPalette.copper : AgentBarPalette.ink)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AgentBarPalette.ink.opacity(0.88))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AgentBarPalette.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dailyVelocitySection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(localizer.L("14-day ledger (by session update)", "14 天多 CLI 趋势（按会话更新时间）"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(localizer.isChinese ? 0 : -0.2)
                    .foregroundStyle(AgentBarPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 9) {
                    ForEach(AgentVendor.allCases) { v in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(v.color)
                                .frame(width: 8, height: 8)
                            Text(v.shortLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(AgentBarPalette.muted)
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
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
            .frame(height: 196)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(localizer.L("Recent local sessions", "最近本地会话"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(localizer.isChinese ? 0 : -0.2)
                    .foregroundStyle(AgentBarPalette.ink)
                Text(localizer.L("parsed in memory · prompts never stored or shown", "读入内存解析计数 · 不保存不显示正文"))
                    .font(.system(size: 11))
                    .foregroundStyle(AgentBarPalette.muted)
                Spacer()
                Text(localizer.L(
                    "\(snap.recentSessions.count) sessions",
                    "\(snap.recentSessions.count) 个会话"
                ))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AgentBarPalette.muted)
            }

            if !monitor.hasLoadedInitialSnapshot {
                Text(localizer.L("Refreshing…", "刷新中…"))
                    .font(.system(size: 12))
                    .foregroundStyle(AgentBarPalette.muted)
                    .padding(.vertical, 8)
            } else if snap.recentSessions.isEmpty {
                Text(localizer.L(
                    "No data: no local CLI sessions detected in the last 30 days.",
                    "没有数据：近 30 天未检测到本地 CLI 会话记录。"
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
                        let sessCompleteness: DataCompleteness = sess.origin == .relayLog
                            ? .relayOnly
                            : (sess.hasRolloutMismatch ? .mismatch : (sess.hasTokenBreakdown ? .complete : .totalOnly))
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(sess.vendor.color)
                                .frame(width: 8, height: 8)
                            Text(sess.vendor.shortLabel)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.ink)
                                .frame(width: 60, alignment: .leading)
                            Text(sess.projectName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AgentBarPalette.ink)
                                .frame(width: 118, alignment: .leading)
                                .lineLimit(1)
                            Text(sess.model.isEmpty ? localizer.L("Unknown", "未知") : sess.model)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.muted)
                                .lineLimit(1)
                            Spacer()
                            Text(TelemetryFormatter.optionalTokens(sess.knownTotalTokens, completeness: sessCompleteness, language: lang))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.muted)
                            Text(TelemetryFormatter.optionalUSD(sess.effectiveCostUSD, completeness: sessCompleteness, language: lang))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(sess.effectiveCostUSD != nil ? AgentBarPalette.ink : AgentBarPalette.muted)
                                .frame(width: 66, alignment: .trailing)
                        }
                        .padding(.vertical, 6.5)
                    }
                }
            }
        }
    }

    private var vendorBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(localizer.L("Source completeness & 30d ledger", "数据源完整度与 30 天账本"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(localizer.isChinese ? 0 : -0.2)
                    .foregroundStyle(AgentBarPalette.ink)
                Spacer()
                Text(localizer.L("30d / cache", "30天 / 缓存"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AgentBarPalette.muted)
            }

            VStack(spacing: 0) {
                ForEach(Array(snap.vendorSummaries.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 {
                        Rectangle().fill(AgentBarPalette.rule.opacity(0.65)).frame(height: 1)
                    }
                    let w30 = item.metrics(for: .thirtyDays)
                    let pending = !monitor.hasLoadedInitialSnapshot
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(item.completeness != .noData ? item.vendor.color : AgentBarPalette.muted.opacity(0.35))
                                .frame(width: 8, height: 8)
                            Text(item.vendor.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AgentBarPalette.ink)
                                .fixedSize(horizontal: true, vertical: false)
                            completenessPill(pending ? nil : item.completeness)
                            Spacer(minLength: 4)
                            Text(pending
                                 ? localizer.L("Refreshing…", "刷新中…")
                                 : TelemetryFormatter.optionalUSD(w30.estimatedCostUSD, completeness: w30.completeness, language: lang))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(w30.estimatedCostUSD != nil ? AgentBarPalette.ink : AgentBarPalette.muted)
                                .fixedSize(horizontal: true, vertical: false)
                            Text(pending
                                 ? "…"
                                 : TelemetryFormatter.optionalPercent(w30.cacheHitRate, completeness: w30.completeness, language: lang))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 2)
                                .background(AgentBarPalette.well)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(AgentBarPalette.muted)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        HStack {
                            Text(item.activeModel)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.muted)
                                .lineLimit(1)
                            Spacer()
                            Text(pending
                                 ? "…"
                                 : localizer.L(
                                     "30d \(TelemetryFormatter.optionalTokens(w30.totalTokens, completeness: w30.completeness, language: lang)) · \(w30.recordCount) rec",
                                     "30天 \(TelemetryFormatter.optionalTokens(w30.totalTokens, completeness: w30.completeness, language: lang)) · \(w30.recordCount) 条"
                                 ))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.muted)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        if !pending, let subNote = w30.mismatchNote(in: lang) ?? w30.costNote(in: lang) {
                            Text(subNote)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(w30.hasRolloutMismatch ? AgentBarPalette.copper : AgentBarPalette.muted.opacity(0.9))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6.5)
                }
            }
        }
    }

    private func completenessPill(_ completeness: DataCompleteness?) -> some View {
        let text: String
        let tint: Color
        if let completeness {
            text = completeness.label(in: lang)
            switch completeness {
            case .complete: tint = AgentBarPalette.jade
            case .mismatch: tint = Color(red: 0.89, green: 0.36, blue: 0.33)
            case .totalOnly: tint = AgentBarPalette.copper
            case .relayOnly: tint = Color(red: 0.85, green: 0.64, blue: 0.25)
            case .noData: tint = AgentBarPalette.muted
            }
        } else {
            text = localizer.L("Refreshing…", "刷新中…")
            tint = AgentBarPalette.muted
        }
        return Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.16))
            .foregroundStyle(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var relayInspectorSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(localizer.L("Cross-vendor relay batons", "跨厂商接力流水线"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(localizer.isChinese ? 0 : -0.2)
                    .foregroundStyle(AgentBarPalette.ink)
                Spacer()
                if let first = snap.relayRuns.first {
                    Text("\(first.projectName) (\(first.steps.count))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                                .fill(step.vendor?.color ?? AgentBarPalette.muted)
                                .frame(width: 7, height: 7)
                            Text(step.stepID)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(AgentBarPalette.ink)
                            Spacer()
                            if step.durationSeconds > 0 {
                                Text(localizer.L("\(step.durationSeconds)s", "\(step.durationSeconds)秒"))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(AgentBarPalette.muted)
                            }
                            if let cost = step.costUSD {
                                Text(TelemetryFormatter.usd(cost))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(AgentBarPalette.ink)
                            } else if let tok = step.tokens {
                                Text(TelemetryFormatter.compactTokens(tok))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(AgentBarPalette.muted)
                            }
                            Text(step.localizedStatus(localizer))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .fixedSize(horizontal: true, vertical: false)
                                .background(AgentBarPalette.jade.opacity(0.18))
                                .foregroundStyle(AgentBarPalette.jade)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(.vertical, 5.5)
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
