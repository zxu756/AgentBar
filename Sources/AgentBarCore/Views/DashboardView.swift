import Charts
import SwiftUI

public struct DashboardView: View {
    @ObservedObject public var monitor: TelemetryMonitor
    @State private var chartMetric: ChartMetric = .cost

    public enum ChartMetric: String, CaseIterable, Identifiable {
        case cost = "API-Eq Spend ($)"
        case tokens = "Tokens"
        public var id: String { rawValue }
    }

    public init(monitor: TelemetryMonitor) {
        self.monitor = monitor
    }

    private var snap: TelemetrySnapshot { monitor.snapshot }

    public var body: some View {
        VStack(spacing: 16) {
            topHeaderBar
            kpiDeck
            HStack(alignment: .top, spacing: 16) {
                dailyChartCard
                    .frame(maxWidth: .infinity)
                fiveHourVendorCard
                    .frame(width: 330)
            }
            HStack(alignment: .top, spacing: 16) {
                recentSessionsCard
                    .frame(maxWidth: .infinity)
                relayInspectorCard
                    .frame(width: 330)
            }
        }
        .padding(20)
        .frame(minWidth: 940, minHeight: 620)
        .background(Color(red: 0.045, green: 0.058, blue: 0.090))
        .preferredColorScheme(.dark)
    }

    private var topHeaderBar: some View {
        HStack {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.16, green: 0.56, blue: 0.95), Color(red: 0.12, green: 0.78, blue: 0.62)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("AgentBar")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Multi-Agent Local Telemetry · Zero Network · SQLITE_OPEN_READONLY")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(ChartMetric.allCases) { m in
                    Button {
                        chartMetric = m
                    } label: {
                        Text(m.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(chartMetric == m ? .white : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(chartMetric == m ? Color(red: 0.20, green: 0.48, blue: 0.92) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )

            Button {
                monitor.refreshNow()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text(monitor.isRefreshing ? "Scanning…" : "Refresh")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var kpiDeck: some View {
        HStack(spacing: 12) {
            kpiTile(
                title: "TODAY API-EQ SPEND",
                primary: TelemetryFormatter.usd(snap.todayTotalCostUSD),
                subtitle: "\(TelemetryFormatter.compactTokens(snap.todayTotalTokens)) tokens today",
                accent: Color(red: 0.22, green: 0.74, blue: 0.97)
            )
            kpiTile(
                title: "5H ROLLING BURST",
                primary: TelemetryFormatter.compactTokens(snap.fiveHourTotalTokens),
                subtitle: "\(TelemetryFormatter.usd(snap.fiveHourTotalCostUSD)) across active CLIs",
                accent: Color(red: 0.20, green: 0.83, blue: 0.60)
            )
            kpiTile(
                title: "30-DAY FOOTPRINT",
                primary: TelemetryFormatter.usd(snap.thirtyDayTotalCostUSD),
                subtitle: "\(TelemetryFormatter.compactTokens(snap.thirtyDayTotalTokens)) total tokens",
                accent: Color(red: 0.90, green: 0.50, blue: 0.36)
            )
            kpiTile(
                title: "ACTIVE HARNESSES",
                primary: "\(snap.activeVendorCount) / \(AgentVendor.allCases.count)",
                subtitle: snap.rateLimitHits24h == 0
                    ? "0 rate-limit 429s in 24h"
                    : "\(snap.rateLimitHits24h) rate-limit hit(s) in 24h",
                accent: snap.rateLimitHits24h == 0
                    ? Color(red: 0.66, green: 0.55, blue: 0.98)
                    : .orange
            )
        }
    }

    private func kpiTile(title: String, primary: String, subtitle: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 3, height: 11)
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(primary)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(red: 0.078, green: 0.098, blue: 0.145))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var dailyChartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("14-DAY MULTI-CLI VELOCITY")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 10) {
                    ForEach(AgentVendor.allCases) { v in
                        HStack(spacing: 4) {
                            Circle().fill(v.color).frame(width: 7, height: 7)
                            Text(v.shortLabel)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Chart(snap.dailyBuckets) { bucket in
                BarMark(
                    x: .value("Day", bucket.date, unit: .day),
                    y: .value(
                        chartMetric.rawValue,
                        chartMetric == .cost ? bucket.costUSD : Double(bucket.tokens) / 1_000_000.0
                    )
                )
                .foregroundStyle(bucket.vendor.color)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.white.opacity(0.05))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { val in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.white.opacity(0.07))
                    AxisValueLabel {
                        if let d = val.as(Double.self) {
                            Text(chartMetric == .cost ? String(format: "$%.0f", d) : String(format: "%.1fM", d))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 212)
        }
        .padding(14)
        .frame(height: 262, alignment: .top)
        .background(Color(red: 0.078, green: 0.098, blue: 0.145))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var fiveHourVendorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CLI BREAKDOWN & CACHE HIT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("30d / Hit%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 9) {
                ForEach(snap.vendorSummaries) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: item.vendor.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(item.vendor.color)
                                .frame(width: 16)
                            Text(item.vendor.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Text(TelemetryFormatter.usd(item.thirtyDayCostUSD))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                            Text(TelemetryFormatter.percent(item.cacheHitRatio))
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(item.activeModel)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(item.sessionCount30d) sess · 5h \(TelemetryFormatter.compactTokens(item.fiveHourTokens))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .frame(height: 262, alignment: .top)
        .background(Color(red: 0.078, green: 0.098, blue: 0.145))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var recentSessionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT SESSIONS (METADATA ONLY — NO PROMPTS READ)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(snap.recentSessions.count) sessions")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 5) {
                ForEach(snap.recentSessions.prefix(5)) { sess in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(sess.vendor.color)
                            .frame(width: 7, height: 7)
                        Text(sess.vendor.shortLabel)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 62, alignment: .leading)
                        Text(sess.projectName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 120, alignment: .leading)
                            .lineLimit(1)
                        Text(sess.model)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(TelemetryFormatter.compactTokens(sess.totalTokens))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(TelemetryFormatter.usd(sess.effectiveCostUSD))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                if snap.recentSessions.isEmpty {
                    Text("No recent local CLI sessions detected in lookback window.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.078, green: 0.098, blue: 0.145))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var relayInspectorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AGENT-RELAY BATONS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if let first = snap.relayRuns.first {
                    Text(first.projectName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
            }

            if let run = snap.relayRuns.first {
                VStack(spacing: 5) {
                    ForEach(run.steps.suffix(4)) { step in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(step.vendor?.color ?? .cyan)
                                .frame(width: 7, height: 7)
                            Text(step.stepID)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                            Spacer()
                            Text("\(step.durationSeconds)s")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let cost = step.costUSD {
                                Text(TelemetryFormatter.usd(cost))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white)
                            } else if let tok = step.tokens {
                                Text(TelemetryFormatter.compactTokens(tok))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text(step.status.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(step.status == "ok" ? Color.green.opacity(0.18) : Color.orange.opacity(0.2))
                                .foregroundStyle(step.status == "ok" ? .green : .orange)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 7)
                        .background(Color.white.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            } else {
                Text("No .relay/LOG.md pipelines found under workspace root.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.078, green: 0.098, blue: 0.145))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
