#Requires -Version 5.1
<#
  dsh-delegate-kit 安装器（仅 Windows，兼容 Windows PowerShell 5.1）

  把当前包里的 skill 文件安装到 Claude Code 和/或 Codex 的 skills 目录。
  目标叶子名固定为 dsh-delegate-kit，绝不能覆盖用户的个人版 dsh-delegate。
#>

param(
    [string]$Target = '',
    [string]$ClaudeSkillsDir = '',
    [string]$CodexSkillsDir = '',
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$WhatIf,
    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'

$script:KitVersion = '0.2.0'
$script:SourceRoot = ''
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Human {
    param([string]$Text)
    [Console]::Out.WriteLine($Text)
}

function Show-Usage {
    Write-Human '用法：'
    Write-Human '  install.ps1 -Target claude|codex|both [选项]'
    Write-Human ''
    Write-Human '选项：'
    Write-Human '  -ClaudeSkillsDir <目录>  覆盖 Claude skills 根目录（默认 $HOME\.claude\skills）'
    Write-Human '  -CodexSkillsDir <目录>   覆盖 Codex skills 根目录（默认 $env:CODEX_HOME\skills 或 $HOME\.codex\skills）'
    Write-Human '  -Force                   目标已存在时覆盖重装'
    Write-Human '  -Uninstall               卸载 dsh-delegate-kit（只删除带 .kit-install.json 的目录）'
    Write-Human '  -WhatIf                  只列出将要复制/删除的文件，不改动磁盘'
    Write-Human '  -Interactive             菜单方式选择宿主，失败时询问是否覆盖重装（install.cmd 双击时使用）'
    Write-Human ''
    Write-Human '示例：'
    Write-Human '  install.ps1 -Target both'
    Write-Human '  install.ps1 -Target claude -Force'
    Write-Human '  install.ps1 -Target both -Uninstall'
}

function Get-CleanPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    return $full.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
}

function Get-HomeDir {
    $homeDir = $HOME
    if ([string]::IsNullOrEmpty($homeDir)) {
        $homeDir = [Environment]::GetFolderPath('UserProfile')
    }
    if ([string]::IsNullOrEmpty($homeDir)) {
        throw '无法确定用户主目录（$HOME 为空）'
    }
    return $homeDir
}

function Test-PathOverlap {
    param([string]$PathA, [string]$PathB)
    $sep = [IO.Path]::DirectorySeparatorChar
    if ($PathA -ieq $PathB) { return $true }
    $a = $PathA.TrimEnd([char[]]@($sep)) + $sep
    $b = $PathB.TrimEnd([char[]]@($sep)) + $sep
    if ($a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

# 逐级解析已存在的目录/文件，遇到 junction / symlink 时跟随到最终目标。
# 不存在的尾部按字面拼接到已解析的父目录上；无法解析时抛错，由调用方拒绝操作。
function Resolve-RealPath {
    param([string]$Path, [int]$Depth = 0)
    if ($Depth -gt 32) {
        throw "符号链接/联接点层级过深，无法解析：$Path"
    }
    $full = Get-CleanPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root)) {
        throw "路径没有根（无法确定盘符或 UNC 根）：$full"
    }
    if ($full.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) -ieq $root.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))) {
        return $root
    }

    $current = $root
    $segments = @($full.Substring($root.Length).Split([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries))
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $candidate = Join-Path $current $segments[$i]
        $exists = [IO.Directory]::Exists($candidate) -or [IO.File]::Exists($candidate)
        if (-not $exists) {
            $rest = @($segments[$i..($segments.Count - 1)]) -join [IO.Path]::DirectorySeparatorChar
            return Get-CleanPath (Join-Path $current $rest)
        }
        if ((-not [IO.Directory]::Exists($candidate)) -and [IO.File]::Exists($candidate) -and $i -lt ($segments.Count - 1)) {
            throw "路径组件是文件，无法作为目录继续解析：$candidate"
        }

        try {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        }
        catch {
            throw "无法读取路径组件「$candidate」：$($_.Exception.Message)"
        }

        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $targets = @($item.Target)
            if ($targets.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$targets[0])) {
                throw "路径组件是联接点/符号链接，但无法取得其目标：$candidate"
            }
            $targetPath = [string]$targets[0]
            if ($targetPath.StartsWith("\??\")) {
                $targetPath = $targetPath.Substring(4)
            }
            elseif ($targetPath.StartsWith("\\?\")) {
                $targetPath = $targetPath.Substring(4)
            }
            if (-not [IO.Path]::IsPathRooted($targetPath)) {
                $targetPath = Join-Path ([IO.Path]::GetDirectoryName($candidate)) $targetPath
            }
            if ($i -lt ($segments.Count - 1)) {
                $remaining = @($segments[($i + 1)..($segments.Count - 1)]) -join [IO.Path]::DirectorySeparatorChar
                $targetPath = Join-Path $targetPath $remaining
            }
            return Resolve-RealPath -Path $targetPath -Depth ($Depth + 1)
        }

        $current = $candidate
    }
    return Get-CleanPath $current
}

function Assert-SafeTarget {
    param([string]$TargetDir)
    $full = Get-CleanPath $TargetDir
    try {
        $realTarget = Resolve-RealPath $full
        $realSource = Resolve-RealPath $script:SourceRoot
    }
    catch {
        throw "拒绝操作：无法解析目标或包源的真实路径（目标：$full；源：$($script:SourceRoot)）：$($_.Exception.Message)"
    }
    $leaf = [IO.Path]::GetFileName($realTarget)
    if ($leaf -ieq 'dsh-delegate') {
        throw "拒绝操作：目标叶子名是 dsh-delegate，会覆盖用户的个人版。目标必须固定为 dsh-delegate-kit。"
    }
    if ($leaf -ine 'dsh-delegate-kit') {
        throw "拒绝操作：目标叶子名必须是 dsh-delegate-kit，实际为「$leaf」。"
    }
    if (Test-PathOverlap $realTarget $realSource) {
        throw "拒绝操作：目标目录与包源目录重叠（目标：$full；目标真实路径：$realTarget；源：$($script:SourceRoot)；源真实路径：$realSource）。"
    }
    return $full
}

function New-HostSpec {
    param(
        [string]$HostName,
        [string]$DisplayName,
        [string]$SkillsRoot,
        [string]$SourceSkill
    )
    $skillsFull = Get-CleanPath $SkillsRoot
    $targetDir = Get-CleanPath (Join-Path $skillsFull 'dsh-delegate-kit')
    return [pscustomobject]@{
        Host      = $HostName
        Display   = $DisplayName
        SkillsDir = $skillsFull
        TargetDir = $targetDir
        SkillFile = $SourceSkill
    }
}

function Test-IsReparsePoint {
    param([string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-FileSha256 {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $hash = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Get-InstallEntries {
    param([string]$SkillFile)
    $entries = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList

    if ([IO.File]::Exists($SkillFile)) {
        [void]$entries.Add([pscustomobject]@{ Source = $SkillFile; Relative = 'SKILL.md'; Kind = 'file' })
    }
    else {
        [void]$missing.Add($SkillFile)
    }

    foreach ($dirName in @('scripts', 'templates')) {
        $dirPath = Join-Path $script:SourceRoot $dirName
        if (-not [IO.Directory]::Exists($dirPath)) {
            [void]$missing.Add($dirPath)
            continue
        }
        $base = (Get-CleanPath $dirPath)
        $files = @(Get-ChildItem -LiteralPath $dirPath -Recurse -Force -File | Sort-Object FullName)
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($base.Length).TrimStart([char[]]@('\', '/'))
            [void]$entries.Add([pscustomobject]@{
                Source   = $file.FullName
                Relative = $dirName + '\' + $relative
                Kind     = 'file'
            })
        }
        if ($dirName -eq 'scripts') {
            # 安装布局要求 scripts\lib 存在；源暂时缺少时创建空目录并给出警告。
            $libPath = Join-Path $dirPath 'lib'
            if (-not [IO.Directory]::Exists($libPath)) {
                [void]$warnings.Add('源缺少 scripts\lib，将在目标中创建空目录')
            }
            [void]$entries.Add([pscustomobject]@{ Source = $null; Relative = 'scripts\lib'; Kind = 'dir' })
        }
    }

    $maintenance = Join-Path $script:SourceRoot 'docs\MAINTENANCE.md'
    if ([IO.File]::Exists($maintenance)) {
        [void]$entries.Add([pscustomobject]@{ Source = $maintenance; Relative = 'docs\MAINTENANCE.md'; Kind = 'file' })
    }
    else {
        [void]$missing.Add($maintenance)
    }

    $helpDoc = Join-Path $script:SourceRoot 'docs\HELP.md'
    if ([IO.File]::Exists($helpDoc)) {
        [void]$entries.Add([pscustomobject]@{ Source = $helpDoc; Relative = 'docs\HELP.md'; Kind = 'file' })
    }
    else {
        [void]$missing.Add($helpDoc)
    }

    $readme = Join-Path $script:SourceRoot 'README.md'
    if ([IO.File]::Exists($readme)) {
        [void]$entries.Add([pscustomobject]@{ Source = $readme; Relative = 'README.md'; Kind = 'file' })
    }
    else {
        [void]$missing.Add($readme)
    }

    return [pscustomobject]@{
        Entries  = @($entries)
        Missing  = @($missing)
        Warnings = @($warnings)
    }
}

function Read-InstallMarker {
    param([string]$TargetDir)
    $markerPath = Join-Path $TargetDir '.kit-install.json'
    if (-not [IO.File]::Exists($markerPath)) { return $null }
    $text = [IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "标记文件为空：$markerPath"
    }
    try {
        $marker = $text | ConvertFrom-Json
    }
    catch {
        throw "无法解析标记文件：$markerPath"
    }
    if ($null -eq $marker) {
        throw "标记文件内容无效：$markerPath"
    }
    return $marker
}

function Copy-PlanToStage {
    param($Plan, [string]$StageDir)
    foreach ($entry in $Plan.Entries) {
        $dest = Join-Path $StageDir $entry.Relative
        if ($entry.Kind -eq 'dir') {
            if (-not [IO.Directory]::Exists($dest)) {
                [void][IO.Directory]::CreateDirectory($dest)
            }
            continue
        }
        $parent = [IO.Path]::GetDirectoryName($dest)
        if (-not [IO.Directory]::Exists($parent)) {
            [void][IO.Directory]::CreateDirectory($parent)
        }
        [IO.File]::Copy($entry.Source, $dest, $true)
    }

    $libDir = Join-Path $StageDir 'scripts\lib'
    if (-not [IO.Directory]::Exists($libDir)) {
        [void][IO.Directory]::CreateDirectory($libDir)
    }
}

function Write-InstallMarker {
    param($Plan, [string]$StageDir)
    $stageFull = Get-CleanPath $StageDir
    $files = @{}
    $stageFiles = @(Get-ChildItem -LiteralPath $StageDir -Recurse -Force -File | Sort-Object FullName)
    foreach ($file in $stageFiles) {
        $relative = $file.FullName.Substring($stageFull.Length).TrimStart([char[]]@('\', '/'))
        $files[$relative] = Get-FileSha256 $file.FullName
    }

    $marker = [ordered]@{
        schemaVersion = 1
        kitVersion    = $script:KitVersion
        host          = $Plan.Host.Host
        sourceDir     = $script:SourceRoot
        installedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        files         = $files
    }
    $json = ($marker | ConvertTo-Json -Depth 10) -replace "`r`n", "`n"
    $markerPath = Join-Path $StageDir '.kit-install.json'
    [IO.File]::WriteAllText($markerPath, $json + "`n", $script:Utf8NoBom)
    return $stageFiles.Count
}

function Remove-TargetDirectory {
    param([string]$Path)
    if ([IO.Directory]::Exists($Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
}

function Install-Plan {
    param($Plan)
    $targetDir = $Plan.Host.TargetDir
    $parent = [IO.Path]::GetDirectoryName($targetDir)
    if (-not [IO.Directory]::Exists($parent)) {
        [void][IO.Directory]::CreateDirectory($parent)
    }

    $stageDir = Join-Path $parent ('.dsh-delegate-kit.stage-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stageDir)
    $moved = $false
    try {
        Copy-PlanToStage -Plan $Plan -StageDir $stageDir
        $fileCount = Write-InstallMarker -Plan $Plan -StageDir $stageDir
        if ([IO.Directory]::Exists($targetDir)) {
            Remove-TargetDirectory $targetDir
        }
        [IO.Directory]::Move($stageDir, $targetDir)
        $moved = $true
        Write-Human ("已安装 {0} -> {1}（{2} 个文件，版本 {3}）" -f $Plan.Host.Display, $targetDir, $fileCount, $script:KitVersion)
    }
    finally {
        if (-not $moved -and [IO.Directory]::Exists($stageDir)) {
            Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Show-WhatIfInstall {
    param($Plan)
    Write-Human ("[WhatIf] 将安装 {0} -> {1}" -f $Plan.Host.Display, $Plan.Host.TargetDir)
    foreach ($entry in $Plan.Entries) {
        $dest = Join-Path $Plan.Host.TargetDir $entry.Relative
        if ($entry.Kind -eq 'dir') {
            Write-Human ("  [目录] {0}" -f $dest)
        }
        else {
            Write-Human ("  [复制] {0} -> {1}" -f $entry.Source, $dest)
        }
    }
    Write-Human ("  [写入] {0}" -f (Join-Path $Plan.Host.TargetDir '.kit-install.json'))
}

function Show-WhatIfUninstall {
    param([string]$TargetDir)
    Write-Human ("[WhatIf] 将删除目录 {0}" -f $TargetDir)
    $base = Get-CleanPath $TargetDir
    $files = @(Get-ChildItem -LiteralPath $TargetDir -Recurse -Force -File | Sort-Object FullName)
    foreach ($file in $files) {
        Write-Human ("  [删除] {0}" -f $file.FullName)
    }
    if ($files.Count -eq 0) {
        Write-Human '  [删除] （目录内没有文件，仅删除目录）'
    }
}

function Show-NextSteps {
    param([string[]]$HostNames)
    Write-Human ''
    Write-Human '下一步：'
    if ($HostNames -contains 'claude') {
        Write-Human '  Claude Code：在聊天里说「/dsh-delegate-kit setup」'
    }
    if ($HostNames -contains 'codex') {
        Write-Human '  Codex：在聊天里说「$dsh-delegate-kit setup」'
    }
    Write-Human '前置条件：先在 dsh 里配好模型和 API Key（推荐运行 dsh web，在 Models 页面配置）。'
}

# ---------------------------------------------------------------------------
# 交互模式（install.cmd 双击入口）：选宿主，失败时询问是否覆盖，实际安装交给非交互的自身
# ---------------------------------------------------------------------------

if ($Interactive -and -not $Uninstall) {
    if ([string]::IsNullOrWhiteSpace($Target)) {
        Write-Human 'dsh-delegate-kit 安装'
        Write-Human '  1. Claude Code（含 Claude 桌面端的 Code 页）'
        Write-Human '  2. Codex（含 Codex 桌面端）'
        Write-Human '  3. 两个都装'
        for ($i = 0; $i -lt 3 -and [string]::IsNullOrWhiteSpace($Target); $i++) {
            [Console]::Out.Write('请输入 1、2 或 3 后回车：')
            $answer = [Console]::In.ReadLine()
            if ($null -eq $answer) { break }
            switch ($answer.Trim()) {
                '1' { $Target = 'claude' }
                '2' { $Target = 'codex' }
                '3' { $Target = 'both' }
            }
        }
        if ([string]::IsNullOrWhiteSpace($Target)) {
            Write-Human '没有有效的选择，已取消安装。'
            exit 2
        }
    }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Target', $Target)
    if ($ClaudeSkillsDir) { $childArgs += @('-ClaudeSkillsDir', $ClaudeSkillsDir) }
    if ($CodexSkillsDir) { $childArgs += @('-CodexSkillsDir', $CodexSkillsDir) }
    if ($WhatIf) { $childArgs += '-WhatIf' }
    if ($Force) { $childArgs += '-Force' }
    & $psExe @childArgs
    $code = $LASTEXITCODE
    if ($code -eq 1 -and -not $Force -and -not $WhatIf) {
        Write-Human ''
        Write-Human '安装未完成，原因见上方提示。如果提示已安装的版本与当前包不同，或你确认目标目录可以覆盖，可以覆盖重装。'
        [Console]::Out.Write('是否覆盖重装？输入 y 确认，其他键取消：')
        $yn = [Console]::In.ReadLine()
        if ($null -ne $yn -and $yn.Trim() -ieq 'y') {
            & $psExe @($childArgs + '-Force')
            $code = $LASTEXITCODE
        }
        else {
            Write-Human '已取消，未做改动。'
        }
    }
    exit $code
}

# ---------------------------------------------------------------------------
# 参数与目标解析
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($Target)) {
    Show-Usage
    exit 2
}

$targetArg = $Target.Trim().ToLowerInvariant()
if (@('claude', 'codex', 'both') -notcontains $targetArg) {
    Write-Human ("错误：-Target 只能是 claude、codex 或 both，实际为「{0}」。" -f $Target)
    Write-Human ''
    Show-Usage
    exit 2
}

if ([string]::IsNullOrEmpty($PSScriptRoot)) {
    Write-Human '错误：无法确定 install.ps1 所在目录（PSScriptRoot 为空）。'
    exit 1
}
$script:SourceRoot = Get-CleanPath $PSScriptRoot

try {
    $homeDir = Get-HomeDir
    $hosts = New-Object System.Collections.ArrayList

    if ($targetArg -eq 'claude' -or $targetArg -eq 'both') {
        if (-not [string]::IsNullOrWhiteSpace($ClaudeSkillsDir)) {
            $claudeRoot = $ClaudeSkillsDir
        }
        else {
            $claudeRoot = Join-Path $homeDir '.claude\skills'
        }
        [void]$hosts.Add((New-HostSpec -HostName 'claude' -DisplayName 'Claude Code' -SkillsRoot $claudeRoot -SourceSkill (Join-Path $script:SourceRoot 'claude\SKILL.md')))
    }

    if ($targetArg -eq 'codex' -or $targetArg -eq 'both') {
        if (-not [string]::IsNullOrWhiteSpace($CodexSkillsDir)) {
            $codexRoot = $CodexSkillsDir
        }
        elseif (-not [string]::IsNullOrEmpty($env:CODEX_HOME)) {
            $codexRoot = Join-Path $env:CODEX_HOME 'skills'
        }
        else {
            $codexRoot = Join-Path $homeDir '.codex\skills'
        }
        [void]$hosts.Add((New-HostSpec -HostName 'codex' -DisplayName 'Codex' -SkillsRoot $codexRoot -SourceSkill (Join-Path $script:SourceRoot 'codex\SKILL.md')))
    }

    # 在动任何磁盘之前校验所有目标路径。
    $seenTargetDirs = @{}
    foreach ($hostSpec in $hosts) {
        $targetKey = (Get-CleanPath $hostSpec.TargetDir).ToLowerInvariant()
        if ($seenTargetDirs.ContainsKey($targetKey)) {
            throw ("多个 host 解析到同一个目标目录，拒绝安装以免互相覆盖：{0} 与 {1} 都指向「{2}」。请为每个 host 指定不同的 skills 目录。" -f $seenTargetDirs[$targetKey], $hostSpec.Display, $hostSpec.TargetDir)
        }
        $seenTargetDirs[$targetKey] = $hostSpec.Display

        $validated = Assert-SafeTarget $hostSpec.TargetDir
        $hostSpec.TargetDir = $validated
    }
}
catch {
    Write-Human ("错误：{0}" -f $_.Exception.Message)
    exit 1
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------

if ($Uninstall) {
    $plans = New-Object System.Collections.ArrayList
    $failures = New-Object System.Collections.ArrayList

    foreach ($hostSpec in $hosts) {
        try {
            $targetDir = $hostSpec.TargetDir
            if ([IO.File]::Exists($targetDir)) {
                throw "目标是文件而不是目录：$targetDir"
            }
            if (-not [IO.Directory]::Exists($targetDir)) {
                [void]$plans.Add([pscustomobject]@{ Host = $hostSpec; Action = 'missing' })
                continue
            }
            if (Test-IsReparsePoint $targetDir) {
                throw "目标是符号链接或联接点，拒绝删除：$targetDir"
            }
            $markerPath = Join-Path $targetDir '.kit-install.json'
            if (-not [IO.File]::Exists($markerPath)) {
                throw "目标目录没有 .kit-install.json，拒绝删除（可能是别人的目录）：$targetDir"
            }
            [void]$plans.Add([pscustomobject]@{ Host = $hostSpec; Action = 'uninstall' })
        }
        catch {
            [void]$failures.Add(("{0}：{1}" -f $hostSpec.Display, $_.Exception.Message))
        }
    }

    if ($failures.Count -gt 0) {
        foreach ($failure in $failures) {
            Write-Human ("错误：{0}" -f $failure)
        }
        exit 1
    }

    foreach ($plan in $plans) {
        $targetDir = $plan.Host.TargetDir
        if ($plan.Action -eq 'missing') {
            Write-Human ("未安装，跳过：{0}（{1}）" -f $plan.Host.Display, $targetDir)
            continue
        }
        if ($WhatIf) {
            Show-WhatIfUninstall $targetDir
            continue
        }
        Remove-TargetDirectory $targetDir
        Write-Human ("已卸载 {0}：{1}" -f $plan.Host.Display, $targetDir)
    }

    Write-Human ''
    Write-Human '注意：卸载只删除了 skill 文件，未改动 KIT_HOME 和规则文件（CLAUDE.md / AGENTS.md）；这些请运行 kit.ps1 uninstall 处理。'
    exit 0
}

# ---------------------------------------------------------------------------
# 安装预检（所有 host 都通过后才写磁盘）
# ---------------------------------------------------------------------------

$installPlans = New-Object System.Collections.ArrayList
$skipMessages = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
$failures = New-Object System.Collections.ArrayList

foreach ($hostSpec in $hosts) {
    try {
        $sourceCheck = Get-InstallEntries $hostSpec.SkillFile
        if ($sourceCheck.Missing.Count -gt 0) {
            $missingList = ($sourceCheck.Missing | ForEach-Object { '  ' + $_ }) -join "`n"
            throw "包源缺少必需文件/目录：`n$missingList"
        }
        foreach ($warning in $sourceCheck.Warnings) {
            [void]$warnings.Add(("{0}：{1}" -f $hostSpec.Display, $warning))
        }

        $targetDir = $hostSpec.TargetDir
        $action = 'install'
        $skipMessage = ''

        if ([IO.File]::Exists($targetDir)) {
            throw "目标路径是文件而不是目录：$targetDir"
        }

        if ([IO.Directory]::Exists($targetDir)) {
            if (Test-IsReparsePoint $targetDir) {
                throw "目标是符号链接或联接点，拒绝操作：$targetDir"
            }

            $markerPath = Join-Path $targetDir '.kit-install.json'
            if ([IO.File]::Exists($markerPath)) {
                $marker = $null
                $markerError = $null
                try {
                    $marker = Read-InstallMarker $targetDir
                }
                catch {
                    $markerError = $_.Exception.Message
                }

                if ($Force) {
                    $action = 'install'
                }
                elseif ($null -ne $markerError) {
                    throw ("目标已存在，且标记文件无法读取（{0}）。加 -Force 覆盖，或先手动检查：{1}" -f $markerError, $targetDir)
                }
                elseif ($null -ne $marker) {
                    $installedVersion = [string]$marker.kitVersion
                    if ($installedVersion -eq $script:KitVersion) {
                        $action = 'skip'
                        $skipMessage = ("{0} 已安装版本 {1}，加 -Force 重装：{2}" -f $hostSpec.Display, $installedVersion, $targetDir)
                    }
                    else {
                        throw ("{0} 已安装版本「{1}」，当前包版本「{2}」。加 -Force 覆盖重装：{3}" -f $hostSpec.Display, $installedVersion, $script:KitVersion, $targetDir)
                    }
                }
                else {
                    throw ("目标已存在但没有有效的 .kit-install.json，拒绝覆盖：{0}" -f $targetDir)
                }
            }
            else {
                $children = @(Get-ChildItem -LiteralPath $targetDir -Force)
                if ($children.Count -gt 0 -and -not $Force) {
                    throw ("目标目录非空且没有 .kit-install.json，拒绝覆盖（可能是别人的目录）：{0}。如确认要覆盖，请加 -Force。" -f $targetDir)
                }
                $action = 'install'
            }
        }

        if ($action -eq 'skip') {
            [void]$skipMessages.Add($skipMessage)
            [void]$installPlans.Add([pscustomobject]@{ Host = $hostSpec; Action = 'skip'; Entries = @() })
        }
        else {
            [void]$installPlans.Add([pscustomobject]@{ Host = $hostSpec; Action = 'install'; Entries = $sourceCheck.Entries })
        }
    }
    catch {
        [void]$failures.Add(("{0}：{1}" -f $hostSpec.Display, $_.Exception.Message))
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Human ("错误：{0}" -f $failure)
    }
    exit 1
}

foreach ($warning in $warnings) {
    Write-Human ("警告：{0}" -f $warning)
}
foreach ($message in $skipMessages) {
    Write-Human $message
}

$installCount = 0
foreach ($plan in $installPlans) {
    if ($plan.Action -eq 'skip') { continue }
    if ($WhatIf) {
        Show-WhatIfInstall $plan
        $installCount++
        continue
    }
    Install-Plan $plan
    $installCount++
}

if ($WhatIf) {
    Write-Human ''
    Write-Human '[WhatIf] 未改动磁盘。'
}

if ($installCount -gt 0 -or $skipMessages.Count -gt 0) {
    Show-NextSteps @($hosts | ForEach-Object { $_.Host })
}

exit 0
