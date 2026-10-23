<#
dsh-run.ps1 — 把任务交给 dsh headless 执行，输出精简摘要（dsh-delegate-kit 版）。

所有配置来自 KIT_HOME\state.json（KIT_HOME = DSH_KIT_HOME，或 DSH_HOME\dsh-delegate-kit，
或 ~\.dsh\dsh-delegate-kit）；补丁、模型、思考档、权限、浏览器/电脑操作能力都不写死。

用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File "<本文件>" -TaskFile <任务单.md> -Cwd <项目目录> [-SessionId <session-...>] [-Effort <档>] [-Mode read-only|workspace-write|danger-full-access] [-EscalationApproved] [-Browser] [-ComputerUse] [-TimeoutMin 90] [-NoProtocol] [-LogPrefix <绝对前缀>] [-HostName claude|codex]

首行固定输出 "STATUS: <OK|FAILED|DSH_UNAVAILABLE|TIMEOUT|DSH_INCOMPATIBLE>"：
  OK                 dsh 正常完成且收到 final
  FAILED             参数错误（exit 2）或其他失败（exit 1）
  DSH_UNAVAILABLE    dsh / node / state.json 不可用
  TIMEOUT            超时，已尝试终止本次拥有的进程树
  DSH_INCOMPATIBLE   state 与当前环境不兼容，预检未通过

运行产物默认在 LogDir（KIT_HOME\logs）下：
  <prefix>.task.md / .jsonl / .err.log / .progress.md / .running / .extend
#>
param(
  [string]$TaskFile,
  [string]$Task,
  [string]$Cwd = (Get-Location).Path,
  [string]$SessionId,
  # 不传则取 state.mode。
  [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
  [string]$Mode = '',
  # 不传则取 state.defaultEffort；是否合法由 state.model.efforts 校验。
  [string]$Effort = '',
  # 显式同意把权限调高到 state.mode 之上。
  [switch]$EscalationApproved,
  # 写入 index 的 host 字段。
  [ValidateSet('claude', 'codex')]
  [string]$HostName = 'claude',
  # 显式开启浏览器；默认关闭并叠加 state.patches.noBrowser。
  [switch]$Browser,
  # 显式开启电脑操作：叠加 computerUse 补丁，并持有全局互斥锁。
  [switch]$ComputerUse,
  [int]$TimeoutMin = 90,
  # 不传则用 KIT_HOME\logs。
  [string]$LogDir = '',
  [int]$MaxFinalChars = 8000,
  [string]$Label = '',
  # 不追加运行约定（只适合几分钟就能完成的小任务）。
  [switch]$NoProtocol,
  # 可选的绝对日志前缀；相对路径按 runner 当前目录规范化。
  [string]$LogPrefix
)

$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$errors = @()
$toolErrors = @()
$script:progressCleanupErrors = @()

function Exit-With([string]$status, [string]$msg, [int]$code) {
  Write-Output "STATUS: $status"
  if ($msg) { Write-Output $msg }
  # 提前退出时也给出已累积的警告（例如写死思考档被忽略）
  foreach ($w in @($script:warnings)) { if ($w) { Write-Output $w } }
  exit $code
}

function Assert-CmdPathSafe([string]$value, [string]$what) {
  if ([string]::IsNullOrEmpty($value)) { throw "$what 为空，无法安全传给 cmd" }
  if ($value.IndexOfAny([char[]]@("`r", "`n")) -ge 0) { throw "$what 含换行，无法安全传给 cmd" }
  if ($value -match '[%"!^&|<>]') {
    throw "$what 含 cmd 不支持的危险字符（百分号、感叹号、脱字符、与号、竖线、尖括号、双引号）: $value"
  }
  if ($value.EndsWith('\') -or $value.EndsWith('/')) { throw "$what 不能以目录分隔符结尾: $value" }
}

function ConvertTo-CmdPath([string]$value, [string]$what) {
  Assert-CmdPathSafe -value $value -what $what
  return '"' + $value + '"'
}

function Stop-OwnedProcessTree([System.Diagnostics.Process]$proc) {
  # 只终止本 runner 启动的 cmd 进程及其子进程；进程已退出时不再按 PID 操作，避免 PID 复用误杀。
  if ($null -eq $proc) { return }
  try { if ($proc.HasExited) { return } } catch { return }
  $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
  try {
    if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
      & $taskkill /T /F /PID $proc.Id 2>$null | Out-Null
    }
  } catch { }
  try {
    if (-not $proc.WaitForExit(5000)) {
      try { $proc.Kill() } catch { }
      [void]$proc.WaitForExit(5000)
    }
  } catch { }
}

function Add-IndexRecord([string]$path, [string]$line) {
  # 并发追加：按日志绝对路径派生命名互斥锁，只锁同一 index 文件。
  $full = [IO.Path]::GetFullPath($path).ToLowerInvariant()
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full))).Replace('-', '').Substring(0, 24)
  } finally { $sha.Dispose() }
  $mutexName = "Local\dsh-codex-index-$hash"
  $mutex = New-Object System.Threading.Mutex($false, $mutexName)
  $acquired = $false
  try {
    try { $acquired = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw '等待 index.jsonl 互斥锁超时' }
    [IO.File]::AppendAllText($path, $line + "`n", $utf8)
  } finally {
    if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
  }
}

function Read-Utf8([string]$path) {
  # 用 ReadWrite 共享方式读取：cmd 正在写 jsonl/err.log 时也能读到已落盘内容。
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
  $fs = $null
  $sr = $null
  try {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $sr = New-Object System.IO.StreamReader($fs, $utf8, $true)
    return $sr.ReadToEnd()
  } catch {
    return ''
  } finally {
    if ($sr) { $sr.Dispose() } elseif ($fs) { $fs.Dispose() }
  }
}

function Read-ExtendRequest([string]$path) {
  # 只接受 1..120 的整数；无论内容是否合法，读取后都清理，避免旧请求反复生效。
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $raw = Read-Utf8 $path
  try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { return $null }
  if ([string]::IsNullOrEmpty($raw)) { return $null }
  if ($raw -match '^\s*([0-9]{1,3})\s*$') {
    $n = [int]$matches[1]
    if ($n -ge 1 -and $n -le 120) { return $n }
  }
  return $null
}

function Write-RunningMarker([string]$path, $obj) {
  [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Compress), $utf8)
}

function Get-TruncatedTail([string]$text, [int]$max, [string]$note) {
  if ([string]::IsNullOrEmpty($text)) { return '' }
  $max = [Math]::Max(0, $max)
  if ($text.Length -le $max) { return $text }
  if ($max -le $note.Length) { return $note.Substring(0, $max) }
  $budget = $max - $note.Length - 1
  if ($budget -lt 0) { $budget = 0 }
  return $note + "`n" + $text.Substring($text.Length - $budget)
}

function Get-FileSha256([string]$path) {
  # 与 Get-FileHash -Algorithm SHA256 一致：大写十六进制。
  $sha = [Security.Cryptography.SHA256]::Create()
  $fs = $null
  try {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    return [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '').ToUpperInvariant()
  } finally {
    if ($fs) { $fs.Dispose() }
    $sha.Dispose()
  }
}

function Get-DshVersion([string]$pkgDir, $encoding) {
  if ([string]::IsNullOrWhiteSpace($pkgDir)) { return '' }
  $pkgJson = Join-Path $pkgDir 'package.json'
  if (-not (Test-Path -LiteralPath $pkgJson -PathType Leaf)) { return '' }
  try {
    $obj = [IO.File]::ReadAllText($pkgJson, $encoding) | ConvertFrom-Json
    if ($obj -and $obj.version) { return [string]$obj.version }
  } catch { }
  return ''
}

function Get-DshPackageDir([string]$baseDir, [string]$fallbackDir) {
  # 优先用实际 dsh 安装目录（Get-Command 推导），state 里的旧路径只作后备。
  $candidate = Join-Path $baseDir 'node_modules\@deepseek-ai\dsh'
  if (Test-Path -LiteralPath (Join-Path $candidate 'package.json') -PathType Leaf) { return $candidate }
  if (-not [string]::IsNullOrWhiteSpace($fallbackDir) -and (Test-Path -LiteralPath (Join-Path $fallbackDir 'package.json') -PathType Leaf)) {
    return $fallbackDir
  }
  return $candidate
}

function Test-GitStatusPathIgnored([string]$line) {
  # porcelain 行格式固定为 "XY 路径"；只按路径忽略 runner 自己的工作区进度目录。
  if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -le 3) { return $false }
  return ($line.Substring(3) -match '(^|/)\.dsh-delegate-kit/')
}

function Complete-ProgressFile {
  # dsh 结束后把工作区进度文件搬回日志目录并清理；可重复调用。
  if ($script:progressFinalized) { return }
  $script:progressFinalized = $true
  if ([string]::IsNullOrEmpty($script:dshProgressPath) -or $script:dshProgressPath -eq $script:logsProgressPath) { return }
  try {
    if (Test-Path -LiteralPath $script:dshProgressPath -PathType Leaf) {
      $text = [IO.File]::ReadAllText($script:dshProgressPath, $utf8)
      [IO.File]::WriteAllText($script:logsProgressPath, $text, $utf8)
      Remove-Item -LiteralPath $script:dshProgressPath -Force -ErrorAction Stop
    }
  } catch {
    $script:progressCleanupErrors += "清理工作区进度文件失败: $($_.Exception.Message)"
  }
  if ($script:workspaceProgressDirCreated) {
    try {
      $left = @(Get-ChildItem -LiteralPath $script:workspaceProgressDir -Force -ErrorAction Stop)
      if ($left.Count -eq 0) { Remove-Item -LiteralPath $script:workspaceProgressDir -Force -ErrorAction Stop }
    } catch {
      $script:progressCleanupErrors += "删除工作区进度目录失败: $($_.Exception.Message)"
    }
  }
}

function Get-StatePatchFiles($state) {
  $list = @()
  if ($null -eq $state -or $null -eq $state.patches) { return $list }
  foreach ($name in @('base', 'noBrowser', 'computerUse')) {
    $prop = $state.patches.PSObject.Properties[$name]
    if ($prop -and $prop.Value -and $prop.Value.path) {
      $list += [pscustomobject]@{ Name = $name; Path = [string]$prop.Value.path; Sha = [string]$prop.Value.sha256 }
    }
  }
  $effortProp = $state.patches.PSObject.Properties['effort']
  if ($effortProp -and $effortProp.Value) {
    foreach ($p in $effortProp.Value.PSObject.Properties) {
      if ($p.Value -and $p.Value.path) {
        $list += [pscustomobject]@{ Name = "effort.$($p.Name)"; Path = [string]$p.Value.path; Sha = [string]$p.Value.sha256 }
      }
    }
  }
  return $list
}

function Read-DshEvents([string]$text, [string]$fallbackSessionId) {
  # 容忍缺字段、坏行和不完整尾行：对应统计计 0 或 null，绝不抛出。
  $result = [ordered]@{
    sid = $fallbackSessionId; final = $null; reason = $null
    toolCalls = 0; steps = 0; thinkChars = 0
    inTok = [int64]0; outTok = [int64]0; cacheTok = [int64]0
    toolErrors = @(); errors = @()
  }
  if ([string]::IsNullOrEmpty($text)) { return $result }
  foreach ($line in ($text -split "`r?`n")) {
    if (-not $line.Trim()) { continue }
    try {
      $e = $null
      try { $e = $line | ConvertFrom-Json } catch { continue }
      if ($null -eq $e) { continue }
      $type = $null
      try { $type = [string]$e.type } catch { $type = $null }
      switch ($type) {
        'session' {
          try { if ($e.sessionId) { $result.sid = [string]$e.sessionId } } catch { }
        }
        'tool_call' {
          try { $result.toolCalls = [int]$result.toolCalls + 1 } catch { }
        }
        'thinking' {
          try {
            $t = $e.text
            if ($null -ne $t) { $result.thinkChars = [int]$result.thinkChars + ([string]$t).Length }
          } catch { }
        }
        'tool_result' {
          try {
            if ($e.status -ne 'completed') {
              $r = [string]$e.result
              if ($r.Length -gt 200) { $r = $r.Substring(0, 200) + '…' }
              $result.toolErrors = @($result.toolErrors) + $r
            }
          } catch { }
        }
        'status' {
          try {
            $phase = $null
            try { $phase = [string]$e.phase } catch { $phase = $null }
            if ($phase -eq 'step_end') {
              $result.steps = [int]$result.steps + 1
              try {
                if ($null -ne $e.usage) {
                  if ($null -ne $e.usage.inputTokens) { $result.inTok = [int64]$result.inTok + [int64]$e.usage.inputTokens }
                  if ($null -ne $e.usage.outputTokens) { $result.outTok = [int64]$result.outTok + [int64]$e.usage.outputTokens }
                  if ($null -ne $e.usage.cacheReadTokens) { $result.cacheTok = [int64]$result.cacheTok + [int64]$e.usage.cacheReadTokens }
                }
              } catch { }
            } elseif ($phase -eq 'turn_end') {
              try {
                if ($null -ne $e.reason) {
                  if ($null -ne $e.reason.kind) { $result.reason = [string]$e.reason.kind }
                  if ($e.reason.message) { $result.errors = @($result.errors) + [string]$e.reason.message }
                }
              } catch { }
            }
          } catch { }
        }
        'error' {
          try { $result.errors = @($result.errors) + ($line.Substring(0, [Math]::Min(300, $line.Length))) } catch { }
        }
        'final' {
          try { if ($null -ne $e.text) { $result.final = [string]$e.text } } catch { }
        }
      }
    } catch { continue }
  }
  return $result
}

# ---- KIT_HOME / state.json ----
$kitHome = $env:DSH_KIT_HOME
if ([string]::IsNullOrWhiteSpace($kitHome)) {
  $dshHome = $env:DSH_HOME
  if ([string]::IsNullOrWhiteSpace($dshHome)) { $dshHome = Join-Path $HOME '.dsh' }
  $kitHome = Join-Path $dshHome 'dsh-delegate-kit'
}
try { $kitHome = [IO.Path]::GetFullPath($kitHome) } catch {
  Exit-With 'DSH_UNAVAILABLE' "KIT_HOME 路径无效: $kitHome" 3
}
$statePath = Join-Path $kitHome 'state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
  Exit-With 'DSH_UNAVAILABLE' 'dsh-delegate-kit 尚未初始化：先运行 setup' 3
}
$state = $null
try {
  $state = [IO.File]::ReadAllText($statePath, $utf8) | ConvertFrom-Json
} catch {
  Exit-With 'DSH_UNAVAILABLE' "读取 state.json 失败: $($_.Exception.Message)" 3
}
if ($null -eq $state) { Exit-With 'DSH_UNAVAILABLE' 'state.json 内容为空：先运行 setup' 3 }

# ---- 定位 dsh / node（规格第 7 节第 2 步）----
$dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
if (-not $dshCmd -or -not $dshCmd.Source) { Exit-With 'DSH_UNAVAILABLE' '找不到 dsh 命令（npm i -g @deepseek-ai/dsh）' 3 }
$base = Split-Path $dshCmd.Source -Parent
$bin = Join-Path $base 'node_modules\@deepseek-ai\dsh\lib\bin.js'
$node = Join-Path $base 'node.exe'
if (-not (Test-Path -LiteralPath $node -PathType Leaf)) {
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if ($nodeCmd -and $nodeCmd.Source) { $node = $nodeCmd.Source }
}
if (-not (Test-Path -LiteralPath $bin -PathType Leaf) -or -not (Test-Path -LiteralPath $node -PathType Leaf)) {
  Exit-With 'DSH_UNAVAILABLE' "找不到 dsh 入口: $bin（node: $node）" 3
}
$dshPkgDir = Get-DshPackageDir $base ([string]$state.dshPackageDir)
$currentVersion = Get-DshVersion $dshPkgDir $utf8

# ---- 预检：版本 / 补丁哈希 / lastCheck（规格第 7 节第 3-4 步）----
$needCheck = $false
$checkReasons = @()
$baselineVersion = [string]$state.dshVersion
if ($currentVersion -ne $baselineVersion) {
  $needCheck = $true
  $checkReasons += "dsh 版本 $currentVersion 与基线 $baselineVersion 不一致"
}
foreach ($pf in @(Get-StatePatchFiles $state)) {
  if (-not (Test-Path -LiteralPath $pf.Path -PathType Leaf)) {
    $needCheck = $true
    $checkReasons += "补丁缺失: $($pf.Name) -> $($pf.Path)"
    continue
  }
  try {
    $actualHash = Get-FileSha256 $pf.Path
    if (-not [string]::Equals($actualHash, $pf.Sha, [StringComparison]::OrdinalIgnoreCase)) {
      $needCheck = $true
      $checkReasons += "补丁哈希不符: $($pf.Name) -> $($pf.Path)"
    }
  } catch {
    $needCheck = $true
    $checkReasons += "补丁无法读取: $($pf.Name) -> $($pf.Path)"
  }
}
if ($state.lastCheck.ok -ne $true) {
  $needCheck = $true
  $checkReasons += 'lastCheck.ok 不是 true'
}

$precheckLine = $null
$versionBeforeCheck = $currentVersion
$baselineBeforeCheck = [string]$state.dshVersion
if ($needCheck) {
  $kitScript = Join-Path $PSScriptRoot 'kit.ps1'
  if (-not (Test-Path -LiteralPath $kitScript -PathType Leaf)) {
    Write-Output 'STATUS: DSH_INCOMPATIBLE'
    foreach ($r in $checkReasons) { Write-Output $r }
    Write-Output "需要自动 check，但找不到 kit.ps1: $kitScript"
    Write-Output '修复：运行 kit.ps1 repair'
    exit 5
  }
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell.exe' }
  $checkOut = ''
  $checkErr = ''
  $checkExit = -2
  $checkTimedOut = $false
  $checkProc = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $kitScript + '" check -Json -UpdateBaseline'
    $psi.WorkingDirectory = $kitHome
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $checkProc = [Diagnostics.Process]::Start($psi)
    # 并发读 stdout/stderr，避免任一管道写满后双方互等；读取完成由进程退出保证。
    $checkOutTask = $checkProc.StandardOutput.ReadToEndAsync()
    $checkErrTask = $checkProc.StandardError.ReadToEndAsync()
    if ($checkProc.WaitForExit(120000)) {
      try { if ($checkOutTask.Wait(5000)) { $checkOut = $checkOutTask.GetAwaiter().GetResult() } } catch { }
      try { if ($checkErrTask.Wait(5000)) { $checkErr = $checkErrTask.GetAwaiter().GetResult() } } catch { }
      try { $checkExit = $checkProc.ExitCode } catch { }
    } else {
      $checkTimedOut = $true
      $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
      try {
        if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
          & $taskkill /T /F /PID $checkProc.Id 2>$null | Out-Null
        } else {
          $checkProc.Kill()
        }
      } catch { try { $checkProc.Kill() } catch { } }
      try { [void]$checkProc.WaitForExit(5000) } catch { }
      try { if ($checkOutTask.Wait(5000)) { $checkOut = $checkOutTask.GetAwaiter().GetResult() } } catch { }
      try { if ($checkErrTask.Wait(5000)) { $checkErr = $checkErrTask.GetAwaiter().GetResult() } } catch { }
    }
  } catch {
    $checkErr = $_.Exception.Message
  } finally {
    if ($checkProc) { try { $checkProc.Dispose() } catch { } }
  }
  if ($checkTimedOut) {
    Write-Output 'STATUS: DSH_INCOMPATIBLE'
    foreach ($r in $checkReasons) { Write-Output $r }
    Write-Output '自动 check 超时（120 秒），已终止 check 进程树'
    Write-Output '修复：运行 kit.ps1 repair'
    exit 5
  }
  $check = $null
  try { $check = $checkOut.Trim() | ConvertFrom-Json } catch { $check = $null }
  if ($null -eq $check -or $check.ok -ne $true) {
    Write-Output 'STATUS: DSH_INCOMPATIBLE'
    $reasons = @()
    if ($null -ne $check -and $null -ne $check.reasons) { $reasons = @($check.reasons | ForEach-Object { [string]$_ }) }
    if (-not $reasons.Count) {
      $reasons = @($checkReasons)
      if ($checkErr) { $reasons += ("kit.ps1 check: " + (($checkErr -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' / ')) }
      $reasons += "kit.ps1 check 未输出可用 JSON（exit $checkExit）"
    }
    foreach ($r in $reasons) { Write-Output $r }
    Write-Output '修复：运行 kit.ps1 repair'
    exit 5
  }
  $state = $null
  try { $state = [IO.File]::ReadAllText($statePath, $utf8) | ConvertFrom-Json } catch { $state = $null }
  if ($null -eq $state) {
    Write-Output 'STATUS: DSH_INCOMPATIBLE'
    Write-Output 'kit.ps1 check 后重新读取 state.json 失败'
    Write-Output '修复：运行 kit.ps1 repair'
    exit 5
  }
  $currentVersion = Get-DshVersion (Get-DshPackageDir $base ([string]$state.dshPackageDir)) $utf8
  $newVersion = $currentVersion
  if ([string]::IsNullOrWhiteSpace($newVersion)) { $newVersion = [string]$state.dshVersion }
  $versionOld = $baselineBeforeCheck
  if ([string]::IsNullOrWhiteSpace($versionOld)) { $versionOld = $versionBeforeCheck }
  if ($versionOld -ne $newVersion) {
    $precheckLine = "预检: dsh 版本 $versionOld -> $newVersion，已自动 check 通过"
  } else {
    $precheckLine = "预检: dsh 版本 $newVersion，已自动 check 通过（基线/补丁已刷新）"
  }
}

# ---- 可选功能门槛（规格第 7 节第 5 步）----
if ($Browser) {
  $browserFeature = $state.features.browser
  if ($null -eq $browserFeature -or $browserFeature.available -ne $true) {
    Write-Output 'STATUS: DSH_INCOMPATIBLE'
    Write-Output 'FEATURE: browser'
    $reason = 'state.features.browser.available 不是 true'
    if ($null -ne $browserFeature -and $browserFeature.reason) { $reason = [string]$browserFeature.reason }
    Write-Output "原因: $reason"
    Write-Output '去掉该参数重派，或运行 kit.ps1 repair'
    exit 5
  }
}
if ($ComputerUse) {
  $cuFeature = $state.features.computerUse
  if ($null -eq $cuFeature -or $cuFeature.available -ne $true) {
    Write-Output 'STATUS: DSH_INCOMPATIBLE'
    Write-Output 'FEATURE: computerUse'
    $reason = 'state.features.computerUse.available 不是 true'
    if ($null -ne $cuFeature -and $cuFeature.reason) { $reason = [string]$cuFeature.reason }
    Write-Output "原因: $reason"
    Write-Output '去掉该参数重派，或运行 kit.ps1 repair'
    exit 5
  }
}

# ---- 思考档（规格第 7 节第 6 步）----
$defaultEffort = [string]$state.defaultEffort
$effortsKnown = ($null -ne $state.model -and $state.model.effortsKnown -eq $true)
$requestedEffort = ([string]$Effort).ToLowerInvariant()
$effortMode = [string]$state.effortMode
if ([string]::IsNullOrWhiteSpace($effortMode)) { $effortMode = 'auto' }
$warnings = @()
$effectiveEffort = $defaultEffort
# 用户写死了思考档：忽略 -Effort（先于档位校验，避免因不支持的档而失败）
if ($effortMode -eq 'fixed' -and -not [string]::IsNullOrWhiteSpace($requestedEffort) -and $requestedEffort -ne $defaultEffort) {
  $warnings += "警告: 用户已写死思考档 $defaultEffort，忽略 -Effort $requestedEffort"
  $requestedEffort = ''
}
if (-not [string]::IsNullOrWhiteSpace($requestedEffort)) {
  if (-not $effortsKnown) {
    Exit-With 'FAILED' '该模型思考等级未知，不能指定 -Effort' 2
  }
  $allowedEfforts = @()
  if ($null -ne $state.model.efforts) { $allowedEfforts = @($state.model.efforts | ForEach-Object { [string]$_ }) }
  if ($allowedEfforts -notcontains $requestedEffort) {
    Exit-With 'FAILED' "不支持的思考档 $requestedEffort，可选：$($allowedEfforts -join '/')" 2
  }
  $effectiveEffort = $requestedEffort
}
$effortPatchPath = $null
if (-not [string]::IsNullOrWhiteSpace($effectiveEffort) -and $effectiveEffort -ne $defaultEffort) {
  $effortProp = $null
  if ($null -ne $state.patches) { $effortProp = $state.patches.PSObject.Properties['effort'] }
  $entry = $null
  if ($effortProp -and $effortProp.Value) {
    $one = $effortProp.Value.PSObject.Properties[$effectiveEffort]
    if ($one) { $entry = $one.Value }
  }
  if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.path)) {
    Exit-With 'FAILED' "state.patches.effort.$effectiveEffort 缺失（缺少思考档 $effectiveEffort 的补丁）：运行 kit.ps1 repair 重新生成" 2
  }
  $effortPatchPath = [string]$entry.path
}

# ---- 权限（规格第 7 节第 7 步）----
$modeRank = @{ 'read-only' = 0; 'workspace-write' = 1; 'danger-full-access' = 2 }
$stateMode = [string]$state.mode
if ([string]::IsNullOrWhiteSpace($stateMode)) { $stateMode = 'workspace-write' }
$effectiveMode = $stateMode
if (-not [string]::IsNullOrWhiteSpace($Mode)) { $effectiveMode = $Mode.ToLowerInvariant() }
$stateRank = $modeRank[$stateMode]
if ($null -eq $stateRank) { $stateRank = 0 }
$effectiveRank = $modeRank[$effectiveMode]
if ($null -eq $effectiveRank) { $effectiveRank = 0 }
if ($effectiveRank -gt $stateRank -and -not $EscalationApproved) {
  Exit-With 'FAILED' "调高权限需要用户明确同意，并加 -EscalationApproved（state.mode=$stateMode，请求 $effectiveMode）" 2
}

# ---- 任务文本与工作目录 ----
if ($TaskFile) {
  if (-not (Test-Path -LiteralPath $TaskFile -PathType Leaf)) { Exit-With 'FAILED' "找不到任务单: $TaskFile" 2 }
  try {
    $taskText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $TaskFile).Path, $utf8)
  } catch {
    Exit-With 'FAILED' "读取任务单失败: $($_.Exception.Message)" 2
  }
} elseif ($Task) {
  $taskText = $Task
} else {
  Exit-With 'FAILED' '必须提供 -TaskFile 或 -Task' 2
}
if ($Cwd.StartsWith('\\')) { Exit-With 'FAILED' 'cmd 不支持 UNC 工作目录，请先映射为盘符' 2 }
if (-not (Test-Path -LiteralPath $Cwd -PathType Container)) { Exit-With 'FAILED' "工作目录不存在: $Cwd" 2 }
$Cwd = (Resolve-Path -LiteralPath $Cwd).Path
if ($TimeoutMin -lt 1) { Exit-With 'FAILED' 'TimeoutMin 必须大于等于 1' 2 }
if ($MaxFinalChars -lt 0) { $MaxFinalChars = 0 }
if ($SessionId -and $SessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
  Exit-With 'FAILED' 'SessionId 含不安全字符，拒绝拼入 cmd 命令' 2
}

# ---- 日志目录 ----
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $kitHome 'logs' }
try {
  if ([string]::IsNullOrWhiteSpace($LogDir)) { throw 'LogDir 为空' }
  if (-not [IO.Path]::IsPathRooted($LogDir)) {
    $LogDir = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $LogDir))
  } else {
    $LogDir = [IO.Path]::GetFullPath($LogDir)
  }
} catch {
  Exit-With 'FAILED' "路径规范化失败: $($_.Exception.Message)" 2
}

$modelId = ''
if ($null -ne $state.model) {
  $modelId = ([string]$state.model.provider) + '/' + ([string]$state.model.id)
}
$kitVersion = [string]$state.kitVersion

# 补丁路径全部来自 state；启动前再确认物理存在。
$selectedPatchPaths = @()
$basePatch = $null
if ($null -ne $state.patches) { $basePatch = $state.patches.base }
if ($null -eq $basePatch -or [string]::IsNullOrWhiteSpace([string]$basePatch.path)) {
  Write-Output 'STATUS: DSH_INCOMPATIBLE'
  Write-Output 'state.patches.base 缺失或 path 为空：基础补丁不可用'
  Write-Output '修复：运行 kit.ps1 repair'
  exit 5
}
$selectedPatchPaths += [string]$basePatch.path
if ($effortPatchPath) { $selectedPatchPaths += $effortPatchPath }
if (-not $Browser) {
  if ($state.patches.noBrowser -and $state.patches.noBrowser.path) {
    $selectedPatchPaths += [string]$state.patches.noBrowser.path
  } else {
    Write-Output 'STATUS: DSH_INCOMPATIBLE'
    Write-Output 'state.patches.noBrowser 缺失：默认需要禁用浏览器补丁'
    Write-Output '修复：运行 kit.ps1 repair'
    exit 5
  }
}
if ($ComputerUse) {
  if ($state.patches.computerUse -and $state.patches.computerUse.path) {
    $selectedPatchPaths += [string]$state.patches.computerUse.path
  } else {
    Write-Output 'STATUS: DSH_INCOMPATIBLE'
    Write-Output 'state.patches.computerUse 缺失'
    Write-Output '修复：运行 kit.ps1 repair'
    exit 5
  }
}
$missingPatch = $null
foreach ($pp in $selectedPatchPaths) {
  if (-not (Test-Path -LiteralPath $pp -PathType Leaf)) { $missingPatch = $pp; break }
}
if ($missingPatch) {
  Write-Output 'STATUS: DSH_INCOMPATIBLE'
  Write-Output "补丁文件不存在: $missingPatch"
  Write-Output '修复：运行 kit.ps1 repair'
  exit 5
}

# 保留 Git 状态核对；调用方禁止 Git 时须在子进程 PATH 中移除 git 入口。
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
function Get-GitState([string]$dir) {
  if (-not $gitCmd) { return $null }
  $top = & $gitCmd.Source -C $dir rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $top) { return $null }
  $head = & $gitCmd.Source -C $dir rev-parse HEAD 2>$null
  $branch = & $gitCmd.Source -C $dir rev-parse --abbrev-ref HEAD 2>$null
  $gitStatus = @(& $gitCmd.Source -C $dir status --porcelain=v1 -uall 2>$null)
  [pscustomobject]@{ Top = "$top"; Head = "$head"; Branch = "$branch"; Status = $gitStatus }
}
$gitBefore = Get-GitState $Cwd

# ---- 日志前缀与初始运行标记 ----
try {
  if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  }
} catch {
  Exit-With 'FAILED' "创建日志目录失败: $($_.Exception.Message)" 2
}
if ($LogPrefix) {
  try {
    if (-not [IO.Path]::IsPathRooted($LogPrefix)) {
      $LogPrefix = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $LogPrefix))
    } else {
      $LogPrefix = [IO.Path]::GetFullPath($LogPrefix)
    }
  } catch {
    Exit-With 'FAILED' "LogPrefix 无效: $($_.Exception.Message)" 2
  }
  if ($LogPrefix -match '[\*\?]') { Exit-With 'FAILED' "LogPrefix 不能包含通配符: $LogPrefix" 2 }
  if ($LogPrefix.EndsWith('\') -or $LogPrefix.EndsWith('/')) { Exit-With 'FAILED' "LogPrefix 必须是文件前缀，不能以目录分隔符结尾: $LogPrefix" 2 }
  if (-not (Split-Path -Leaf $LogPrefix)) { Exit-With 'FAILED' "LogPrefix 缺少文件名: $LogPrefix" 2 }
  if (Test-Path -LiteralPath $LogPrefix -PathType Container) { Exit-With 'FAILED' "LogPrefix 指向目录，拒绝使用: $LogPrefix" 2 }
} else {
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
  $LogPrefix = Join-Path $LogDir $stamp
}
$logBase = $LogPrefix
$taskPath = "$logBase.task.md"
$jsonlPath = "$logBase.jsonl"
$errPath = "$logBase.err.log"
$logsProgressPath = "$logBase.progress.md"
$extendPath = "$logBase.extend"
$runningPath = "$logBase.running"
$indexPath = Join-Path $LogDir 'index.jsonl'

# 进度文件按实际沙箱权限决定位置：
#   danger-full-access 可以写日志目录，直接用 <logBase>.progress.md；
#   workspace-write 只能写工作区与会话临时目录，放 <Cwd>\.dsh-delegate-kit\<stamp>.progress.md，
#     结束后由脚本搬回日志目录并清理工作区副本；
#   read-only 什么都不能写，不创建进度文件。
$runStamp = Split-Path -Leaf $logBase
$workspaceProgressDir = Join-Path $Cwd '.dsh-delegate-kit'
$workspaceProgressPath = $null
$dshProgressPath = $null
$logsProgressEnabled = ($effectiveMode -ne 'read-only')
switch ($effectiveMode) {
  'workspace-write' {
    $workspaceProgressPath = Join-Path $workspaceProgressDir ($runStamp + '.progress.md')
    $dshProgressPath = $workspaceProgressPath
  }
  'danger-full-access' { $dshProgressPath = $logsProgressPath }
}
$progressRecordPath = if ($logsProgressEnabled) { $logsProgressPath } else { $null }
$workspaceProgressDirCreated = $false

try {
  foreach ($artifact in @($taskPath, $jsonlPath, $errPath, $logsProgressPath, $extendPath, $runningPath)) {
    Assert-CmdPathSafe -value $artifact -what '日志产物路径'
    if (Test-Path -LiteralPath $artifact) { throw "拒绝覆盖已存在的日志产物: $artifact" }
  }
  $prefixDir = Split-Path -Parent $logBase
  if (-not $prefixDir) { throw "LogPrefix 缺少父目录: $logBase" }
  if (-not (Test-Path -LiteralPath $prefixDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $prefixDir | Out-Null
  }
} catch {
  Exit-With 'FAILED' $_.Exception.Message 2
}

$startTime = Get-Date
$startedAt = $startTime.ToString('o')
$deadlineAt = $startTime.AddMinutes($TimeoutMin)
$runningPhase = if ($ComputerUse) { 'waiting-lock' } else { 'running' }
$running = [ordered]@{
  label = $Label; cwd = $Cwd; sessionId = $SessionId; mode = $effectiveMode
  pid = $PID; childPid = $null; phase = $runningPhase
  startedAt = $startedAt; deadline = $deadlineAt.ToString('o')
  jsonl = $jsonlPath; progress = $dshProgressPath; extend = $extendPath
  log = $logBase; task = $taskPath; extendedMin = 0; computerUse = [bool]$ComputerUse
  effort = $effectiveEffort; browser = [bool]$Browser
}
try {
  [IO.File]::WriteAllText($taskPath, $taskText, $utf8)
  [IO.File]::WriteAllText($jsonlPath, '', $utf8)
  [IO.File]::WriteAllText($errPath, '', $utf8)
  if ($logsProgressEnabled) { [IO.File]::WriteAllText($logsProgressPath, '', $utf8) }
  if ($workspaceProgressPath) {
    if (-not (Test-Path -LiteralPath $workspaceProgressDir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $workspaceProgressDir | Out-Null
      $workspaceProgressDirCreated = $true
    }
  }
  Write-RunningMarker -path $runningPath -obj $running
} catch {
  Exit-With 'FAILED' "初始化日志失败: $($_.Exception.Message)" 1
}

# ---- 电脑操作全局互斥锁：仅在显式开启时获取，与个人版共用同一锁名 ----
# 等锁与执行分别最多 TimeoutMin 分钟；等锁失败不会启动 dsh。
$cuMutex = $null
$cuWaitSec = 0
$cuHeld = $false
if ($ComputerUse) {
  try {
    $cuMutex = New-Object System.Threading.Mutex($false, 'Global\dsh-delegate-computer-use')
  } catch {
    Complete-ProgressFile
    try { if (Test-Path -LiteralPath $runningPath) { Remove-Item -LiteralPath $runningPath -Force -ErrorAction SilentlyContinue } } catch { }
    Exit-With 'FAILED' "创建电脑操作互斥锁失败: $($_.Exception.Message)" 1
  }
  $lockWaitMs = [int][Math]::Min(([double]$TimeoutMin * 60000.0), 2147483647.0)
  $waitSw = [Diagnostics.Stopwatch]::StartNew()
  $got = $false
  $lockWaitError = $null
  try {
    $got = $cuMutex.WaitOne($lockWaitMs)
  } catch [System.Threading.AbandonedMutexException] {
    # 上一个持锁进程异常退出；此异常表示当前进程已取得锁。
    $got = $true
  } catch {
    $lockWaitError = $_.Exception.Message
  } finally {
    $waitSw.Stop()
  }
  $cuWaitSec = [int]$waitSw.Elapsed.TotalSeconds
  $cuHeld = $got
  if ($lockWaitError) {
    # 锁创建/等待本身出错，不要当成等锁超时（exit 4）。
    Complete-ProgressFile
    try { if (Test-Path -LiteralPath $runningPath) { Remove-Item -LiteralPath $runningPath -Force -ErrorAction SilentlyContinue } } catch { }
    try { $cuMutex.Dispose() } catch { }
    Exit-With 'FAILED' "等锁异常: $lockWaitError" 1
  }
  if (-not $got) {
    Complete-ProgressFile
    $endedAt = (Get-Date).ToString('o')
    $lockSid = if ($SessionId) { $SessionId } else { $null }
    $record = [ordered]@{
      label = $Label; status = 'TIMEOUT'; sessionId = $lockSid; cwd = $Cwd; mode = $effectiveMode; effort = $effectiveEffort; browser = [bool]$Browser; computerUse = $true; lockWaitSec = $cuWaitSec
      elapsedSec = $cuWaitSec; steps = 0; toolCalls = 0; toolErrors = 0
      inTok = [int64]0; outTok = [int64]0; cacheTok = [int64]0; thinkChars = 0
      startedAt = $startedAt; endedAt = $endedAt; exit = $null; turnEnd = $null
      finalPresent = $false; newGitEntries = $null; log = $logBase
      task = $taskPath; jsonl = $jsonlPath; errLog = $errPath; progress = $progressRecordPath; extend = $extendPath
      extendedMin = 0; inputTokens = 0; outputTokens = 0; cacheReadTokens = 0
      phase = 'waiting-lock'; host = $HostName; model = $modelId; kitVersion = $kitVersion
    }
    $indexError = $null
    $cleanupError = $null
    try { Add-IndexRecord -path $indexPath -line ($record | ConvertTo-Json -Compress) } catch { $indexError = "写入 index.jsonl 失败: $($_.Exception.Message)" }
    try {
      if (Test-Path -LiteralPath $runningPath) { Remove-Item -LiteralPath $runningPath -Force -ErrorAction Stop }
    } catch { $cleanupError = "删除运行标记失败: $($_.Exception.Message)" }
    $cuMutex.Dispose()
    Write-Output 'STATUS: TIMEOUT'
    if ($lockSid) { Write-Output "sessionId: $lockSid" } else { Write-Output 'sessionId: null' }
    Write-Output 'extendedMin: 0'
    Write-Output ("exit: null | turn_end: null | 耗时: {0:N0}s | 模式: {1} | 思考强度: {2}" -f $waitSw.Elapsed.TotalSeconds, $effectiveMode, $effectiveEffort)
    Write-Output "模型: $modelId | 思考: $effectiveEffort（$effortMode）| 权限: $effectiveMode"
    if ($precheckLine) { Write-Output $precheckLine }
    foreach ($w in $warnings) { Write-Output $w }
    Write-Output "电脑操作: 已开启 | 排队等锁 ${cuWaitSec}s"
    Write-Output '未启动 dsh：等待电脑操作锁超时。'
    Write-Output "工作目录: $Cwd"
    Write-Output ("步数: 0 | 工具调用: 0（失败 0）| tokens 新输入/输出: 0/0 | 缓存读取: 0（单价低，不代表新增工作量）| 浏览器: {0}" -f $(if ($Browser) { '已挂载' } else { '未挂载' }))
    if ($indexError) { Write-Output $indexError }
    if ($cleanupError) { Write-Output $cleanupError }
    foreach ($pe in @($script:progressCleanupErrors)) { if ($pe) { Write-Output $pe } }
    Write-Output "日志: $logBase.{task.md,jsonl,err.log,progress.md,extend}"
    Write-Output '--- dsh 最终回复 ---'
    Write-Output '（无）'
    Write-Output '（progress.md 为空：dsh 未启动）'
    exit 4
  }
}

try {
  # 拿到锁后重新设置执行截止时间；排队时间不计入执行预算。
  $executionStart = Get-Date
  $deadlineAt = $executionStart.AddMinutes($TimeoutMin)
  $running['phase'] = 'running'
  $running['deadline'] = $deadlineAt.ToString('o')
  $running['lockWaitSec'] = $cuWaitSec
  try { Write-RunningMarker -path $runningPath -obj $running } catch { $errors += "更新运行标记失败: $($_.Exception.Message)" }

  # ---- 运行约定：默认追加到实际送入 dsh 的任务文本，原任务单不改 ----
  $finalTaskText = $taskText
  if (-not $NoProtocol) {
    $softDeadline = $executionStart.AddMinutes($TimeoutMin * 0.75)
    $uiaScript = Join-Path $PSScriptRoot 'uia.ps1'
    if ($effectiveMode -eq 'read-only') {
      $progressLine = '- 进度落盘：本任务为只读权限，不能写任何文件（包括进度文件）。每完成一个子步骤，把阶段结论简要写进回复正文；最终回复按返回格式汇总。'
    } elseif ($effectiveMode -eq 'workspace-write') {
      $progressLine = "- 进度落盘：每完成一个子步骤或得出一批结论，立即把「时间 / 步骤 / 要点 / 证据（文件:行号 或 命令及结果）」追加写入 $dshProgressPath（UTF-8，只追加，禁止覆盖）。这是工作区内允许写的唯一额外文件，结束后由脚本移走；除任务单明确允许的文件外不要写其他文件。"
    } else {
      $progressLine = "- 进度落盘：每完成一个子步骤或得出一批结论，立即把「时间 / 步骤 / 要点 / 证据（文件:行号 或 命令及结果）」追加写入 $dshProgressPath（UTF-8，只追加，禁止覆盖）。只有追加写这个 progress 文件不算越权；除任务单明确允许的文件外不要写其他文件。"
    }
    $protocol = @"

---
【委派运行约定（由 dsh-run.ps1 自动追加，与任务单同等效力）】
- 时间预算：本次最长执行 $TimeoutMin 分钟。开始时间：$($executionStart.ToString('yyyy-MM-dd HH:mm:ss'))；初始硬截止：$($deadlineAt.ToString('yyyy-MM-dd HH:mm:ss'))。运行中主 Agent 可通过 $extendPath 延时，实际截止以 $runningPath 中的 deadline 为准。每个阶段用 Get-Date 自查当前时间，不要超过截止时间。
$progressLine
- 收尾时机：到 $($softDeadline.ToString('yyyy-MM-dd HH:mm:ss'))（初始预算的 75%）后停止开始新的探索，整理已有结论并按任务要求返回；未完成事项明确列出。若运行被延时，按新截止时间同样保留最后 25% 用于收尾。
- 不要派生子 Agent，也不要启动并行会话。
- 并行调用：互不依赖的读取、搜索、查询放在同一步里一次性发起多个工具调用，不要一步只调一个、等结果再发下一个；只有后一步依赖前一步结果时才分步。
- 效率：同一操作用同一种方法失败两次，就换方法或跳过并记录，不要原地反复试。先用搜索定位，再按行段读取；不重复读取已读且未变的文件；命令输出用 Select-Object -First、行号范围等限制在约 200 行以内。重复要用的逻辑写成脚本文件后反复调用，不要每步重写一大段命令。能一条命令完成的事不要拆成多步。
- 上下文：对话超过约 20 万 token 会被自动压缩，早期的工具输出会丢失，所以结论要及时写进 progress 文件，之后以它为准。
"@
    if ($Browser) {
      $protocol += "`r`n"
      $protocol += @"
- 浏览器操作优先用页面文本和无障碍树，少截图。
"@
    }
    if ($ComputerUse) {
      $protocol += "`r`n"
      $protocol += @"
- 电脑操作（本任务已开启）：
  - 首选 UIA 辅助脚本按元素名称操作，不按坐标点击。用法（每步一条命令，失败时输出会列出候选元素）：
      powershell -NoProfile -ExecutionPolicy Bypass -File "$uiaScript" windows
      ... tree  -Window <标题子串> [-Type Button] [-Name 关键字]     列出元素
      ... text  -Window <标题子串>                                   读取可见文字
      ... click -Window <标题子串> -Name <名称> [-Type Button] [-Exact] [-Index n]
      ... set   -Window <标题子串> [-Name <名称>] [-Type Edit] -Value <文本>
      ... keys  -Window <标题子串> -Value "{ENTER}"                  SendKeys 语法
      ... wait  -Window <标题子串> -Name <名称> [-Gone] [-Timeout 30] 等元素出现或消失，代替 Start-Sleep
      ... maximize|focus -Window <标题子串>
    -WindowPid <pid> 可代替 -Window。脚本已处理高 DPI 缩放和 Electron 首次访问时延迟构建无障碍树的问题。
  - 截图只用于确认视觉状态，不要用截图来找点击位置。
  - 必须改用 cua_driver 工具时：先最大化窗口；Electron/Chrome 窗口（类名 Chrome_WidgetWin_1）的点击和按键加 delivery_mode "foreground"；get_window_state 返回的 snapshot_id 原样照抄；界面变化后先重新 get_window_state 再点；page 的 query_dom 只用简单标签选择器。
"@
    }
    $finalTaskText = $taskText + "`r`n" + $protocol
  }

  $startFailure = $null
  $timedOut = $false
  $exitCode = -2
  $status = 'FAILED'
  # 事件流里的 session 优先；若进程被强杀且没来得及写 session，保留调用方传入的原 SessionId 供续接。
  $sid = $SessionId; $final = $null; $reason = $null
  $toolCalls = 0
  $steps = 0
  $thinkChars = 0
  $inTok = [int64]0; $outTok = [int64]0; $cacheTok = [int64]0
  $extendedMin = 0
  $stdout = ''
  $stderr = ''
  $p = $null
  $sw = [Diagnostics.Stopwatch]::StartNew()

  try {
    try {
      [IO.File]::WriteAllText($taskPath, $finalTaskText, $utf8)
    } catch {
      $startFailure = "写入实际任务文件失败: $($_.Exception.Message)"
      $errors += $startFailure
    }

    if (-not $startFailure) {
      try {
        $nodeArg = ConvertTo-CmdPath -value $node -what 'node 路径'
        $binArg = ConvertTo-CmdPath -value $bin -what 'dsh 入口路径'
        $patchArgs = @()
        foreach ($pp in $selectedPatchPaths) {
          $patchArgs += @('--patch', (ConvertTo-CmdPath -value $pp -what '补丁路径'))
        }
        $taskArg = ConvertTo-CmdPath -value $taskPath -what '任务文件路径'
        $jsonlArg = ConvertTo-CmdPath -value $jsonlPath -what 'jsonl 日志路径'
        $errArg = ConvertTo-CmdPath -value $errPath -what 'err 日志路径'
      } catch {
        $startFailure = "cmd 路径不安全，拒绝启动: $($_.Exception.Message)"
        $errors += $startFailure
      }
    }

    if (-not $startFailure) {
      $dshArgs = @($nodeArg, $binArg, 'headless')
      $dshArgs += $patchArgs
      $dshArgs += '--json'
      if ($SessionId) { $dshArgs += @('--session-id', $SessionId) }
      $dshArgs += '-'
      $cmdLine = ($dshArgs -join ' ') + ' < ' + $taskArg + ' > ' + $jsonlArg + ' 2> ' + $errArg
      if ($cmdLine.Length -gt 8000) {
        $startFailure = 'cmd 命令超过 8000 字符，拒绝启动'
        $errors += $startFailure
      }
    }

    if (-not $startFailure) {
      $comspec = $env:ComSpec
      if ([string]::IsNullOrWhiteSpace($comspec) -or -not (Test-Path -LiteralPath $comspec -PathType Leaf)) {
        $comspec = Join-Path $env:SystemRoot 'System32\cmd.exe'
      }
      if (-not (Test-Path -LiteralPath $comspec -PathType Leaf)) {
        $startFailure = "找不到 cmd.exe: $comspec"
        $errors += $startFailure
      }
    }

    if (-not $startFailure) {
      # stdout/stderr 由 cmd 直接重定向到文件，进程边跑边写；任务日志文件作为 stdin。
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $comspec
      $psi.Arguments = '/d /s /c "' + $cmdLine + '"'
      $psi.WorkingDirectory = $Cwd
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      # 不碰 ProcessStartInfo.EnvironmentVariables：本机 PowerShell 5.1 首次访问会生成
      # 缺少 SystemRoot 的不完整环境，Node 会因 CSPRNG 初始化失败直接 abort。
      # 改为在父进程设置环境变量，让子进程自然继承，启动后立即恢复。
      $prevPermissionMode = $env:DSH_PERMISSION_MODE
      $env:DSH_PERMISSION_MODE = $effectiveMode
      try {
        $p = [Diagnostics.Process]::Start($psi)
      } catch {
        $startFailure = "启动 dsh 失败: $($_.Exception.Message)"
        $errors += $startFailure
      } finally {
        if ([string]::IsNullOrEmpty($prevPermissionMode)) {
          Remove-Item Env:DSH_PERMISSION_MODE -ErrorAction SilentlyContinue
        } else {
          $env:DSH_PERMISSION_MODE = $prevPermissionMode
        }
      }
    }

    if ($p) {
      $running['childPid'] = $p.Id
      try { Write-RunningMarker -path $runningPath -obj $running } catch { $errors += "写入 childPid 失败: $($_.Exception.Message)" }

      # 每 5 秒检查一次 .extend 和截止时间；合法延时只累加执行 deadline。
      while (-not $p.WaitForExit(5000)) {
        $add = Read-ExtendRequest -path $extendPath
        if ($null -ne $add) {
          $deadlineAt = $deadlineAt.AddMinutes($add)
          $extendedMin += $add
          $running['deadline'] = $deadlineAt.ToString('o')
          $running['extendedMin'] = $extendedMin
          try { Write-RunningMarker -path $runningPath -obj $running } catch { $errors += "更新延时标记失败: $($_.Exception.Message)" }
        }
        if ($p.HasExited) { break }
        if ((Get-Date) -ge $deadlineAt) {
          $timedOut = $true
          Stop-OwnedProcessTree $p
          break
        }
      }

      if ($timedOut) {
        $exitCode = -1
      } elseif ($p.HasExited) {
        try { $exitCode = $p.ExitCode } catch { $exitCode = -2; $errors += "读取退出码失败: $($_.Exception.Message)" }
      } else {
        $exitCode = -2
        $errors += 'dsh 进程未在限定时间内退出'
      }
    }

    # 事件流已由进程直接写入文件；只读不重写，外层被强杀时首个 session 事件仍保留。
    $stdout = Read-Utf8 $jsonlPath
    $stderr = Read-Utf8 $errPath

    # ---- 解析事件流（坏行 / 缺字段不抛错）----
    $ev = Read-DshEvents $stdout $SessionId
    if ($ev.sid) { $sid = [string]$ev.sid }
    $final = $ev.final
    $reason = $ev.reason
    $toolCalls = [int]$ev.toolCalls
    $steps = [int]$ev.steps
    $thinkChars = [int]$ev.thinkChars
    $inTok = [int64]$ev.inTok; $outTok = [int64]$ev.outTok; $cacheTok = [int64]$ev.cacheTok
    $toolErrors = @($ev.toolErrors)
    $errors += @($ev.errors)

    # ---- 严格状态判定：只有 exit=0 + turn_end=completed + final 才算 OK ----
    $errBlob = ($stderr + "`n" + ($errors -join "`n"))
    $unavailablePattern = 'MISSING_CREDENTIAL|Unauthorized|\b401\b|\b402\b|\b403\b|insufficient|quota|balance|subscription|payment|invalid api key|api key'
    if ($timedOut) { $status = 'TIMEOUT' }
    elseif ($startFailure) { $status = 'FAILED' }
    elseif ($exitCode -eq 0 -and $reason -eq 'completed' -and -not [string]::IsNullOrEmpty([string]$final)) { $status = 'OK' }
    elseif ($errBlob -match $unavailablePattern) { $status = 'DSH_UNAVAILABLE' }
    else { $status = 'FAILED' }
  } catch {
    $status = 'FAILED'
    $errors += "运行异常: $($_.Exception.Message)"
  } finally {
    try { $sw.Stop() } catch { }
    if ($p) {
      try { if (-not $p.HasExited) { Stop-OwnedProcessTree $p } } catch { }
    }
    # 正常、超时、失败都在这里把工作区进度搬回日志目录；Git 快照随后再取。
    Complete-ProgressFile
  }

  $gitAfter = Get-GitState $Cwd
  $gitLines = @(); $newEntries = @(); $goneEntries = @()
  if (-not $gitBefore) {
    $gitLines += '（未取得 Git 快照：可能非仓库或 Git 不可用，需人工核对范围）'
  } elseif (-not $gitAfter) {
    $gitLines += '⚠ 无法取得运行后的 Git 快照，需人工检查仓库状态。'
  } else {
    if ($gitAfter.Head -ne $gitBefore.Head) { $gitLines += "⚠ HEAD 变化: $($gitBefore.Head) -> $($gitAfter.Head)" }
    if ($gitAfter.Branch -ne $gitBefore.Branch) { $gitLines += "⚠ 分支变化: $($gitBefore.Branch) -> $($gitAfter.Branch)" }
    $gitBeforeStatus = @($gitBefore.Status | Where-Object { -not (Test-GitStatusPathIgnored $_) })
    $gitAfterStatus = @($gitAfter.Status | Where-Object { -not (Test-GitStatusPathIgnored $_) })
    $newEntries = @($gitAfterStatus | Where-Object { $gitBeforeStatus -notcontains $_ })
    $goneEntries = @($gitBeforeStatus | Where-Object { $gitAfterStatus -notcontains $_ })
    if ($newEntries.Count) { $gitLines += '本次新增/变化的 git 状态:'; $gitLines += ($newEntries | ForEach-Object { "  $_" }) }
    if ($goneEntries.Count) { $gitLines += '运行前存在、运行后消失的状态:'; $gitLines += ($goneEntries | ForEach-Object { "  $_" }) }
    if (-not $newEntries.Count -and -not $goneEntries.Count) { $gitLines += 'git 状态无变化（仍须检查实际 diff，已有修改可能被再次改动）' }
  }

  # ---- 完成记录：追加到 index.jsonl，按日志路径互斥 ----
  $endedAt = (Get-Date).ToString('o')
  $record = [ordered]@{
    label = $Label; status = $status; sessionId = $sid; cwd = $Cwd; mode = $effectiveMode; effort = $effectiveEffort; browser = [bool]$Browser
    host = $HostName; model = $modelId; kitVersion = $kitVersion
    startedAt = $startedAt; endedAt = $endedAt; exit = $exitCode; turnEnd = $reason
    finalPresent = [bool]$final
    newGitEntries = if ($gitBefore -and $gitAfter) { $newEntries.Count } else { $null }
    log = $logBase; task = $taskPath; jsonl = $jsonlPath; errLog = $errPath
    progress = $progressRecordPath; extend = $extendPath
    extendedMin = $extendedMin
    elapsedSec = [int]$sw.Elapsed.TotalSeconds; steps = $steps; toolCalls = $toolCalls; toolErrors = $toolErrors.Count
    inTok = $inTok; outTok = $outTok; cacheTok = $cacheTok; thinkChars = $thinkChars
    inputTokens = $inTok; outputTokens = $outTok; cacheReadTokens = $cacheTok
    computerUse = [bool]$ComputerUse; lockWaitSec = $cuWaitSec
  }
  if ($startFailure) { $record['startFailure'] = $startFailure }
  $indexError = $null
  $cleanupError = $null
  try {
    Add-IndexRecord -path $indexPath -line ($record | ConvertTo-Json -Compress)
  } catch {
    $indexError = "写入 index.jsonl 失败: $($_.Exception.Message)"
    $errors += $indexError
  }
  try {
    if (Test-Path -LiteralPath $runningPath) { Remove-Item -LiteralPath $runningPath -Force -ErrorAction Stop }
  } catch {
    $cleanupError = "删除运行标记失败: $($_.Exception.Message)"
  }
  try { if (Test-Path -LiteralPath $extendPath) { Remove-Item -LiteralPath $extendPath -Force -ErrorAction SilentlyContinue } } catch { }

  # ---- 输出摘要 ----
  Write-Output "STATUS: $status"
  if ($sid) { Write-Output "sessionId: $sid" } else { Write-Output 'sessionId: null' }
  Write-Output "extendedMin: $extendedMin"
  Write-Output ("exit: {0} | turn_end: {1} | 耗时: {2:N0}s | 模式: {3} | 思考强度: {4}" -f $exitCode, $reason, $sw.Elapsed.TotalSeconds, $effectiveMode, $effectiveEffort)
  Write-Output "模型: $modelId | 思考: $effectiveEffort（$effortMode）| 权限: $effectiveMode"
  if ($precheckLine) { Write-Output $precheckLine }
  foreach ($w in $warnings) { Write-Output $w }
  if ($ComputerUse) { Write-Output "电脑操作: 已开启 | 排队等锁 ${cuWaitSec}s" }
  Write-Output ("步数: {0} | 工具调用: {1}（失败 {2}）| tokens 新输入/输出: {3}/{4} | 缓存读取: {5}（单价低，不代表新增工作量）| 浏览器: {6}" -f $steps, $toolCalls, $toolErrors.Count, $inTok, $outTok, $cacheTok, $(if ($Browser) { '已挂载' } else { '未挂载' }))
  Write-Output "工作目录: $Cwd"
  $gitLines | ForEach-Object { Write-Output $_ }
  if ($startFailure) { Write-Output "启动失败: $startFailure" }
  if ($indexError) { Write-Output $indexError }
  if ($cleanupError) { Write-Output $cleanupError }
  foreach ($pe in @($script:progressCleanupErrors)) { if ($pe) { Write-Output $pe } }
  if ($timedOut) { Write-Output '已超时：已尝试终止本次拥有的 dsh 进程树，并清理运行标记。' }
  if ($status -eq 'FAILED' -and -not $final -and -not $startFailure) { Write-Output '未收到 final 事件，按失败处理，不判定为 OK。' }
  if ($toolErrors.Count) { Write-Output '失败的工具调用（前 5 条）:'; $toolErrors | Select-Object -First 5 | ForEach-Object { Write-Output "  - $_" } }
  if ($status -ne 'OK') {
    $tail = ($stderr -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 8) -join "`n"
    if ($tail) { Write-Output "stderr 末尾:`n$tail" }
    if ($errors.Count) { Write-Output "错误事件:`n$($errors -join "`n")" }
  }
  Write-Output "日志: $logBase.{task.md,jsonl,err.log,progress.md,extend}"

  Write-Output '--- dsh 最终回复 ---'
  if ($final) {
    if ($final.Length -gt $MaxFinalChars) { $final = $final.Substring(0, $MaxFinalChars) + "`n…（已截断，全文见 jsonl 的 final 事件）" }
    Write-Output $final
  } else { Write-Output '（无）' }

  if ($status -ne 'OK' -and -not $final) {
    if ($progressRecordPath) {
      $progressText = Read-Utf8 $logsProgressPath
      if ($progressText.Trim()) {
        $tailText = Get-TruncatedTail -text $progressText -max $MaxFinalChars -note '…（前文已截断，全文见 progress.md）'
        Write-Output '--- 阶段性结论（progress.md 尾部）---'
        Write-Output $tailText
      } else {
        Write-Output '（progress.md 为空：dsh 未按约定落盘）'
      }
    } else {
      Write-Output '（本任务为只读权限，未启用进度文件）'
    }
    if ($sid) {
      Write-Output "挽救方法：用 -SessionId $sid 续接，任务写「不要再调用任何工具，直接根据已有分析按原返回格式输出结论」，通常几分钟完成。"
    } else {
      Write-Output '未捕获 sessionId，无法自动续接；请查看上面的 progress.md 与 jsonl。'
    }
  }
} finally {
  # 异常路径的兜底清理（正常路径已在运行段 finally 中完成）。
  Complete-ProgressFile
  if ($cuMutex) {
    if ($cuHeld) { try { $cuMutex.ReleaseMutex() } catch { } }
    $cuMutex.Dispose()
  }
}

switch ($status) { 'OK' { exit 0 } 'DSH_UNAVAILABLE' { exit 3 } 'TIMEOUT' { exit 4 } 'DSH_INCOMPATIBLE' { exit 5 } default { exit 1 } }
