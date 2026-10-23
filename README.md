# dsh-skills

面向 DeepSeek Harness（DSH）的 Agent Skill 合集。每个子目录是一个独立的 skill 包，有自己的 `README.md`、`SKILL.md` 和 `LICENSE`，通过 [skills.sh](https://skills.sh) 的 `npx skills` 安装。

仓库地址（内容相同）：

- GitHub：<https://github.com/beilanya/dsh-skills>（`npx skills` 默认从这里安装）
- gitee：<https://gitee.com/beilanya/dsh-skills>（国内访问快）

## Skill 列表

| 目录 | 适用宿主 | 说明 |
|---|---|---|
| [dsh-delegate-kit](dsh-delegate-kit) | Claude Code、Codex（仅 Windows） | 让主 Agent 只负责思考、写任务单和审核，把编码、检索、构建测试、复现取证、网页和桌面操作委派给命令行版 dsh（`dsh headless`）里配置的模型执行；含一次性初始化、派发前兼容自检、自动修复和效率统计 |

## 快速开始

以 dsh-delegate-kit 为例：

1. **前置条件**：已安装 Node.js 和 dsh（`npm i -g @deepseek-ai/dsh`），并已在 dsh 里配置好要当子代理的模型和 API Key（推荐运行 `dsh web`，在 Models 页面配置）。
2. **安装**（一条命令，Claude Code 和 Codex 的桌面端、命令行都能用）：

   ```powershell
   npx skills add beilanya/dsh-skills --skill dsh-delegate-kit -g
   ```

   按提示勾选 Claude Code 和/或 Codex。访问 GitHub 慢时把 `beilanya/dsh-skills` 换成 `https://gitee.com/beilanya/dsh-skills.git`。

3. **配置**：新开一个会话，输入 setup，按提示选择模型、思考等级和权限：

   | 客户端 | 输入 |
   |---|---|
   | Claude 桌面端（**Code** 页）、`claude` 命令行 | `/dsh-delegate-kit setup` |
   | Codex 桌面端、`codex` 命令行 | `$dsh-delegate-kit setup` |

4. **日常使用**：setup 时同意写入全局规则后，照常提需求即可，主 Agent 会自动判断哪些活交给 dsh。全部指令：`/dsh-delegate-kit help`（Codex：`$dsh-delegate-kit help`）。
5. **更新**：说 `/dsh-delegate-kit update`（Codex：`$dsh-delegate-kit update`），或直接运行 `npx skills update dsh-delegate-kit -g`。dsh 升级后失效时，见子目录 README 的「dsh 升级后失效怎么办」。

详细说明、两个宿主都用时怎么配置、权限与安全、兼容性和卸载方法见各子目录的 README。

## 目录约定

- 每个 skill 一个子目录，至少包含 `README.md`（中文，面向使用者）、`SKILL.md` 和 `LICENSE`。`npx skills` 会把 `SKILL.md` 所在的整个目录复制到用户的 skills 目录。
- 仓库根目录和 `skills\` 下不要放 `SKILL.md`：skills CLI 在这些标准位置找不到 skill 时才会递归搜索子目录，放了就找不到各子目录里的 skill。
- 同时支持多个宿主、流程又不同时，`SKILL.md` 只做通用入口，按宿主读取同目录 `hosts\` 下的说明（例如 `hosts\claude-code.md`、`hosts\codex.md`）。这些文件不能叫 `SKILL.md`，也不要叫 `claude.md`（Windows 不区分大小写，会被 Claude Code 当成 `CLAUDE.md` 自动加载）。
- 运行时产生的数据（配置、日志、备份）写在用户目录下的专属位置，不写进仓库。
- 仓库内统一 LF，Windows 工作区检出为 CRLF（见 `.gitattributes`）；PowerShell 脚本保存为 UTF-8 带 BOM，以兼容 Windows PowerShell 5.1。

## 开发

- 修改后至少跑一遍对应 skill 的回归清单（dsh-delegate-kit 见 `dsh-delegate-kit\docs\MAINTENANCE.md`），测试时用临时目录隔离运行数据，不要影响自己正在用的配置。
- 本地验证 skills CLI 能否识别：在任意空目录运行 `npx skills add <本仓库路径> -l`。
- `origin` 配置了同时推送 gitee 和 GitHub，直接 `git push` 即可；`npx skills` 从 GitHub 安装，两边都要推到。
- 新增 skill：在根目录新建子目录，各自维护 `README.md`、`SKILL.md` 和 `LICENSE`，并在上面的列表里登记。
