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
            Divider().overlay(Color.white.opacity(0.08))
            vendorListSection
            if let latestRelay = snap.relayRuns.first {
                Divider().overlay(Color.white.opacity(0.08))
                relayStrip(latestRelay)
            }
            Divider().overlay(Color.white.opacity(0.08))
            footerControls
        }
        .padding(14)
        .frame(width: 388)
        .background(Color(red: 0.055, green: 0.070, blue: 0.105))
        .preferredColorScheme(.dark)
    }

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.22, green: 0.74, blue: 0.97))
                    Text("AGENTBAR TELEMETRY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(TelemetryFormatter.usd(snap.todayTotalCostUSD))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("today · \(TelemetryFormatter.compactTokens(snap.todayTotalTokens)) tok")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("5H WINDOW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(TelemetryFormatter.compactTokens(snap.fiveHourTotalTokens))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                if snap.rateLimitHits24h > 0 {
                    Text("\(snap.rateLimitHits24h) × 429 (24h)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                } else {
                    Text("0 rate limits")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.85))
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
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(item.vendor.color)
                            .frame(width: max(6, (geo.size.width - 8) * frac))
                    }
                }
                if snap.todayTotalCostUSD == 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                }
            }
        }
        .frame(height: 7)
    }

    private var vendorListSection: some View {
        VStack(spacing: 8) {
            ForEach(snap.vendorSummaries) { item in
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(item.sourceAvailable ? item.vendor.color : Color.gray.opacity(0.35))
                            .frame(width: 8, height: 8)
                        Text(item.vendor.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(item.sourceAvailable ? .white : .secondary)
                        Text(item.activeModel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(TelemetryFormatter.compactTokens(item.fiveHourTokens))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(TelemetryFormatter.usd(item.todayCostUSD))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 56, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.07))
                            Capsule()
                                .fill(item.vendor.color.opacity(0.88))
                                .frame(width: max(item.fiveHourTokens > 0 ? 4 : 0, geo.size.width * item.fiveHourBurstFraction))
                        }
                    }
                    .frame(height: 4)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func relayStrip(_ run: RelayRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("RELAY · \(run.projectName)", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(run.steps.count) batons · \(TelemetryFormatter.usd(run.totalCostUSD))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            HStack(spacing: 5) {
                ForEach(run.steps.suffix(4)) { step in
                    HStack(spacing: 4) {
                        Circle()
                            .fill((step.vendor?.color) ?? .cyan)
                            .frame(width: 6, height: 6)
                        Text(step.stepID)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
    }

    private var footerControls: some View {
        HStack(spacing: 8) {
            Button(action: onOpenDashboard) {
                HStack(spacing: 5) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Dashboard")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(red: 0.20, green: 0.48, blue: 0.92))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                monitor.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 26, height: 24)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Refresh local SQLite & JSONL logs")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 26, height: 24)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Local Read-Only")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
}
