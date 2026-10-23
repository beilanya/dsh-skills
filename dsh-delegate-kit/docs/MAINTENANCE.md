# dsh-delegate-kit 维护手册

本文件说明这个包的组成、运行时数据、已核实的关键事实、兼容与升级机制、排障步骤和回归清单。改动脚本或 dsh 升级后，先读本文件，再按第 6 节回归。

当前版本：`0.2.0`（2026-10-23）。

## 1. 组成文件

包内文件与安装后的关系：`install.ps1` 把 `claude\SKILL.md` 或 `codex\SKILL.md` 安装为 `<skill目录>\SKILL.md`，同时复制 `scripts\`、`templates\`、`docs\MAINTENANCE.md`、`README.md`，并写入 `.kit-install.json` 作为安装标记。

| 文件 | 作用 | 编码 |
|---|---|---|
| `README.md` | 面向第一次安装的用户：前置条件、安装、setup、子命令、权限、兼容性、卸载、常见问题 | UTF-8 无 BOM |
| `install.ps1` | 安装、覆盖、`-WhatIf` 预览、`-Uninstall` 卸载、`-Interactive` 菜单模式；只操作叶子名为 `dsh-delegate-kit` 的目录 | UTF-8 **带 BOM** |
| `install.cmd` | 双击安装入口，只调用 `install.ps1 -Interactive`；内容保持纯 ASCII（`chcp 65001` 后 `set /p` 读不到输入，所以中文提示都放在 PowerShell 里） | ASCII，CRLF |
| `claude\SKILL.md` | Claude Code 侧的 setup/派发/审核/续接流程和提示格式 | UTF-8 无 BOM |
| `codex\SKILL.md` | Codex 侧的 setup/dispatch/回调/审核/续接流程 | UTF-8 无 BOM |
| `scripts\kit.ps1` | 子命令入口：setup、check、repair、status、stats、diag、rules、uninstall、update、help | UTF-8 **带 BOM** |
| `scripts\dsh-run.ps1` | 执行器：预检、拼补丁、启动 `dsh headless --json`、解析事件、写摘要和 index；自包含，不 dot-source `common.ps1` | UTF-8 **带 BOM** |
| `scripts\dsh-dispatch.ps1` | Codex 专用：隐藏启动独立 worker，worker 调 `dsh-run.ps1`，完成后用 `codex queue` 回调 | UTF-8 **带 BOM** |
| `scripts\uia.ps1` | UIA 辅助脚本：按元素名称读取、点击、输入、等待，供电脑操作任务使用 | UTF-8 **带 BOM** |
| `scripts\lib\common.ps1` | kit 共用函数：路径、state、定位 dsh/node、UTF-8/BOM、调用 helper、Chrome/Edge 探测、插件状态 | UTF-8 **带 BOM** |
| `scripts\lib\setup.ps1` | setup、check、repair、status 的实现 | UTF-8 **带 BOM** |
| `scripts\lib\maint.ps1` | stats、diag、rules、uninstall、update 的实现 | UTF-8 **带 BOM** |
| `scripts\lib\kit-meta.json` | 包元数据：`testedDshVersions`（已验证的 dsh 版本）、`recommendedDshVersion`（回退建议）、`updateSource` / `updateBranch` / `packagePath`（update 的拉取来源） | UTF-8 无 BOM |
| `scripts\lib\dshkit.mjs` | Node 助手：解析 profile/dump YAML、查 pi-ai 模型目录、生成补丁；stdout 只输出一个 JSON | UTF-8 无 BOM |
| `templates\rules-claude.md` | 追加到 `~\.claude\CLAUDE.md` 的规则模板，`{{DATE}}`、`{{MODEL}}`、`{{EFFORT_DESC}}`、`{{MODE}}` 由脚本替换 | UTF-8 无 BOM |
| `templates\rules-codex.md` | 追加到 `$CODEX_HOME\AGENTS.md`（未设置时 `~\.codex\AGENTS.md`）的规则模板 | UTF-8 无 BOM |
| `docs\MAINTENANCE.md` | 本维护手册 | UTF-8 无 BOM |

编码规则（都是实际踩过的坑）：

- 所有 `.ps1` 存成 UTF-8 **带 BOM**；`.yml`、`.json`、`.mjs`、`.md` 不带 BOM。包内没有 `.yml`/`.json` 源文件；运行时生成的补丁 `.yml` 和 `state.json` 等 `.json` 一律无 BOM。
- 生成的补丁 `.yml`、`state.json`、日志不带 BOM；补丁用 LF。
- 读写文本用 `[IO.File]::ReadAllText/WriteAllText(path, text, (New-Object System.Text.UTF8Encoding($false)))`，不要用 `Get-Content` / `Set-Content` / `Out-File`（Windows PowerShell 5.1 默认 ANSI，会损坏中文）。
- 规则文件是用户已有的 `CLAUDE.md` / `AGENTS.md`：脚本保留原文件的 BOM 和换行风格，只追加带 begin/end 标记的段落。
- 规则文件必须是 UTF-8（可带 BOM）。`Test-KitUtf8TextFile` 按字节检测：UTF-16 BOM 或严格 UTF-8 解码失败即拒绝，`rules -Apply` 和 `uninstall` 都在写盘前返回，提示「规则文件不是 UTF-8 编码，请先转成 UTF-8 再运行」，原文件字节不变。

## 2. 运行时数据

`KIT_HOME` = `$env:DSH_KIT_HOME`；未设置时是 `<DSH_HOME>\dsh-delegate-kit`，`DSH_HOME` 未设置时是 `~\.dsh`。

| 路径 | 内容 |
|---|---|
| `state.json` | 当前配置和上次自检结果，setup/repair/check 写 |
| `spec.json` | 生成补丁用的中间文件（来源 profile、provider/model、efforts、defaultEffort、browserAvailable、chromePath、pluginIds） |
| `patches\base.yml` | 第 1 层：启用凭证插件、所选模型的服务商配置、默认模型、压缩参数（适用时）、浏览器插入（可用时） |
| `patches\effort-<档>.yml` | 第 2 层：每个不等于默认档的受支持档各一个，写完整的 `agent-default-model` 配置 |
| `patches\no-browser.yml` | 第 3 层：只把两个浏览器插件设为 `disabled: true`，不写 config |
| `patches\computer-use.yml` | 第 4 层：插入 computer-use 和 cua-driver 原生驱动 |
| `check\` | `check`/`repair` 产生的 dump 和解析中间文件 |
| `logs\` | Claude 侧默认日志目录；每次运行的任务、事件流、错误、progress（最终副本）、运行标记，以及 `index.jsonl` |
| `logs\codex\` | Codex 侧默认日志目录；request/summary/completion/worker 日志和 runner 产物 |
| `<工作目录>\.dsh-delegate-kit\` | 仅 `workspace-write` 运行期间存在：`<stamp>.progress.md`；结束后搬回 `logs\` 并删除，本次创建的空目录也删除。被强杀时可能残留，可手动删除；git 核对忽略该路径 |
| `backups\` | 追加或移除规则前的备份；`uninstall` 永远保留 |
| `diag\` | `diag-<时间戳>\` 目录和 `diag-<时间戳>.zip` |
| `rules.json` | 记录每个宿主规则文件的路径、备份路径、追加前后 sha256 和 `createdByKit` |

`uninstall`（不传 `-Host`，即 all）会删除 `patches\`、`state.json`、`rules.json`、`spec.json`、`check\`；`logs\` 只在 `-PurgeLogs` 时删除；`backups\` 始终保留。只传 `-Host claude|codex` 时只移除该宿主的规则段落，`patches\`、`state.json`、`spec.json`、`check\` 都不删；`rules.json` 会移除该宿主的记录，记录为空时删除文件。

`-RemoveSkills` 只删除带 `.kit-install.json` 的 `dsh-delegate-kit` 目录；可用 `-ClaudeSkillsDir` / `-CodexSkillsDir` 指定 skills 根目录（与 `install.ps1` 同名参数），也会把 kit 自身所在且 host 匹配的安装目录作为候选。规则文件原本不存在、由 kit 创建时，移除段落后内容为空会删除该文件。任一规则段落移除失败（warn/failed）时跳过全部清理并返回 1。

### state.json 主要字段

| 字段 | 含义 |
|---|---|
| `schemaVersion` | 状态结构版本，当前为 1 |
| `kitVersion` | 最近一次 setup 或通过的 `check -UpdateBaseline` 所用的 kit 版本，当前 `0.2.0` |
| `createdAt` / `updatedAt` | 创建/最后更新时间（ISO 8601） |
| `dshHome` | 使用的 DSH_HOME |
| `dshVersion` | 基线 dsh 版本；派发前预检用它比对 |
| `dshPackageDir` | 已安装 dsh 包目录 |
| `nodeVersion` | 定位到的 Node 版本 |
| `model` | `provider`、`id`、`name`、`plugin`、`pluginName`、`source`、`contextWindow`、`input`、`vision`、`efforts`、`effortsKnown`、`capabilitySource`、`providerEntry`（false 表示沿用 dsh 内置服务商配置，base 里没有服务商插件条目） |
| `effortMode` | `fixed`（写死某一档）或 `auto`（主 Agent 按任务判断） |
| `defaultEffort` | 写进基础补丁的档；思考等级未知时为 `null`，不写 `reasoningEffort` |
| `mode` | `read-only`、`workspace-write`、`danger-full-access` |
| `patches` | `base`、`effort.<档>`、`noBrowser`、`computerUse`，每项含 `path` 和 `sha256` |
| `plugins` | `aligned`、`expected`、`installed`、`misaligned`、`browserOk`、`computerOk`、`command` |
| `pluginIds` | 7 个插件条目的 `id`/`name`：credentials、agentDefaultModel、compaction、browserUse、browserProvider、computerUse、computerProvider；repair 重新识别后写回 |
| `features` | `browser`（available/reason/chromePath）、`computerUse`（available/reason）、`compaction`（available/applied/thresholdRatio/retainTokens/reason） |
| `lastCheck` | `at`、`ok`、`dshVersion`；`ok` 不是 true 会触发下次派发前自动 check |

### 补丁叠加顺序

`base` → `effort-<档>` → `no-browser` → `computer-use`。

- `base.yml` 只在浏览器可用时插入浏览器插件；`no-browser.yml` 无论浏览器是否可用都会生成。
- `effort-<档>.yml` 只在请求档不等于 `defaultEffort` 时叠加；必须写完整的 provider/model/reasoningEffort，因为同 id 插件的 `config` 是整体替换。
- `computer-use.yml` 只在带 `-ComputerUse` 时叠加；`no-browser.yml` 默认叠加，带 `-Browser` 时不叠加。

### 日志与 index

一次 Claude 侧运行默认产生：

```text
<prefix>.task.md      实际送入 dsh 的任务文本（含自动追加的运行约定）
<prefix>.jsonl        dsh --json 事件流
<prefix>.err.log      stderr
<prefix>.progress.md  dsh 按约定追加的阶段结论
<prefix>.running      运行标记（pid、childPid、deadline、sessionId、日志路径）
<prefix>.extend       延时请求（1-120 分钟）
```

进度文件按实际权限落盘（`dsh-run.ps1` 的 `$effectiveMode`）：

- `danger-full-access`：直接写 `<prefix>.progress.md`（日志目录）。
- `workspace-write`：写 `<Cwd>\.dsh-delegate-kit\<stamp>.progress.md`，`.running` 的 `progress` 指向它；dsh 结束（含超时/失败）后在 `finally` 里 `Complete-ProgressFile` 搬回 `<prefix>.progress.md`、删除工作区副本，工作区子目录空且是本次创建时一并删除。摘要、挽救提示和 index 都使用 logs 副本。
- `read-only`：不创建任何进度文件，`.running` 的 `progress` 为 null，`index.progress` 为 null；运行约定改为「阶段结论写进回复正文」。
- git 范围核对用 `Test-GitStatusPathIgnored` 忽略 `.dsh-delegate-kit/` 行；外层进程被强杀时工作区进度目录可能残留，需手动删除。

Codex 侧另外有：

```text
<taskId>.request.json     冻结参数的请求
<taskId>.task.md          冻结的任务
<taskId>.summary.txt      完整摘要
<taskId>.completion.json  结果、回调状态和各类路径
<taskId>.worker.log       worker 日志
<taskId>.running          dispatcher/worker 标记
<taskId>.run.*            runner 的 task/jsonl/err/progress/running/extend/runner.out/runner.err
```

`completion.json` 和 `summary.txt` 的 `mode` 在请求未指定时从 runner 输出的「模式: ...」补齐；只有 `TIMEOUT` / `FAILED` 会在 summary 里追加 SessionId 挽救提示，其他非 OK 状态保留 progress 尾部。

`index.jsonl` 每次运行结束追加一行（`logs\index.jsonl` 和 `logs\codex\index.jsonl` 各一份），用按日志路径派生的命名互斥锁串行追加；主要字段：
`label`、`status`、`sessionId`、`cwd`、`mode`、`effort`、`browser`、`computerUse`、`lockWaitSec`、`elapsedSec`、`steps`、`toolCalls`、`toolErrors`、`inTok`、`outTok`、`cacheTok`、`thinkChars`、`startedAt`、`endedAt`、`exit`、`turnEnd`、`extendedMin`、`newGitEntries`、`log`、`progress`、`host`、`model`、`kitVersion`；另外还写 `task`、`jsonl`、`errLog`、`extend`、`finalPresent`、`inputTokens`、`outputTokens`、`cacheReadTokens`，启动失败时写 `startFailure`。

电脑操作使用系统级互斥锁 `Global\dsh-delegate-computer-use`；等锁时间记入 `lockWaitSec`，等锁超时也会写一条 `TIMEOUT` 记录。

`stats -Days` 为负数时直接返回参数错误（exit 2），不读取 `index.jsonl`；`-Days 0` 表示不按天数过滤。

## 3. 关键事实

### 模型配置和 Key

- `dsh web` 的 Models 页面把模型配置写进 `~\.dsh\profiles\web\cordis.patch.yml`。
- DSH 桌面端的配置写进 `~\.dsh\profiles\desktop\cordis.patch.yml`。
- headless profile（`~\.dsh\profiles\headless`）默认为空，**不继承** web/desktop 的模型配置，所以 kit 从 web 或 desktop 的 profile 读取所选 provider/model，再生成 headless 用的补丁。
- API Key 存在 `$DSH_HOME\.credentials.yaml`，所有 profile 共用。headless 默认禁用凭证插件；基础补丁必须把 `@deepseek-ai/dsh-credentials-local` 重新设为 `disabled: false`，否则报 `MISSING_CREDENTIAL`。
- kit 不读取、不打印、不复制 `.credentials.yaml`；`diag` 也不复制 profiles 目录。

### 模型收集

- pi-ai 模型来自 `config.providers.<provider>.models[]`，也来自 `config.providers.<provider>.modelOverrides.<id>`；后者的 `contextWindow`、`input` 优先用于该模型，能力仍按 pi-ai 目录判定。
- `agent-default-model` 指向的模型即使没有对应的服务商插件条目，也会加入候选；`gen-patches` 会省略服务商条目（沿用 dsh 内置配置），返回 `providerEntry: false` 和 `warnings`。setup 把该 warning 并入 `Result.warnings`，并把 `providerEntry` 写进 `state.model`；check 在 `providerEntry=false` 时只要求 credentials 和 `agent-default-model`。
- 同一模型出现在多个 profile 时，能力、`contextWindow`、`input` 取**单个**主来源条目：`web > desktop > sources[0]`（与 setup 选 sourceProfile 的规则一致），不跨 profile 拼字段。
- profile 条目里的 `reasoningEfforts` 只接受 `false` 或非空对象；`null`、`{}`、`true`、数组等非法写法按「思考等级未知」处理（`efforts=null`、`effortsKnown=false`、`capabilitySource=profile-fallback`）并给 warning。

### 沙箱与进度文件

- Windows 上 dsh 的 ACL 沙箱在 `workspace-write` 下只允许写工作区和会话私有临时目录，`read-only` 下什么都不能写，`danger-full-access` 才能写日志目录。
- 因此进度文件：`workspace-write` 写 `<Cwd>\.dsh-delegate-kit\<stamp>.progress.md`，结束后搬回日志目录并清理（空且本次创建的子目录删除）；`read-only` 不写进度文件，阶段结论在回复里；`danger-full-access` 写日志目录。
- 工作区进度目录会被 git 范围核对忽略；外层被强杀时可能残留，可手动删除。

### 插件配置叠加

- 同 id 插件的 `config` 是**整体替换**，不是逐字段合并。只写 `reasoningEffort` 会把 `provider`/`model` 弄丢，所以 effort 补丁必须写完整配置。
- 只写 `disabled: true` 而不写 `config` 时，原 `config` 保留；`no-browser.yml` 就是利用这一点。
- 插件 id/name 以 `pluginIds` 为准，repair 会用 dump 重新识别；默认值见 `common.ps1` 和 `dshkit.mjs` 的 `DEFAULT_PLUGIN_IDS`。

### 思考档

- 能否思考、支持哪些档，按 pi-ai 模型目录 `<dsh包>\node_modules\@earendil-works\pi-ai\dist\models.generated.js` 判定；找不到时用 `createRequire` 从 dsh 包解析。不能写死路径。
- 目录条目 `reasoning` 为 false 时只支持 `off`。否则按 `THINKING_LEVELS = off/minimal/low/medium/high/xhigh/max` 检查 `thinkingLevelMap[level]`：值为 `null` 不支持；`xhigh`/`max` 必须在 map 里显式声明才支持；其余档缺省即支持。
- profile 条目自带合法的 `reasoningEfforts` 时以它为准：`false` 只支持 `off`；非空对象里声明了的档才支持。`capabilitySource` 记为 `profile-declared`；`null`、`{}`、`true` 等非法写法按「模型收集」一节的规则当作未知。
- 给用户选的档 = 支持的档去掉 `off`。不同模型支持的档不同；传不支持的档，dsh 报 `UNSUPPORTED_REASONING_EFFORT`，kit 在 setup/派发前会先拒绝。
- 目录查不到时 `effortsKnown=false`、`capabilitySource=profile-fallback`，不能指定 `-Effort`。

### 压缩

- 压缩由 `@deepseek-ai/dsh-compaction-basic` 负责：触发阈值 = `min(thresholdRatio × contextWindow, 压力预算)`。
- 阈值比较的是会话内容的估算 token，**不含**约 1.2 万的系统提示和工具定义。
- kit 取 `thresholdRatio = 200000 / contextWindow`；若大于 `0.8`（窗口小于 25 万）则不写压缩条目，保持默认。`retainTokens` 默认 `60000`，且必须小于阈值预算，否则取 `floor(阈值 token × 0.3)`。
- 大工具结果另由 `tool-result-pruner` 截断：单次工具输出超过 8192 字符会被截断。
- 不挂浏览器的首步上下文约从 1.21 万降到 0.74 万 token；这是默认叠加 `no-browser.yml` 的依据。

### 配置、插件与 CLI

- desktop profile 由 Electron 独占，命令行改不了；只能读它的 `cordis.patch.yml` 作为模型来源。
- 插件版本必须与全局 dsh 一致；安装时显式写 `包名@版本`。pnpm 的发布冷却期可能把不带版本的安装静默降级到旧版本。
- kit 对齐插件时使用的命令形如：
  `dsh plugin --profile headless add @deepseek-ai/dsh-browser-use@<版本> @deepseek-ai/dsh-experimental-browser-use-playwright-mcp@<版本> @deepseek-ai/dsh-computer-use@<版本> @deepseek-ai/dsh-experimental-computer-use-cua-driver-native@<版本>`
- `dsh headless` 的 `--patch` 必须在 `--json` / `--dump-config` 前面，否则报 unknown option。
- `dshkit.mjs` 的 YAML 使用 `JSON_SCHEMA` 加自定义 `!!js` 类型：日期样式字符串不会被转成时间戳，`!!js` 标签能原样往返。
- headless `--json` 事件类型包括：`session`、`tool_call`、`tool_result`、`thinking`、`text`、`status`（`turn_start` / `step_start` / `step_end`，`step_end` 带 `usage`）、`final`、`error`。`dsh-run.ps1` 只把 `exit=0` + `turn_end=completed` + 非空 `final` 判为 `OK`。
- 权限由环境变量 `DSH_PERMISSION_MODE` 传给 dsh；`dsh-run.ps1` 在启动子进程前设置，启动后恢复原值。

### diag 脱敏

`ConvertTo-KitRedacted` 对 `state.json`、日志和错误输出做文本脱敏，覆盖：

- JSON/键值对中键名含 `api_key`、`apikey`、`access_token`、`token`、`secret`、`password` 的条目；键名两侧允许引号，值截至引号/空白/逗号/右括号，无引号的值补双引号以保持 JSON 合法。
- URL 查询参数 `key`、`api_key`、`apikey`、`access_token`、`token`。
- `Authorization` 整段替换，再处理 `Bearer <token>`；只替换令牌本身，保留两侧引号/括号。
- 常见令牌前缀：`sk-`、`gsk_`、`AIza`、`ghp_`、`github_pat_`、`xoxb-`、`xoxp-`、`AKIA`。

### Windows PowerShell 5.1 的坑

- `.ps1` 必须带 BOM，否则中文和部分字符会被错误解析。
- 双引号 here-string 里不要用中文弯引号 “ ”，会被当成字符串定界符；统一用「」。
- `Get-Content` / `Set-Content` / `Out-File` 在 5.1 默认 ANSI，读写中文要用 `[IO.File]`。
- 函数里给人看的提示用 `[Console]::Out.WriteLine` 或写 stderr，不要用 `Write-Output`，否则会混进返回值。
- `$Host` 是 PowerShell 自动变量，不能当参数名；脚本用 `HostName` 参数加 `[Alias('Host')]`。

### 确认压缩是否触发

headless 的插件日志不写 stderr，需要看会话文件：

`~\.dsh\sessions\<cwd编码>\<sessionId>\session.v4.jsonl.zstd`

该文件由多个 zstd 帧拼接。按魔数 `28 B5 2F FD` 切开，逐帧解压，统计 `compaction/start` 的数量。Node 24 自带 `zlib.zstdDecompressSync`，可以用下面的脚本（UTF-8 无 BOM 保存）：

```js
const fs = require('fs');
const zlib = require('zlib');
const buf = fs.readFileSync(process.argv[2]);
const magic = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const starts = [];
let i = 0;
while ((i = buf.indexOf(magic, i)) !== -1) { starts.push(i); i += 4; }
let text = '';
for (let n = 0; n < starts.length; n++) {
  const end = n + 1 < starts.length ? starts[n + 1] : buf.length;
  text += zlib.zstdDecompressSync(buf.subarray(starts[n], end)).toString('utf8');
}
console.log((text.match(/compaction\/start/g) || []).length);
```

### UIA 脚本的三条要点

- .NET 自带的托管 UIA 不会给 Win32/WinForms 控件套代理，这类控件一律显示为 `Pane`、没有 Invoke/Value 模式。`uia.ps1` 按窗口类名还原类型，并改用 `BM_CLICK` / `WM_SETTEXT` 消息操作；Electron、WPF、WinUI 自带 UIA 支持，不受影响。
- Chromium/Electron 窗口第一次被 UIA 访问时才构建页面无障碍树，第一次读通常只拿到窗口框架上的 3 个按钮；`uia.ps1` 会等页面出现 `Document` 元素后再读（最多重试 3 次）。
- 脚本在调用 UIA 前先声明 DPI 感知，否则高缩放下坐标和元素位置会错。

## 4. 兼容与升级机制

### 派发前预检

`dsh-run.ps1` 启动 dsh 前做轻量检查：

1. 读 `state.json`；不存在、dsh/node 找不到 → `DSH_UNAVAILABLE`，exit 3。
2. 运行前先做输入校验：`-Cwd` 以 `\\` 开头（UNC）→ `FAILED` exit 2，提示先映射盘符；`-TimeoutMin` 小于 1 → `FAILED` exit 2；任务单不存在或读取失败 → `FAILED` exit 2。
3. 定位 dsh 包目录时优先用当前命令解析出的 `<base>\node_modules\@deepseek-ai\dsh`，`state.dshPackageDir` 只作后备；后续 check 也使用同一实际目录。
4. 当前 dsh 版本与 `state.dshVersion` 不一致，或任一补丁文件缺失/sha256 不符，或 `state.lastCheck.ok` 不是 true → 需要 check。
5. 需要时自动运行：
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<同目录>\kit.ps1" check -Json -UpdateBaseline`
   stdout/stderr 并发读取；最多等 120 秒，超时用 `taskkill /T /F` 终止 check 进程树并返回「自动 check 超时」。
6. check 返回的 JSON `ok` 不是 true，或没有输出可用 JSON → `DSH_INCOMPATIBLE`，逐条输出 reasons，exit 5，不启动 dsh。
7. `state.patches.base` 缺失或路径为空 → `DSH_INCOMPATIBLE`，exit 5。
8. 可选功能门槛不满足（`-Browser` / `-ComputerUse` 但对应 `features.*.available` 不是 true）→ `DSH_INCOMPATIBLE`，输出 `FEATURE: browser` 或 `FEATURE: computerUse`，exit 5。
9. 思考档、权限不合法 → `FAILED`，参数错误 exit 2。
10. 等电脑操作锁时出现非 `AbandonedMutexException` 的异常 → `FAILED` exit 1，清理 `.running`、工作区进度目录并释放互斥锁，不误报 `TIMEOUT`。
11. 运行后 git 快照取不到时，摘要提示无法取得运行后快照，`index.newGitEntries` 写 null。预检或参数错误提前退出的运行不写 `index.jsonl`。
12. 当前 dsh 版本不在 `kit-meta.json` 的 `testedDshVersions` 里时，摘要加一条“未经本 kit 验证”警告（含回退命令），不影响派发。

### 运行后的状态判定

`Resolve-RunStatus` 按顺序判定：超时 → `TIMEOUT`；启动失败 → `FAILED`；exit 0 且 `turn_end` 的 `reason.kind=completed` 且有 `final` → `OK`；stderr/错误事件匹配凭证、鉴权、额度关键词 → `DSH_UNAVAILABLE`；exit 0 但一个已知事件都没识别到、或识别不到 `turn_end` → `DSH_INCOMPATIBLE` 并输出 `FORMAT: output`；其余 → `FAILED`。

`FORMAT: output` 说明 dsh 的 `--json` 事件格式变了（check 不调模型，发现不了这类变化）。dsh 很可能已经执行了任务，主 Agent 应先核对工作区再补做。修复方法是按新格式更新 `Read-DshEvents`，回归后发新版 kit。OK 但没识别到任何 `step_end` 时，摘要会警告统计可能不准，也是格式变化的信号。

### setup 的输入校验与写盘

- setup 的 `-Effort` / `-Mode` 用大小写敏感比较（`-cnotcontains` / `-ceq`），只接受规范小写值；`High`、`WORKSPACE-WRITE` 等写法返回参数错误（exit 2），保证写进 state 和补丁的都是规范值。dsh-run 的 `-Effort` / `-Mode` 则先 `ToLowerInvariant()` 再校验和提权判断，日志与 `DSH_PERMISSION_MODE` 里都是小写。
- 只带 `-Effort`、`-Mode`、`-InstallPlugins`、`-AcknowledgeFullAccess` 之一但没有 `-Model` 时直接返回错误和正确用法，不会进入配置流程。
- `dshkit.mjs gen-patches` 先在临时目录生成补丁；成功后才复制进 `patches\` 并写 `state.json`。生成失败时删除临时目录，旧补丁、`spec.json`、`state.json` 保持不变。
- `gen-patches` 返回的 `providerEntry` 和 `warnings` 会写入 `state.model` / `Result.warnings`；`providerEntry=false` 表示沿用 dsh 内置服务商配置。
- setup 第二段、check、repair 写 state 时共用命名互斥锁，避免两个 dsh-run 同时自动 check 互相覆盖。

### check 检查什么

- dsh 和 node 是否存在。
- 所有补丁文件是否存在、是否带 BOM；sha256 不符只记 warning，仍继续验证内容。
- `base.yml` 能否被 `dsh headless --patch ... --dump-config` 解析。
- 凭证插件是否存在且 `disabled` 不是 true。
- 服务商插件条目是否含所选 provider/model；pi-ai 服务商同时接受 `providers.<p>.models[].id` 和 `providers.<p>.modelOverrides` 的键。
- `state.model.providerEntry=false` 时不要求 base 里有服务商插件条目（沿用 dsh 内置配置），但仍校验凭证和 `agent-default-model`。
- `agent-default-model` 的 provider/model/reasoningEffort 是否与 state 一致，`disabled` 不能是 true。
- 每个 `effort-<档>.yml` 单独叠加后，`reasoningEffort` 是否为目标档。
- `no-browser.yml` 是否把两个浏览器插件都设为 disabled。
- `computer-use.yml` 是否插入两个电脑操作插件。
- 模型目录里是否仍支持默认档和所有 effort 档；`capabilitySource=profile-declared` 时重新调用 dshkit models 取该模型当前 efforts 校验，查不到该模型则 `ok=false`。
- 浏览器、电脑操作、压缩功能是否可用，并把结果写回 `state.features` 和 `state.lastCheck`。
- `-UpdateBaseline` 且检查通过时，把当前 dsh 版本、`dshPackageDir`、`nodeVersion` 和插件状态写回 state。
- 写 state 时使用命名互斥锁（`Local\dsh-delegate-kit-state-<KIT_HOME 小写全路径 SHA256 前 16 位>`，最多等 120 秒），setup 第二段/check/repair 串行，避免互相覆盖。

`-Json` 输出对象包含 `ok`、`dshVersion`、`baselineVersion`、`reasons`、`warnings`、`features`、`required`、`updatedBaseline`。

### repair 做什么

- 没有 state 时 exit 2，提示先 setup。
- 检查可选插件是否与 dsh 版本对齐；只有带 `-InstallPlugins` 才执行安装，否则只输出命令。
- 用 dump 重新识别插件 id/name；base 补丁无法叠加时退回原始配置树识别。
- 重新查询模型目录，更新 efforts/contextWindow/input/vision。
- 固定档模型升级后不再支持该档时停止，并要求重新 setup 选档。
- auto 模式重新选择默认档（`high` → `medium` → 支持的最后一档）。
- 使用当前实际 dsh 安装目录，重新生成补丁、更新 state（写 state 同样加互斥锁），再跑 `check -UpdateBaseline`。

### update 做什么

- 需要 git。从 `kit-meta.json` 的 `updateSource`（可用环境变量 `DSH_KIT_UPDATE_SOURCE` 覆盖，测试时指向本地仓库）浅克隆 `updateBranch` 到 `KIT_HOME\update\<时间戳>`，结束时删除。
- 从新包 `install.ps1` 读版本号，与当前包版本比较；更新内容取新包本文件第 7 节里比当前版本新的条目。
- 已安装副本：对 claude、codex 分别按 `Get-KitSkillTarget` 的规则（参数 → `DSH_KIT_CLAUDE_SKILLS_DIR` / `DSH_KIT_CODEX_SKILLS_DIR` → kit 自身目录 → 默认目录）找目录，带有效 `.kit-install.json` 且 host 匹配的才算。
- 不带 `-Apply` 只报告；带 `-Apply` 时对每个副本运行新包的 `install.ps1 -Target <host> -<Host>SkillsDir <根目录> -Force`，然后用新装的 `kit.ps1` 跑 `check -Json -UpdateBaseline`，不通过再跑 `repair`。没有 state 时跳过自检。
- 不动 `KIT_HOME` 里的配置和日志；新 SKILL.md 需要宿主开新会话才会加载。

### 发布新版本（维护者）

1. dsh 发布新版后，在本机升级 dsh，按第 6 节回归。
2. 需要改代码时修改并回归；无论是否改代码，把验证通过的 dsh 版本加入 `kit-meta.json` 的 `testedDshVersions`，必要时更新 `recommendedDshVersion`，同时更新 README 的兼容表。
3. 改了代码就同时改 `install.ps1` 和 `scripts\lib\common.ps1` 里的 `$script:KitVersion`，在第 7 节加一行变更记录（格式 `- x.y.z（日期）：说明`，update 靠它展示更新内容）。
4. 推送到 gitee 的 `main` 分支，用户运行 `update` 即可拿到。

### 功能分级

| 级别 | 内容 | 缺失时 |
|---|---|---|
| 必需 | 凭证插件、所选模型服务商配置、默认模型 | 对应 `check` 不通过；报 `MISSING_CREDENTIAL` 或模型配置错误 |
| 可选 | 浏览器、电脑操作 | 对应 `features.*.available=false`；带参数派发返回 `FEATURE: ...` |
| 可选调优 | 压缩参数 | 不写压缩条目，使用 dsh 默认值；不影响派发 |

### 安装路径校验

`install.ps1` 在动磁盘前校验所有目标：

- 多个 host 解析到同一目标目录（规范化后忽略大小写比较）→ 报错并 exit 1，不进入安装。
- `Assert-SafeTarget` 先用 `Resolve-RealPath` 逐级解析目标与包源的真实路径（跟随 junction/symlink，处理相对目标和 `\\?\` 前缀），再做叶子名与重叠检查；目标经联接点解析后与包源重叠、路径组件是文件、层级过深或无法解析时一律拒绝，exit 1。
- 安装仍使用原字面目标路径，解析只用于校验。

## 5. 故障排查

### `DSH_UNAVAILABLE`

可能原因：未 setup、`state.json` 不存在或损坏、找不到 `dsh` / `node`、`MISSING_CREDENTIAL`、401/402/403、quota/balance/subscription 等认证或额度错误。

处理：

1. `dsh --version`、`node --version`，确认命令在 PATH 中。
2. 运行 `kit.ps1 status`；未初始化就重新 `setup`。
3. 凭证/额度问题到 `dsh web` 的 Models 页面重新配置 Key；不要读取或手改 `.credentials.yaml`。
4. 仍失败时运行 `repair`，并查看 `%TEMP%` 或日志里的 `.err.log` 末尾。

### `DSH_INCOMPATIBLE`

可能原因：dsh 升级后版本与基线不一致、补丁缺失/被改坏、模型不再支持所选档、浏览器/电脑操作功能不可用。

处理：

1. 看返回的 reasons（或 `kit.ps1 check` 的输出）。
2. 运行 `kit.ps1 repair`；需要安装插件时由用户确认后加 `-InstallPlugins`。
3. 原因是 `FEATURE: browser` 或 `FEATURE: computerUse` 时，任务不依赖该功能就去掉对应参数重派。
4. 模型档位不再支持时，重新 `setup` 选档。
5. 带 `FORMAT: output` 时 repair 无效：用户侧运行 `update` 或回退 dsh；维护者侧按「运行后的状态判定」修 `Read-DshEvents`。

### `FEATURE: browser`

可能原因：浏览器插件没和 dsh 对齐，或本机没有 Chrome/Edge。

处理：

1. `kit.ps1 check` 查看 `features.browser.reason`。
2. 运行 `repair`；插件未对齐时按输出命令征得用户同意后安装。
3. 不依赖浏览器时去掉 `-Browser`。去掉后默认叠加 `no-browser.yml`，不会加载浏览器工具。

### 补丁 `failed to parse`

可能原因：补丁带 BOM、编码错误、YAML 语法错误，或文件被手工改坏。

处理：

1. 用 `dsh headless --patch <补丁> --dump-config` 复现，stderr 会指出 `failed to parse overlay <文件>`。
2. 检查文件前 3 字节是否为 BOM；补丁应为 UTF-8 无 BOM。
3. 不手工修生成物；运行 `repair` 重新生成，再 `check`。
4. 若 `state.patches` 指向的文件已不存在，也运行 `repair`。

### 规则文件被拒绝

提示「规则文件不是 UTF-8 编码，请先转成 UTF-8 再运行」时，说明 `CLAUDE.md` / `AGENTS.md` 是 GBK 或 UTF-16 等编码。`rules -Apply` 和 `uninstall` 都在写盘前退出，文件未被修改。把规则文件转成 UTF-8（带 BOM 也可以）后重试。

规则文件本身是联接点/符号链接时，`uninstall` 会拒绝操作（状态 `refused`），链接和目标文件都保留。

### `uninstall` 拒绝清理

`uninstall` 不传 `-Host`（all）时，清理前会校验 KIT_HOME 归属：`state.json` 必须可解析、`schemaVersion=1`、有 `kitVersion`，且 `patches` 不能等于 `DSH_HOME\patches`、`KIT_HOME` 不能等于 `DSH_HOME`。不满足时返回 1 并保留全部数据。先确认 `DSH_KIT_HOME` 指向 kit 自己的目录，不要指向 `DSH_HOME` 或公共 patches 目录。

任一规则段落移除失败（包括只有开始/结束标记中的一侧）时，同样跳过全部清理并返回 1；先修好规则文件再重跑。

### 工作目录是 UNC 路径

`dsh-run.ps1` 会在启动前返回 `STATUS: FAILED` 和「cmd 不支持 UNC 工作目录，请先映射为盘符」。先把 `\\server\share\...` 映射为盘符，再把 `-Cwd` 指向盘符路径。

### 进度文件不见了或落在工作区

- `workspace-write`：运行期间在 `<Cwd>\.dsh-delegate-kit\<stamp>.progress.md`，结束后应搬到 `logs\` 并删除工作区副本；被强杀时可能残留，可手动删除。
- `read-only`：本来就不创建进度文件，阶段结论在回复正文里，`index.progress` 为 null。
- `danger-full-access`：直接写在 `logs\` 下。
- 若 `logs\` 下的 progress 为空，先看 `index.jsonl` 的 `progress` 字段指向哪里，再检查 `.running` 中的 `progress`。

### 认证或额度报错

`MISSING_CREDENTIAL`、`Unauthorized`、401/402/403、`insufficient`、`quota`、`balance`、`subscription`、`payment`、`invalid api key` 等都属于 dsh 侧凭证/额度问题，不是补丁能修的：

1. 打开 `dsh web` 的 Models 页面，检查 provider、模型和 Key。
2. 确认 Key 仍有效、额度足够、模型仍可用。
3. 重新跑 `setup` 或 `repair`，让 `check` 重新确认模型和插件状态。

### Codex 收不到回调

可能原因：没有 `CODEX_THREAD_ID`、找不到 `codex` 命令、`codex queue` 失败或超时、worker 未启动，或 thread id 含非法字符。

处理：

1. 读 `<taskId>.completion.json` 的 `callback.status`（`queued` / `failed` / `unavailable` / `timeout`）和 `callback.error`。
2. 确认 `CODEX_THREAD_ID` 已设置；取不到时不要猜，显式传 `-NotifyThreadId <id>`，或只在确实不需要回调时用 `-NoNotify`。thread id 仅允许 `A-Za-z0-9._:-`，否则 dispatch 在启动前返回 exit 2。
3. 准备日志目录、冻结任务、request 或运行标记任一步失败时，dispatch 返回 `STATUS: FAILED`（exit 2）并清理标记，不会误报 `DISPATCHED`。
4. 确认 `codex` 在 PATH 中；dispatch 会优先找原生 `codex.exe`，npm 安装的 `codex.ps1` 也会映射到同包原生 exe。
5. 回调消息在发送前会把换行压成 ` | `，避免 `cmd` 命令行被截断；消息过长时截到 1800 字符。
6. dispatch 启动 worker 后会观察 3 秒；worker 已退出且没有生成 completion 时，写失败结果并返回 `STATUS: FAILED`（exit 2），同时发一次失败回调（如启用）。
7. 回调失败只记录在 completion，不覆盖结果、不自动重发；直接读 `<taskId>.summary.txt` 和 `<taskId>.run.jsonl` 恢复。
8. 首次在新机器使用时，先做第 6 节的假 codex 回调测试。

## 6. 回归清单

以下操作全部在临时 `DSH_KIT_HOME` 和临时规则副本上做；不要用真实 KIT_HOME，也不要把测试产物写进用户项目。

准备：

```powershell
$root = Join-Path $env:TEMP ('dsh-kit-regress-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$env:DSH_KIT_HOME = Join-Path $root 'kit'
$kit = '<skill目录>\scripts\kit.ps1'
$utf8 = New-Object System.Text.UTF8Encoding($false)
```

### 6.1 语法与 BOM

```powershell
Get-ChildItem -Path '<包目录>' -Recurse -Filter *.ps1 | ForEach-Object {
  $e = $null
  [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null
  if ($e.Count -ne 0) { "语法错误: $($_.FullName)"; $e }
}
Get-ChildItem -Path '<包目录>' -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.mjs', '.md', '.yml', '.json' } | ForEach-Object {
  $b = [IO.File]::ReadAllBytes($_.FullName)
  $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
  '{0} BOM={1}' -f $_.FullName, $bom
}
```

预期：所有 `.ps1` 的 BOM 为 True；`.mjs`、`.md`、生成的 `.yml`/`.json` 为 False。

### 6.2 setup 第一段候选 JSON

```powershell
$choose = powershell -NoProfile -ExecutionPolicy Bypass -File $kit setup -Json | ConvertFrom-Json
$choose.stage          # choose
$choose.models.Count   # > 0
$choose.effortChoices
$choose.modes
$choose.plugins
$choose.warnings
```

检查：`stage=choose`；模型里有 `provider`/`id`/`sources`/`vision`/`contextWindow`/`efforts`；`effortsKnown=false` 的模型在 `effortChoices` 里是 `provider-default`；`modes` 含三种权限。

### 6.3 第二段生成补丁并 dump

```powershell
$m = $choose.models[0]
$model = "$($m.provider)/$($m.id)"
powershell -NoProfile -ExecutionPolicy Bypass -File $kit setup -Model $model -Effort auto -Mode workspace-write -Json | ConvertFrom-Json
$state = [IO.File]::ReadAllText((Join-Path $env:DSH_KIT_HOME 'state.json'), $utf8) | ConvertFrom-Json
$dump = & dsh headless --patch $state.patches.base.path --patch $state.patches.noBrowser.path --dump-config
[IO.File]::WriteAllText((Join-Path $root 'dump.yml'), ($dump -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
```

检查 dump 中至少有：credentials（`disabled: false`）、所选服务商插件、`agent-default-model`（provider/model 和 `reasoningEffort`）、压缩条目（窗口足够大时）、浏览器条目（可用时）。确认 `--patch` 在 `--dump-config` 前；逐个叠加 `effort-<档>.yml` 时，`reasoningEffort` 应为目标档，provider/model 不能被弄丢。

### 6.4 dsh-run 极小真实任务

```powershell
$task = Join-Path $root 'smoke.md'
[IO.File]::WriteAllText($task, "目标：只回答 OK，不要调用任何工具。`n工作目录：$root`n可改文件：无（只读任务）`n验收：返回 OK。`n停止条件：返回 OK 即停。", (New-Object System.Text.UTF8Encoding($false)))
powershell -NoProfile -ExecutionPolicy Bypass -File '<skill目录>\scripts\dsh-run.ps1' -TaskFile $task -Cwd $root -Label smoke -TimeoutMin 5 -NoProtocol
```

预期：首行 `STATUS: OK`，摘要显示“浏览器: 未挂载”，index 新增一条记录；确认默认叠加了 `no-browser.yml`。

只有 `features.browser.available` 为 true 时才测 `-Browser`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File '<skill目录>\scripts\dsh-run.ps1' -TaskFile $task -Cwd $root -Label smoke-browser -TimeoutMin 5 -NoProtocol -Browser
```

预期：摘要显示“浏览器: 已挂载”，工具调用里出现浏览器工具；功能不可用时应返回 `DSH_INCOMPATIBLE` 和 `FEATURE: browser`，而不是启动 dsh。

### 6.5 check 触发

```powershell
# 改基线版本：预检应触发自动 check
$s = [IO.File]::ReadAllText((Join-Path $env:DSH_KIT_HOME 'state.json'), $utf8) | ConvertFrom-Json
$s.dshVersion = '0.0.0'
[IO.File]::WriteAllText((Join-Path $env:DSH_KIT_HOME 'state.json'), ($s | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
powershell -NoProfile -ExecutionPolicy Bypass -File $kit check -Json | ConvertFrom-Json

# 改坏补丁：check 应 exit 1
[IO.File]::WriteAllText($s.patches.base.path, "broken: [yaml", (New-Object System.Text.UTF8Encoding($false)))
powershell -NoProfile -ExecutionPolicy Bypass -File $kit check -Json

# 用 dsh-run 验证预检会先自动 check；不存在的任务单不会启动 dsh，也不耗 token
powershell -NoProfile -ExecutionPolicy Bypass -File '<skill目录>\scripts\dsh-run.ps1' -TaskFile (Join-Path $root 'missing.md') -Cwd $root
```

预期：版本变化只产生 warning，直接 `check` 可通过；用 `dsh-run.ps1` 时它会先自动 check 并刷新基线，然后因任务单不存在返回 `STATUS: FAILED`，没有启动 dsh。补丁损坏时 `check` 返回不通过，`dsh-run.ps1` 派发前返回 `STATUS: DSH_INCOMPATIBLE`，不启动 dsh。随后运行 `repair` 恢复。

### 6.6 rules 追加与 uninstall 原样移除

```powershell
$rules = Join-Path $root 'CLAUDE.md'
[IO.File]::WriteAllText($rules, "# test`n", (New-Object System.Text.UTF8Encoding($false)))
$before = (Get-FileHash -LiteralPath $rules -Algorithm SHA256).Hash
powershell -NoProfile -ExecutionPolicy Bypass -File $kit rules -Host claude -Show -RulesFile $rules
powershell -NoProfile -ExecutionPolicy Bypass -File $kit rules -Host claude -Apply -RulesFile $rules
powershell -NoProfile -ExecutionPolicy Bypass -File $kit uninstall -Host claude -RulesFile $rules
$after = (Get-FileHash -LiteralPath $rules -Algorithm SHA256).Hash
$before -eq $after   # True
```

检查：追加后出现 `<!-- dsh-delegate-kit:begin v1 ... -->` / `<!-- dsh-delegate-kit:end -->`；`backups\` 有备份；uninstall 后 hash 与追加前一致，标记消失。测试只在临时副本上做，不要动真实的 `CLAUDE.md` / `AGENTS.md`。

### 6.7 dispatch + 假 codex 回调

```powershell
$bin = Join-Path $root 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
$argsFile = Join-Path $root 'codex-args.txt'
$fake = "@echo off`r`necho %*>>`"$argsFile`"`r`nexit /b 0`r`n"
[IO.File]::WriteAllText((Join-Path $bin 'codex.cmd'), $fake, (New-Object System.Text.UTF8Encoding($false)))
$env:PATH = $bin + ';' + $env:PATH
$env:CODEX_THREAD_ID = 'test-thread'
powershell -NoProfile -ExecutionPolicy Bypass -File '<skill目录>\scripts\dsh-dispatch.ps1' -TaskFile $task -Cwd $root -Label cb -TimeoutMin 5 -NoProtocol
```

预期：dispatch 首行 `STATUS: DISPATCHED`，返回 `taskId` / `completion`；等待 `<taskId>.completion.json` 出现后检查：

```powershell
$c = [IO.File]::ReadAllText('<taskId.completion.json>', $utf8) | ConvertFrom-Json
$c.status
$c.callback.status   # queued
$c.callback.exit     # 0
[IO.File]::ReadAllText($argsFile, $utf8)   # 含 queue --thread test-thread --message [DSH_DONE]...
```

这验证 worker、runner、completion 写入和 `codex queue` 参数；假 codex 不会真的向 Codex 发消息。

### 6.8 电脑操作只截图不点击

带 `-ComputerUse` 派发一个只读任务，任务单明确写“只截图并报告屏幕分辨率，禁止点击、输入、按键或移动窗口”。预期：拿到锁后执行；摘要显示“电脑操作: 已开启”，`lockWaitSec` 有记录；不应出现任何点击/输入工具调用。需要 UIA 辅助时只运行只读命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File '<skill目录>\scripts\uia.ps1' windows
powershell -NoProfile -ExecutionPolicy Bypass -File '<skill目录>\scripts\uia.ps1' tree -Window '<标题子串>' -Type Button
```

同时派两个电脑操作任务时，第二个应显示排队等锁，`lockWaitSec > 0`。

### 6.9 进度文件按权限落盘

先在一个临时工作目录跑 `workspace-write` 任务（极小的真实任务即可）：

```powershell
$proj = Join-Path $root 'proj'
New-Item -ItemType Directory -Force -Path $proj | Out-Null
$progTask = Join-Path $root 'prog.md'
[IO.File]::WriteAllText($progTask, "目标：把「步骤 1 / 结论 OK / 证据 无」追加写入进度文件后只回答 OK。`n工作目录：$proj`n可改文件：仅进度文件`n验收：返回 OK。`n停止条件：返回 OK 即停。", (New-Object System.Text.UTF8Encoding($false)))
powershell -NoProfile -ExecutionPolicy Bypass -File '<skill目录>\scripts\dsh-run.ps1' -TaskFile $progTask -Cwd $proj -Label prog -Mode workspace-write -TimeoutMin 5 -NoProtocol
Test-Path (Join-Path $proj '.dsh-delegate-kit')          # False：结束后已清理
$last = Get-Content (Join-Path $env:DSH_KIT_HOME 'logs\index.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
$last.progress                                          # 指向 logs 下的 .progress.md
Test-Path $last.progress                                # True
```

预期：运行期间 `<Cwd>\.dsh-delegate-kit\` 下出现 `<stamp>.progress.md`，结束后工作区副本和本次创建的空目录都消失，`logs\` 副本保留；如果外层强杀，工作区目录可能残留，这是已知行为，可手动删除。git 仓库里该目录不出现在范围核对结果中。

再用 `read-only` 跑一个简单任务（任务单本身不要求写进度）：

```powershell
$roTask = Join-Path $root 'ro.md'
[IO.File]::WriteAllText($roTask, "目标：只回答 OK，不要调用任何工具。`n工作目录：$proj`n验收：返回 OK。`n停止条件：返回 OK 即停。", (New-Object System.Text.UTF8Encoding($false)))
powershell -NoProfile -ExecutionPolicy Bypass -File '<skill目录>\scripts\dsh-run.ps1' -TaskFile $roTask -Cwd $proj -Label ro -Mode read-only -TimeoutMin 5 -NoProtocol
Test-Path (Join-Path $proj '.dsh-delegate-kit')          # False
$lastRo = Get-Content (Join-Path $env:DSH_KIT_HOME 'logs\index.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
$null -eq $lastRo.progress                               # True
```

预期：任务文本里的进度约定是「只读权限，阶段结论写进回复」，不创建任何进度文件，`index.progress` 为 null。

### 6.10 规则文件编码与 uninstall 归属校验

非 UTF-8 规则文件必须被拒绝，且文件字节不变：

```powershell
$gbkRules = Join-Path $root 'gbk-CLAUDE.md'
[IO.File]::WriteAllBytes($gbkRules, [Text.Encoding]::GetEncoding(936).GetBytes("# 测试`n"))
$before = (Get-FileHash -LiteralPath $gbkRules -Algorithm SHA256).Hash
powershell -NoProfile -ExecutionPolicy Bypass -File $kit rules -Host claude -Apply -RulesFile $gbkRules
$LASTEXITCODE                                           # 1
$before -eq (Get-FileHash -LiteralPath $gbkRules -Algorithm SHA256).Hash   # True
```

同样用 UTF-16LE（`[Text.Encoding]::Unicode.GetBytes(...)`）再跑一次，预期结果相同；换成 UTF-8 带 BOM 时应成功追加。

归属校验：在临时 KIT_HOME 完成一次 setup 后，把 `state.json` 的 `schemaVersion` 改成 2，再用临时 HOME 跑 `uninstall`（避免碰真实规则文件）：

```powershell
$s = [IO.File]::ReadAllText((Join-Path $env:DSH_KIT_HOME 'state.json'), $utf8) | ConvertFrom-Json
$s.schemaVersion = 2
[IO.File]::WriteAllText((Join-Path $env:DSH_KIT_HOME 'state.json'), ($s | ConvertTo-Json -Depth 20), $utf8)
$fakeHome = Join-Path $root 'home'
New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
$env:USERPROFILE = $fakeHome
powershell -NoProfile -ExecutionPolicy Bypass -File $kit uninstall
$LASTEXITCODE                                           # 1
Test-Path (Join-Path $env:DSH_KIT_HOME 'patches')        # True：拒绝清理后补丁保留
```

另测 `KIT_HOME` 等于 `DSH_HOME` 或 `patches` 等于 `<DSH_HOME>\patches` 时同样返回 1；规则段落只有 begin 没有 end 时也应返回 1、`ruleFailures` 计数为 1，且 state/patches 不被删除。测试结束恢复 `$env:USERPROFILE`。

## 7. 变更记录

- 0.1.0（2026-10-23）：首个版本。
- 0.2.0（2026-10-23）：dsh 输出格式无法识别时返回 `DSH_INCOMPATIBLE` + `FORMAT: output`，不再误判为 FAILED；dsh 版本未经验证时在 check、status 和派发摘要里警告并给出回退命令；新增 `update` 子命令，从 gitee 检查并安装新版 kit；README 增加「dsh 升级后失效怎么办」。
