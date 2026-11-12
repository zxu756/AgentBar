import SwiftUI

public struct SettingsView: View {
    @ObservedObject public var monitor: TelemetryMonitor

    public init(monitor: TelemetryMonitor) {
        self.monitor = monitor
    }

    public var body: some View {
        Form {
            Section("Menu Bar Display") {
                Picker("Menu Bar Label", selection: $monitor.labelMode) {
                    ForEach(MenuBarLabelMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Picker("Refresh Cadence", selection: $monitor.refreshIntervalSeconds) {
                    Text("Every 15 seconds").tag(15)
                    Text("Every 30 seconds").tag(30)
                    Text("Every 60 seconds").tag(60)
                    Text("Every 5 minutes").tag(300)
                }

                Toggle(
                    "Launch AgentBar at Login",
                    isOn: Binding(
                        get: { monitor.launchAtLoginEnabled },
                        set: { monitor.setLaunchAtLogin($0) }
                    )
                )
            }

            Section("Multi-Agent Relay Workspace") {
                TextField("Workspace Root (.relay/LOG.md scan)", text: $monitor.workspacePath)
                    .font(.system(.body, design: .monospaced))
            }

            Section("Privacy & Security Guarantee") {
                Text("AgentBar opens local SQLite files strictly with SQLITE_OPEN_READONLY, extracts only numeric token/cost/model/timestamp metadata, never reads prompt or response text, and makes zero network requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 340)
    }
}
