# dsh-skills

面向 DeepSeek Harness（DSH）的 Agent Skill 合集。每个子目录是一个独立的 skill 包，有自己的 `README.md`、安装脚本和 `LICENSE`，可以单独安装和维护。

## Skill 列表

| 目录 | 适用宿主 | 说明 |
|---|---|---|
| [dsh-delegate-kit](dsh-delegate-kit) | Claude Code、Codex（仅 Windows） | 让主 Agent 只负责思考、写任务单和审核，把编码、检索、构建测试、复现取证、网页和桌面操作委派给命令行版 dsh（`dsh headless`）里配置的模型执行；含一次性初始化、派发前兼容自检、自动修复和效率统计 |

## 快速开始

以 dsh-delegate-kit 为例：

1. 前置条件：已安装 Node.js 和 dsh（`npm i -g @deepseek-ai/dsh`），并已在 dsh 里配置好要当子代理的模型和 API Key（推荐运行 `dsh web`，在 Models 页面配置）。
2. 获取代码并安装：

   ```powershell
   git clone https://gitee.com/beilanya/dsh-skills.git
   cd dsh-skills\dsh-delegate-kit
   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Target both
   ```

   `-Target` 可以是 `claude`、`codex` 或 `both`。

3. 初始化：Claude Code 里说 `/dsh-delegate-kit setup`，Codex 里说 `$dsh-delegate-kit setup`，按提示选择模型、思考等级和权限。
4. 查看全部指令：`/dsh-delegate-kit help`（Codex：`$dsh-delegate-kit help`）。
5. 以后更新：说 `/dsh-delegate-kit update`（Codex：`$dsh-delegate-kit update`），确认后自动重装两边。dsh 升级后失效时，见子目录 README 的「dsh 升级后失效怎么办」。

详细说明、权限与安全、兼容性和卸载方法见各子目录的 README。

## 目录约定

- 每个 skill 一个子目录，至少包含 `README.md`（中文，面向使用者）、宿主用的 `SKILL.md`、安装脚本和 `LICENSE`。
- 同时支持多个宿主时，按宿主分开放 `SKILL.md`（例如 `claude\SKILL.md`、`codex\SKILL.md`），由安装脚本复制到对应的 skills 目录。
- 运行时产生的数据（配置、日志、备份）写在用户目录下的专属位置，不写进仓库。
- 仓库内统一 LF，Windows 工作区检出为 CRLF（见 `.gitattributes`）；PowerShell 脚本保存为 UTF-8 带 BOM，以兼容 Windows PowerShell 5.1。

## 开发

- 修改后至少跑一遍对应 skill 的回归清单（dsh-delegate-kit 见 `dsh-delegate-kit\docs\MAINTENANCE.md`），测试时用临时目录隔离运行数据，不要影响自己正在用的配置。
- 新增 skill：在根目录新建子目录，各自维护 `README.md`、`SKILL.md` 和 `LICENSE`，并在上面的列表里登记。
