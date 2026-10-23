# dsh-delegate-kit 共用函数（由 kit.ps1 dot-source；dsh-run.ps1 不依赖本文件）。
# 兼容 Windows PowerShell 5.1。给人看的提示一律走 Write-KitInfo，不要用 Write-Output（会混进返回值）。

$script:KitVersion = '0.4.0'
$script:KitUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:KitJsonMode = $false
$script:KitModes = @('read-only', 'workspace-write', 'danger-full-access')
# 浏览器、电脑操作所需的 headless 插件包，版本必须与 dsh 一致
$script:KitOptionalPlugins = @(
  '@deepseek-ai/dsh-browser-use',
  '@deepseek-ai/dsh-experimental-browser-use-playwright-mcp',
  '@deepseek-ai/dsh-computer-use',
  '@deepseek-ai/dsh-experimental-computer-use-cua-driver-native'
)
$script:KitBrowserPlugins = @('@deepseek-ai/dsh-browser-use', '@deepseek-ai/dsh-experimental-browser-use-playwright-mcp')
$script:KitComputerPlugins = @('@deepseek-ai/dsh-computer-use', '@deepseek-ai/dsh-experimental-computer-use-cua-driver-native')
$script:KitDefaultPluginIds = [ordered]@{
  credentials       = [ordered]@{ id = 'credentials'; name = '@deepseek-ai/dsh-credentials-local' }
  agentDefaultModel = [ordered]@{ id = 'agent-default-model'; name = '@deepseek-ai/dsh-agent-default-model' }
  compaction        = [ordered]@{ id = 'compaction-basic'; name = '@deepseek-ai/dsh-compaction-basic' }
  browserUse        = [ordered]@{ id = 'browser-use'; name = '@deepseek-ai/dsh-browser-use' }
  browserProvider   = [ordered]@{ id = 'browser-use-playwright-mcp'; name = '@deepseek-ai/dsh-experimental-browser-use-playwright-mcp' }
  computerUse       = [ordered]@{ id = 'computer-use'; name = '@deepseek-ai/dsh-computer-use' }
  computerProvider  = [ordered]@{ id = 'computer-use-cua-driver-native'; name = '@deepseek-ai/dsh-experimental-computer-use-cua-driver-native' }
}

# ---- 输出 ----
function Write-KitInfo([string]$msg) {
  # -Json 模式下 stdout 只留给 JSON，提示改写 stderr
  if ($script:KitJsonMode) { [Console]::Error.WriteLine($msg) } else { [Console]::Out.WriteLine($msg) }
}

# ---- 文本与 JSON（UTF-8 无 BOM）----
function Read-KitText([string]$path) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $text = [IO.File]::ReadAllText($path, $script:KitUtf8)
  if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
  return $text
}
function Test-KitUtf8TextFile([string]$path) {
  # 按字节判断：UTF-8（可带 BOM）返回 Ok=$true；UTF-16 BOM 或非法 UTF-8 返回 Ok=$false
  $r = [ordered]@{ Exists = $false; Ok = $true; Bom = $false; Reason = '' }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $r }
  $r.Exists = $true
  $bytes = [IO.File]::ReadAllBytes($path)
  if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
    $r.Ok = $false; $r.Reason = 'UTF-16 BOM'
    return $r
  }
  $offset = 0
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $offset = 3; $r.Bom = $true
  }
  $strict = New-Object System.Text.UTF8Encoding($false, $true)
  try {
    [void]$strict.GetString($bytes, $offset, $bytes.Length - $offset)
  } catch {
    $r.Ok = $false; $r.Reason = '非法 UTF-8 字节序列'
  }
  return $r
}
function Write-KitText([string]$path, [string]$text) {
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($path, $text, $script:KitUtf8)
}
function Read-KitJson([string]$path) {
  $text = Read-KitText $path
  if ($null -eq $text -or -not $text.Trim()) { return $null }
  return ($text | ConvertFrom-Json)
}
function Write-KitJson([string]$path, $obj) {
  Write-KitText $path ($obj | ConvertTo-Json -Depth 20)
}
function Test-KitBom([string]$path) {
  $fs = [IO.File]::OpenRead($path)
  try { $b = New-Object byte[] 3; $n = $fs.Read($b, 0, 3) } finally { $fs.Dispose() }
  return ($n -eq 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}
function Get-KitSha256([string]$path) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $sha = [Security.Cryptography.SHA256]::Create()
  $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try { return [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '') } finally { $fs.Dispose(); $sha.Dispose() }
}
function Get-KitProp($obj, [string]$name) {
  # 容错读取属性：对象为空或属性不存在时返回 $null
  if ($null -eq $obj) { return $null }
  if ($obj -is [System.Collections.IDictionary]) { if ($obj.Contains($name)) { return $obj[$name] } else { return $null } }
  $p = $obj.PSObject.Properties[$name]
  if ($null -eq $p) { return $null }
  return $p.Value
}
function ConvertTo-KitLocalTimeText([string]$iso) {
  # ISO 时间转本地 yyyy-MM-dd HH:mm；空值或格式不对时返回空串
  if (-not $iso) { return '' }
  try {
    $dto = [DateTimeOffset]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture)
    return $dto.LocalDateTime.ToString('yyyy-MM-dd HH:mm')
  } catch {
    return ''
  }
}

# ---- 路径 ----
function Get-DshHome {
  if ($env:DSH_HOME) { return [IO.Path]::GetFullPath($env:DSH_HOME) }
  return (Join-Path $HOME '.dsh')
}
function Get-KitPaths {
  $kitHome = if ($env:DSH_KIT_HOME) { [IO.Path]::GetFullPath($env:DSH_KIT_HOME) } else { Join-Path (Get-DshHome) 'dsh-delegate-kit' }
  return [ordered]@{
    Home      = $kitHome
    State     = Join-Path $kitHome 'state.json'
    Patches   = Join-Path $kitHome 'patches'
    Logs      = Join-Path $kitHome 'logs'
    LogsCodex = Join-Path $kitHome 'logs\codex'
    Backups   = Join-Path $kitHome 'backups'
    Diag      = Join-Path $kitHome 'diag'
    Off       = Join-Path $kitHome 'off.json'
    DshHome   = Get-DshHome
    Headless  = Join-Path (Get-DshHome) 'profiles\headless'
    WebProfile     = Join-Path (Get-DshHome) 'profiles\web\cordis.patch.yml'
    DesktopProfile = Join-Path (Get-DshHome) 'profiles\desktop\cordis.patch.yml'
    Helper    = Join-Path $PSScriptRoot 'dshkit.mjs'
    Templates = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'templates'
  }
}

# ---- 状态文件 ----
function Read-KitState { return (Read-KitJson (Get-KitPaths).State) }
function Save-KitState($state) {
  $state.updatedAt = (Get-Date).ToString('o')
  Write-KitJson (Get-KitPaths).State $state
}
function Get-KitModeRank([string]$mode) { return [array]::IndexOf($script:KitModes, $mode) }

# ---- 包元数据（scripts\lib\kit-meta.json：已验证的 dsh 版本、更新源）----
function Get-KitMeta {
  $r = [ordered]@{
    testedDshVersions     = @()
    recommendedDshVersion = ''
    updateSource          = ''
    updateBranch          = 'main'
    packagePath           = 'dsh-delegate-kit'
    npxSource             = 'beilanya/dsh-skills'
  }
  $m = $null
  try { $m = Read-KitJson (Join-Path $PSScriptRoot 'kit-meta.json') } catch { $m = $null }
  if ($null -ne $m) {
    $tv = Get-KitProp $m 'testedDshVersions'
    if ($tv) { $r.testedDshVersions = @($tv | ForEach-Object { [string]$_ }) }
    foreach ($k in @('recommendedDshVersion', 'updateSource', 'updateBranch', 'packagePath', 'npxSource')) {
      $v = [string](Get-KitProp $m $k)
      if ($v) { $r[$k] = $v }
    }
  }
  # 测试或镜像用：环境变量覆盖更新源（可以是本地仓库路径）
  if ($env:DSH_KIT_UPDATE_SOURCE) { $r.updateSource = [string]$env:DSH_KIT_UPDATE_SOURCE }
  return $r
}
function Get-KitDshTestedInfo([string]$version) {
  # 当前 dsh 版本是否在本 kit 验证过的列表里；未验证只提示，不判不兼容
  $meta = Get-KitMeta
  $tested = @($meta.testedDshVersions)
  $r = [ordered]@{
    version     = $version
    tested      = [bool]($version -and ($tested -contains $version))
    testedList  = $tested
    recommended = [string]$meta.recommendedDshVersion
    rollback    = ''
    message     = ''
  }
  if ($r.recommended) { $r.rollback = 'npm i -g @deepseek-ai/dsh@' + $r.recommended }
  if ($version -and -not $r.tested -and $tested.Count -gt 0) {
    $msg = 'dsh ' + $version + ' 未经本 kit 验证（已验证：' + ($tested -join '、') + '）。派发异常时可运行 update 获取新版 kit'
    if ($r.rollback) { $msg += '，或回退 dsh：' + $r.rollback }
    $r.message = $msg
  }
  return $r
}

# ---- 定位 dsh / node ----
function Find-KitDsh {
  $r = [ordered]@{ Found = $false; Base = $null; Bin = $null; Node = $null; PackageDir = $null; Version = $null; NodeVersion = $null; Error = $null }
  $cmd = Get-Command dsh -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd -or -not $cmd.Source) { $r.Error = '找不到 dsh 命令。安装：npm i -g @deepseek-ai/dsh（需要 Node.js）'; return $r }
  $r.Base = Split-Path $cmd.Source -Parent
  $r.PackageDir = Join-Path $r.Base 'node_modules\@deepseek-ai\dsh'
  $r.Bin = Join-Path $r.PackageDir 'lib\bin.js'
  $node = Join-Path $r.Base 'node.exe'
  if (-not (Test-Path -LiteralPath $node -PathType Leaf)) {
    $nc = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nc -and $nc.Source) { $node = $nc.Source } else { $node = $null }
  }
  $r.Node = $node
  if (-not $node) { $r.Error = '找不到 Node.js（node.exe）。请安装 Node.js 并确认 node 在 PATH 中'; return $r }
  if (-not (Test-Path -LiteralPath $r.Bin -PathType Leaf)) { $r.Error = "找不到 dsh 入口：$($r.Bin)"; return $r }
  $pkg = Read-KitJson (Join-Path $r.PackageDir 'package.json')
  $r.Version = [string](Get-KitProp $pkg 'version')
  if (-not $r.Version) { $r.Error = "读不到 dsh 版本：$($r.PackageDir)\package.json"; return $r }
  $r.NodeVersion = (& $node --version 2>$null | Select-Object -First 1)
  $r.Found = $true
  return $r
}

# ---- 进程调用 ----
function ConvertTo-KitArg([string]$value) {
  if ($null -eq $value) { $value = '' }
  if ($value -eq '') { return '""' }
  if ($value -notmatch '[\s"]') { return $value }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $bs = 0
  foreach ($ch in $value.ToCharArray()) {
    if ($ch -eq '\') { $bs++; continue }
    if ($ch -eq '"') { [void]$sb.Append(('\' * ($bs * 2 + 1))); [void]$sb.Append('"'); $bs = 0; continue }
    if ($bs -gt 0) { [void]$sb.Append(('\' * $bs)); $bs = 0 }
    [void]$sb.Append($ch)
  }
  if ($bs -gt 0) { [void]$sb.Append(('\' * ($bs * 2))) }
  [void]$sb.Append('"')
  return $sb.ToString()
}
function Get-KitReadTaskText($task) {
  # 只取已完成的读取任务；未完成时绝不读 .Result，避免永久阻塞
  if ($null -eq $task -or -not $task.IsCompleted) { return '' }
  try { return [string]$task.Result } catch { return '' }
}
function Invoke-KitProcess([string]$file, [string[]]$argList, [string]$cwd, [int]$timeoutSec = 120) {
  # 运行外部程序并收集 stdout/stderr（UTF-8）；超时会终止进程
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $file
  $psi.Arguments = (($argList | ForEach-Object { ConvertTo-KitArg $_ }) -join ' ')
  if ($cwd) { $psi.WorkingDirectory = $cwd }
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $script:KitUtf8
  $psi.StandardErrorEncoding = $script:KitUtf8
  $p = [Diagnostics.Process]::Start($psi)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  $timedOut = $false
  if (-not $p.WaitForExit($timeoutSec * 1000)) {
    $timedOut = $true
    try { & taskkill.exe /T /F /PID $p.Id 2>$null | Out-Null } catch { }
    [void]$p.WaitForExit(5000)
  }
  $outOk = $outTask.Wait(5000)
  $errOk = $errTask.Wait(5000)
  if (-not $outOk -or -not $errOk) { $timedOut = $true }
  $out = Get-KitReadTaskText $outTask
  $err = Get-KitReadTaskText $errTask
  if (-not $p.HasExited) {
    try { & taskkill.exe /T /F /PID $p.Id 2>$null | Out-Null } catch { }
    [void]$p.WaitForExit(2000)
  }
  $code = if ($timedOut -or -not $p.HasExited) { -1 } else { $p.ExitCode }
  try { $p.Dispose() } catch { }
  return [ordered]@{ ExitCode = $code; Out = $out; Err = $err; TimedOut = $timedOut }
}
function Get-KitWorkDir {
  # 子进程工作目录：KIT_HOME 可能尚未创建（setup 第一段不写盘），此时用临时目录
  $h = (Get-KitPaths).Home
  if (Test-Path -LiteralPath $h -PathType Container) { return $h }
  return [IO.Path]::GetTempPath()
}
function Invoke-KitHelper($dsh, [string[]]$helperArgs) {
  # 调用 lib\dshkit.mjs，stdout 应为一个 JSON 对象；返回 @{ ExitCode; Json; Out; Err }
  $paths = Get-KitPaths
  $r = Invoke-KitProcess $dsh.Node (@($paths.Helper) + $helperArgs) (Get-KitWorkDir) 120
  $json = $null
  if ($r.Out -and $r.Out.Trim()) { try { $json = $r.Out | ConvertFrom-Json } catch { $json = $null } }
  return [ordered]@{ ExitCode = $r.ExitCode; Json = $json; Out = $r.Out; Err = $r.Err }
}
function Invoke-KitDumpConfig($dsh, [string[]]$patchFiles, [string]$outFile) {
  # dsh headless --patch ... --dump-config（不调模型，约 0.25 秒）；--patch 必须在 --dump-config 前
  $a = @($dsh.Bin, 'headless')
  foreach ($f in $patchFiles) { $a += @('--patch', $f) }
  $a += '--dump-config'
  $r = Invoke-KitProcess $dsh.Node $a (Get-KitWorkDir) 60
  if ($outFile) { Write-KitText $outFile ([string]$r.Out) }
  return $r
}

# ---- 环境探测 ----
function Find-KitChrome {
  # 返回 @{ Path; Note }；找不到时 Path 为 $null
  $cands = @()
  foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if ($root) { $cands += (Join-Path $root 'Google\Chrome\Application\chrome.exe') }
  }
  foreach ($hive in @('HKLM:', 'HKCU:')) {
    try {
      $v = (Get-ItemProperty -Path "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" -ErrorAction Stop).'(default)'
      if ($v) { $cands += $v.Trim('"') }
    } catch { }
  }
  foreach ($c in $cands) { if (Test-Path -LiteralPath $c -PathType Leaf) { return [ordered]@{ Path = $c; Note = '' } } }
  $edge = @()
  foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
    if ($root) { $edge += (Join-Path $root 'Microsoft\Edge\Application\msedge.exe') }
  }
  foreach ($hive in @('HKLM:', 'HKCU:')) {
    try {
      $v = (Get-ItemProperty -Path "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe" -ErrorAction Stop).'(default)'
      if ($v) { $edge += $v.Trim('"') }
    } catch { }
  }
  foreach ($c in $edge) { if (Test-Path -LiteralPath $c -PathType Leaf) { return [ordered]@{ Path = $c; Note = '未找到 Chrome，使用 Edge 代替' } } }
  return [ordered]@{ Path = $null; Note = '未找到 Chrome 或 Edge，浏览器功能不可用' }
}
function Get-KitPluginStatus($dsh) {
  # 检查 headless profile 里浏览器/电脑操作插件是否与 dsh 版本对齐（只读）
  $paths = Get-KitPaths
  $expected = $dsh.Version
  $installed = [ordered]@{}
  $bad = @()
  $pkgJson = Read-KitJson (Join-Path $paths.Headless 'package.json')
  $deps = Get-KitProp $pkgJson 'dependencies'
  foreach ($name in $script:KitOptionalPlugins) {
    $declared = [string](Get-KitProp $deps $name)
    $modPkg = Read-KitJson (Join-Path $paths.Headless ("node_modules\" + $name.Replace('/', '\') + '\package.json'))
    $ver = [string](Get-KitProp $modPkg 'version')
    $installed[$name] = if ($ver) { $ver } else { $null }
    if ($ver -ne $expected -or $declared -ne $expected) { $bad += $name }
  }
  $cmd = 'dsh plugin --profile headless add ' + (($script:KitOptionalPlugins | ForEach-Object { "$_@$expected" }) -join ' ')
  return [ordered]@{
    aligned = ($bad.Count -eq 0); expected = $expected; installed = $installed; misaligned = @($bad)
    browserOk = (@($bad | Where-Object { $script:KitBrowserPlugins -contains $_ }).Count -eq 0)
    computerOk = (@($bad | Where-Object { $script:KitComputerPlugins -contains $_ }).Count -eq 0)
    command = $cmd
  }
}
