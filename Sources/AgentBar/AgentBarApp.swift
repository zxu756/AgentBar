import AgentBarCore
import AppKit
import Foundation
import SwiftUI

public struct AgentBarApp: App {
    @StateObject private var monitor: TelemetryMonitor
    @StateObject private var localizer: AppLocalizer
    @Environment(\.openWindow) private var openWindow

    public init() {
        let args = CommandLine.arguments
        if args.contains("--demo") {
            _monitor = StateObject(wrappedValue: TelemetryMonitor.preview)
        } else {
            _monitor = StateObject(wrappedValue: TelemetryMonitor())
        }
        _localizer = StateObject(wrappedValue: AppLocalizer.shared)
    }

    public var body: some Scene {
        Window(localizer.L("AgentBar — Local Multi-CLI Ledger", "AgentBar — 本地多智能体用量账本"), id: "dashboard") {
            DashboardView(monitor: monitor, localizer: localizer)
        }
        .defaultSize(width: 1020, height: 720)
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

@main
enum AgentBarMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--cli") || args.contains("--help") || args.contains("-h") {
            let code = CLIRunner.run(arguments: args)
            Foundation.exit(code)
        }

        if let idx = args.firstIndex(of: "--export-screenshots") {
            guard idx + 1 < args.count else {
                fputs("Error: --export-screenshots requires an output directory.\n", stderr)
                Foundation.exit(2)
            }
            let outURL = URL(fileURLWithPath: args[idx + 1])
            let exportLang = AppLocalizer.resolveCLILanguage(from: args) ?? .en
            do {
                try MainActor.assumeIsolated {
                    try ScreenshotExporter.exportMarketingScreenshots(to: outURL, language: exportLang)
                }
                print("Exported 2x Retina DEMO screenshots (\(exportLang.rawValue)) to \(outURL.path)")
                Foundation.exit(0)
            } catch {
                fputs("Failed to export screenshots: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        // Reject unrecognized user CLI flags instead of silently launching the GUI with exit 0
        var i = 1
        while i < args.count {
            let arg = args[i]
            if arg == "--demo" {
                i += 1
            } else if arg == "--lang" {
                guard i + 1 < args.count, AppLanguage.parseCLI(args[i + 1]) != nil else {
                    fputs("Error: invalid --lang argument (expected en or zh).\n", stderr)
                    Foundation.exit(2)
                }
                i += 2
            } else if arg.hasPrefix("--lang=") {
                let val = String(arg.dropFirst("--lang=".count))
                guard AppLanguage.parseCLI(val) != nil else {
                    fputs("Error: invalid --lang argument (expected en or zh).\n", stderr)
                    Foundation.exit(2)
                }
                i += 1
            } else if arg.hasPrefix("-psn_") || arg == "-NSDocumentRevisionsDebugMode" || arg == "-AppleLanguages" {
                // Standard macOS LaunchServices / AppKit arguments
                i += (arg == "-NSDocumentRevisionsDebugMode" || arg == "-AppleLanguages") ? 2 : 1
            } else {
                fputs("Error: unrecognized argument '\(arg)'.\n\(CLIRunner.usageText())\n", stderr)
                Foundation.exit(2)
            }
        }

        AgentBarApp.main()
    }
}
