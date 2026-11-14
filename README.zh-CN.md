# AgentBar

**[English](README.md)** | **简体中文** | **[技术规范 (`docs/SPEC.md`)](docs/SPEC.md)**

**面向多智能体编程工作流的 macOS 原生只读菜单栏与命令行遥测账本**（支持 `Claude Code`、`Codex CLI`、`OpenCode`、`Mistral Vibe`、`Antigravity` 及 [`agent-relay`](https://github.com/zxu756/agent-relay) `.relay/LOG.md` 接力流水线）。

**零网络请求 · `SQLITE_OPEN_READONLY` 严格只读 · 零固定比例估算 · 实时 `中文 / EN` 双语界面与无头 `--cli` · 零第三方依赖 (`macOS 14.0+`)**

> **发布状态说明（未发布（v0.2.0 之后））**：当前 Homebrew Cask 已发布的 `v0.2.0` 仅包含初版菜单栏界面；无头命令行 `--cli snapshot`、`--home` / `--workspace` / `--now` / `--no-zstd`、`Scripts/test.sh`、五级完整度（`complete` / `mismatch` / `totalOnly` / `relayOnly` / `noData`）、费用旁已计价/未知型号条数说明及流式去重均属 **未发布（v0.2.0 之后）**，请按下方源码方式编译使用。

![AgentBar 中文主账本面板 — DEMO 演示数据](docs/screenshot-dashboard-zh.png)
*`[DEMO / 演示数据]` 上图由确定性合成预览数据（`--demo` / `--export-screenshots`）渲染生成，绝不包含任何个人真实本地日志。*

<p align="center">
  <img src="docs/screenshot-menubar-zh.png" width="410" alt="AgentBar 中文菜单栏弹窗 — DEMO 演示数据" />
  <br />
  <em><code>[DEMO / 演示数据]</code> 菜单栏弹窗合成预览截图。</em>
</p>

---

## AgentBar 统计什么（以及不猜测什么）

同时使用多款本地 AI 编程 CLI（`claude`、`codex`、`opencode`、`vibe`、`agy`）时，用量分散在包月滚动窗口、API 预付额度与多工具文件接力记录中。**AgentBar** 通过原生菜单栏界面与无头命令行（`AgentBar --cli snapshot [--json]`，未发布（v0.2.0 之后））以严格只读方式汇总本地真实记录：

- **流式内容块去重统计（`Claude Code`）**：按 `(message.id, requestId)` 对同一轮回复的多条流式块（`thinking`、`text`、`tool_use`）去重并取最终最大用量，消除多块重复累加。
- **Rollout 明细核对与不一致标记（`Codex CLI`）**：将 `~/.codex/state_5.sqlite` 的 `threads` 表与 `rollout-*.jsonl`（及归档 `.jsonl.zst`，需本机装有 `zstd`）关联，提取未缓存输入、缓存读取与输出 Token，并与 `threads.tokens_used` 核对总量。若 rollout 合计与 SQLite 不一致，则标出 `rollout=X vs sqlite=Y` 并将完整度降级为 `总量不一致`（`mismatch`）；若缺少可读 rollout 明细，则标为 `只有总量`（`totalOnly`），明细、缓存命中率与费用均输出 `null`（界面显示 `未知`），不用固定比例拆分伪造。
- **五级数据源完整度标签**：每个厂商与时间窗口（`最近 5 小时`、`今天`、`7 天`、`30 天`）均明确标注 `完整`、`总量不一致`、`只有总量`、`只有接力里的部分` 或 `没有数据`（首次扫描完成前显示 `刷新中…`）。
- **诚实的 API 等效折算说明（`单价未核对`）**：所有估算金额统一标注 **`按 API 价折算（单价未核对；只含已计价记录，未知型号未计入）`**，并在费用金额旁写明 **`只含已计价的 N 条，另有 M 条未知型号未计入`**；未收录或内部模型标识单独计入 `unmatchedModelCount`，不静默套用其他模型单价。
- **严格 `.relay/LOG.md` 接力解析**：识别 `##` / `###` 步骤标题（含 conductor 会话内记录及带逗号的失败状态），遇到任何标题立即闭合上一步防止正文串行，且仅从步骤标题提取 `vendor`（如 `NN-verify` 保持 `vendor: null`）。
- **实时 `中文 / EN` 双语切换**：支持顶栏 **`中文 | EN`** 胶囊、快捷键 `⇧⌘L` 以及命令行 `--lang zh|en`（中文输出包含完整本地化的数据源说明与状态标签）。

---

## 各 CLI 数据源与完整度说明（`M0`）

| CLI 工具 | 本地只读数据源 | 典型完整度 | 口径说明与 M0 边界 |
|---|---|---|---|
| **Claude Code** | `~/.claude/projects/**/*.jsonl`（`message.id`、`requestId`、`message.usage`、`message.model`、`costUSD`、`timestamp`） | `完整` (`complete`) | 按 `(message.id, requestId)` 单轮去重；按单轮时间戳归桶。 |
| **Codex CLI** | `~/.codex/state_5.sqlite` (`threads`) + `rollout_path` (`rollout-*.jsonl` / `.jsonl.zst`) | `完整` / `总量不一致` / `只有总量` | 核对 `token_count.info.total_token_usage` 与 `threads.tokens_used`。**M0 口径**：当前按 `threads.updated_at` 会话最后更新时间归桶；逐事件跨天归桶排在 M1。 |
| **OpenCode** | `~/.local/share/opencode/opencode.db`（`session_v2 表`：`cost`、`tokens_*`、`model`、`time_updated`） | `完整` (`complete`) | **M0 口径**：当前按 `session_v2.time_updated` 会话最后更新时间归桶；从 `message`/`part` 逐事件归桶排在 M1。 |
| **Mistral Vibe** | `~/Projects/*/.relay/LOG.md`（`meta.json 无 Token 统计`） | `只有接力里的部分` (`relayOnly`) 或 `没有数据` | 当前版本 Vibe 的 `meta.json` 不含 Token 字段（`journal/*.jsonl` 解析排在 M1）；不标为 `完整`。 |
| **Antigravity** | `~/Projects/*/.relay/LOG.md` + `~/.gemini/antigravity-cli/log/cli-*.log`（`cli-*.log 无 Token 统计`） | `只有接力里的部分` (`relayOnly`) 或 `没有数据` | 独立 `cli-*.log` 不含 Token 用量；仅汇总 `.relay/LOG.md` 中的步骤总 Token，不猜测未拆分费用。 |

---

## 分型号 API 等效单价表（`PriceCatalog`，`未核对`）

以下费率沿用离线基线，在本次 M0 离线返工中未联网逐项核对厂商定价页，因此每个型号前缀单独占一行，列出单价、官方定价来源网址并将核对日期标为 `未核对`（匹配规则与缓存命中率公式 `cache_read / (input + cache_read + cache_write)` 见 [`docs/SPEC.md`](docs/SPEC.md)）：

<details>
<summary>展开查看 29 行分型号单价表（每百万 Token 单价、官方来源网址、核对日期）</summary>

| 型号前缀 | 输入 / 1M | 缓存读取 / 1M | 缓存写入 / 1M | 输出 / 1M | 官方定价来源网址 | 核对日期 |
|---|---:|---:|---:|---:|---|---|
| `claude-opus` | \$15.00 | \$1.50 | \$18.75 | \$75.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | 未核对 |
| `claude-3-opus` | \$15.00 | \$1.50 | \$18.75 | \$75.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | 未核对 |
| `claude-4-opus` | \$15.00 | \$1.50 | \$18.75 | \$75.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | 未核对 |
| `claude-sonnet` | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | 未核对 |
| `claude-3-5-sonnet` | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | 未核对 |
| `claude-3-7-sonnet` | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | 未核对 |
| `claude-4-sonnet` | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | 未核对 |
| `claude-haiku` | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | 未核对 |
| `claude-3-haiku` | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | 未核对 |
| `claude-3-5-haiku` | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | 未核对 |
| `claude-4-haiku` | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | 未核对 |
| `gpt-6` | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | 未核对 |
| `gpt-5` | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | 未核对 |
| `codex-mini` | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | 未核对 |
| `o3` | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | 未核对 |
| `o4-mini` | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | 未核对 |
| `deepseek-v4` | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | 未核对 |
| `deepseek-v3` | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | 未核对 |
| `deepseek-chat` | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | 未核对 |
| `deepseek-reasoner` | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | 未核对 |
| `gemini-4-carbon` | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | 未核对 |
| `gemini 4 carbon` | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | 未核对 |
| `gemini-2.5-pro` | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | 未核对 |
| `gemini-3-pro` | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | 未核对 |
| `gemini-4-argon` | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | 未核对 |
| `gemini 4 argon` | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | 未核对 |
| `gemini-2.0-flash` | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | 未核对 |
| `gemini-2.5-flash` | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | 未核对 |
| `gemini-3-flash` | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | 未核对 |

</details>

---

## 隐私与安全架构

1. **零网络访问**：仅链接 macOS 系统框架（`SwiftUI`、`Charts`、`AppKit`、`ServiceManagement`、`libsqlite3`），二进制不含任何 `URLSession`、`NWConnection` 或 `CFNetwork` 符号。
2. **严格只读 (`SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`)**：以只读模式及 `250ms` 忙等待超时读取本地 SQLite，不锁死或修改正在运行的 CLI。
3. **内存解析计数、不保存不显示正文**：`AgentBar` 会将本地会话 JSONL/日志文件读入内存按行解析 JSON，但只提取数值型 Token 计数字段、模型名称、时间戳、费用与目录名，不保存、不显示、不上传提示词或回复正文。

---

## 安装与源码构建

### 从源码编译（需 macOS 14.0+、Swift 6.0+）

```bash
git clone https://github.com/zxu756/AgentBar.git
cd AgentBar
swift build
./Scripts/test.sh scope Collectors Pricing RelayLog CLI Core
./Scripts/build-app.sh
open build/AgentBar.app
```

### Homebrew Cask 安装（`v0.2.0` — M0 前已发布界面版本）

```bash
brew install --cask zxu756/tap/agentbar
```

> 发布包采用本地 ad-hoc 签名，首次启动如遇 Gatekeeper 提示，可执行 `xattr -cr /Applications/AgentBar.app`。

---

## 无头命令行（Headless CLI）与验收复现（未发布（v0.2.0 之后））

`AgentBar` 在进入 `AppKit` 事件循环前处理 `--cli`，与菜单栏界面共用同一套采集函数，不弹窗、不写 `~/Library/Preferences`。若显式传入不存在的 `--home <目录>` 或 `--workspace <目录>`，命令将向 `stderr` 输出错误并以退出码 `2` 退出；默认 `HOME` 下某款 CLI 未安装则显示 `没有数据`：

```bash
# 命令行帮助（英文 / 简体中文）
.build/debug/AgentBar --help --lang en
.build/debug/AgentBar --help --lang zh

# 人类可读本地快照（英文 / 简体中文）
.build/debug/AgentBar --cli snapshot --lang en
.build/debug/AgentBar --cli snapshot --lang zh

# 机器可读 JSON 快照（未知明细严格输出 null）
.build/debug/AgentBar --cli snapshot --json --lang en
.build/debug/AgentBar --cli snapshot --json --lang zh

# 合成演示数据快照与 2x Retina 双语截图导出
.build/debug/AgentBar --cli snapshot --demo --lang en
.build/debug/AgentBar --cli snapshot --demo --lang zh
.build/debug/AgentBar --export-screenshots /tmp/agentbar-screenshots --lang en
.build/debug/AgentBar --export-screenshots /tmp/agentbar-screenshots --lang zh

# 运行 M0 独立对账验收与 README 命令回放
./Scripts/test.sh milestone 0
```

---

## 开源协议

MIT
