# dsh-skills

面向 DeepSeek Harness（DSH）的 Agent Skill 合集。每个子目录是一个独立的 skill 包，有自己的 `README.md`、安装脚本和 `LICENSE`，可以单独安装和维护。

仓库地址（内容相同，任选其一）：

- gitee：<https://gitee.com/beilanya/dsh-skills>（国内访问快）
- GitHub：<https://github.com/beilanya/dsh-skills>（供 [skills.sh](https://skills.sh) / `npx skills` 生态检索和安装）

## Skill 列表

| 目录 | 适用宿主 | 说明 |
|---|---|---|
| [dsh-delegate-kit-installer](skills/dsh-delegate-kit-installer) | 任何支持 Agent Skills 的宿主 | dsh-delegate-kit 的安装器，供 `npx skills add` 使用：装上后对 Agent 说“安装 dsh-delegate-kit”，它会获取代码并运行 kit 自带的安装脚本 |
| [dsh-delegate-kit](dsh-delegate-kit) | Claude Code、Codex（仅 Windows） | 让主 Agent 只负责思考、写任务单和审核，把编码、检索、构建测试、复现取证、网页和桌面操作委派给命令行版 dsh（`dsh headless`）里配置的模型执行；含一次性初始化、派发前兼容自检、自动修复和效率统计 |

## 快速开始

以 dsh-delegate-kit 为例：

1. 前置条件：已安装 Node.js 和 dsh（`npm i -g @deepseek-ai/dsh`），并已在 dsh 里配置好要当子代理的模型和 API Key（推荐运行 `dsh web`，在 Models 页面配置）。
2. 安装（四选一，详见 [dsh-delegate-kit/README.md](dsh-delegate-kit/README.md#安装)）：
   - **npx skills**（[Vercel skills 生态](https://skills.sh)）：先装安装器，再让 Agent 完成安装：

     ```powershell
     npx skills add beilanya/dsh-skills --skill dsh-delegate-kit-installer -g
     ```

     然后在 Claude Code 或 Codex 里新开会话，说“安装 dsh-delegate-kit”。kit 需要按宿主选择不同的 `SKILL.md` 并带上脚本，所以不能用 `npx skills add` 直接装 kit 本体，安装器会替你运行 kit 自带的安装脚本。装好后可以用 `npx skills remove dsh-delegate-kit-installer` 删掉安装器，不影响已装好的 kit。
   - **图形化**：在本页点「克隆/下载」→「下载 ZIP」，解压后双击 `dsh-delegate-kit\install.cmd`，按提示选择装到 Claude、Codex 或两边。
   - **让 Agent 代装**：在 Claude 桌面端的 Code 页或 Codex 桌面端，把 README 里「方法二」的提示词发给它。
   - **命令行**：

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
- `skills\` 目录只放给 `npx skills` 生态识别的 skill（目前只有安装器）。CLI 只扫描根目录、`skills\` 等固定位置，找到后不再递归，所以 `dsh-delegate-kit\claude\`、`dsh-delegate-kit\codex\` 不会被误装。
- 同时支持多个宿主时，按宿主分开放 `SKILL.md`（例如 `claude\SKILL.md`、`codex\SKILL.md`），由安装脚本复制到对应的 skills 目录。
- 运行时产生的数据（配置、日志、备份）写在用户目录下的专属位置，不写进仓库。
- 仓库内统一 LF，Windows 工作区检出为 CRLF（见 `.gitattributes`）；PowerShell 脚本保存为 UTF-8 带 BOM，以兼容 Windows PowerShell 5.1。

## 开发

- 修改后至少跑一遍对应 skill 的回归清单（dsh-delegate-kit 见 `dsh-delegate-kit\docs\MAINTENANCE.md`），测试时用临时目录隔离运行数据，不要影响自己正在用的配置。
- 新增 skill：在根目录新建子目录，各自维护 `README.md`、`SKILL.md` 和 `LICENSE`，并在上面的列表里登记。
