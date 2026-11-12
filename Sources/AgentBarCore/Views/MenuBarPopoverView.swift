import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject public var monitor: TelemetryMonitor
    public var onOpenDashboard: () -> Void
    public var onOpenSettings: () -> Void

    public init(
        monitor: TelemetryMonitor,
        onOpenDashboard: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.onOpenDashboard = onOpenDashboard
        self.onOpenSettings = onOpenSettings
    }

    private var snap: TelemetrySnapshot { monitor.snapshot }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .frame(width: 392)
        .background(AgentBarPalette.canvas)
        .preferredColorScheme(.dark)
    }

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AgentBar · Local telemetry")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AgentBarPalette.muted)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(TelemetryFormatter.usd(snap.todayTotalCostUSD))
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.7)
                        .monospacedDigit()
                        .foregroundStyle(AgentBarPalette.copper)
                    Text("today · \(TelemetryFormatter.compactTokens(snap.todayTotalTokens)) tok")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(AgentBarPalette.muted)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("5-hour burst")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AgentBarPalette.muted)
                Text(TelemetryFormatter.compactTokens(snap.fiveHourTotalTokens))
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(AgentBarPalette.ink)
                if snap.rateLimitHits24h > 0 {
                    Text(verbatim: "\(snap.rateLimitHits24h) × 429 (24h)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AgentBarPalette.copper.opacity(0.18))
                        .foregroundStyle(AgentBarPalette.copper)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text("Zero 429s")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(AgentBarPalette.jade)
                }
            }
        }
    }

    private var proportionalFuelBar: some View {
        GeometryReader { geo in
            let total = max(0.0001, snap.todayTotalCostUSD)
            HStack(spacing: 2) {
                ForEach(snap.vendorSummaries) { item in
                    let frac = item.todayCostUSD / total
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
        .frame(height: 8)
    }

    private var vendorListSection: some View {
        VStack(spacing: 9) {
            ForEach(snap.vendorSummaries) { item in
                VStack(spacing: 5) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.sourceAvailable ? item.vendor.color : AgentBarPalette.muted.opacity(0.35))
                            .frame(width: 8, height: 8)
                        Text(item.vendor.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(item.sourceAvailable ? AgentBarPalette.ink : AgentBarPalette.muted)
                        Text(item.activeModel)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(AgentBarPalette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(TelemetryFormatter.compactTokens(item.fiveHourTokens))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(AgentBarPalette.muted)
                        Text(TelemetryFormatter.usd(item.todayCostUSD))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AgentBarPalette.ink)
                            .frame(width: 56, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AgentBarPalette.well)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(item.vendor.color)
                                .frame(width: max(item.fiveHourTokens > 0 ? 4 : 0, geo.size.width * item.fiveHourBurstFraction))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    private func relayStrip(_ run: RelayRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Relay · \(run.projectName)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AgentBarPalette.ink)
                Spacer()
                Text(verbatim: "\(run.steps.count) batons · \(TelemetryFormatter.usd(run.totalCostUSD))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AgentBarPalette.muted)
            }
            HStack(spacing: 5) {
                ForEach(run.steps.suffix(4)) { step in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(step.vendor?.color ?? AgentBarPalette.copper)
                            .frame(width: 6, height: 6)
                        Text(step.stepID)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(AgentBarPalette.ink)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
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
                Text("Open ledger")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AgentBarPalette.canvas)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
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

            Spacer()

            Text("Read-only")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(AgentBarPalette.muted)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(AgentBarPalette.muted)
        }
    }
}
