<#
dsh-delegate-kit 回归（维护者工具，对应 dsh-delegate-kit\docs\MAINTENANCE.md 第 6 节）。
本目录不在 skill 目录里，npx skills 安装时不会带上，不影响使用者。

全部在临时 DSH_KIT_HOME、临时规则文件和临时 USERPROFILE 上进行，不碰真实配置；
会真实调用 dsh 跑几个极小任务（消耗少量 token），6.8 会在桌面上截图两次（只读，不点击）。

用法（Windows PowerShell 5.1）：
  powershell -NoProfile -ExecutionPolicy Bypass -File dev\regress-dsh-delegate-kit.ps1
  ... -Model opencode-go/deepseek-v4.1-flash   指定 setup 用的模型（默认取 setup 候选里的第一个）
  ... -Only 6.1,6.10                           只跑指定小节（6.1 之外的小节都会先做 setup）
  ... -KeepTemp                                保留临时目录（默认结束时删除，其中可能有屏幕截图）
输出每项 PASS/FAIL，末行 SUMMARY；有失败时退出码为 1。
#>
param(
  [string]$Skill = (Join-Path $PSScriptRoot '..\dsh-delegate-kit'),
  [string]$Model = '',
  [string[]]$Only = @(),
  [switch]$KeepTemp
)
$ErrorActionPreference = 'Continue'
$Skill = (Resolve-Path -LiteralPath $Skill).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)
$root = Join-Path $env:TEMP ('dsh-kit-regress-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$env:DSH_KIT_HOME = Join-Path $root 'kit'
$kit = Join-Path $Skill 'scripts\kit.ps1'
$run = Join-Path $Skill 'scripts\dsh-run.ps1'
$dispatch = Join-Path $Skill 'scripts\dsh-dispatch.ps1'
$realProfile = $env:USERPROFILE
$script:pass = 0; $script:fail = 0
function T([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Output "PASS $name" } else { $script:fail++; Write-Output "FAIL $name $detail" }
}
function PS1 { param([Parameter(ValueFromRemainingArguments)]$a) $o = & powershell -NoProfile -ExecutionPolicy Bypass -File @a 2>&1 | Out-String; [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE } }
function Want([string]$s) { $Only.Count -eq 0 -or $Only -contains $s }
function W([string]$p, [string]$t) { [IO.File]::WriteAllText($p, $t, $utf8) }
function RJ([string]$p) { [IO.File]::ReadAllText($p, $utf8) | ConvertFrom-Json }
Write-Output "root=$root"
Write-Output ("dsh=" + (& dsh --version))

# 6.1 语法与 BOM
if (Want '6.1') {
  $bad = @()
  Get-ChildItem -Path $Skill -Recurse -Filter *.ps1 | ForEach-Object { $e = $null; [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null; if ($e.Count) { $bad += $_.Name } }
  T '6.1 ps1 语法' ($bad.Count -eq 0) ($bad -join ',')
  $bomBad = @()
  Get-ChildItem -Path $Skill -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.mjs', '.md', '.yml', '.json' } | ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName); $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    if (($_.Extension -eq '.ps1') -ne $bom) { $bomBad += "$($_.Name)=$bom" }
  }
  T '6.1 BOM 规则' ($bomBad.Count -eq 0) ($bomBad -join ',')
}

# 6.2 / 6.3 setup 两段式 + dump（6.1 之外的小节都依赖 setup）
$needSetup = $Only.Count -eq 0 -or @($Only | Where-Object { $_ -ne '6.1' }).Count -gt 0
if ($needSetup) {
$r = PS1 $kit setup -Json
$choose = $null; try { $choose = $r.Out | ConvertFrom-Json } catch { }
T '6.2 stage=choose' ($choose.stage -eq 'choose') $r.Out.Substring(0, [Math]::Min(300, $r.Out.Length))
T '6.2 models>0' (@($choose.models).Count -gt 0)
$m0 = @($choose.models)[0]
T '6.2 模型字段' ($m0.provider -and $m0.id -and ($null -ne $m0.sources) -and ($null -ne $m0.vision) -and ($null -ne $m0.contextWindow) -and ($null -ne $m0.efforts))
T '6.2 modes 三种' ((@($choose.modes) | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.id } }) -join ',' -match 'read-only' -and (($choose.modes | Out-String) -match 'workspace-write') -and (($choose.modes | Out-String) -match 'danger-full-access'))
$ids = @($choose.models | ForEach-Object { '{0}/{1}' -f $_.provider, $_.id })
if (-not $Model) { $Model = $ids[0] }
Write-Output "model=$Model"
T '6.2 目标模型在候选中' ($ids -contains $Model) ($ids -join ',')
$modelId = $Model.Substring($Model.IndexOf('/') + 1)
$mSel = @($choose.models) | Where-Object { ('{0}/{1}' -f $_.provider, $_.id) -eq $Model } | Select-Object -First 1
$r = PS1 $kit setup -Model $Model -Effort auto -Mode workspace-write -Json
T '6.3 setup 第二段 exit 0' ($r.Code -eq 0) $r.Out.Substring(0, [Math]::Min(400, $r.Out.Length))
$state = RJ (Join-Path $env:DSH_KIT_HOME 'state.json')
$dump = (& dsh headless --patch $state.patches.base.path --patch $state.patches.noBrowser.path --dump-config 2>&1) -join "`n"
W (Join-Path $root 'dump.yml') $dump
T '6.3 dump 含 credentials' ($dump -match 'credentials')
T '6.3 dump 含 agent-default-model' ($dump -match 'agent-default-model' -and $dump.Contains($modelId))
if ($mSel.effortsKnown) { T '6.3 dump 含 reasoningEffort' ($dump -match 'reasoningEffort') }
if ($mSel.contextWindow -ge 250000) { T '6.3 dump 含压缩条目' ($dump -match 'compaction') }
# 逐个叠加 effort-<档>.yml：reasoningEffort 应为目标档，provider/model 不能丢
foreach ($e in @($mSel.efforts)) {
  $ep = Join-Path $env:DSH_KIT_HOME "patches\effort-$e.yml"
  if (-not (Test-Path $ep)) { continue }
  $d2 = (& dsh headless --patch $state.patches.base.path --patch $ep --dump-config 2>&1) -join "`n"
  T "6.3 effort-$e 叠加" ($d2 -match "reasoningEffort:\s*$e" -and $d2.Contains($modelId))
}
}

# 6.4 极小真实任务（不挂浏览器 / 挂浏览器）
$task = Join-Path $root 'smoke.md'
W $task "目标：只回答 OK，不要调用任何工具。`n工作目录：$root`n可改文件：无（只读任务）`n验收：返回 OK。`n停止条件：返回 OK 即停。"
if (Want '6.4') {
  $idx = Join-Path $env:DSH_KIT_HOME 'logs\index.jsonl'
  $n0 = if (Test-Path $idx) { @(Get-Content $idx).Count } else { 0 }
  $r = PS1 $run -TaskFile $task -Cwd $root -Label smoke -TimeoutMin 5 -NoProtocol
  T '6.4 smoke STATUS OK' ($r.Out -match '^STATUS: OK') $r.Out.Substring(0, [Math]::Min(300, $r.Out.Length))
  T '6.4 浏览器未挂载' ($r.Out -match '浏览器: 未挂载')
  T '6.4 index 新增' ((@(Get-Content $idx).Count) -eq $n0 + 1)
  $r = PS1 $run -TaskFile $task -Cwd $root -Label smoke-browser -TimeoutMin 5 -NoProtocol -Browser
  T '6.4 browser STATUS OK' ($r.Out -match '^STATUS: OK') $r.Out.Substring(0, [Math]::Min(300, $r.Out.Length))
  T '6.4 浏览器已挂载' ($r.Out -match '浏览器: 已挂载')
}

# 6.5 check 触发
if (Want '6.5') {
  $sp = Join-Path $env:DSH_KIT_HOME 'state.json'
  $s = RJ $sp; $s.dshVersion = '0.0.0'; W $sp ($s | ConvertTo-Json -Depth 20)
  $r = PS1 $kit check -Json
  T '6.5 版本变化 check 通过' ($r.Code -eq 0) $r.Out.Substring(0, [Math]::Min(300, $r.Out.Length))
  $s = RJ $sp; $s.dshVersion = '0.0.0'; W $sp ($s | ConvertTo-Json -Depth 20)
  $r = PS1 $run -TaskFile (Join-Path $root 'missing.md') -Cwd $root
  T '6.5 预检后任务单缺失 FAILED' ($r.Out -match '^STATUS: FAILED') $r.Out.Substring(0, [Math]::Min(300, $r.Out.Length))
  T '6.5 基线已刷新' ((RJ $sp).dshVersion -eq (& dsh --version))
  $basePath = (RJ $sp).patches.base.path
  $orig = [IO.File]::ReadAllText($basePath, $utf8)
  W $basePath 'broken: [yaml'
  $r = PS1 $kit check -Json
  T '6.5 补丁损坏 check 不通过' ($r.Code -ne 0)
  $r = PS1 $run -TaskFile $task -Cwd $root -Label broken -TimeoutMin 5 -NoProtocol
  T '6.5 补丁损坏派发 INCOMPATIBLE' ($r.Out -match '^STATUS: DSH_INCOMPATIBLE') $r.Out.Substring(0, [Math]::Min(300, $r.Out.Length))
  $r = PS1 $kit repair -Json
  $r2 = PS1 $kit check -Json
  T '6.5 repair 后 check 通过' ($r2.Code -eq 0) $r2.Out.Substring(0, [Math]::Min(300, $r2.Out.Length))
}

# 6.6 rules 追加与 uninstall 原样移除
if (Want '6.6') {
  $rules = Join-Path $root 'CLAUDE.md'
  W $rules "# test`n"
  $before = (Get-FileHash -LiteralPath $rules -Algorithm SHA256).Hash
  $r = PS1 $kit rules -Host claude -Show -RulesFile $rules
  $r = PS1 $kit rules -Host claude -Apply -RulesFile $rules
  $mid = [IO.File]::ReadAllText($rules, $utf8)
  T '6.6 段落标记' ($mid -match 'dsh-delegate-kit:begin v1' -and $mid -match 'dsh-delegate-kit:end')
  T '6.6 有备份' (@(Get-ChildItem (Join-Path $env:DSH_KIT_HOME 'backups') -ErrorAction SilentlyContinue).Count -gt 0)
  $r = PS1 $kit uninstall -Host claude -RulesFile $rules
  T '6.6 uninstall 原样恢复' ($before -eq (Get-FileHash -LiteralPath $rules -Algorithm SHA256).Hash)
}

# 6.7 dispatch + 假 codex 回调
if (Want '6.7') {
  $bin = Join-Path $root 'bin'; New-Item -ItemType Directory -Force -Path $bin | Out-Null
  $argsFile = Join-Path $root 'codex-args.txt'
  W (Join-Path $bin 'codex.cmd') "@echo off`r`necho %*>>`"$argsFile`"`r`nexit /b 0`r`n"
  $oldPath = $env:PATH; $env:PATH = $bin + ';' + $env:PATH; $env:CODEX_THREAD_ID = 'test-thread'
  $r = PS1 $dispatch -TaskFile $task -Cwd $root -Label cb -TimeoutMin 5 -NoProtocol
  T '6.7 DISPATCHED' ($r.Out -match '^STATUS: DISPATCHED') $r.Out.Substring(0, [Math]::Min(300, $r.Out.Length))
  $comp = ([regex]::Match($r.Out, '(?m)^completion:\s*(.+)$')).Groups[1].Value.Trim()
  if (-not $comp) { $comp = ([regex]::Match($r.Out, '[A-Za-z]:\\[^\r\n"]+\.completion\.json')).Value }
  $deadline = (Get-Date).AddMinutes(6)
  while ($comp -and -not (Test-Path $comp) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
  if ($comp -and (Test-Path $comp)) {
    Start-Sleep -Seconds 3
    $c = RJ $comp
    T '6.7 completion status OK' ($c.status -eq 'OK') ($c | ConvertTo-Json -Depth 5 -Compress)
    T '6.7 callback queued exit 0' ($c.callback.status -eq 'queued' -and $c.callback.exit -eq 0)
    $ca = if (Test-Path $argsFile) { [IO.File]::ReadAllText($argsFile, $utf8) } else { '' }
    T '6.7 codex queue 参数' ($ca -match 'queue' -and $ca -match 'test-thread' -and $ca -match 'DSH_DONE')
  } else { T '6.7 completion 出现' $false "comp=$comp" }
  $env:PATH = $oldPath; Remove-Item Env:CODEX_THREAD_ID
}

# 6.8 电脑操作只截图（两个并发验证排队）
if (Want '6.8') {
  $cuTask = Join-Path $root 'cu.md'
  W $cuTask "目标：用电脑操作工具截一张屏幕截图，只报告屏幕分辨率。`n工作目录：$root`n禁止点击、输入、按键、拖动或移动任何窗口。`n可改文件：无（只读任务），截图工具自动保存的图片除外。`n验收：报告分辨率。`n停止条件：报告分辨率即停。"
  $j1 = Start-Job { param($p, $t, $c, $h) $env:DSH_KIT_HOME = $h; & powershell -NoProfile -ExecutionPolicy Bypass -File $p -TaskFile $t -Cwd $c -Label cu1 -ComputerUse -TimeoutMin 10 -NoProtocol 2>&1 | Out-String } -ArgumentList $run, $cuTask, $root, $env:DSH_KIT_HOME
  Start-Sleep -Seconds 4
  $j2 = Start-Job { param($p, $t, $c, $h) $env:DSH_KIT_HOME = $h; & powershell -NoProfile -ExecutionPolicy Bypass -File $p -TaskFile $t -Cwd $c -Label cu2 -ComputerUse -TimeoutMin 10 -NoProtocol 2>&1 | Out-String } -ArgumentList $run, $cuTask, $root, $env:DSH_KIT_HOME
  $o1 = Receive-Job $j1 -Wait; $o2 = Receive-Job $j2 -Wait
  # 作业输出经控制台代码页解码，中文不可靠；以 index.jsonl 为准
  $rows = @(Get-Content (Join-Path $env:DSH_KIT_HOME 'logs\index.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.label -in 'cu1', 'cu2' })
  $c1 = $rows | Where-Object { $_.label -eq 'cu1' } | Select-Object -Last 1
  $c2 = $rows | Where-Object { $_.label -eq 'cu2' } | Select-Object -Last 1
  T '6.8 cu1 OK 且电脑操作开启' ($c1.status -eq 'OK' -and $c1.computerUse -eq $true) ($c1 | ConvertTo-Json -Compress)
  T '6.8 cu2 OK 且电脑操作开启' ($c2.status -eq 'OK' -and $c2.computerUse -eq $true) ($c2 | ConvertTo-Json -Compress)
  T '6.8 并发时有一个排队等锁>0' ((@($c1.lockWaitSec, $c2.lockWaitSec) | Measure-Object -Maximum).Maximum -gt 0) "w1=$($c1.lockWaitSec) w2=$($c2.lockWaitSec)"
  $logs = Get-ChildItem (Join-Path $env:DSH_KIT_HOME 'logs') -Filter *.jsonl | Sort-Object LastWriteTime -Descending | Select-Object -First 2
  $clicks = $logs | ForEach-Object { Select-String -LiteralPath $_.FullName -Pattern '"name":"[^"]*(click|type_text|press_key|drag|scroll|move_window)' }
  T '6.8 无点击/输入调用' (@($clicks).Count -eq 0) (@($clicks | ForEach-Object { $_.Matches[0].Value }) -join ',')
  Get-ChildItem $root -Filter 'screen-*.png' -ErrorAction SilentlyContinue | Remove-Item -Force
}

# 6.9 进度文件按权限落盘
if (Want '6.9') {
  $proj = Join-Path $root 'proj'; New-Item -ItemType Directory -Force -Path $proj | Out-Null
  $progTask = Join-Path $root 'prog.md'
  W $progTask "目标：把「步骤 1 / 结论 OK / 证据 无」追加写入进度文件后只回答 OK。`n工作目录：$proj`n可改文件：仅进度文件`n验收：返回 OK。`n停止条件：返回 OK 即停。"
  $r = PS1 $run -TaskFile $progTask -Cwd $proj -Label prog -Mode workspace-write -TimeoutMin 5 -NoProtocol
  T '6.9 prog OK' ($r.Out -match '^STATUS: OK') $r.Out.Substring(0, [Math]::Min(300, $r.Out.Length))
  T '6.9 工作区目录已清理' (-not (Test-Path (Join-Path $proj '.dsh-delegate-kit')))
  $last = Get-Content (Join-Path $env:DSH_KIT_HOME 'logs\index.jsonl') -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
  T '6.9 progress 在 logs 且存在' ($last.progress -and $last.progress -like '*\logs\*' -and (Test-Path $last.progress))
  $roTask = Join-Path $root 'ro.md'
  W $roTask "目标：只回答 OK，不要调用任何工具。`n工作目录：$proj`n验收：返回 OK。`n停止条件：返回 OK 即停。"
  $r = PS1 $run -TaskFile $roTask -Cwd $proj -Label ro -Mode read-only -TimeoutMin 5 -NoProtocol
  T '6.9 ro OK' ($r.Out -match '^STATUS: OK')
  T '6.9 ro 无工作区目录' (-not (Test-Path (Join-Path $proj '.dsh-delegate-kit')))
  $lastRo = Get-Content (Join-Path $env:DSH_KIT_HOME 'logs\index.jsonl') -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
  T '6.9 ro progress null' ($null -eq $lastRo.progress)
}

# 6.10 规则文件编码与 uninstall 归属校验
if (Want '6.10') {
  foreach ($enc in @(@{ n = 'GBK'; e = [Text.Encoding]::GetEncoding(936) }, @{ n = 'UTF16LE'; e = [Text.Encoding]::Unicode })) {
    $f = Join-Path $root "$($enc.n)-CLAUDE.md"
    [IO.File]::WriteAllBytes($f, $enc.e.GetBytes("# 测试`n"))
    $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
    $r = PS1 $kit rules -Host claude -Apply -RulesFile $f
    T "6.10 $($enc.n) 被拒绝" ($r.Code -eq 1 -and $h -eq (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash) "code=$($r.Code)"
  }
  $fb = Join-Path $root 'bom-CLAUDE.md'
  W $fb ''; [IO.File]::WriteAllText($fb, "# 测试`n", (New-Object System.Text.UTF8Encoding($true)))
  $r = PS1 $kit rules -Host claude -Apply -RulesFile $fb
  T '6.10 UTF8 BOM 可追加' ($r.Code -eq 0 -and ([IO.File]::ReadAllText($fb, $utf8) -match 'dsh-delegate-kit:begin'))
  # 归属校验：用独立 KIT_HOME，避免影响后续步骤
  $saveHome = $env:DSH_KIT_HOME
  $env:DSH_KIT_HOME = Join-Path $root 'kit-own'
  $r = PS1 $kit setup -Model $Model -Effort auto -Mode workspace-write -Json
  $sp = Join-Path $env:DSH_KIT_HOME 'state.json'
  $s = RJ $sp; $s.schemaVersion = 2; W $sp ($s | ConvertTo-Json -Depth 20)
  $fakeHome = Join-Path $root 'home'; New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
  $env:USERPROFILE = $fakeHome
  $r = PS1 $kit uninstall
  T '6.10 schemaVersion 不符拒绝 uninstall' ($r.Code -eq 1 -and (Test-Path (Join-Path $env:DSH_KIT_HOME 'patches'))) "code=$($r.Code)"
  $env:USERPROFILE = $realProfile
  $env:DSH_KIT_HOME = $saveHome
}

# 6.11 on / off
if (Want '6.11') {
  $fakeHome = Join-Path $root 'off-home'
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.claude') | Out-Null
  $rules = Join-Path $fakeHome '.claude\CLAUDE.md'
  W $rules "# test`n`n- 委派时优先派给 haiku 子 Agent。`n"
  $env:USERPROFILE = $fakeHome
  $r = PS1 $kit rules -Host claude -Apply
  $r = PS1 $kit off
  $offText = [IO.File]::ReadAllText($rules, $utf8)
  T '6.11 off 移除段落保留用户规则' (($offText -notmatch 'dsh-delegate-kit:begin') -and ($offText -match '委派时优先派给 haiku 子 Agent。'))
  T '6.11 off.json 存在' (Test-Path (Join-Path $env:DSH_KIT_HOME 'off.json'))
  $r = PS1 $kit status
  T '6.11 status 显示已关闭' ($r.Out -match '委派开关：已关闭')
  $r = PS1 $kit rules -Host claude -Apply
  T '6.11 关闭时 rules -Apply 拒绝' ($r.Code -ne 0)
  $r = PS1 $run -TaskFile $task -Cwd $root -Label off -TimeoutMin 5 -NoProtocol
  T '6.11 派发 DSH_DISABLED exit 6' ($r.Code -eq 6 -and $r.Out -match '^STATUS: DSH_DISABLED')
  $r = PS1 $dispatch -TaskFile $task -Cwd $root -Label off2 -TimeoutMin 5 -NoProtocol
  T '6.11 dispatch DSH_DISABLED exit 6' ($r.Code -eq 6)
  $r = PS1 $kit on
  T '6.11 on 后 off.json 消失' (-not (Test-Path (Join-Path $env:DSH_KIT_HOME 'off.json')))
  T '6.11 on 写回段落' ([IO.File]::ReadAllText($rules, $utf8) -match 'dsh-delegate-kit:begin')
  $r = PS1 $kit on
  T '6.11 重复 on 提示已开启' ($r.Out -match '已经是开启状态')
  $env:USERPROFILE = $realProfile
}

$env:USERPROFILE = $realProfile
Write-Output "SUMMARY pass=$($script:pass) fail=$($script:fail) root=$root"
if (-not $KeepTemp) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
if ($script:fail -gt 0) { exit 1 }
