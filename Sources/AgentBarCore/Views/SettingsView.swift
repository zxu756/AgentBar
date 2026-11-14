import SwiftUI

public struct SettingsView: View {
    @ObservedObject public var monitor: TelemetryMonitor
    @ObservedObject public var localizer: AppLocalizer

    @MainActor
    public init(monitor: TelemetryMonitor, localizer: AppLocalizer? = nil) {
        self.monitor = monitor
        self.localizer = localizer ?? .shared
    }

    public var body: some View {
        Form {
            Section(localizer.L("Language & Menu Bar", "界面语言与菜单栏")) {
                HStack {
                    Text(localizer.L("Interface Language", "界面语言"))
                    Spacer()
                    LanguageTogglePill(localizer: localizer)
                }

                Picker(localizer.L("Menu Bar Label", "菜单栏显示"), selection: $monitor.labelMode) {
                    ForEach(MenuBarLabelMode.allCases) { mode in
                        Text(mode.localizedTitle(localizer)).tag(mode)
                    }
                }

                Picker(localizer.L("Refresh Cadence", "刷新频率"), selection: $monitor.refreshIntervalSeconds) {
                    Text(localizer.L("Every 15 seconds", "每 15 秒")).tag(15)
                    Text(localizer.L("Every 30 seconds", "每 30 秒")).tag(30)
                    Text(localizer.L("Every 60 seconds", "每 60 秒")).tag(60)
                    Text(localizer.L("Every 5 minutes", "每 5 分钟")).tag(300)
                }

                Toggle(
                    localizer.L("Launch AgentBar at Login", "登录时自动启动 AgentBar"),
                    isOn: Binding(
                        get: { monitor.launchAtLoginEnabled },
                        set: { monitor.setLaunchAtLogin($0) }
                    )
                )
            }

            Section(localizer.L("Multi-Agent Relay Workspace", "多智能体接力工作区")) {
                TextField(
                    localizer.L("Workspace Root (.relay/LOG.md scan)", "工作区根目录（扫描 .relay/LOG.md）"),
                    text: $monitor.workspacePath
                )
                .font(.system(.body, design: .monospaced))
            }

            Section(localizer.L("Pricing & Read-Only Privacy", "计价口径与只读隐私说明")) {
                Text(localizer.L(
                    "All estimated dollar amounts are API-equivalent conversions using the \(PriceCatalog.pricingVersion) pricing table; unrecognized models are counted separately instead of guessed. AgentBar opens SQLite files strictly with SQLITE_OPEN_READONLY, never reads prompt/reply text, and makes zero network requests.",
                    "所有估算美元金额均按 API 价折算（价格表 \(PriceCatalog.pricingVersion)），未收录模型单独统计而不猜测单价。AgentBar 严格以 SQLITE_OPEN_READONLY 只读打开本地数据库，绝不读取提示词或回复正文，且发起零网络请求。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .environment(\.locale, localizer.language.locale)
        .frame(width: 480, height: 390)
    }
}
