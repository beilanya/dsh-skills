# dsh-delegate-kit 指令说明

## 怎么下指令

| 宿主 | 写法 | 例子 |
|---|---|---|
| Claude Code | `/dsh-delegate-kit <子命令>`，或直接用自然语言 | `/dsh-delegate-kit status`、「看看 dsh 的效率统计」 |
| Codex | `$dsh-delegate-kit <子命令>`，或在 `/skills` 里选中后说子命令（Codex 没有 `/dsh-delegate-kit` 斜杠命令） | `$dsh-delegate-kit check` |

平时不用下指令：全局规则启用后，主 Agent 判断适合时会自动把活派给 dsh。想控制派不派，直接说：

| 你说 | 效果 |
|---|---|
| 「交给 dsh 做：<任务>」 | 规划后委派，任务再小也派 |
| 「拆成几个独立任务并行派给 dsh」 | 划清文件范围后并行派发 |
| 「这个你自己做，别派出去」 | 本任务由主 Agent 自己做，不影响以后 |
| 「先出方案和拆分，我确认后再派」 | 只给方案，等你确认 |
| 「dsh 任务进度怎么样」 | 读运行中标记和进度文件，报告实际状态 |
| 「这个任务用 high / low 思考」「这个任务用只读权限」 | 覆盖本次的思考档或权限（权限只能调低，调高要你明确同意） |

## 子命令

| 子命令 | 作用 | 常用参数 |
|---|---|---|
| `help` | 显示本说明 | — |
| `setup` | 初始化。第一段列出候选（模型及能力、思考档、权限），你在聊天里选；第二段生成配置并自检 | 第二段：`-Model <provider/id> -Effort <档\|auto> -Mode <权限>`；选完全权限加 `-AcknowledgeFullAccess`；需要对齐插件时 `-InstallPlugins`（先征求你同意） |
| `status` | 当前配置：模型、能否看图、上下文窗口、支持的思考档、思考模式、默认权限、可选功能、dsh 版本、上次自检 | — |
| `check` | 自检，不调模型、不花 token：dsh 版本对比基线、补丁能否解析、必需插件、模型是否仍支持所选思考档、可选功能 | `-UpdateBaseline`：通过后把当前 dsh 版本记为新基线 |
| `repair` | dsh 升级或自检失败后修复：重新识别插件、按当前模型目录重新生成补丁、再自检 | `-InstallPlugins`：把 headless 插件版本对齐到 dsh（先征求你同意） |
| `stats` | 委派效率统计（按思考档、是否挂浏览器分组：次数、耗时、步数、工具调用、token） | `-Days <n>`：只看最近 n 天 |
| `diag` | 生成诊断包 zip（版本、自检结果、日志末尾、状态文件；已脱敏，不含任何 Key） | — |
| `update` | 检查 gitee 上的新版 kit：显示当前版本、最新版本、更新内容（只拉到临时目录比对，不改动已安装文件） | `-Apply`：确认后重装到本机所有已安装的副本（Claude、Codex 一起），再自检；`-Force`：没有新版也重装 |
| `rules` | 查看或追加全局规则段落（让主 Agent 主动委派） | `-Host claude\|codex`；`-Show` 只看；`-Apply` 追加（会先备份）；`-RulesFile <路径>` 指定文件 |
| `uninstall` | 卸载 | `-Host claude\|codex` 只移除该宿主的规则段落；不传 `-Host` 时移除两边规则并删除补丁和状态；`-RemoveSkills` 删 Skill 文件；`-PurgeLogs` 删日志；`-ClaudeSkillsDir`/`-CodexSkillsDir` 指定自定义安装目录 |

所有子命令都支持 `-Json`（输出机器可读的 JSON）。

## 派发参数（主 Agent 使用，你也可以在聊天里点名要求）

Claude 用 `scripts\dsh-run.ps1`，Codex 用 `scripts\dsh-dispatch.ps1`，参数相同：

| 参数 | 说明 |
|---|---|
| `-TaskFile <路径>` / `-Task <文本>` | 任务单 |
| `-Cwd <目录>` | 工作目录（不支持 UNC 路径） |
| `-Label <名称>` | 任务名，提示和日志里显示 |
| `-Effort <档>` | 思考档，只接受该模型支持的档；setup 写死时会被忽略 |
| `-Mode <权限>` | `read-only` / `workspace-write` / `danger-full-access`；可以调低，调高要你同意并加 `-EscalationApproved` |
| `-Browser` | 挂载浏览器（默认不挂） |
| `-ComputerUse` | 开启电脑操作（会操作你的桌面，多个任务自动排队） |
| `-SessionId <id>` | 续接之前的 dsh 会话 |
| `-TimeoutMin <分钟>` | 超时，默认 90，至少 1 |
| `-NoProtocol` | 不追加运行约定（只适合几分钟的小任务） |
| `-NotifyThreadId <id>` / `-NoNotify` | 仅 Codex：回调的 thread id / 不回调 |

## 返回状态

| STATUS | 含义 | 主 Agent 怎么处理 |
|---|---|---|
| `OK` | 正常完成 | 审核改动并亲自复跑关键验收 |
| `FAILED` / `TIMEOUT` | 失败或超时 | 先从进度文件和 sessionId 挽救结论，再决定重派或接手 |
| `DSH_UNAVAILABLE` | 未初始化、dsh 不存在、凭证或额度问题 | 回退到宿主自带方式，并告诉你原因 |
| `DSH_INCOMPATIBLE` | dsh 升级后不兼容，或所需可选功能不可用 | 回退并建议运行 `repair` |
| `DSH_INCOMPATIBLE` + `FORMAT: output` | dsh 跑完了，但 kit 认不出新版 dsh 的输出格式 | 先核对工作区（任务可能已做完），只补做剩下的部分；建议运行 `update`，或回退 dsh |

## dsh 升级后失效怎么办

一般不用管：派发失败时主 Agent 会自动改用宿主自带方式完成任务，并告诉你原因。想恢复 dsh 委派，按顺序试：

1. `repair`：配置层的不兼容（插件 id、补丁格式、思考档写法变了）大多能自动修好。
2. `update`：repair 修不好，或提示 `FORMAT: output` 时，说明需要新版 kit；有新版就按提示更新。
3. 回退 dsh：暂时没有新版 kit 时，把 dsh 装回已验证的版本（`check` / `status` 会给出命令，例如 `npm i -g @deepseek-ai/dsh@0.2.1-rc.2`），下次派发会自动自检恢复。注意 DSH 桌面端用的也是这个 dsh。

`status` 和每次派发的摘要会提示当前 dsh 版本是否经过本 kit 验证。

## 文件位置

| 位置 | 内容 |
|---|---|
| `~\.dsh\dsh-delegate-kit\` | kit 数据：`state.json`、`patches\`、`logs\`（Codex 在 `logs\codex\`）、`backups\`、`diag\` |
| `~\.claude\skills\dsh-delegate-kit\`、`~\.codex\skills\dsh-delegate-kit\` | Skill 文件 |
| 环境变量 `DSH_KIT_HOME` | 改 kit 数据目录（测试时常用） |

更多说明见 Skill 目录下的 `README.md`，排障见 `docs\MAINTENANCE.md`。
