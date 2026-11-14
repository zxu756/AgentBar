import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject public var monitor: TelemetryMonitor
    @ObservedObject public var localizer: AppLocalizer
    public var onOpenDashboard: () -> Void
    public var onOpenSettings: () -> Void

    @MainActor
    public init(
        monitor: TelemetryMonitor,
        localizer: AppLocalizer? = nil,
        onOpenDashboard: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.localizer = localizer ?? .shared
        self.onOpenDashboard = onOpenDashboard
        self.onOpenSettings = onOpenSettings
    }

    private var snap: TelemetrySnapshot { monitor.snapshot }
    private var lang: AppLanguage { localizer.language }

    public var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            headerSection
            proportionalFuelBar
            Rectangle().fill(AgentBarPalette.rule).frame(height: 1)
            vendorListSection
            if let latestRelay = snap.relayRuns.first {
                Rectangle().fill(AgentBarPalette.rule).frame(height: 1)
                relayStrip(latestRelay)
            }
            Rectangle().fill(AgentBarPalette.rule).frame(height: 1)
            footerControls
        }
        .padding(16)
        .frame(width: 408)
        .background(AgentBarPalette.canvas)
        .environment(\.locale, localizer.language.locale)
        .preferredColorScheme(.dark)
    }

    private var headerSection: some View {
        let pending = !monitor.hasLoadedInitialSnapshot
        let noAnyData = !pending && snap.activeVendorCount == 0

        let mainCostText: String = {
            if pending { return localizer.L("Refreshing…", "刷新中…") }
            if noAnyData { return localizer.L("No data", "没有数据") }
            if !snap.hasKnownTodayCost { return localizer.L("Unknown", "未知") }
            return TelemetryFormatter.usd(snap.todayTotalCostUSD)
        }()

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                Text("AgentBar")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(AgentBarPalette.ink)
                if snap.isDemoData {
                    Text(localizer.L("DEMO", "DEMO · 演示数据"))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(AgentBarPalette.copper.opacity(0.22))
                        .foregroundStyle(AgentBarPalette.copper)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 4)
                LanguageTogglePill(localizer: localizer, compact: true)
            }

            Text(PriceCatalog.costDisclaimer(in: lang))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(AgentBarPalette.muted)
                .lineLimit(1)

            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(mainCostText)
                        .font(.system(size: 25, weight: .bold))
                        .tracking(-0.6)
                        .monospacedDigit()
                        .foregroundStyle(AgentBarPalette.copper)
                        .fixedSize(horizontal: true, vertical: false)
                    if !pending && !noAnyData {
                        Text(localizer.L(
                            "today · \(TelemetryFormatter.compactTokens(snap.todayTotalTokens)) tok",
                            "今日 · \(TelemetryFormatter.compactTokens(snap.todayTotalTokens)) Token"
                        ))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(AgentBarPalette.muted)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(localizer.L("5h burst", "5h 突发"))
                            .font(.system(size: 11))
                            .foregroundStyle(AgentBarPalette.muted)
                        Text(pending ? "…" : (noAnyData ? "—" : TelemetryFormatter.compactTokens(snap.fiveHourTotalTokens)))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(AgentBarPalette.ink)
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    if snap.unknownModelRecordCount30d > 0 {
                        Text(localizer.L(
                            "\(snap.unknownModelRecordCount30d) unpriced (30d)",
                            "30天 \(snap.unknownModelRecordCount30d) 条未匹配"
                        ))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AgentBarPalette.muted)
                        .fixedSize(horizontal: true, vertical: false)
                    } else if snap.rateLimitHits24h > 0 {
                        Text(localizer.L(
                            "\(snap.rateLimitHits24h) × 429 (24h)",
                            "24h 限流 \(snap.rateLimitHits24h) 次"
                        ))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(AgentBarPalette.copper)
                        .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Text(localizer.L("Read-only local", "本地只读"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(AgentBarPalette.jade)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
    }

    private var proportionalFuelBar: some View {
        GeometryReader { geo in
            let total = max(0.0001, snap.todayTotalCostUSD)
            HStack(spacing: 2) {
                ForEach(snap.vendorSummaries) { item in
                    let cost = item.todayCostUSD ?? 0
                    let frac = cost / total
                    if frac > 0.01 {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(item.vendor.color)
                            .frame(width: max(6, (geo.size.width - 8) * frac))
                    }
                }
                if snap.todayTotalCostUSD == 0 {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(AgentBarPalette.well)
                }
            }
        }
        .frame(height: 7)
    }

    private var vendorListSection: some View {
        let pending = !monitor.hasLoadedInitialSnapshot
        return VStack(spacing: 8) {
            ForEach(snap.vendorSummaries) { item in
                let wToday = item.metrics(for: .today)
                let w30 = item.metrics(for: .thirtyDays)
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.completeness != .noData ? item.vendor.color : AgentBarPalette.muted.opacity(0.35))
                            .frame(width: 8, height: 8)
                        Text(item.vendor.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(item.completeness != .noData ? AgentBarPalette.ink : AgentBarPalette.muted)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(pending ? localizer.L("Refreshing…", "刷新中…") : item.completeness.label(in: lang))
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AgentBarPalette.well)
                            .foregroundStyle(AgentBarPalette.muted)
                            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 4)
                        Text(pending
                             ? "…"
                             : TelemetryFormatter.optionalTokens(w30.totalTokens, completeness: w30.completeness, language: lang))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(AgentBarPalette.muted)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(pending
                             ? "…"
                             : TelemetryFormatter.optionalUSD(wToday.estimatedCostUSD, completeness: wToday.completeness, language: lang))
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(wToday.estimatedCostUSD != nil ? AgentBarPalette.ink : AgentBarPalette.muted)
                            .frame(width: 64, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AgentBarPalette.well)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(item.vendor.color)
                                .frame(width: max((item.fiveHourTokens ?? 0) > 0 ? 4 : 0, geo.size.width * item.fiveHourBurstFraction))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    private func relayStrip(_ run: RelayRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(localizer.L("Relay · \(run.projectName)", "接力 · \(run.projectName)"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AgentBarPalette.ink)
                Spacer()
                Text(localizer.L(
                    "\(run.steps.count) steps · \(TelemetryFormatter.usd(run.totalCostUSD))",
                    "\(run.steps.count) 步 · \(TelemetryFormatter.usd(run.totalCostUSD))"
                ))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AgentBarPalette.muted)
            }
            HStack(spacing: 5) {
                ForEach(run.steps.suffix(4)) { step in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(step.vendor?.color ?? AgentBarPalette.muted)
                            .frame(width: 6, height: 6)
                        Text(step.stepID)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(AgentBarPalette.ink)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 3)
                    .background(AgentBarPalette.well)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        }
    }

    private var footerControls: some View {
        HStack(spacing: 8) {
            Button(action: onOpenDashboard) {
                Text(localizer.L("Open ledger", "打开完整账本"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AgentBarPalette.canvas)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(AgentBarPalette.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                monitor.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentBarPalette.ink)
                    .frame(width: 26, height: 25)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(AgentBarPalette.rule, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(localizer.L("Refresh telemetry", "刷新本地遥测"))

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentBarPalette.ink)
                    .frame(width: 26, height: 25)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(AgentBarPalette.rule, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(localizer.L("Settings", "偏好设置"))

            Spacer()

            Text(localizer.L("Pricing \(PriceCatalog.pricingVersion)", "价格表 \(PriceCatalog.pricingVersion)"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AgentBarPalette.muted)
                .fixedSize(horizontal: true, vertical: false)

            Button(localizer.L("Quit", "退出")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(AgentBarPalette.muted)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}
