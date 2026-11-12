import AgentBarCore
import AppKit
import Foundation
import SwiftUI

@main
struct AgentBarApp: App {
    @StateObject private var monitor: TelemetryMonitor
    @Environment(\.openWindow) private var openWindow

    init() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--export-screenshots"), idx + 1 < args.count {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            do {
                try MainActor.assumeIsolated {
                    try ScreenshotExporter.exportMarketingScreenshots(to: outURL)
                }
                print("Exported 2x Retina screenshots to \(outURL.path)")
                exit(0)
            } catch {
                fputs("Failed to export screenshots: \(error)\n", stderr)
                exit(1)
            }
        }
        _monitor = StateObject(wrappedValue: TelemetryMonitor())
    }

    var body: some Scene {
        Window("AgentBar", id: "dashboard") {
            DashboardView(monitor: monitor)
        }
        .defaultSize(width: 980, height: 640)

        MenuBarExtra {
            MenuBarPopoverView(
                monitor: monitor,
                onOpenDashboard: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "dashboard")
                },
                onOpenSettings: {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            )
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                if let text = monitor.menuBarText {
                    Text(text)
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(monitor: monitor)
        }
    }
}
