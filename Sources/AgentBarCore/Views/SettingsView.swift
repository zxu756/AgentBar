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
                    "All estimated dollar amounts are API-equivalent conversions using unverified local rates; each cost display states priced record counts vs excluded unknown-model records. AgentBar opens SQLite files strictly with SQLITE_OPEN_READONLY and reads local JSONL/log files into memory to parse JSON lines, extracting only token counts, model names, and timestamps—never storing, displaying, or uploading prompt or reply text, and making zero network requests.",
                    "所有估算美元金额均按本地未核对单价作 API 等价折算，并在费用旁标明已计价条数与未计入的未知型号条数。AgentBar 严格以 SQLITE_OPEN_READONLY 只读打开本地数据库，并将本地 JSONL/日志文件读入内存解析 JSON 行，仅提取 Token 计数、模型名称与时间戳字段，不保存、不显示、不上传提示词或回复正文，且发起零网络请求。"
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
