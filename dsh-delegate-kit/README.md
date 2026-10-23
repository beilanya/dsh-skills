# dsh-delegate-kit

让主 Agent（Claude Code / Codex）负责思考、写任务单和审核，把实际执行交给命令行版 dsh（`dsh headless`）里配置的模型。

- 只支持 **Windows**，脚本兼容 **Windows PowerShell 5.1** 及以上。
- 只支持 **Claude Code** 和 **Codex** 两种宿主。
- kit 只读取 dsh 的模型配置，不读取、不打印、不复制任何 API Key。

## 工作方式

1. **主 Agent 判断**：全局规则启用后，主 Agent 遇到方案已定的编码、大量检索、构建测试、复现取证、网页或桌面操作时，判断“写任务单加审核”是否明显比亲自做省事，是就委派；小改动、方案讨论、审核验收自己做。
2. **写任务单**：目标、工作目录、可改文件、禁止事项、验收命令、返回格式写成独立完整的文件，大任务拆成互不依赖的子任务并行派发。
3. **后台执行**：`dsh-run.ps1` 叠加 kit 生成的补丁（凭证、所选模型和思考档、按需挂浏览器或电脑操作），以 `dsh headless --json` 运行，事件流和进度实时落盘；Codex 侧由 `dsh-dispatch.ps1` 在后台运行，完成后用 `codex queue` 回调。
4. **审核**：主 Agent 读摘要（状态、耗时、token、git 变化、最终回复），核对 diff，亲自复跑关键验收；不合格就用 `-SessionId` 续接修正。
5. **兼容保护**：每次派发前比对 dsh 版本和补丁哈希，变化时自动自检；不兼容返回 `DSH_INCOMPATIBLE`，主 Agent 自动回退到宿主自带方式，你再运行 `repair` 修复。dsh 的输出格式认不出来时同样返回 `DSH_INCOMPATIBLE`（带 `FORMAT: output`），不会把成功的任务误判成失败；当前 dsh 版本没经过本 kit 验证时会给出警告。见「[dsh 升级后失效怎么办](#dsh-升级后失效怎么办)」。

## 前置条件

1. 已安装 Node.js。
2. 已安装 dsh：

   ```powershell
   npm i -g @deepseek-ai/dsh
   ```

3. **先在 dsh 里配置好要当子代理的模型和 API Key**。推荐运行 `dsh web`，在 **Models** 页面配置；也可以在 DSH 桌面端配置。kit 不会代你填写或显示 Key。
4. headless profile 已初始化。没有初始化时，运行一次下面的命令即可：

   ```powershell
   dsh plugin --profile headless list
   ```

5. 浏览器功能可选：需要本机有 Chrome 或 Edge；电脑操作不需要浏览器。

## 安装

三种方法任选一种，装完的结果完全一样。同一份安装同时适用于桌面端和命令行：

- Claude 桌面端的 **Code** 页和命令行 `claude` 都读 `~\.claude\skills`；
- Codex 桌面端和命令行 `codex` 都读 `~\.codex\skills`。

> 不适用的通用入口：Claude 桌面端「设置」里上传 ZIP 的 Skills 是给 claude.ai 聊天用的，运行在云端，调用不了本机的 dsh；Codex 的 `$skill-installer` 只会原样复制仓库目录，不会按宿主选择 `SKILL.md`。这两种方式都装不了本 kit。

### 方法一：图形化（下载 ZIP，双击安装）

1. 浏览器打开 <https://gitee.com/beilanya/dsh-skills>，点「克隆/下载」→「下载 ZIP」（gitee 可能要求先登录），解压到任意目录。
2. 进入解压出的 `dsh-delegate-kit` 文件夹，双击 **`install.cmd`**。
   - 弹出「Windows 已保护你的电脑」时，点「更多信息」→「仍要运行」。也可以在解压前右键 ZIP →「属性」→ 勾选「解除锁定」。
3. 在弹出的窗口里按提示输入数字后回车：`1` 只装 Claude Code，`2` 只装 Codex，`3` 两个都装。
   - 已经装过别的版本时会询问是否覆盖，输入 `y` 回车即可。
   - 看到「已安装 ...」后按任意键关闭窗口。
4. 初始化：
   - **Claude 桌面端**：打开 **Code** 页，新建一个会话，输入 `/dsh-delegate-kit setup`。
   - **Codex 桌面端**：新建一个线程，输入 `$dsh-delegate-kit setup`。也可以先在侧边栏 **Skills** 里确认能看到 `dsh-delegate-kit`；看不到就重启 Codex。

### 方法二：让桌面端的 Agent 代装

在 Claude 桌面端的 Code 页或 Codex 桌面端新建会话，把下面这段发给它（需要本机装有 git）：

```text
请帮我安装 dsh-delegate-kit：如果 %USERPROFILE%\dsh-skills 不存在，就运行 git clone https://gitee.com/beilanya/dsh-skills.git "%USERPROFILE%\dsh-skills"；已存在就在该目录运行 git pull。然后在 %USERPROFILE%\dsh-skills\dsh-delegate-kit 目录运行 powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Target both，把输出原样告诉我。不要做其他任何改动。
```

装完后**新开一个会话**，再输入 `/dsh-delegate-kit setup`（Claude）或 `$dsh-delegate-kit setup`（Codex）。只用其中一个宿主时，把提示词里的 `both` 改成 `claude` 或 `codex`。

### 方法三：命令行

在 PowerShell 里执行：

```powershell
git clone https://gitee.com/beilanya/dsh-skills.git
cd dsh-skills\dsh-delegate-kit
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Target both
```

`-Target` 按需选 `claude`、`codex` 或 `both`。没有 git 时，用方法一的 ZIP 解压后在 `dsh-delegate-kit` 目录执行最后一行即可。然后：

- 命令行 Claude Code：运行 `claude`，输入 `/dsh-delegate-kit setup`；
- 命令行 Codex：运行 `codex`，输入 `$dsh-delegate-kit setup`。

`install.ps1` 的参数：

| 参数 | 含义 |
|---|---|
| `-Target claude\|codex\|both` | 安装到哪个宿主，必填 |
| `-ClaudeSkillsDir <目录>` | 覆盖 Claude 的 skills 根目录（默认 `~\.claude\skills`） |
| `-CodexSkillsDir <目录>` | 覆盖 Codex 的 skills 根目录（默认 `$env:CODEX_HOME\skills` 或 `~\.codex\skills`） |
| `-Force` | 目标已存在时覆盖重装 |
| `-WhatIf` | 只列出要复制或删除的文件，不改动磁盘 |
| `-Uninstall` | 只删除带 `.kit-install.json` 的已安装 skill 目录 |
| `-Interactive` | 菜单方式选择宿主，失败时询问是否覆盖重装（`install.cmd` 用的就是它） |

安装前会先校验目标路径：两个宿主解析到同一个目录时直接拒绝（exit 1），不会覆盖；目标路径经联接点/符号链接解析后如果与包源目录重叠，也会拒绝，包源不会被删除或写入。

安装位置：

| 宿主 | 默认目录 |
|---|---|
| Claude Code | `~\.claude\skills\dsh-delegate-kit` |
| Codex | `$env:CODEX_HOME\skills\dsh-delegate-kit`；未设置 `CODEX_HOME` 时是 `~\.codex\skills\dsh-delegate-kit` |

安装后，Claude Code 里说 `/dsh-delegate-kit setup`，Codex 里说 `$dsh-delegate-kit setup`；也可以用自然语言表达同样意思。Codex 没有 `/dsh-delegate-kit` 这样的斜杠命令。装好后已经打开的会话不一定能识别新 skill，新开一个会话最稳妥。

## 初始化：两段式 setup

setup 不能自己向你提问，提问由宿主里的主 Agent 完成。

1. **第一段：出候选。** 主 Agent 运行 `kit.ps1 setup -Json`，检查 dsh、Node、headless profile，并列出可选模型、每个模型支持的思考档、权限模式和可选功能状态。环境不满足时返回 exit 2 和修复指引。
2. **第二段：生成配置。** 你在聊天里选好模型、思考等级和权限后，主 Agent 运行：

   ```powershell
   kit.ps1 setup -Model <provider/id> -Effort <档|auto> -Mode <权限> -Json
   ```

   选 `danger-full-access` 时还要加 `-AcknowledgeFullAccess`。脚本会生成补丁、写 `state.json` 并跑一次 `check`。

   setup 的 `-Effort` 和 `-Mode` 只接受小写规范值（例如 `high`、`auto`、`workspace-write`）；`High`、`WORKSPACE-WRITE` 这类写法会被拒绝（派发时 dsh-run / dsh-dispatch 的 `-Effort`、`-Mode` 会自动转成小写再校验）。只带 `-Effort`、`-Mode`、`-InstallPlugins` 或 `-AcknowledgeFullAccess` 却没有 `-Model` 时直接报错，不会改配置。补丁先在临时目录生成，成功后才移入 `patches\` 并写 `state.json`；生成失败时旧配置保持不变，不会留下半成品。

几个需要你知道的确认点：

- **插件版本对齐**：输出里 `plugins.needInstall` 为 true 时，主 Agent 会先把 `plugins.command` 给你看；只有你同意后，才会执行安装命令（`repair -InstallPlugins` 或 `setup -InstallPlugins`）。安装只改 headless profile，不影响 DSH 桌面端。
- **全局规则**：主 Agent 会先用 `rules -Host claude -Show`（Codex 用 `rules -Host codex -Show`）把要追加到 `CLAUDE.md` / `AGENTS.md` 的完整段落给你看。你同意后才写入；原文件存在时先备份，段落用开始/结束标记包起来，`uninstall` 能原样移除。
- **冒烟测试**：会真实调用模型并消耗 token。主 Agent 必须先问你，同意后才跑极小任务。

## 日常使用

setup 完成并同意追加全局规则后，平时**不需要任何额外操作**：照常给主 Agent 提需求，它判断适合时会自动派给 dsh，并在派发和完成时给出醒目提示（任务名、模型、思考档、权限、任务单链接、耗时）。

想手动控制时直接说：

| 你说 | 效果 |
|---|---|
| 「交给 dsh 做：<任务>」 | 任务再小也委派 |
| 「拆成几个独立任务并行派给 dsh」 | 划清文件范围后并行派发 |
| 「这个你自己做，别派出去」 | 本任务不委派 |
| 「先出方案，我确认后再派」 | 只给方案，等你确认 |
| 「dsh 任务进度怎么样」 | 报告运行中任务的实际状态 |

全部指令说明：Claude 里 `/dsh-delegate-kit help`，Codex 里 `$dsh-delegate-kit help`。没有追加全局规则时，kit 只在你点名时使用。

## 子命令

统一写法：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\kit.ps1" <子命令> [参数]
```

| 子命令 | 作用 | 关键参数 |
|---|---|---|
| `help` | 详细指令说明：怎么下指令、常用说法、每个子命令和派发参数、返回状态、文件位置（内容见 `docs\HELP.md`） | `-Json` |
| `setup` | 两段式初始化：先出候选，再生成补丁和状态 | `-Model`、`-Effort`、`-Mode`、`-AcknowledgeFullAccess`、`-InstallPlugins`、`-Json` |
| `check` | 自检：版本、补丁、插件、模型思考档、可选功能；不调模型 | `-Json`、`-UpdateBaseline` |
| `repair` | 重新识别插件 id、重新生成补丁、再自检 | `-InstallPlugins` |
| `status` | 显示当前模型、思考模式、默认权限和可选功能 | 无 |
| `stats` | 按 `index.jsonl` 统计效率 | `-Days <天数>`（不能为负数） |
| `diag` | 生成脱敏诊断包 | 无 |
| `update` | 检查 gitee 上的新版 kit；`-Apply` 时重装到本机所有已安装的副本并自检 | `-Apply`、`-Force` |
| `rules` | 展示或追加全局规则段落 | `-Host claude\|codex`、`-Show`、`-Apply`、`-RulesFile <路径>` |
| `uninstall` | 移除规则段落和 kit 数据 | `-Host claude\|codex\|all`、`-RemoveSkills`、`-PurgeLogs`、`-RulesFile <路径>`、`-ClaudeSkillsDir <目录>`、`-CodexSkillsDir <目录>` |

## 权限

| 权限 | 含义 |
|---|---|
| `read-only` | 只能读取文件，不能修改（适合只读分析） |
| `workspace-write` | 可读写工作目录，不能访问网络或系统目录（推荐） |
| `danger-full-access` | 完全访问：可执行任意命令、读写任意文件、访问网络 |

- 默认不是完全权限；不传 `-Mode` 时 setup 使用 `workspace-write`。
- 选 `danger-full-access` 前，主 Agent 必须明确提示风险：执行者可以读写本机任何文件、运行任何命令；Windows 上沙箱拦不住工作区外的写入，越界只能事后靠 git 核对发现。
- 主 Agent 可以按任务把权限调低（例如只读审查用 `read-only`）；**调高**必须先得到你的明确同意，并加 `-EscalationApproved`，否则脚本直接拒绝。

## 运行限制

- 工作目录必须是本地盘符路径（如 `E:\work\project`）。不支持 UNC 路径（`\\server\share\...`）；需要时先映射为盘符，否则 `dsh-run.ps1` 会在启动前返回 `STATUS: FAILED` 和「cmd 不支持 UNC 工作目录」。
- `-TimeoutMin`（最长执行分钟数，默认 90）至少为 1；`dsh-run.ps1` 会在启动 dsh 前拒绝 0 或负数。
- Windows 上 dsh 的 ACL 沙箱会限制可写位置，进度文件的落盘位置随权限变化，见「文件位置」中的说明。

## 思考等级

- setup 第一段会按当前模型目录列出该模型**实际支持**的档，不会把别的模型的档套过来。配置了 `opencode-go/deepseek-v4.1-flash` 时，通常是 `low`、`high`、`max`。
- 可以**写死某一档**：setup 时选具体档，之后每次派发都用它。
- 也可以选 **auto（由主 Agent 按任务判断）**：主 Agent 在支持的档里按任务性质选择；kit 写入的默认档优先取 `high`，没有 `high` 取 `medium`，再没有就取支持的最后一档。
- 模型思考等级未知时只能使用服务商默认档，不能指定 `-Effort`。
- 模型也可以只写在 profile 的 `config.providers.<provider>.modelOverrides.<id>` 里，这同样会出现在候选列表中；`contextWindow` 和 `input` 取 override 中的值。
- 只被 `agent-default-model` 引用、没有对应服务商插件条目的模型也能配置：kit 沿用 dsh 内置的服务商配置，不向基础补丁写服务商条目，并给出警告（结果里的 `providerEntry` 为 false）。
- profile 里 `reasoningEfforts` 写成 `null`、`{}`、`true` 等非法形式时，按「思考等级未知」处理并给出警告，不会当成能力声明。
- 同一模型出现在多个 profile 时，能力、上下文窗口和输入类型以 **web** 那份为准（没有 web 时用 desktop），不会把不同 profile 的字段拼在一起。
- 给 dsh 传了不支持的档，dsh 会报 `UNSUPPORTED_REASONING_EFFORT`；setup 和 `dsh-run.ps1` 会先校验并拒绝。

## 文件位置

kit 数据默认在 `~\.dsh\dsh-delegate-kit\`，可用环境变量 `DSH_KIT_HOME` 改到其他目录。

| 路径 | 内容 |
|---|---|
| `state.json` | 当前模型、思考档、权限、补丁哈希、插件状态、上次自检结果 |
| `patches\` | `base.yml`、`effort-<档>.yml`、`no-browser.yml`、`computer-use.yml` |
| `logs\` | Claude 侧运行日志和 `index.jsonl` |
| `logs\codex\` | Codex 侧 request/summary/completion 和运行日志 |
| `backups\` | 修改 `CLAUDE.md` / `AGENTS.md` 前的备份 |
| `diag\` | `diag` 生成的诊断目录和 ZIP |

另外还会生成 `spec.json`、`check\`、`rules.json`。kit 不会改动 `~\.dsh\patches`，也不会改动 DSH 桌面端的 desktop profile。

### 进度文件放在哪

Windows 上 dsh 的 ACL 沙箱在 `workspace-write` 下只允许写工作区和会话私有临时目录，`read-only` 下什么都不能写，所以进度文件（`.progress.md`）的位置随权限变化：

| 权限 | 进度文件位置 | 结束后的处理 |
|---|---|---|
| `workspace-write` | `<工作目录>\.dsh-delegate-kit\<时间戳>.progress.md` | 搬回日志目录，删除工作区副本；本次创建且已空的 `.dsh-delegate-kit\` 子目录也删除 |
| `read-only` | 不创建进度文件 | 阶段结论直接写在回复正文里；`index.jsonl` 的 `progress` 为 null |
| `danger-full-access` | `<日志目录>\<时间戳>.progress.md` | 留在日志目录 |

- 工作区里的 `.dsh-delegate-kit\` 只在运行期间存在，git 核对会忽略它；如果外层进程被强杀、脚本来不及收尾，它会留在工作区，可以手动删除。
- `index.jsonl` 的 `progress` 字段指向日志目录中的副本；只读运行没有进度文件。跑到结束的运行（含 `OK`、`TIMEOUT`、`FAILED`）才会写 `index.jsonl`，预检或参数错误提前退出的不记。
- `uninstall`（不传 `-Host`，即 all）会删除 `patches\`、`state.json`、`spec.json`、`check\`、`rules.json`；`logs\` 默认保留，`backups\` 永远保留。

## 兼容性

| dsh 版本 | 测试日期 | 结果 |
|---|---|---|
| `0.2.1-rc.2` | 2026-10-23 | 通过（已测试；具体测试项见 `docs\MAINTENANCE.md` 的回归清单） |

已验证的版本同时写在 `scripts\lib\kit-meta.json` 里。当前 dsh 版本不在列表中时，`check`、`status` 和每次派发的摘要都会给出“未经本 kit 验证”的警告和回退命令；这只是提示，不影响使用。

dsh 升级后，`dsh-run.ps1` 会在派发前做一次轻量预检（版本、补丁哈希、上次 check）；需要时自动运行 `check`。自动 `check` 最多等 120 秒，超时会终止它并返回 `DSH_INCOMPATIBLE`；`base` 补丁缺失或路径为空也按 `DSH_INCOMPATIBLE` 处理，不启动 dsh。不通过时返回 `STATUS: DSH_INCOMPATIBLE`，不会启动 dsh；宿主按 Skill 规则回退到宿主自带方式（Claude Code 用内置子 Agent，Codex 自己做或用 Codex 子代理），并提示你运行 `repair` 修复。某项可选功能不可用时，也会以 `FEATURE: browser` 或 `FEATURE: computerUse` 的形式返回 `DSH_INCOMPATIBLE`，去掉对应参数即可重派。

check 只验证配置、不调用模型，所以 dsh 输出格式的变化要到真正派发时才能发现：dsh 正常退出（exit 0）却识别不到 `turn_end` 等事件时，返回 `DSH_INCOMPATIBLE` 并带 `FORMAT: output`。这时 dsh 很可能已经执行了任务，主 Agent 会先核对工作区再补做剩余部分；这种情况 `repair` 修不了，需要新版 kit。

### dsh 升级后失效怎么办

不需要改任何代码，在对话框里按顺序处理即可：

1. **什么都不做也能用**：派发失败时主 Agent 会自动改用宿主自带方式（Claude Code 用子 Agent，Codex 自己做）完成当前任务，并告诉你原因。
2. **运行 `repair`**（Claude：`/dsh-delegate-kit repair`，Codex：`$dsh-delegate-kit repair`）：插件 id、补丁格式、思考档写法变化这类配置层问题大多能自动修好。提示插件未对齐时，按主 Agent 的提问同意安装即可。提示模型或思考档不再支持时，重新运行 `setup` 选择。
3. **运行 `update`**：repair 修不好，或提示 `FORMAT: output` 时，说明需要新版 kit。`update` 会从 gitee 检查新版并列出更新内容，你确认后自动重装到 Claude 和 Codex 两边并自检；完成后开一个新会话即可。
4. **回退 dsh**：还没有适配的新版 kit 时，把 dsh 装回兼容表里的版本，下次派发会自动自检并恢复：

   ```powershell
   npm i -g @deepseek-ai/dsh@0.2.1-rc.2
   ```

   DSH 桌面端用的也是这个 dsh，等 kit 发布新版后再升级回来。

问题仍未解决时，运行 `diag` 生成诊断包（不含任何 Key），到 [gitee 仓库](https://gitee.com/beilanya/dsh-skills/issues) 提 issue 并附上诊断包。

## 更新 kit

- 推荐：在对话框里说 `/dsh-delegate-kit update`（Codex：`$dsh-delegate-kit update`）。需要本机装有 git；只拉取到 `KIT_HOME\update\` 下的临时目录比对，用完即删，确认后才重装。
- 手动：重新 `git clone`（或在原来的克隆目录里 `git pull`），再在 `dsh-delegate-kit` 目录运行 `install.ps1 -Target both -Force`（只装了一边时换成 `claude` 或 `codex`）。
- 更新只替换 skill 文件，不动 `KIT_HOME` 里的配置和日志，也不需要重新 setup；更新后会自动跑一次 `check`，不通过时自动 `repair`。

## 卸载

在 Claude Code 里说 `/dsh-delegate-kit uninstall`，在 Codex 里说 `$dsh-delegate-kit uninstall`。实际执行：

```powershell
# 不传 -Host 时等价于 -Host all：移除两个宿主的规则段落，并删除 kit 生成的补丁和状态
kit.ps1 uninstall

# 只处理一个宿主：只移除该宿主的规则段落，不清理 kit 的 patches/state/spec/check
kit.ps1 uninstall -Host claude
kit.ps1 uninstall -Host codex

# 可选：同时删除已安装的 skill 文件 / 删除日志
kit.ps1 uninstall -Host all -RemoveSkills -PurgeLogs

# 自定义 skills 根目录；参数名与 install.ps1 相同
kit.ps1 uninstall -Host all -RemoveSkills -ClaudeSkillsDir 'D:\skills' -CodexSkillsDir 'D:\skills-codex'
```

- 只传 `-Host claude` 或 `-Host codex` 时，只移除该宿主的规则段落；补丁、`state.json`、`spec.json`、`check\` 不做清理。`rules.json` 只移除该宿主的记录，若因此为空则删除该文件。
- 不传 `-Host`（即 all）时，先移除两个宿主的规则段落，再删除 `patches\`、`state.json`、`spec.json`、`check\`、`rules.json`；`logs\` 默认保留，`-PurgeLogs` 才删除（含 `logs\codex\`）。
- 规则段落用标记定位，`uninstall` 会原样移除；移除前会备份到 `backups\`。规则文件必须是 UTF-8（带 BOM 也可以）；GBK、UTF-16 等编码会被拒绝并提示先转码，文件不会被修改。
- **清理前会校验 KIT_HOME 归属**：`state.json` 必须可解析、`schemaVersion` 为 1 且有 `kitVersion`，且 `patches` 不能等于 `DSH_HOME\patches`、`KIT_HOME` 不能等于 `DSH_HOME`；不满足时拒绝清理。
- 任一规则段落移除失败（含状态为警告）时，**不做任何清理**并返回 1，`state.json` 和补丁都保留。
- `-RemoveSkills` 只删除带 `.kit-install.json` 的 `dsh-delegate-kit` 目录；可用 `-ClaudeSkillsDir` / `-CodexSkillsDir` 指定根目录（与 `install.ps1` 同名参数对应），也会识别 kit 自身所在的安装目录。
- 如果规则文件是 kit 自己创建的（原文件不存在），移除段落且内容为空后会被删除。
- `backups\` 永远保留。
- 也可以只删 skill 文件：`install.ps1 -Uninstall -Target claude|codex|both`。它不处理 `CLAUDE.md` / `AGENTS.md`，也不删除 `KIT_HOME`。

## 常见问题

**出现 `DSH_UNAVAILABLE` 怎么办？**

表示 dsh 侧不可用：kit 还没 setup、找不到 dsh 或 Node，或者凭证/鉴权/额度有问题（例如 `MISSING_CREDENTIAL`、401/402/403、quota）。先确认 `dsh` 和 `node` 在 PATH 里，再运行 `status` 和 `repair`；凭证问题回到 `dsh web` 的 Models 页面重新配置 Key。

**出现 `DSH_INCOMPATIBLE` 怎么办？**

表示当前 dsh 与 kit 的基线不兼容：dsh 版本变了、补丁缺失或被改坏、模型不再支持所选思考档，或所需可选功能不可用。运行 `repair` 重新生成并自检；如果原因是 `FEATURE: browser` / `FEATURE: computerUse`，也可以去掉对应参数重派。带 `FORMAT: output` 时 repair 无效，按「[dsh 升级后失效怎么办](#dsh-升级后失效怎么办)」运行 `update` 或回退 dsh。

**浏览器不可用怎么办？**

通常是没装 Chrome/Edge，或浏览器插件版本没和 dsh 对齐。运行 `repair` 查看原因；插件未对齐时按主 Agent 展示的命令征得你同意后安装。带 `-Browser` 会直接返回 `FEATURE: browser`，任务不依赖浏览器时去掉该参数即可。

**`diag` 诊断包里会有 Key 吗？**

不会。`diag` 不读取 `.credentials.yaml`，也不复制 `profiles` 目录；`state.json`、日志和错误输出会做脱敏，Key 不会出现在诊断包里。脱敏覆盖：JSON/键值对里的 API Key、token、secret、password 等键（键名两侧允许引号）；URL 查询参数 `key`、`api_key`、`apikey`、`access_token`、`token`；`Authorization` 整段；`Bearer` 令牌；以及 `sk-`、`gsk_`、`AIza`、`ghp_`、`github_pat_`、`xoxb-`、`xoxp-`、`AKIA` 等常见前缀。

**规则文件不是 UTF-8 怎么办？**

`rules -Apply` 和 `uninstall` 会按字节检查编码，只接受 UTF-8（带 BOM 也可以）。GBK 或 UTF-16（带 BOM 的 UTF-16LE/BE）会被拒绝并提示先转码，原文件不会被修改。转成 UTF-8 后重试即可。

**Codex 收不到回调怎么办？**

先看 `<taskId>.completion.json` 的 `callback.status`。取不到 thread id 时不要猜，显式传 `-NotifyThreadId <id>`；确实不需要回调时用 `-NoNotify`。回调消息会压成单行（换行改成 ` | `），避免 `cmd` 截断；thread id 只允许 `A-Za-z0-9._:-`。后台 worker 启动后 3 秒内退出且没有生成 completion 时，dispatch 会返回 `STATUS: FAILED`（exit 2）并写失败结果。
