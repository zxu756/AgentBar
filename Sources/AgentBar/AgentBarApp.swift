import AgentBarCore
import AppKit
import Foundation
import SwiftUI

@main
struct AgentBarApp: App {
    @StateObject private var monitor: TelemetryMonitor
    @StateObject private var localizer: AppLocalizer
    @Environment(\.openWindow) private var openWindow

    init() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--export-screenshots"), idx + 1 < args.count {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            let exportLang = AppLocalizer.resolveCLILanguage(from: args) ?? .en
            do {
                try MainActor.assumeIsolated {
                    try ScreenshotExporter.exportMarketingScreenshots(to: outURL, language: exportLang)
                }
                print("Exported 2x Retina screenshots (\(exportLang.rawValue)) to \(outURL.path)")
                exit(0)
            } catch {
                fputs("Failed to export screenshots: \(error)\n", stderr)
                exit(1)
            }
        }
        _monitor = StateObject(wrappedValue: TelemetryMonitor())
        _localizer = StateObject(wrappedValue: AppLocalizer.shared)
    }

    var body: some Scene {
        Window(localizer.L("AgentBar — Local Multi-CLI Ledger", "AgentBar — 本地多智能体用量账本"), id: "dashboard") {
            DashboardView(monitor: monitor, localizer: localizer)
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandMenu(localizer.L("Language", "语言")) {
                Button("切换语言 / Toggle Language") {
                    localizer.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        localizer.language = lang
                    } label: {
                        HStack {
                            Text("\(lang.displayName) (\(lang.badge))")
                            if localizer.language == lang {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }

        MenuBarExtra {
            MenuBarPopoverView(
                monitor: monitor,
                localizer: localizer,
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
            SettingsView(monitor: monitor, localizer: localizer)
        }
    }
}
