# setup.ps1 — dsh-delegate-kit 的 setup / check / repair / status 四个子命令实现。
# 由 kit.ps1 dot-source，依赖 common.ps1。兼容 Windows PowerShell 5.1。
# 约定：函数返回 @{ ExitCode=<int>; Result=<可转 JSON 的对象>; Text=<中文多行文本> }，不向 stdout 写内容。
# 编码：本文件 UTF-8 带 BOM；生成的补丁、state.json、spec.json 一律 UTF-8 无 BOM。

# ============================================================
# 通用小工具
# ============================================================

function Get-KitSetupCwd($dsh) {
  # Invoke-KitHelper 用 KIT_HOME 作 cwd，但 setup 第一段禁止创建 KIT_HOME；这里显式选一个已存在的目录。
  $kitHome = (Get-KitPaths).Home
  if ($kitHome -and (Test-Path -LiteralPath $kitHome -PathType Container)) { return $kitHome }
  if ($dsh -and $dsh.Base -and (Test-Path -LiteralPath $dsh.Base -PathType Container)) { return $dsh.Base }
  return $env:TEMP
}

function Invoke-KitSetupHelper($dsh, [string[]]$helperArgs) {
  $paths = Get-KitPaths
  $cwd = Get-KitSetupCwd $dsh
  $r = Invoke-KitProcess $dsh.Node (@($paths.Helper) + $helperArgs) $cwd 120
  $json = $null
  if ($r.Out -and $r.Out.Trim()) {
    try { $json = $r.Out | ConvertFrom-Json } catch { $json = $null }
  }
  return [ordered]@{ ExitCode = $r.ExitCode; Json = $json; Out = $r.Out; Err = $r.Err; TimedOut = $r.TimedOut }
}

function Get-KitSetupHelperError($r) {
  $msg = $null
  if ($r -and $r.Json) { $msg = [string](Get-KitProp $r.Json 'error') }
  if (-not $msg -and $r -and $r.Err) {
    $lines = @(([string]$r.Err).Trim() -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -gt 0) { $msg = $lines[0].Trim() }
  }
  if (-not $msg) { $msg = 'dshkit.mjs 退出码 ' + [string]$r.ExitCode }
  return $msg
}

function Set-KitStateProp($obj, [string]$name, $value) {
  if ($null -eq $obj) { return }
  if ($obj -is [System.Collections.IDictionary]) { $obj[$name] = $value; return }
  if ($null -ne $obj.PSObject.Properties[$name]) { $obj.$name = $value; return }
  $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
}

function Test-KitPropExists($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  if ($obj -is [System.Collections.IDictionary]) { return $obj.Contains($name) }
  return ($null -ne $obj.PSObject.Properties[$name])
}

function Get-KitPluginIdEntry($state, [string]$key) {
  $value = $null
  if ($state) { $value = Get-KitProp (Get-KitProp $state 'pluginIds') $key }
  if (-not $value) { $value = $script:KitDefaultPluginIds[$key] }
  return $value
}

function Copy-KitPluginIds($source) {
  $out = [ordered]@{}
  foreach ($key in @('credentials', 'agentDefaultModel', 'compaction', 'browserUse', 'browserProvider', 'computerUse', 'computerProvider')) {
    $v = $null
    if ($source) { $v = Get-KitProp $source $key }
    if (-not $v) { $v = $script:KitDefaultPluginIds[$key] }
    $id = [string](Get-KitProp $v 'id')
    $name = [string](Get-KitProp $v 'name')
    if (-not $id) { $id = [string]$script:KitDefaultPluginIds[$key].id }
    if (-not $name) { $name = [string]$script:KitDefaultPluginIds[$key].name }
    $out[$key] = [ordered]@{ id = $id; name = $name }
  }
  return $out
}

function Get-KitModelEfforts($model) {
  if ($null -eq $model) { return @() }
  if ($model.effortsKnown -ne $true) { return @() }
  if ($null -eq $model.efforts) { return @() }
  return @($model.efforts)
}

function Get-KitAutoDefaultEffort($model) {
  if ($null -eq $model) { return $null }
  if ($model.effortsKnown -ne $true) { return $null }
  $supported = @(Get-KitModelEfforts $model)
  if ($supported -contains 'high') { return 'high' }
  if ($supported -contains 'medium') { return 'medium' }
  if ($supported.Count -gt 0) { return [string]$supported[$supported.Count - 1] }
  return $null
}

function Get-KitEffortChoices($models) {
  $out = [ordered]@{}
  foreach ($m in @($models)) {
    $key = [string]$m.provider + '/' + [string]$m.id
    if ($m.effortsKnown -eq $true) {
      $levels = @()
      if ($m.efforts) { $levels = @($m.efforts) }
      $out[$key] = @($levels + 'auto')
    } else {
      $out[$key] = @('provider-default')
    }
  }
  return $out
}

function Get-KitModeChoices {
  return @(
    [ordered]@{
      id   = 'read-only'
      desc = '只能读取文件，不能修改（适合只读分析）'
    },
    [ordered]@{
      id          = 'workspace-write'
      desc        = '可读写工作目录，不能访问网络或系统目录（推荐）'
      recommended = $true
    },
    [ordered]@{
      id      = 'danger-full-access'
      desc    = '完全访问：可执行任意命令、读写任意文件、访问网络'
      warning = '风险极高，仅在明确需要时使用，且必须加 -AcknowledgeFullAccess'
    }
  )
}

function New-KitSetupFailure([string]$stage, $reasons, $envInfo, [string]$rerun = 'kit.ps1 setup') {
  $list = @($reasons)
  $result = [ordered]@{ stage = $stage; ok = $false; reasons = $list }
  if ($null -ne $envInfo) { $result.env = $envInfo }
  $lines = New-Object 'System.Collections.Generic.List[string]'
  if ($stage -eq 'repair') {
    $lines.Add('dsh-delegate-kit repair 未完成：')
  } else {
    $lines.Add('dsh-delegate-kit setup 未完成：')
  }
  foreach ($r in $list) { $lines.Add('✗ ' + [string]$r) }
  $lines.Add('')
  $lines.Add('修复后重跑：' + $rerun)
  return @{ ExitCode = 2; Result = $result; Text = ($lines -join "`n") }
}

function Get-KitSetupModels($dsh) {
  $paths = Get-KitPaths
  $helperArgs = @('models', '--dsh-pkg', $dsh.PackageDir)
  if (Test-Path -LiteralPath $paths.WebProfile -PathType Leaf) {
    $helperArgs += @('--profile', ('web=' + $paths.WebProfile))
  }
  if (Test-Path -LiteralPath $paths.DesktopProfile -PathType Leaf) {
    $helperArgs += @('--profile', ('desktop=' + $paths.DesktopProfile))
  }
  $r = Invoke-KitSetupHelper $dsh $helperArgs
  if ($r.ExitCode -ne 0 -or $null -eq $r.Json -or (Get-KitProp $r.Json 'error')) {
    return [ordered]@{ ok = $false; models = @(); warnings = @(); error = (Get-KitSetupHelperError $r) }
  }
  $models = @()
  if (Get-KitProp $r.Json 'models') { $models = @(Get-KitProp $r.Json 'models') }
  $warnings = @()
  if (Get-KitProp $r.Json 'warnings') { $warnings = @(Get-KitProp $r.Json 'warnings') }
  return [ordered]@{ ok = $true; models = $models; warnings = $warnings; error = '' }
}

function Invoke-KitPluginInstall($dsh) {
  # 只在调用方明确带 -InstallPlugins 时执行；600 秒超时。
  $argList = @($dsh.Bin, 'plugin', '--profile', 'headless', 'add')
  foreach ($name in $script:KitOptionalPlugins) {
    $argList += ('{0}@{1}' -f $name, $dsh.Version)
  }
  return Invoke-KitProcess $dsh.Node $argList (Get-KitSetupCwd $dsh) 600
}

function Get-KitProcessSummary($r) {
  $text = ([string]$r.Out + "`n" + [string]$r.Err)
  $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
  $summary = ($lines -join ' | ')
  if ($summary.Length -gt 400) { $summary = $summary.Substring(0, 400) + '...' }
  return $summary
}

function Get-KitPatchFileCheck([string]$label, [string]$path, [string]$sha) {
  $r = [ordered]@{ name = $label; ok = $true; detail = ''; reasons = @(); warnings = @() }
  if (-not $path) {
    $r.ok = $false
    $r.detail = 'state 里没有路径'
    $r.reasons = @('补丁文件缺失：' + $label)
    return $r
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    $r.ok = $false
    $r.detail = '文件不存在：' + $path
    $r.reasons = @('补丁文件缺失：' + $path)
    return $r
  }
  if (Test-KitBom $path) {
    $r.ok = $false
    $r.detail = '文件带 BOM：' + $path
    $r.reasons = @('补丁文件带 BOM（应为无 BOM UTF-8）：' + $path)
    return $r
  }
  $actual = Get-KitSha256 $path
  if ($sha -and $actual -and $actual -ne $sha) {
    $r.detail = 'sha256 不符，已继续验证内容'
    $r.warnings = @('补丁被改动过：' + $path)
  } else {
    $r.detail = $path
  }
  return $r
}

function Get-KitDumpErrorLine([string]$errText) {
  $text = [string]$errText
  if (-not $text.Trim()) { return 'dsh 未输出错误信息' }
  $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
  $fallback = $null
  foreach ($line in $lines) {
    if ($line -match 'failed to parse') {
      # 优先取真正的错误消息（Error: dsh: failed to parse ...），跳过 JS 源码里的 throw new Error
      if ($line -notmatch 'throw new Error' -and $line -notmatch '\$\{') { return $line.Trim() }
      if (-not $fallback) { $fallback = $line.Trim() }
    }
  }
  if ($fallback) { return $fallback }
  if ($lines.Count -gt 0) { return $lines[0].Trim() }
  return '未知错误'
}

function Find-KitDumpEntry($entries, [string]$name, [string]$id) {
  if ($name) {
    foreach ($e in @($entries)) {
      if ($null -ne $e -and [string]$e.name -eq $name) { return $e }
    }
  }
  if ($id) {
    foreach ($e in @($entries)) {
      if ($null -ne $e -and [string]$e.id -eq $id) { return $e }
    }
  }
  return $null
}

function Invoke-KitCheckDump($dsh, [string[]]$patchFiles, [string]$outFile) {
  $r = [ordered]@{ ok = $false; entries = @(); error = '' }
  $dump = Invoke-KitDumpConfig $dsh $patchFiles $outFile
  if ($dump.ExitCode -ne 0) {
    $r.error = Get-KitDumpErrorLine $dump.Err
    return $r
  }
  $parse = Invoke-KitSetupHelper $dsh @('parse-dump', '--file', $outFile, '--dsh-pkg', $dsh.PackageDir)
  if ($parse.ExitCode -ne 0 -or $null -eq $parse.Json) {
    $r.error = '解析 dump 失败：' + (Get-KitSetupHelperError $parse)
    return $r
  }
  $r.ok = $true
  if (Get-KitProp $parse.Json 'entries') { $r.entries = @(Get-KitProp $parse.Json 'entries') }
  return $r
}

function New-KitPatchState($gen) {
  $files = Get-KitProp $gen 'files'
  $out = [ordered]@{}
  $basePath = [string](Get-KitProp $files 'base')
  $out.base = [ordered]@{ path = $basePath; sha256 = (Get-KitSha256 $basePath) }
  $efforts = [ordered]@{}
  $effortObj = Get-KitProp $files 'effort'
  if ($effortObj) {
    foreach ($p in $effortObj.PSObject.Properties) {
      $pth = [string]$p.Value
      $efforts[[string]$p.Name] = [ordered]@{ path = $pth; sha256 = (Get-KitSha256 $pth) }
    }
  }
  $out.effort = $efforts
  $nb = [string](Get-KitProp $files 'noBrowser')
  $out.noBrowser = [ordered]@{ path = $nb; sha256 = (Get-KitSha256 $nb) }
  $cu = [string](Get-KitProp $files 'computerUse')
  $out.computerUse = [ordered]@{ path = $cu; sha256 = (Get-KitSha256 $cu) }
  return $out
}

function Copy-KitGeneratedFiles($gen, [string]$patchDir) {
  # gen-patches 先在临时目录生成；成功后把补丁复制进 Patches，并把 gen.files 的路径改成最终路径。
  $files = Get-KitProp $gen 'files'
  if (-not $files) { return }
  foreach ($name in @('base', 'noBrowser', 'computerUse')) {
    $src = [string](Get-KitProp $files $name)
    if ($src -and (Test-Path -LiteralPath $src -PathType Leaf)) {
      $dst = Join-Path $patchDir ([IO.Path]::GetFileName($src))
      Copy-Item -LiteralPath $src -Destination $dst -Force
      Set-KitStateProp $files $name $dst
    }
  }
  $efforts = Get-KitProp $files 'effort'
  if ($efforts) {
    foreach ($p in @($efforts.PSObject.Properties)) {
      $src = [string]$p.Value
      if ($src -and (Test-Path -LiteralPath $src -PathType Leaf)) {
        $dst = Join-Path $patchDir ([IO.Path]::GetFileName($src))
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Set-KitStateProp $efforts $p.Name $dst
      }
    }
  }
}

function Remove-KitStaleEfforts([string]$dir, $keepLevels) {
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
  $keep = @($keepLevels)
  Get-ChildItem -LiteralPath $dir -Filter 'effort-*.yml' -File -ErrorAction SilentlyContinue | ForEach-Object {
    $level = $_.BaseName.Substring(7)
    if ($keep -notcontains $level) {
      Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-KitFeatureCompaction($gen) {
  $comp = Get-KitProp $gen 'compaction'
  return [ordered]@{
    applied        = [bool](Get-KitProp $comp 'applied')
    thresholdRatio = (Get-KitProp $comp 'thresholdRatio')
    retainTokens   = (Get-KitProp $comp 'retainTokens')
    reason         = [string](Get-KitProp $comp 'reason')
  }
}

# ============================================================
# state.json 命名互斥锁：setup 第二段 / check / repair 写状态时串行
# 名字：Local\dsh-delegate-kit-state-<KIT_HOME 小写全路径 SHA256 前 16 位>
# ============================================================

function Get-KitStateLockName {
  $homePath = [string](Get-KitPaths).Home
  $normalized = $homePath.ToLowerInvariant()
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
  return 'Local\dsh-delegate-kit-state-' + $hash.Substring(0, 16)
}

function Enter-KitStateLock([int]$timeoutSec = 120) {
  # 拿不到锁返回 $null（最多等 timeoutSec 秒）
  $name = Get-KitStateLockName
  $mutex = New-Object System.Threading.Mutex($false, $name)
  $acquired = $false
  try {
    $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($timeoutSec))
  } catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
  } catch {
    $mutex.Dispose()
    return $null
  }
  if (-not $acquired) {
    $mutex.Dispose()
    return $null
  }
  return $mutex
}

function Exit-KitStateLock($mutex) {
  if ($null -eq $mutex) { return }
  try { [void]$mutex.ReleaseMutex() } catch { }
  $mutex.Dispose()
}

# ============================================================
# setup
# ============================================================

function Invoke-KitSetup {
  param(
    [string]$Model,
    [string]$Effort,
    [string]$Mode,
    [switch]$InstallPlugins,
    [switch]$AcknowledgeFullAccess
  )
  $usage = 'kit.ps1 setup -Model <provider>/<id> [-Effort <档|auto>] [-Mode <read-only|workspace-write|danger-full-access>] [-InstallPlugins] [-AcknowledgeFullAccess]'
  if (-not $Model) {
    $hasChoice = [bool]($Effort -or $Mode -or $InstallPlugins.IsPresent -or $AcknowledgeFullAccess.IsPresent)
    if ($hasChoice) {
      return New-KitSetupFailure 'choose' @('缺少 -Model：只传 -Effort/-Mode/-InstallPlugins/-AcknowledgeFullAccess 不会修改配置。先运行 kit.ps1 setup 查看候选模型，再加 -Model 完成配置') $null $usage
    }
    return Invoke-KitSetupChoose
  }
  return Invoke-KitSetupConfigure -Model $Model -Effort $Effort -Mode $Mode -InstallPlugins:$InstallPlugins -AcknowledgeFullAccess:$AcknowledgeFullAccess
}

function Invoke-KitSetupChoose {
  $paths = Get-KitPaths
  $envInfo = [ordered]@{
    dshVersion    = $null
    nodeVersion   = $null
    dshPackageDir = $null
    headlessProfile = $paths.Headless
    kitHome       = $paths.Home
  }
  $dsh = Find-KitDsh
  if (-not $dsh.Found) {
    $dshCmd = Get-Command dsh -ErrorAction SilentlyContinue | Select-Object -First 1
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dshCmd) {
      $reason = '找不到 dsh 命令。修复：npm i -g @deepseek-ai/dsh'
    } elseif (-not $nodeCmd) {
      $reason = '找不到 Node.js（node.exe）。修复：安装 Node.js（建议 LTS）并重开终端'
    } else {
      $reason = '找不到可用的 dsh：' + [string]$dsh.Error + '。修复：npm i -g @deepseek-ai/dsh'
    }
    return New-KitSetupFailure 'choose' @($reason) $envInfo
  }
  $envInfo.dshVersion = $dsh.Version
  $envInfo.nodeVersion = $dsh.NodeVersion
  $envInfo.dshPackageDir = $dsh.PackageDir

  $headlessPkg = Join-Path $paths.Headless 'package.json'
  if (-not (Test-Path -LiteralPath $headlessPkg -PathType Leaf)) {
    return New-KitSetupFailure 'choose' @(('headless profile 未初始化：' + $headlessPkg + ' 不存在。修复：运行一次 dsh plugin --profile headless list 初始化 headless profile')) $envInfo
  }

  $modelsR = Get-KitSetupModels $dsh
  if (-not $modelsR.ok) {
    return New-KitSetupFailure 'choose' @(('读取模型列表失败：' + [string]$modelsR.error + '。修复：确认 dsh 安装完整（npm i -g @deepseek-ai/dsh）后重试')) $envInfo
  }
  $models = @($modelsR.models)
  if ($models.Count -eq 0) {
    return New-KitSetupFailure 'choose' @('web 和 desktop profile 里都没有可用模型。修复：先运行 dsh web，在 Models 页面配置模型和 API Key（也可以在 DSH 桌面端配置）') $envInfo
  }

  $plugins = Get-KitPluginStatus $dsh
  $chrome = Find-KitChrome
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  foreach ($w in @($modelsR.warnings)) { if ($w) { $warnings.Add([string]$w) } }
  if (Test-Path -LiteralPath $paths.WebProfile -PathType Leaf) { } else { $warnings.Add('未找到 web profile：' + $paths.WebProfile) }
  if (Test-Path -LiteralPath $paths.DesktopProfile -PathType Leaf) { } else { $warnings.Add('未找到 desktop profile：' + $paths.DesktopProfile) }
  if (-not $plugins.aligned) {
    $warnings.Add('headless 浏览器/电脑操作插件与 dsh 版本不一致：' + ((@($plugins.misaligned)) -join '、') + '；需要时重跑 setup 并加 -InstallPlugins')
  }
  if (-not $chrome.Path) { $warnings.Add($chrome.Note) }

  $result = [ordered]@{
    stage           = 'choose'
    env             = $envInfo
    models          = $models
    effortChoices   = (Get-KitEffortChoices $models)
    recommendedEffort = 'auto'
    modes           = (Get-KitModeChoices)
    plugins         = $plugins
    browser         = [ordered]@{ path = $chrome.Path; note = $chrome.Note; available = [bool]$chrome.Path }
    warnings        = @($warnings)
  }

  $lines = New-Object 'System.Collections.Generic.List[string]'
  $lines.Add('dsh-delegate-kit setup — 环境检查通过')
  $lines.Add(('dsh {0}（node {1}）' -f $dsh.Version, $dsh.NodeVersion))
  $lines.Add('dsh 包目录：' + $dsh.PackageDir)
  $lines.Add('headless profile：' + $paths.Headless)
  $lines.Add('KIT_HOME：' + $paths.Home)
  $lines.Add('')
  $lines.Add('候选模型：')
  foreach ($m in $models) {
    $visionText = '纯文本'
    if ($m.vision -eq $true) { $visionText = '支持看图' }
    $windowText = '未知'
    if ($null -ne $m.contextWindow) { $windowText = [string]$m.contextWindow }
    $effortText = '未知'
    if ($m.effortsKnown -eq $true) {
      $lv = @(Get-KitModelEfforts $m)
      if ($lv.Count -gt 0) { $effortText = ($lv -join '/') } else { $effortText = '无（off）' }
    }
    $srcText = (@($m.sources) -join ',')
    $lines.Add(('  {0}/{1}  {2}  来源 {3}  窗口 {4}  {5}  思考档 {6}' -f $m.provider, $m.id, $m.name, $srcText, $windowText, $visionText, $effortText))
  }
  $lines.Add('')
  $lines.Add('思考档选择（provider/id = 可选值）：')
  $choices = Get-KitEffortChoices $models
  foreach ($key in $choices.Keys) { $lines.Add('  ' + $key + ' = ' + ((@($choices[$key])) -join '/')) }
  $lines.Add('')
  $lines.Add('权限模式：')
  foreach ($m in (Get-KitModeChoices)) {
    $suffix = ''
    if ($m.recommended -eq $true) { $suffix = '（推荐）' }
    if ($m.warning) { $suffix = '（' + $m.warning + '）' }
    $lines.Add(('  {0}：{1}{2}' -f $m.id, $m.desc, $suffix))
  }
  $lines.Add('')
  $pluginText = '已对齐'
  if (-not $plugins.aligned) { $pluginText = '未对齐（' + ((@($plugins.misaligned)) -join '、') + '）' }
  $lines.Add('headless 可选插件：' + $pluginText + '（期望版本 ' + $plugins.expected + '）')
  if ($chrome.Path) {
    $lines.Add('浏览器：' + $chrome.Path)
    if ($chrome.Note) { $lines.Add('  注意：' + $chrome.Note) }
  } else {
    $lines.Add('浏览器：不可用（' + $chrome.Note + '）')
  }
  if ($warnings.Count -gt 0) {
    $lines.Add('')
    $lines.Add('警告：')
    foreach ($w in $warnings) { $lines.Add('⚠ ' + $w) }
  }
  $lines.Add('')
  $lines.Add('下一步（示例）：')
  $first = $models[0]
  $lines.Add(('  kit.ps1 setup -Model {0}/{1} -Effort auto -Mode workspace-write' -f $first.provider, $first.id))

  return @{ ExitCode = 0; Result = $result; Text = ($lines -join "`n") }
}

function Invoke-KitSetupConfigure {
  param(
    [string]$Model,
    [string]$Effort,
    [string]$Mode,
    [switch]$InstallPlugins,
    [switch]$AcknowledgeFullAccess
  )
  $paths = Get-KitPaths
  $envInfo = [ordered]@{
    dshVersion    = $null
    nodeVersion   = $null
    dshPackageDir = $null
    headlessProfile = $paths.Headless
    kitHome       = $paths.Home
  }
  $dsh = Find-KitDsh
  if (-not $dsh.Found) {
    return New-KitSetupFailure 'configure' @('找不到可用的 dsh：' + [string]$dsh.Error + '。修复：npm i -g @deepseek-ai/dsh') $envInfo
  }
  $envInfo.dshVersion = $dsh.Version
  $envInfo.nodeVersion = $dsh.NodeVersion
  $envInfo.dshPackageDir = $dsh.PackageDir

  $headlessPkg = Join-Path $paths.Headless 'package.json'
  if (-not (Test-Path -LiteralPath $headlessPkg -PathType Leaf)) {
    return New-KitSetupFailure 'configure' @(('headless profile 未初始化：' + $headlessPkg + ' 不存在。修复：运行一次 dsh plugin --profile headless list 初始化 headless profile')) $envInfo
  }

  $modelsR = Get-KitSetupModels $dsh
  if (-not $modelsR.ok) {
    return New-KitSetupFailure 'configure' @('读取模型列表失败：' + [string]$modelsR.error) $envInfo
  }
  $models = @($modelsR.models)

  $slash = $Model.IndexOf('/')
  if ($slash -lt 1 -or $slash -ge ($Model.Length - 1)) {
    return New-KitSetupFailure 'configure' @('模型格式应为 provider/id，例如 opencode-go/deepseek-v4.1-flash') $envInfo
  }
  $provider = $Model.Substring(0, $slash)
  $modelId = $Model.Substring($slash + 1)
  $selModel = $null
  foreach ($m in $models) {
    if ([string]$m.provider -eq $provider -and [string]$m.id -eq $modelId) { $selModel = $m; break }
  }
  if ($null -eq $selModel) {
    $keys = @($models | ForEach-Object { [string]$_.provider + '/' + [string]$_.id })
    $reasons = @('候选模型里没有 ' + $Model)
    if ($keys.Count -gt 0) { $reasons += ('可选：' + ($keys -join '、')) }
    return New-KitSetupFailure 'configure' $reasons $envInfo
  }

  $supported = @(Get-KitModelEfforts $selModel)
  $effortsKnown = ($selModel.effortsKnown -eq $true)
  $effortInput = [string]$Effort
  if (-not $effortInput) { $effortInput = 'auto' }
  if ($effortInput -ceq 'provider-default') { $effortInput = 'auto' }
  if ($effortInput -cne 'auto') {
    if (-not $effortsKnown) {
      return New-KitSetupFailure 'configure' @('模型 ' + $Model + ' 的思考等级未知，只能选 auto') $envInfo
    }
    if ($supported -cnotcontains $effortInput) {
      $choiceText = 'auto'
      if ($supported.Count -gt 0) { $choiceText = (@($supported) + 'auto') -join '/' }
      return New-KitSetupFailure 'configure' @('不支持的思考档 ' + $effortInput + '，可选：' + $choiceText) $envInfo
    }
  }

  $modeInput = [string]$Mode
  if (-not $modeInput) { $modeInput = 'workspace-write' }
  if ($script:KitModes -cnotcontains $modeInput) {
    return New-KitSetupFailure 'configure' @('不支持的权限模式 ' + $modeInput + '，可选：read-only、workspace-write、danger-full-access') $envInfo
  }
  if ($modeInput -ceq 'danger-full-access' -and -not $AcknowledgeFullAccess) {
    return New-KitSetupFailure 'configure' @('danger-full-access 会允许 dsh 执行任意命令、读写任意文件并访问网络，风险极高。确认要用请加 -AcknowledgeFullAccess 重跑') $envInfo
  }

  if ($effortInput -ceq 'auto') {
    $effortMode = 'auto'
    $defaultEffort = Get-KitAutoDefaultEffort $selModel
  } else {
    $effortMode = 'fixed'
    $defaultEffort = $effortInput
  }

  $plugins = Get-KitPluginStatus $dsh
  $resultPlugins = $plugins
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  foreach ($w in @($modelsR.warnings)) { if ($w) { $warnings.Add([string]$w) } }
  if (-not $plugins.aligned) {
    if ($InstallPlugins) {
      $install = Invoke-KitPluginInstall $dsh
      $plugins = Get-KitPluginStatus $dsh
      $resultPlugins = $plugins
      if ($install.ExitCode -ne 0) {
        $warnings.Add('插件安装失败（exit ' + [string]$install.ExitCode + '）：' + (Get-KitProcessSummary $install))
      } elseif (-not $plugins.aligned) {
        $warnings.Add('插件安装命令已执行，但仍未对齐：' + ((@($plugins.misaligned)) -join '、'))
      }
    } else {
      $resultPlugins = [ordered]@{
        needInstall = $true
        command     = $plugins.command
        aligned     = $false
        expected    = $plugins.expected
        installed   = $plugins.installed
        misaligned  = @($plugins.misaligned)
      }
    }
  }

  $chrome = Find-KitChrome
  $browserOk = [bool]($plugins.browserOk -and $chrome.Path)
  $browserReason = ''
  if (-not $plugins.browserOk) {
    $browserReason = '浏览器插件未与 dsh 版本对齐'
  } elseif (-not $chrome.Path) {
    $browserReason = $chrome.Note
  } else {
    $browserReason = $chrome.Note
  }
  $computerOk = [bool]$plugins.computerOk
  $computerReason = ''
  if (-not $computerOk) { $computerReason = '电脑操作插件未与 dsh 版本对齐' }
  if ($browserReason) { $warnings.Add('浏览器：' + $browserReason) }
  if ($computerReason) { $warnings.Add('电脑操作：' + $computerReason) }

  $sources = @($selModel.sources)
  $sourceName = ''
  if ($sources -contains 'web') { $sourceName = 'web' }
  elseif ($sources -contains 'desktop') { $sourceName = 'desktop' }
  elseif ($sources.Count -gt 0) { $sourceName = [string]$sources[0] }
  $sourceProfile = ''
  if ($sourceName -eq 'web') { $sourceProfile = $paths.WebProfile }
  elseif ($sourceName -eq 'desktop') { $sourceProfile = $paths.DesktopProfile }
  if (-not $sourceProfile -or -not (Test-Path -LiteralPath $sourceProfile -PathType Leaf)) {
    return New-KitSetupFailure 'configure' @('模型来源 profile 不可用：' + $sourceName + '（' + $sourceProfile + '）') $envInfo
  }

  $stateLock = Enter-KitStateLock 120
  if ($null -eq $stateLock) {
    return New-KitSetupFailure 'configure' @('等待状态文件锁超时（120 秒）：可能有其他 dsh/kit 进程正在写入配置，请稍后重试') $envInfo
  }
  try {
  $oldState = Read-KitState
  $now = (Get-Date).ToString('o')
  $createdAt = $now
  if ($oldState) {
    $oldCreated = Get-KitProp $oldState 'createdAt'
    if ($oldCreated) { $createdAt = [string]$oldCreated }
  }
  $idsSource = $null
  if ($oldState) { $idsSource = Get-KitProp $oldState 'pluginIds' }
  $pluginIds = Copy-KitPluginIds $idsSource

  $modelState = [ordered]@{
    provider        = [string]$selModel.provider
    id              = [string]$selModel.id
    name            = [string]$selModel.name
    plugin          = [string]$selModel.plugin
    pluginName      = [string]$selModel.pluginName
    source          = $sourceName
    contextWindow   = $selModel.contextWindow
    input           = @($selModel.input)
    vision          = [bool]$selModel.vision
    efforts         = @(Get-KitModelEfforts $selModel)
    effortsKnown    = $effortsKnown
    capabilitySource = [string]$selModel.capabilitySource
  }
  if (-not $effortsKnown) { $modelState.efforts = $null }

  $features = [ordered]@{
    browser     = [ordered]@{ available = $browserOk; reason = $browserReason; chromePath = $chrome.Path }
    computerUse = [ordered]@{ available = $computerOk; reason = $computerReason }
    compaction  = [ordered]@{ applied = $false; thresholdRatio = $null; retainTokens = $null; reason = '' }
  }
  $state = [ordered]@{
    schemaVersion = 1
    kitVersion    = $script:KitVersion
    createdAt     = $createdAt
    updatedAt     = $now
    dshHome       = $paths.DshHome
    dshVersion    = $dsh.Version
    dshPackageDir = $dsh.PackageDir
    nodeVersion   = $dsh.NodeVersion
    model         = $modelState
    effortMode    = $effortMode
    defaultEffort = $defaultEffort
    mode          = $modeInput
    patches       = [ordered]@{}
    plugins       = $plugins
    pluginIds     = $pluginIds
    features      = $features
  }

  # 先在临时目录生成补丁；成功后才移入 Patches 并写 state，失败则旧配置保持不变。
  $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('dsh-delegate-kit-setup-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
  $spec = [ordered]@{
    sourceProfile   = $sourceProfile
    provider        = [string]$selModel.provider
    model           = [string]$selModel.id
    plugin          = [string]$selModel.plugin
    pluginName      = [string]$selModel.pluginName
    efforts         = @(Get-KitModelEfforts $selModel)
    defaultEffort   = $defaultEffort
    contextWindow   = $selModel.contextWindow
    browserAvailable = $browserOk
    chromePath      = $chrome.Path
    pluginIds       = $pluginIds
  }
  $tempSpecPath = Join-Path $tempDir 'spec.json'
  Write-KitJson $tempSpecPath $spec

  $genR = Invoke-KitSetupHelper $dsh @('gen-patches', '--spec', $tempSpecPath, '--out', $tempDir, '--dsh-pkg', $dsh.PackageDir)
  if ($genR.ExitCode -ne 0 -or $null -eq $genR.Json -or (Get-KitProp $genR.Json 'error')) {
    return New-KitSetupFailure 'configure' @('生成补丁失败：' + (Get-KitSetupHelperError $genR)) $envInfo
  }
  $gen = $genR.Json
  foreach ($gw in @(Get-KitProp $gen 'warnings')) { if ($gw) { $warnings.Add([string]$gw) } }
  $modelState.providerEntry = [bool](Get-KitProp $gen 'providerEntry')

  New-Item -ItemType Directory -Force -Path $paths.Patches | Out-Null
  Copy-KitGeneratedFiles $gen $paths.Patches
  Copy-Item -LiteralPath $tempSpecPath -Destination (Join-Path $paths.Home 'spec.json') -Force
  $patchState = New-KitPatchState $gen
  $state.patches = $patchState
  Remove-KitStaleEfforts $paths.Patches @($patchState.effort.Keys)

  $compFeature = Get-KitFeatureCompaction $gen
  $state.features = [ordered]@{
    browser     = [ordered]@{ available = $browserOk; reason = $browserReason; chromePath = $chrome.Path }
    computerUse = [ordered]@{ available = $computerOk; reason = $computerReason }
    compaction  = [ordered]@{
      applied        = $compFeature.applied
      thresholdRatio = $compFeature.thresholdRatio
      retainTokens   = $compFeature.retainTokens
      reason         = $compFeature.reason
    }
  }
  Save-KitState $state

  $check = Invoke-KitCheck -UpdateBaseline

  $result = [ordered]@{
    stage         = 'configured'
    ok            = [bool](Get-KitProp $check.Result 'ok')
    env           = $envInfo
    model         = $modelState
    effortMode    = $effortMode
    defaultEffort = $defaultEffort
    mode          = $modeInput
    patches       = $patchState
    plugins       = $resultPlugins
    features      = (Get-KitProp $check.Result 'features')
    warnings      = @($warnings)
    check         = $check.Result
  }

  $lines = New-Object 'System.Collections.Generic.List[string]'
  $lines.Add('dsh-delegate-kit setup 完成')
  $lines.Add('模型：' + $provider + '/' + $modelId + '（' + [string]$selModel.name + '）')
  $effortText = 'auto（默认 ' + [string]$defaultEffort + '）'
  if ($effortMode -eq 'fixed') { $effortText = 'fixed（' + [string]$defaultEffort + '）' }
  $lines.Add('思考档：' + $effortText)
  $lines.Add('权限：' + $modeInput)
  $lines.Add('补丁目录：' + $paths.Patches)
  $lines.Add('补丁文件：')
  $lines.Add('  base.yml')
  foreach ($key in $patchState.effort.Keys) { $lines.Add('  effort-' + $key + '.yml') }
  $lines.Add('  no-browser.yml')
  $lines.Add('  computer-use.yml')
  if ($resultPlugins.needInstall -eq $true) {
    $lines.Add('')
    $lines.Add('插件未对齐，未执行安装。征得用户同意后执行：')
    $lines.Add('  ' + [string]$resultPlugins.command)
    $lines.Add('或重跑 setup 并加 -InstallPlugins。')
  }
  $lines.Add('')
  $lines.Add([string](Get-KitProp $check 'Text'))
  $lines.Add('')
  $lines.Add('提示：')
  $lines.Add('- 可以跑一个极小的真实任务做冒烟测试（会消耗 token，需先征得用户同意）。')
  $lines.Add('- 查看要追加的全局规则：kit.ps1 rules -Host claude -Show（Codex 用 -Host codex）。')

  return @{ ExitCode = [int](Get-KitProp $check 'ExitCode'); Result = $result; Text = ($lines -join "`n") }
  } finally {
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    Exit-KitStateLock $stateLock
  }
}

# ============================================================
# check
# ============================================================

function Invoke-KitCheck {
  param([switch]$UpdateBaseline)
  $paths = Get-KitPaths
  $stateLock = Enter-KitStateLock 120
  if ($null -eq $stateLock) {
    $lockReason = '等待状态文件锁超时（120 秒）：可能有其他 dsh/kit 进程正在写入配置，请稍后重试'
    $result = [ordered]@{
      ok             = $false
      dshVersion     = ''
      baselineVersion = ''
      reasons        = @($lockReason)
      warnings       = @()
      dshTested      = $null
      features       = [ordered]@{
        browser     = [ordered]@{ available = $false; reason = '未执行' }
        computerUse = [ordered]@{ available = $false; reason = '未执行' }
        compaction  = [ordered]@{ available = $false; reason = '未执行' }
      }
      required       = @()
      updatedBaseline = $false
    }
    return @{ ExitCode = 1; Result = $result; Text = ('dsh-delegate-kit 自检未执行：' + $lockReason) }
  }
  try {
  $state = Read-KitState
  if ($null -eq $state) {
    $result = [ordered]@{
      ok             = $false
      dshVersion     = ''
      baselineVersion = ''
      reasons        = @('未初始化：先运行 setup')
      warnings       = @()
      dshTested      = $null
      features       = [ordered]@{
        browser     = [ordered]@{ available = $false; reason = '未初始化' }
        computerUse = [ordered]@{ available = $false; reason = '未初始化' }
        compaction  = [ordered]@{ available = $false; reason = '未初始化' }
      }
      required       = @()
    }
    return @{ ExitCode = 2; Result = $result; Text = 'dsh-delegate-kit 尚未初始化：先运行 kit.ps1 setup' }
  }

  $reasons = New-Object 'System.Collections.Generic.List[string]'
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  $required = New-Object 'System.Collections.Generic.List[object]'
  $baseline = [string](Get-KitProp $state 'dshVersion')
  $dsh = Find-KitDsh
  $dshOk = [bool]$dsh.Found
  $curVersion = ''
  if ($dshOk) { $curVersion = [string]$dsh.Version }
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
  $nodePath = $null
  if ($dsh.Node) { $nodePath = $dsh.Node } elseif ($nodeCmd) { $nodePath = $nodeCmd.Source }
  $nodeOk = [bool]($nodePath -and (Test-Path -LiteralPath $nodePath -PathType Leaf))

  $dshDetail = ''
  if ($dshOk) { $dshDetail = '版本 ' + $dsh.Version } else { $dshDetail = [string]$dsh.Error }
  $required.Add([ordered]@{ name = 'dsh'; ok = $dshOk; detail = $dshDetail })
  if (-not $dshOk) { $reasons.Add('找不到可用的 dsh：' + [string]$dsh.Error) }
  $nodeDetail = [string]$nodePath
  if (-not $nodeOk) { $nodeDetail = '找不到 node.exe' }
  $required.Add([ordered]@{ name = 'node'; ok = $nodeOk; detail = $nodeDetail })
  if (-not $nodeOk) { $reasons.Add('找不到 Node.js（node.exe）') }

  if ($curVersion -and $baseline -and $curVersion -ne $baseline) {
    $warnings.Add('dsh 版本 ' + $baseline + ' -> ' + $curVersion)
  }
  # 当前 dsh 不在 kit 已验证列表时只警告，不加入 reasons、不影响 ok。
  $dshTested = Get-KitDshTestedInfo $curVersion
  if ($dshTested.message) { $warnings.Add([string]$dshTested.message) }

  $patches = Get-KitProp $state 'patches'
  $baseInfo = Get-KitProp $patches 'base'
  $basePath = [string](Get-KitProp $baseInfo 'path')
  $baseSha = [string](Get-KitProp $baseInfo 'sha256')
  $effortMap = Get-KitProp $patches 'effort'
  $noBrowserInfo = Get-KitProp $patches 'noBrowser'
  $nbPath = [string](Get-KitProp $noBrowserInfo 'path')
  $cuInfo = Get-KitProp $patches 'computerUse'
  $cuPath = [string](Get-KitProp $cuInfo 'path')

  $effortLevels = @()
  if ($effortMap) {
    foreach ($p in $effortMap.PSObject.Properties) { $effortLevels += [string]$p.Name }
  }

  $patchItems = @()
  $patchItems += [ordered]@{ label = 'base.yml'; path = $basePath; sha = $baseSha }
  foreach ($level in $effortLevels) {
    $info = Get-KitProp $effortMap $level
    $patchItems += [ordered]@{ label = ('effort-' + $level + '.yml'); path = [string](Get-KitProp $info 'path'); sha = [string](Get-KitProp $info 'sha256') }
  }
  $patchItems += [ordered]@{ label = 'no-browser.yml'; path = $nbPath; sha = [string](Get-KitProp $noBrowserInfo 'sha256') }
  $patchItems += [ordered]@{ label = 'computer-use.yml'; path = $cuPath; sha = [string](Get-KitProp $cuInfo 'sha256') }

  foreach ($item in $patchItems) {
    $c = Get-KitPatchFileCheck $item.label $item.path $item.sha
    $required.Add([ordered]@{ name = ('补丁 ' + $item.label); ok = $c.ok; detail = $c.detail })
    foreach ($r in @($c.reasons)) { $reasons.Add([string]$r) }
    foreach ($w in @($c.warnings)) { $warnings.Add([string]$w) }
  }

  $checkDir = Join-Path $paths.Home 'check'
  New-Item -ItemType Directory -Force -Path $checkDir | Out-Null

  $baseDumpOk = $false
  $baseEntries = @()
  $baseDumpError = ''
  if ($dshOk -and $basePath -and (Test-Path -LiteralPath $basePath -PathType Leaf)) {
    $baseDump = Invoke-KitCheckDump $dsh @($basePath) (Join-Path $checkDir 'base.yml')
    $baseDumpOk = [bool]$baseDump.ok
    $baseEntries = @($baseDump.entries)
    $baseDumpError = [string]$baseDump.error
    $required.Add([ordered]@{ name = 'dump base'; ok = $baseDumpOk; detail = $(if ($baseDumpOk) { 'ok' } else { $baseDumpError }) })
    if (-not $baseDumpOk) { $reasons.Add('base 补丁叠加失败：' + $baseDumpError) }
  } else {
    $required.Add([ordered]@{ name = 'dump base'; ok = $false; detail = 'base 补丁不存在或 dsh 不可用，已跳过' })
    if ($dshOk) { $baseDumpError = 'base 补丁文件不存在' } else { $baseDumpError = 'dsh 不可用' }
  }

  $model = Get-KitProp $state 'model'
  $modelProvider = [string](Get-KitProp $model 'provider')
  $modelId = [string](Get-KitProp $model 'id')
  $defaultEffort = Get-KitProp $state 'defaultEffort'

  if ($baseDumpOk) {
    $credId = Get-KitPluginIdEntry $state 'credentials'
    $cred = Find-KitDumpEntry $baseEntries ([string]$credId.name) ([string]$credId.id)
    $credOk = $false
    $credDetail = ''
    if ($null -eq $cred) {
      $credDetail = 'dump 里找不到 ' + [string]$credId.name
    } elseif ([string]$cred.name -ne [string]$credId.name) {
      $credDetail = '条目名称是 ' + [string]$cred.name + '，期望 ' + [string]$credId.name
    } elseif ($cred.disabled -eq $true) {
      $credDetail = '被禁用（disabled=true）'
    } else {
      $credOk = $true
      $credDetail = 'id=' + [string]$cred.id
    }
    $required.Add([ordered]@{ name = '凭证插件'; ok = $credOk; detail = $credDetail })
    if (-not $credOk) { $reasons.Add('凭证插件未正确启用：' + $credDetail) }

    $pluginName = [string](Get-KitProp $model 'pluginName')
    $pluginId = [string](Get-KitProp $model 'plugin')
    $needProviderEntry = -not ((Get-KitProp $model 'providerEntry') -eq $false)
    $peOk = $true
    $peDetail = ''
    if (-not $needProviderEntry) {
      $peDetail = 'state 标记 providerEntry=false，沿用 dsh 内置服务商配置，无需服务商插件条目'
    } else {
      $pe = Find-KitDumpEntry $baseEntries $pluginName $pluginId
      if ($null -eq $pe) {
        $peOk = $false
        $peDetail = 'dump 里找不到服务商插件条目 ' + $pluginName
      } elseif ($pe.disabled -eq $true) {
        $peOk = $false
        $peDetail = '服务商插件被禁用'
      } else {
        $cfg = Get-KitProp $pe 'config'
        $providers = Get-KitProp $cfg 'providers'
        if ($providers) {
          $prov = Get-KitProp $providers $modelProvider
          if ($null -eq $prov) {
            $peOk = $false
            $peDetail = '缺少 provider ' + $modelProvider
          } elseif ($pluginName -ceq '@deepseek-ai/dsh-llm-pi-ai') {
            $modelPartOk = $false
            foreach ($me in @(Get-KitProp $prov 'models')) {
              if ([string](Get-KitProp $me 'id') -ceq $modelId) { $modelPartOk = $true; break }
            }
            if (-not $modelPartOk) {
              $overrides = Get-KitProp $prov 'modelOverrides'
              if ($null -ne $overrides -and (Test-KitPropExists $overrides $modelId)) { $modelPartOk = $true }
            }
            if ($modelPartOk) {
              $peOk = $true
              $peDetail = '含 provider ' + $modelProvider + ' 和模型 ' + $modelId
            } else {
              $peOk = $false
              $peDetail = 'provider ' + $modelProvider + ' 里缺少模型 ' + $modelId + '（models 与 modelOverrides 都没有）'
            }
          } else {
            $peOk = $true
            $peDetail = '含 provider ' + $modelProvider
          }
        } else {
          $modelHits = @()
          foreach ($me in @(Get-KitProp $cfg 'models')) {
            if ([string](Get-KitProp $me 'id') -eq $modelId) { $modelHits += $me }
          }
          if ($modelHits.Count -gt 0) {
            $peOk = $true
            $peDetail = '含模型 ' + $modelId
          } else {
            $peOk = $false
            $peDetail = '缺少模型 ' + $modelId
          }
        }
      }
    }
    $required.Add([ordered]@{ name = '服务商插件'; ok = $peOk; detail = $peDetail })
    if (-not $peOk) { $reasons.Add('服务商插件条目不正确：' + $peDetail) }

    $admId = Get-KitPluginIdEntry $state 'agentDefaultModel'
    $adm = Find-KitDumpEntry $baseEntries ([string]$admId.name) ([string]$admId.id)
    $admOk = $false
    $admDetail = ''
    if ($null -eq $adm) {
      $admDetail = 'dump 里找不到 ' + [string]$admId.name
    } elseif ($adm.disabled -eq $true) {
      $admDetail = '条目被禁用（disabled=true）'
    } else {
      $cfg = Get-KitProp $adm 'config'
      $pOk = ([string](Get-KitProp $cfg 'provider') -eq $modelProvider)
      $mOk = ([string](Get-KitProp $cfg 'model') -eq $modelId)
      $hasEffort = Test-KitPropExists $cfg 'reasoningEffort'
      if (-not $pOk -or -not $mOk) {
        $admDetail = 'provider/model 是 ' + [string](Get-KitProp $cfg 'provider') + '/' + [string](Get-KitProp $cfg 'model')
      } elseif ($defaultEffort) {
        if (-not $hasEffort -or [string](Get-KitProp $cfg 'reasoningEffort') -cne [string]$defaultEffort) {
          $admDetail = 'reasoningEffort 是 ' + [string](Get-KitProp $cfg 'reasoningEffort') + '，期望 ' + [string]$defaultEffort
        } else {
          $admOk = $true
          $admDetail = 'reasoningEffort=' + [string]$defaultEffort
        }
      } else {
        if ($hasEffort) {
          $admDetail = '默认档应为 provider 默认，但出现了 reasoningEffort=' + [string](Get-KitProp $cfg 'reasoningEffort')
        } else {
          $admOk = $true
          $admDetail = '未写 reasoningEffort'
        }
      }
    }
    $required.Add([ordered]@{ name = '默认模型'; ok = $admOk; detail = $admDetail })
    if (-not $admOk) { $reasons.Add('默认模型条目不正确：' + $admDetail) }

    foreach ($level in $effortLevels) {
      $info = Get-KitProp $effortMap $level
      $efPath = [string](Get-KitProp $info 'path')
      if (-not $efPath -or -not (Test-Path -LiteralPath $efPath -PathType Leaf)) {
        $required.Add([ordered]@{ name = ('思考档 ' + $level); ok = $false; detail = '补丁文件不存在' })
        continue
      }
      $safeLevel = ($level -replace '[^A-Za-z0-9_-]', '_')
      $efOut = Join-Path $checkDir ('effort-' + $safeLevel + '.yml')
      $efDump = Invoke-KitCheckDump $dsh @($basePath, $efPath) $efOut
      $efOk = $false
      $efDetail = ''
      if (-not $efDump.ok) {
        $efDetail = '叠加失败：' + [string]$efDump.error
        $reasons.Add('思考档 ' + $level + ' 补丁叠加失败：' + [string]$efDump.error)
      } else {
        $entry = Find-KitDumpEntry @($efDump.entries) ([string]$admId.name) ([string]$admId.id)
        if ($null -eq $entry) {
          $efDetail = 'dump 里找不到默认模型条目'
        } else {
          $cfg = Get-KitProp $entry 'config'
          if ([string](Get-KitProp $cfg 'provider') -ne $modelProvider -or [string](Get-KitProp $cfg 'model') -ne $modelId) {
            $efDetail = 'provider/model 被改动为 ' + [string](Get-KitProp $cfg 'provider') + '/' + [string](Get-KitProp $cfg 'model')
          } elseif ([string](Get-KitProp $cfg 'reasoningEffort') -cne $level) {
            $efDetail = 'reasoningEffort 是 ' + [string](Get-KitProp $cfg 'reasoningEffort') + '，期望 ' + $level
          } else {
            $efOk = $true
            $efDetail = 'reasoningEffort=' + $level
          }
        }
      }
      $required.Add([ordered]@{ name = ('思考档 ' + $level); ok = $efOk; detail = $efDetail })
      if (-not $efOk) { $reasons.Add('思考档 ' + $level + ' 补丁未生效：' + $efDetail) }
    }
  } else {
    foreach ($level in $effortLevels) {
      $required.Add([ordered]@{ name = ('思考档 ' + $level); ok = $false; detail = 'base dump 失败，未验证' })
    }
  }

  $nbDumpOk = $false
  $nbEntries = @()
  $nbDumpError = ''
  if ($baseDumpOk -and $nbPath -and (Test-Path -LiteralPath $nbPath -PathType Leaf)) {
    $nbDump = Invoke-KitCheckDump $dsh @($basePath, $nbPath) (Join-Path $checkDir 'no-browser.yml')
    $nbDumpOk = [bool]$nbDump.ok
    $nbEntries = @($nbDump.entries)
    $nbDumpError = [string]$nbDump.error
    $required.Add([ordered]@{ name = 'dump no-browser'; ok = $nbDumpOk; detail = $(if ($nbDumpOk) { 'ok' } else { $nbDumpError }) })
    if (-not $nbDumpOk) { $reasons.Add('no-browser 补丁叠加失败：' + $nbDumpError) }
  } else {
    $required.Add([ordered]@{ name = 'dump no-browser'; ok = $false; detail = 'no-browser 补丁不存在或 base dump 失败，已跳过' })
    if ($nbPath -and -not (Test-Path -LiteralPath $nbPath -PathType Leaf)) { $nbDumpError = 'no-browser 补丁文件不存在' }
  }

  $cuDumpOk = $false
  $cuEntries = @()
  $cuDumpError = ''
  if ($baseDumpOk -and $cuPath -and (Test-Path -LiteralPath $cuPath -PathType Leaf)) {
    $cuDump = Invoke-KitCheckDump $dsh @($basePath, $cuPath) (Join-Path $checkDir 'computer-use.yml')
    $cuDumpOk = [bool]$cuDump.ok
    $cuEntries = @($cuDump.entries)
    $cuDumpError = [string]$cuDump.error
  } elseif (-not $cuPath -or -not (Test-Path -LiteralPath $cuPath -PathType Leaf)) {
    $cuDumpError = 'computer-use 补丁文件不存在'
  } else {
    $cuDumpError = 'base dump 失败，未验证'
  }

  if ($dshOk -and ($model.effortsKnown -eq $true)) {
    $catOk = $true
    $catDetail = ''
    $needLevels = @()
    if ($defaultEffort) { $needLevels += [string]$defaultEffort }
    foreach ($level in $effortLevels) { if ($needLevels -cnotcontains $level) { $needLevels += $level } }
    if ([string](Get-KitProp $model 'capabilitySource') -ceq 'profile-declared') {
      # profile 声明的档位会随 profile 改动；按 setup 同样的 profile 参数重新读取当前声明。
      $pm = Get-KitSetupModels $dsh
      $hit = $null
      if ($pm.ok) {
        foreach ($m in @($pm.models)) {
          if ([string]$m.provider -ceq $modelProvider -and [string]$m.id -ceq $modelId) { $hit = $m; break }
        }
      }
      if ($null -eq $hit) {
        $catOk = $false
        if ($pm.ok) {
          $catDetail = 'profile 里查不到该模型'
          $reasons.Add('模型 ' + $modelProvider + '/' + $modelId + ' 已不在 web/desktop profile 的模型声明中，无法确认思考档；请重新运行 setup 选择模型')
        } else {
          $catDetail = '重新读取 profile 失败'
          $reasons.Add('重新读取 profile 模型声明失败，无法确认思考档：' + [string]$pm.error)
        }
      } elseif ($hit.effortsKnown -ne $true) {
        $catOk = $false
        $catDetail = 'profile 未声明有效思考档'
        $reasons.Add('模型 ' + $modelProvider + '/' + $modelId + ' 在 profile 中未声明有效思考档；请重新运行 setup 选择思考档')
      } else {
        $supported = @(Get-KitModelEfforts $hit)
        foreach ($level in $needLevels) {
          if ($supported -cnotcontains $level) {
            $catOk = $false
            $reasons.Add('profile 当前声明的思考档已不包含 ' + $level + '（支持：' + (@($supported) -join '/') + '）')
          }
        }
        if ($catOk) { $catDetail = 'profile 声明支持 ' + (@($supported) -join '/') }
      }
    } else {
      $cat = Invoke-KitSetupHelper $dsh @('catalog', '--dsh-pkg', $dsh.PackageDir, '--provider', $modelProvider, '--model', $modelId)
      if ($cat.ExitCode -ne 0 -or $null -eq $cat.Json) {
        $catDetail = '查询失败，已跳过'
        $warnings.Add('重新查询模型能力失败：' + (Get-KitSetupHelperError $cat))
      } elseif (-not (Get-KitProp $cat.Json 'found')) {
        $catDetail = '模型目录里查不到，已跳过'
        $warnings.Add('模型目录里查不到 ' + $modelProvider + '/' + $modelId + '，无法校验思考档')
      } else {
        $supported = @()
        if (Get-KitProp $cat.Json 'efforts') { $supported = @(Get-KitProp $cat.Json 'efforts') }
        foreach ($level in $needLevels) {
          if ($supported -cnotcontains $level) {
            $catOk = $false
            $reasons.Add('dsh 升级后模型不再支持思考档 ' + $level)
          }
        }
        if ($catOk) { $catDetail = '支持 ' + (@($supported) -join '/') }
      }
    }
    $required.Add([ordered]@{ name = '模型思考档'; ok = $catOk; detail = $catDetail })
  }

  $oldFeatures = Get-KitProp $state 'features'
  $oldBrowser = Get-KitProp $oldFeatures 'browser'
  $chromePathOut = [string](Get-KitProp $oldBrowser 'chromePath')
  $pluginStatus = $null
  if ($dshOk) { $pluginStatus = Get-KitPluginStatus $dsh }

  $browserAvail = $false
  $browserReason = ''
  if (-not $dshOk) {
    $browserReason = 'dsh 不可用'
  } elseif ($null -eq $pluginStatus -or -not $pluginStatus.browserOk) {
    $browserReason = '浏览器插件未与 dsh 版本对齐'
  } elseif (-not $baseDumpOk) {
    $browserReason = 'base 补丁 dump 失败，无法确认浏览器配置'
  } else {
    $buId = Get-KitPluginIdEntry $state 'browserUse'
    $bpId = Get-KitPluginIdEntry $state 'browserProvider'
    $bu = Find-KitDumpEntry $baseEntries ([string]$buId.name) ([string]$buId.id)
    $bp = Find-KitDumpEntry $baseEntries ([string]$bpId.name) ([string]$bpId.id)
    if ($null -eq $bu -or $null -eq $bp) {
      $browserReason = 'base 补丁没有插入浏览器插件'
    } elseif ($bu.disabled -eq $true -or $bp.disabled -eq $true) {
      $browserReason = 'base 补丁里浏览器插件被禁用'
    } elseif (-not $nbDumpOk) {
      $browserReason = 'no-browser 补丁 dump 失败，无法确认浏览器已禁用：' + $nbDumpError
    } else {
      $nbu = Find-KitDumpEntry $nbEntries ([string]$buId.name) ([string]$buId.id)
      $nbp = Find-KitDumpEntry $nbEntries ([string]$bpId.name) ([string]$bpId.id)
      if ($null -eq $nbu -or $null -eq $nbp) {
        $browserReason = 'no-browser 补丁里缺少浏览器条目'
      } elseif ($nbu.disabled -ne $true -or $nbp.disabled -ne $true) {
        $browserReason = 'no-browser 补丁没有禁用浏览器插件'
      } else {
        $exe = [string](Get-KitProp (Get-KitProp $bp 'config') 'executablePath')
        if ($exe) { $chromePathOut = $exe }
        if (-not $exe) {
          $browserReason = '浏览器插件没有配置 executablePath'
        } elseif (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
          $browserReason = '浏览器可执行文件不存在：' + $exe
        } else {
          $browserAvail = $true
          $browserReason = ''
        }
      }
    }
  }

  $cuAvail = $false
  $cuReason = ''
  if (-not $dshOk) {
    $cuReason = 'dsh 不可用'
  } elseif ($null -eq $pluginStatus -or -not $pluginStatus.computerOk) {
    $cuReason = '电脑操作插件未与 dsh 版本对齐'
  } elseif (-not $cuDumpOk) {
    $cuReason = 'computer-use 补丁叠加或解析失败：' + $cuDumpError
  } else {
    $cuId = Get-KitPluginIdEntry $state 'computerUse'
    $cpId = Get-KitPluginIdEntry $state 'computerProvider'
    $cu1 = Find-KitDumpEntry $cuEntries ([string]$cuId.name) ([string]$cuId.id)
    $cu2 = Find-KitDumpEntry $cuEntries ([string]$cpId.name) ([string]$cpId.id)
    if ($null -eq $cu1 -or $null -eq $cu2) {
      $cuReason = 'computer-use 补丁没有插入电脑操作插件'
    } elseif ($cu1.disabled -eq $true -or $cu2.disabled -eq $true) {
      $cuReason = '电脑操作插件被禁用'
    } else {
      $cuAvail = $true
      $cuReason = ''
    }
  }

  $oldComp = Get-KitProp $oldFeatures 'compaction'
  $compApplied = [bool](Get-KitProp $oldComp 'applied')
  $compThreshold = Get-KitProp $oldComp 'thresholdRatio'
  $compRetain = Get-KitProp $oldComp 'retainTokens'
  $compReason = [string](Get-KitProp $oldComp 'reason')
  $compAvail = $true
  if ($compApplied) {
    if (-not $baseDumpOk) {
      $compAvail = $false
      $compReason = 'base 补丁 dump 失败，无法确认压缩参数'
    } else {
      $cmpId = Get-KitPluginIdEntry $state 'compaction'
      $cmp = Find-KitDumpEntry $baseEntries ([string]$cmpId.name) ([string]$cmpId.id)
      if ($null -eq $cmp) {
        $compAvail = $false
        $compReason = 'base 补丁里没有压缩条目'
      } else {
        $ratio = Get-KitProp (Get-KitProp $cmp 'config') 'thresholdRatio'
        if ($null -eq $ratio) {
          $compAvail = $false
          $compReason = '压缩条目没有 thresholdRatio'
        } elseif ($null -ne $compThreshold -and [math]::Abs(([double]$ratio) - ([double]$compThreshold)) -gt 0.00001) {
          $compAvail = $false
          $compReason = '压缩阈值与 state 不一致：dump=' + [string]$ratio + '，state=' + [string]$compThreshold
        } else {
          $compReason = ''
        }
      }
    }
  }

  $features = [ordered]@{
    browser     = [ordered]@{ available = $browserAvail; reason = $browserReason; chromePath = $chromePathOut }
    computerUse = [ordered]@{ available = $cuAvail; reason = $cuReason }
    compaction  = [ordered]@{
      available      = $compAvail
      applied        = $compApplied
      thresholdRatio = $compThreshold
      retainTokens   = $compRetain
      reason         = $compReason
    }
  }

  $ok = ($reasons.Count -eq 0)
  $now = (Get-Date).ToString('o')
  Set-KitStateProp $state 'updatedAt' $now
  Set-KitStateProp $state 'lastCheck' ([ordered]@{ at = $now; ok = $ok; dshVersion = $curVersion })
  Set-KitStateProp $state 'features' $features
  if ($UpdateBaseline -and $ok) {
    Set-KitStateProp $state 'kitVersion' $script:KitVersion
    if ($curVersion) { Set-KitStateProp $state 'dshVersion' $curVersion }
    if ($dshOk) {
      Set-KitStateProp $state 'dshPackageDir' $dsh.PackageDir
      Set-KitStateProp $state 'nodeVersion' $dsh.NodeVersion
    }
    if ($null -ne $pluginStatus) { Set-KitStateProp $state 'plugins' $pluginStatus }
    # 补丁改动过但仍通过自检：刷新哈希，避免之后每次派发都重跑 check
    $patchEntries = @()
    foreach ($k in @('base', 'noBrowser', 'computerUse')) { $pe = Get-KitProp $state.patches $k; if ($pe) { $patchEntries += $pe } }
    $effortSet = Get-KitProp $state.patches 'effort'
    if ($effortSet) { foreach ($ep in $effortSet.PSObject.Properties) { if ($ep.Value) { $patchEntries += $ep.Value } } }
    foreach ($pe in $patchEntries) {
      $peHash = Get-KitSha256 ([string](Get-KitProp $pe 'path'))
      if ($peHash) { Set-KitStateProp $pe 'sha256' $peHash }
    }
  }
  Save-KitState $state

  $result = [ordered]@{
    ok              = $ok
    dshVersion      = $curVersion
    baselineVersion = $baseline
    reasons         = @($reasons)
    warnings        = @($warnings)
    dshTested       = $dshTested
    features        = [ordered]@{
      browser     = [ordered]@{ available = $browserAvail; reason = $browserReason }
      computerUse = [ordered]@{ available = $cuAvail; reason = $cuReason }
      compaction  = [ordered]@{ available = $compAvail; reason = $compReason }
    }
    required        = $required.ToArray()
    updatedBaseline = [bool]($UpdateBaseline -and $ok)
  }

  $lines = New-Object 'System.Collections.Generic.List[string]'
  $lines.Add('dsh-delegate-kit 自检（基线 ' + $baseline + '，当前 ' + $curVersion + '）')
  foreach ($item in $required) {
    $mark = '✗'
    if ($item.ok -eq $true) { $mark = '✓' }
    $detailText = ''
    if ($item.detail) { $detailText = '：' + [string]$item.detail }
    $lines.Add($mark + ' ' + [string]$item.name + $detailText)
  }
  foreach ($w in $warnings) { $lines.Add('⚠ ' + [string]$w) }
  $lines.Add('可选功能：')
  $browserMark = '✗'
  if ($browserAvail) { $browserMark = '✓' }
  $browserLine = $browserMark + ' 浏览器'
  if ($browserReason) { $browserLine += '：' + $browserReason }
  $lines.Add($browserLine)
  $cuMark = '✗'
  if ($cuAvail) { $cuMark = '✓' }
  $cuLine = $cuMark + ' 电脑操作'
  if ($cuReason) { $cuLine += '：' + $cuReason }
  $lines.Add($cuLine)
  $compMark = '✗'
  if ($compAvail) { $compMark = '✓' }
  $compLine = $compMark + ' 压缩'
  if ($compApplied) { $compLine += '（thresholdRatio=' + [string]$compThreshold + '，retainTokens=' + [string]$compRetain + '）' }
  if ($compReason) { $compLine += '：' + $compReason }
  $lines.Add($compLine)
  $lines.Add('')
  if ($ok) { $lines.Add('结论：通过') } else { $lines.Add('结论：不通过（运行 kit.ps1 repair 修复）') }

  return @{ ExitCode = $(if ($ok) { 0 } else { 1 }); Result = $result; Text = ($lines -join "`n") }
  } finally {
    Exit-KitStateLock $stateLock
  }
}

# ============================================================
# repair
# ============================================================

function Invoke-KitRepair {
  param([switch]$InstallPlugins)
  $paths = Get-KitPaths
  $stateLock = Enter-KitStateLock 120
  if ($null -eq $stateLock) {
    $lockReason = '等待状态文件锁超时（120 秒）：可能有其他 dsh/kit 进程正在写入配置，请稍后重试'
    $result = [ordered]@{ ok = $false; stage = 'repair'; reasons = @($lockReason); warnings = @(); patches = $null; plugins = $null }
    return @{ ExitCode = 1; Result = $result; Text = ('dsh-delegate-kit repair 未执行：' + $lockReason) }
  }
  try {
  $state = Read-KitState
  if ($null -eq $state) {
    $result = [ordered]@{ ok = $false; stage = 'repair'; reasons = @('未初始化：先运行 setup'); warnings = @(); patches = $null; plugins = $null }
    return @{ ExitCode = 2; Result = $result; Text = 'dsh-delegate-kit 尚未初始化：先运行 kit.ps1 setup' }
  }

  $reasons = New-Object 'System.Collections.Generic.List[string]'
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  $dsh = Find-KitDsh
  if (-not $dsh.Found) {
    return New-KitSetupFailure 'repair' @('找不到可用的 dsh：' + [string]$dsh.Error + '。修复：npm i -g @deepseek-ai/dsh') $null 'kit.ps1 repair'
  }

  $plugins = Get-KitPluginStatus $dsh
  $resultPlugins = $plugins
  if (-not $plugins.aligned) {
    if ($InstallPlugins) {
      $install = Invoke-KitPluginInstall $dsh
      $plugins = Get-KitPluginStatus $dsh
      $resultPlugins = $plugins
      if ($install.ExitCode -ne 0) {
        $warnings.Add('插件安装失败（exit ' + [string]$install.ExitCode + '）：' + (Get-KitProcessSummary $install))
      } elseif (-not $plugins.aligned) {
        $warnings.Add('插件安装命令已执行，但仍未对齐：' + ((@($plugins.misaligned)) -join '、'))
      }
    } else {
      $resultPlugins = [ordered]@{
        needInstall = $true
        command     = $plugins.command
        aligned     = $false
        expected    = $plugins.expected
        installed   = $plugins.installed
        misaligned  = @($plugins.misaligned)
      }
      $warnings.Add('插件未对齐，未执行安装。征得用户同意后加 -InstallPlugins 重跑。')
    }
  }

  # 用 dump 重新识别插件 id
  $ids = Copy-KitPluginIds (Get-KitProp $state 'pluginIds')
  $checkDir = Join-Path $paths.Home 'check'
  New-Item -ItemType Directory -Force -Path $checkDir | Out-Null
  $patchStateOld = Get-KitProp $state 'patches'
  $basePath = [string](Get-KitProp (Get-KitProp $patchStateOld 'base') 'path')
  $cuPath = [string](Get-KitProp (Get-KitProp $patchStateOld 'computerUse') 'path')
  $entries = @()
  $baseDumpOk = $false
  if ($basePath -and (Test-Path -LiteralPath $basePath -PathType Leaf)) {
    $dump = Invoke-KitDumpConfig $dsh @($basePath) (Join-Path $checkDir 'repair-base.yml')
    if ($dump.ExitCode -eq 0) {
      $parse = Invoke-KitSetupHelper $dsh @('parse-dump', '--file', (Join-Path $checkDir 'repair-base.yml'), '--dsh-pkg', $dsh.PackageDir)
      if ($parse.ExitCode -eq 0 -and $null -ne $parse.Json) {
        if (Get-KitProp $parse.Json 'entries') { $entries += @(Get-KitProp $parse.Json 'entries') }
        $baseDumpOk = $true
      }
    }
  }
  if (-not $baseDumpOk) {
    $dump = Invoke-KitDumpConfig $dsh @() (Join-Path $checkDir 'repair-raw.yml')
    if ($dump.ExitCode -eq 0) {
      $parse = Invoke-KitSetupHelper $dsh @('parse-dump', '--file', (Join-Path $checkDir 'repair-raw.yml'), '--dsh-pkg', $dsh.PackageDir)
      if ($parse.ExitCode -eq 0 -and $null -ne $parse.Json) {
        if (Get-KitProp $parse.Json 'entries') { $entries += @(Get-KitProp $parse.Json 'entries') }
        $warnings.Add('base 补丁无法叠加，已按原始配置树重新识别插件 id')
      } else {
        $warnings.Add('无法解析原始配置树，保留现有插件 id')
      }
    } else {
      $warnings.Add('无法 dump 配置树，保留现有插件 id')
    }
  }
  if ($basePath -and $cuPath -and (Test-Path -LiteralPath $basePath -PathType Leaf) -and (Test-Path -LiteralPath $cuPath -PathType Leaf)) {
    $dump = Invoke-KitDumpConfig $dsh @($basePath, $cuPath) (Join-Path $checkDir 'repair-computer-use.yml')
    if ($dump.ExitCode -eq 0) {
      $parse = Invoke-KitSetupHelper $dsh @('parse-dump', '--file', (Join-Path $checkDir 'repair-computer-use.yml'), '--dsh-pkg', $dsh.PackageDir)
      if ($parse.ExitCode -eq 0 -and $null -ne $parse.Json) {
        if (Get-KitProp $parse.Json 'entries') { $entries += @(Get-KitProp $parse.Json 'entries') }
      }
    }
  }
  foreach ($key in @('credentials', 'agentDefaultModel', 'compaction', 'browserUse', 'browserProvider', 'computerUse', 'computerProvider')) {
    $name = [string]$ids[$key].name
    foreach ($e in @($entries)) {
      if ($null -ne $e -and [string]$e.name -eq $name) {
        if ($e.id) { $ids[$key].id = [string]$e.id }
        break
      }
    }
  }
  Set-KitStateProp $state 'pluginIds' $ids

  # 重新查模型能力
  $model = Get-KitProp $state 'model'
  $modelProvider = [string](Get-KitProp $model 'provider')
  $modelId = [string](Get-KitProp $model 'id')
  # 先按 setup 的方式从 profile 重新收集（profile 自带 reasoningEfforts 时以它为准），找不到再查目录
  $profileHit = $null
  $pm = Get-KitSetupModels $dsh
  if ($pm.ok) {
    foreach ($m in @($pm.models)) {
      if ([string]$m.provider -eq $modelProvider -and [string]$m.id -eq $modelId -and [string]$m.capabilitySource -ne 'profile-fallback') { $profileHit = $m; break }
    }
  }
  $cat = Invoke-KitSetupHelper $dsh @('catalog', '--dsh-pkg', $dsh.PackageDir, '--provider', $modelProvider, '--model', $modelId)
  if ($null -ne $profileHit) {
    Set-KitStateProp $model 'efforts' @($profileHit.efforts)
    Set-KitStateProp $model 'effortsKnown' ([bool]$profileHit.effortsKnown)
    Set-KitStateProp $model 'capabilitySource' ([string]$profileHit.capabilitySource)
    if ($null -ne $profileHit.contextWindow) { Set-KitStateProp $model 'contextWindow' $profileHit.contextWindow }
    if ($null -ne $profileHit.input) {
      Set-KitStateProp $model 'input' @($profileHit.input)
      Set-KitStateProp $model 'vision' (@($profileHit.input) -contains 'image')
    }
  } elseif ($cat.ExitCode -eq 0 -and $null -ne $cat.Json -and (Get-KitProp $cat.Json 'found')) {
    $newEfforts = @()
    if (Get-KitProp $cat.Json 'efforts') { $newEfforts = @(Get-KitProp $cat.Json 'efforts') }
    Set-KitStateProp $model 'efforts' $newEfforts
    Set-KitStateProp $model 'effortsKnown' $true
    Set-KitStateProp $model 'capabilitySource' 'catalog'
    $cw = Get-KitProp $cat.Json 'contextWindow'
    if ($null -ne $cw) { Set-KitStateProp $model 'contextWindow' $cw }
    $inp = Get-KitProp $cat.Json 'input'
    if ($null -ne $inp) {
      $inArr = @($inp)
      Set-KitStateProp $model 'input' $inArr
      Set-KitStateProp $model 'vision' ($inArr -contains 'image')
    }
  } else {
    $warnings.Add('无法重新查询模型能力，保留原思考档：' + (Get-KitSetupHelperError $cat))
  }

  $effortsKnown = ($model.effortsKnown -eq $true)
  $supported = @()
  if ($effortsKnown) { $supported = @(Get-KitModelEfforts $model) }
  $effortMode = [string](Get-KitProp $state 'effortMode')
  if (-not $effortMode) { $effortMode = 'auto' }
  $defaultEffort = Get-KitProp $state 'defaultEffort'
  if ($effortMode -eq 'fixed') {
    $fixedEffort = [string]$defaultEffort
    if ($fixedEffort -and $supported -notcontains $fixedEffort) {
      $reasons.Add('dsh 升级后模型不再支持思考档 ' + $fixedEffort + '，请重新运行 setup 选择思考档')
      $result = [ordered]@{
        ok       = $false
        stage    = 'repair'
        reasons  = @($reasons)
        warnings = @($warnings)
        model    = $model
        plugins  = $resultPlugins
      }
      $lines = New-Object 'System.Collections.Generic.List[string]'
      $lines.Add('dsh-delegate-kit 修复停止：')
      foreach ($r in $reasons) { $lines.Add('✗ ' + $r) }
      foreach ($w in $warnings) { $lines.Add('⚠ ' + $w) }
      $lines.Add('')
      $lines.Add('修复后重跑：kit.ps1 setup -Model ' + $modelProvider + '/' + $modelId + ' -Effort auto -Mode ' + [string](Get-KitProp $state 'mode'))
      return @{ ExitCode = 1; Result = $result; Text = ($lines -join "`n") }
    }
  } else {
    $effortMode = 'auto'
    if ($effortsKnown) {
      if ($supported -contains 'high') { $defaultEffort = 'high' }
      elseif ($supported -contains 'medium') { $defaultEffort = 'medium' }
      elseif ($supported.Count -gt 0) { $defaultEffort = [string]$supported[$supported.Count - 1] }
      else { $defaultEffort = $null }
    } else {
      $defaultEffort = $null
    }
    Set-KitStateProp $state 'defaultEffort' $defaultEffort
  }
  Set-KitStateProp $state 'effortMode' $effortMode

  $chrome = Find-KitChrome
  $oldFeatures = Get-KitProp $state 'features'
  $oldBrowser = Get-KitProp $oldFeatures 'browser'
  $chromePath = [string](Get-KitProp $oldBrowser 'chromePath')
  if (-not $chromePath -or -not (Test-Path -LiteralPath $chromePath -PathType Leaf)) { $chromePath = $chrome.Path }
  $browserOk = [bool]($plugins.browserOk -and $chromePath)
  $browserReason = ''
  if (-not $plugins.browserOk) { $browserReason = '浏览器插件未与 dsh 版本对齐' }
  elseif (-not $chromePath) { $browserReason = '未找到 Chrome 或 Edge' }
  $computerOk = [bool]$plugins.computerOk
  $computerReason = ''
  if (-not $computerOk) { $computerReason = '电脑操作插件未与 dsh 版本对齐' }

  $sourceName = [string](Get-KitProp $model 'source')
  if ($sourceName -ne 'web' -and $sourceName -ne 'desktop') {
    if (Test-Path -LiteralPath $paths.WebProfile -PathType Leaf) { $sourceName = 'web' }
    elseif (Test-Path -LiteralPath $paths.DesktopProfile -PathType Leaf) { $sourceName = 'desktop' }
  }
  $sourceProfile = ''
  if ($sourceName -eq 'web') { $sourceProfile = $paths.WebProfile }
  elseif ($sourceName -eq 'desktop') { $sourceProfile = $paths.DesktopProfile }
  if (-not $sourceProfile -or -not (Test-Path -LiteralPath $sourceProfile -PathType Leaf)) {
    return New-KitSetupFailure 'repair' @('模型来源 profile 不可用：' + $sourceName + '（' + $sourceProfile + '）') $null 'kit.ps1 repair'
  }

  New-Item -ItemType Directory -Force -Path $paths.Patches | Out-Null
  $spec = [ordered]@{
    sourceProfile    = $sourceProfile
    provider         = $modelProvider
    model            = $modelId
    plugin           = [string](Get-KitProp $model 'plugin')
    pluginName       = [string](Get-KitProp $model 'pluginName')
    efforts          = $supported
    defaultEffort    = $defaultEffort
    contextWindow    = (Get-KitProp $model 'contextWindow')
    browserAvailable = $browserOk
    chromePath       = $chromePath
    pluginIds        = $ids
  }
  $specPath = Join-Path $paths.Home 'spec.json'
  Write-KitJson $specPath $spec
  $genR = Invoke-KitSetupHelper $dsh @('gen-patches', '--spec', $specPath, '--out', $paths.Patches, '--dsh-pkg', $dsh.PackageDir)
  if ($genR.ExitCode -ne 0 -or $null -eq $genR.Json -or (Get-KitProp $genR.Json 'error')) {
    return New-KitSetupFailure 'repair' @('生成补丁失败：' + (Get-KitSetupHelperError $genR)) $null 'kit.ps1 repair'
  }
  $gen = $genR.Json
  foreach ($gw in @(Get-KitProp $gen 'warnings')) { if ($gw) { $warnings.Add([string]$gw) } }
  Set-KitStateProp $model 'providerEntry' ([bool](Get-KitProp $gen 'providerEntry'))
  $patchState = New-KitPatchState $gen
  Set-KitStateProp $state 'patches' $patchState
  Remove-KitStaleEfforts $paths.Patches @($patchState.effort.Keys)
  $compFeature = Get-KitFeatureCompaction $gen
  Set-KitStateProp $state 'features' ([ordered]@{
    browser     = [ordered]@{ available = $browserOk; reason = $browserReason; chromePath = $chromePath }
    computerUse = [ordered]@{ available = $computerOk; reason = $computerReason }
    compaction  = [ordered]@{
      applied        = $compFeature.applied
      thresholdRatio = $compFeature.thresholdRatio
      retainTokens   = $compFeature.retainTokens
      reason         = $compFeature.reason
    }
  })
  Set-KitStateProp $state 'dshPackageDir' $dsh.PackageDir
  Set-KitStateProp $state 'nodeVersion' $dsh.NodeVersion
  Set-KitStateProp $state 'updatedAt' ((Get-Date).ToString('o'))
  Save-KitState $state

  $check = Invoke-KitCheck -UpdateBaseline
  $result = [ordered]@{
    ok            = [bool](Get-KitProp $check.Result 'ok')
    stage         = 'repair'
    effortMode    = $effortMode
    defaultEffort = $defaultEffort
    model         = $model
    patches       = $patchState
    plugins       = $resultPlugins
    features      = (Get-KitProp $check.Result 'features')
    warnings      = @($warnings)
    check         = $check.Result
  }

  $lines = New-Object 'System.Collections.Generic.List[string]'
  $lines.Add('dsh-delegate-kit repair 完成，已重新生成补丁。')
  $lines.Add('模型：' + $modelProvider + '/' + $modelId)
  $lines.Add('思考档：' + $effortMode + '（默认 ' + [string]$defaultEffort + '）')
  if ($resultPlugins.needInstall -eq $true) {
    $lines.Add('')
    $lines.Add('插件未对齐，未执行安装。征得用户同意后加 -InstallPlugins 重跑：')
    $lines.Add('  ' + [string]$resultPlugins.command)
  }
  foreach ($w in $warnings) { $lines.Add('⚠ ' + [string]$w) }
  $lines.Add('')
  $lines.Add([string](Get-KitProp $check 'Text'))
  return @{ ExitCode = [int](Get-KitProp $check 'ExitCode'); Result = $result; Text = ($lines -join "`n") }
  } finally {
    Exit-KitStateLock $stateLock
  }
}

# ============================================================
# status
# ============================================================

function Invoke-KitStatus {
  $paths = Get-KitPaths
  $state = Read-KitState
  if ($null -eq $state) {
    return @{
      ExitCode = 2
      Result = [ordered]@{ initialized = $false; reasons = @('未初始化：先运行 setup'); dshTested = $null }
      Text = 'dsh-delegate-kit 尚未初始化：先运行 kit.ps1 setup'
    }
  }
  $model = Get-KitProp $state 'model'
  $provider = [string](Get-KitProp $model 'provider')
  $modelId = [string](Get-KitProp $model 'id')
  $modelName = [string](Get-KitProp $model 'name')
  $vision = [bool](Get-KitProp $model 'vision')
  $contextWindow = Get-KitProp $model 'contextWindow'
  $effortsKnown = ((Get-KitProp $model 'effortsKnown') -eq $true)
  $efforts = @()
  if ($effortsKnown) { $efforts = @(Get-KitModelEfforts $model) }
  $effortMode = [string](Get-KitProp $state 'effortMode')
  if (-not $effortMode) { $effortMode = 'auto' }
  $defaultEffort = [string](Get-KitProp $state 'defaultEffort')
  $mode = [string](Get-KitProp $state 'mode')

  $curVersion = ''
  $dsh = Find-KitDsh
  if ($dsh.Found) { $curVersion = [string]$dsh.Version }
  $dshTested = Get-KitDshTestedInfo $curVersion

  $features = Get-KitProp $state 'features'
  $browser = Get-KitProp $features 'browser'
  $computer = Get-KitProp $features 'computerUse'
  $compaction = Get-KitProp $features 'compaction'
  $browserAvail = ((Get-KitProp $browser 'available') -eq $true)
  $browserReason = [string](Get-KitProp $browser 'reason')
  $computerAvail = ((Get-KitProp $computer 'available') -eq $true)
  $computerReason = [string](Get-KitProp $computer 'reason')
  $compAvail = ((Get-KitProp $compaction 'available') -eq $true)
  $compReason = [string](Get-KitProp $compaction 'reason')
  $compApplied = ((Get-KitProp $compaction 'applied') -eq $true)

  $lastCheck = Get-KitProp $state 'lastCheck'
  $lastCheckAt = [string](Get-KitProp $lastCheck 'at')
  $lastCheckOk = ((Get-KitProp $lastCheck 'ok') -eq $true)
  $baselineVersion = [string](Get-KitProp $state 'dshVersion')

  $result = [ordered]@{
    initialized  = $true
    model        = [ordered]@{
      provider      = $provider
      id            = $modelId
      name          = $modelName
      vision        = $vision
      contextWindow = $contextWindow
    }
    efforts      = $efforts
    effortsKnown = $effortsKnown
    effortMode   = $effortMode
    defaultEffort = $defaultEffort
    mode         = $mode
    features     = [ordered]@{
      browser     = [ordered]@{ available = $browserAvail; reason = $browserReason }
      computerUse = [ordered]@{ available = $computerAvail; reason = $computerReason }
      compaction  = [ordered]@{
        available      = $compAvail
        applied        = $compApplied
        thresholdRatio = (Get-KitProp $compaction 'thresholdRatio')
        retainTokens   = (Get-KitProp $compaction 'retainTokens')
        reason         = $compReason
      }
    }
    dshVersion        = $baselineVersion
    currentDshVersion = $curVersion
    dshTested         = $dshTested
    lastCheck         = [ordered]@{ at = $lastCheckAt; ok = $lastCheckOk }
    patchesDir        = $paths.Patches
    logsDir           = $paths.Logs
    kitHome           = $paths.Home
    kitVersion        = [string](Get-KitProp $state 'kitVersion')
  }

  $lines = New-Object 'System.Collections.Generic.List[string]'
  $lines.Add('dsh-delegate-kit 状态')
  $lines.Add('模型：' + $provider + '/' + $modelId + '（' + $modelName + '）')
  $visionText = '纯文本'
  if ($vision) { $visionText = '支持看图' }
  $cwText = '未知'
  if ($null -ne $contextWindow) { $cwText = [string]$contextWindow }
  $lines.Add('看图：' + $visionText + '；上下文窗口：' + $cwText)
  $effortText = '未知'
  if ($effortsKnown) {
    if ($efforts.Count -gt 0) { $effortText = ($efforts -join '/') } else { $effortText = '无（off）' }
  }
  $lines.Add('支持思考档：' + $effortText)
  $modeText = 'auto（默认 ' + $defaultEffort + '）'
  if ($effortMode -eq 'fixed') { $modeText = 'fixed（' + $defaultEffort + '）' }
  $lines.Add('思考模式：' + $modeText)
  $lines.Add('默认权限：' + $mode)
  $lines.Add('可选功能：')
  $bMark = '✗'
  if ($browserAvail) { $bMark = '✓' }
  $bLine = '  ' + $bMark + ' 浏览器'
  if ($browserReason) { $bLine += '：' + $browserReason }
  $lines.Add($bLine)
  $cMark = '✗'
  if ($computerAvail) { $cMark = '✓' }
  $cLine = '  ' + $cMark + ' 电脑操作'
  if ($computerReason) { $cLine += '：' + $computerReason }
  $lines.Add($cLine)
  $pMark = '✗'
  if ($compAvail) { $pMark = '✓' }
  $pLine = '  ' + $pMark + ' 压缩'
  if ($compApplied) { $pLine += '（已应用）' }
  if ($compReason) { $pLine += '：' + $compReason }
  $lines.Add($pLine)
  $lines.Add('dsh 基线版本：' + $baselineVersion + '；当前版本：' + $curVersion)
  if ($dshTested.tested) {
    $lines.Add('dsh 版本：' + $curVersion + '（已验证）')
  } elseif ($dshTested.message) {
    $lines.Add([string]$dshTested.message)
  }
  $checkText = '未运行'
  if ($lastCheckAt) {
    $checkText = $lastCheckAt + ' ' + $(if ($lastCheckOk) { '通过' } else { '不通过' })
  }
  $lines.Add('上次自检：' + $checkText)
  $lines.Add('补丁目录：' + $paths.Patches)
  $lines.Add('日志目录：' + $paths.Logs)

  return @{ ExitCode = 0; Result = $result; Text = ($lines -join "`n") }
}
