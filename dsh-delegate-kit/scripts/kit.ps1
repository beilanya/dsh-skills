<#
kit.ps1 — dsh-delegate-kit 入口。用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File kit.ps1 <子命令> [参数] [-Json]

子命令：
  help                       详细指令说明（内容来自 docs\HELP.md）
  setup                      第一段：环境检查 + 输出候选项（模型及能力、思考档、权限）
  setup -Model <provider/id> -Effort <档|auto> -Mode <权限> [-InstallPlugins] [-AcknowledgeFullAccess]
                             第二段：生成补丁、写状态文件、跑 check
  check [-UpdateBaseline]    自检（不调模型）；exit 0 通过 / 1 不兼容 / 2 未初始化
  repair [-InstallPlugins]   对齐插件、重新识别插件 id、重新生成补丁，再 check
  status                     当前配置
  stats [-Days n]            效率统计
  diag                       生成诊断包（不含 Key）
  rules -Host claude|codex -Show|-Apply [-RulesFile <路径>]
                             展示 / 追加全局规则段落（追加前备份）
  uninstall [-Host claude|codex|all] [-RulesFile <路径>] [-RemoveSkills] [-PurgeLogs]
            [-ClaudeSkillsDir <目录>] [-CodexSkillsDir <目录>]
  update [-Apply] [-Force]    查询新版 kit；-Apply 时运行 npx skills update 更新并自检。
-Json：stdout 只输出一个 JSON 对象，提示写 stderr。
环境变量：DSH_HOME（默认 ~\.dsh）、DSH_KIT_HOME（默认 <DSH_HOME>\dsh-delegate-kit）。
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup', 'check', 'repair', 'status', 'stats', 'diag', 'rules', 'uninstall', 'update', 'help')]
  [string]$Command = 'help',
  [string]$Model,
  [string]$Effort,
  [string]$Mode,
  [switch]$InstallPlugins,
  [switch]$AcknowledgeFullAccess,
  [switch]$UpdateBaseline,
  [int]$Days = 0,
  # 参数名不能叫 $Host（PowerShell 自动变量），用别名让调用方仍可写 -Host
  [Alias('Host')]
  [ValidateSet('', 'claude', 'codex', 'all')]
  [string]$HostName = '',
  [switch]$Show,
  [switch]$Apply,
  [string]$RulesFile,
  [switch]$RemoveSkills,
  [switch]$PurgeLogs,
  [string]$ClaudeSkillsDir = '',
  [string]$CodexSkillsDir = '',
  [switch]$Json,
  [switch]$Force
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$script:KitScriptDir = $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\setup.ps1')
. (Join-Path $PSScriptRoot 'lib\maint.ps1')
$script:KitJsonMode = [bool]$Json

# 各 Invoke-Kit* 函数返回 @{ ExitCode = <int>; Result = <可转 JSON 的对象>; Text = <给人看的多行文本> }
switch ($Command) {
  'setup'     { $r = Invoke-KitSetup -Model $Model -Effort $Effort -Mode $Mode -InstallPlugins:$InstallPlugins -AcknowledgeFullAccess:$AcknowledgeFullAccess }
  'check'     { $r = Invoke-KitCheck -UpdateBaseline:$UpdateBaseline }
  'repair'    { $r = Invoke-KitRepair -InstallPlugins:$InstallPlugins }
  'status'    { $r = Invoke-KitStatus }
  'stats'     { $r = Invoke-KitStats -Days $Days }
  'diag'      { $r = Invoke-KitDiag }
  'rules'     { $r = Invoke-KitRules -HostName $HostName -Show:$Show -Apply:$Apply -RulesFile $RulesFile }
  'uninstall' { $r = Invoke-KitUninstall -HostName $HostName -RulesFile $RulesFile -RemoveSkills:$RemoveSkills -PurgeLogs:$PurgeLogs -ClaudeSkillsDir $ClaudeSkillsDir -CodexSkillsDir $CodexSkillsDir }
  'update'    { $r = Invoke-KitUpdate -Apply:$Apply -Force:$Force }
  default {
    # 详细说明以 docs\HELP.md 为准；找不到时退回本文件开头的注释块
    $helpDoc = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\HELP.md'
    if (Test-Path -LiteralPath $helpDoc -PathType Leaf) {
      $help = (Read-KitText $helpDoc).TrimEnd()
      $r = @{ ExitCode = 0; Result = @{ help = $help; source = $helpDoc }; Text = $help }
      break
    }
    $helpLines = New-Object System.Collections.ArrayList
    $inHelp = $false
    foreach ($ln in (Get-Content -LiteralPath $PSCommandPath -Encoding UTF8)) {
      if (-not $inHelp) {
        if ($ln -match '^\s*<#') { $inHelp = $true }
        continue
      }
      if ($ln -match '#>') { break }
      [void]$helpLines.Add($ln)
    }
    $help = ($helpLines -join "`n").TrimEnd()
    $r = @{ ExitCode = 0; Result = @{ help = $help }; Text = $help }
  }
}

if ($Json) {
  [Console]::Out.WriteLine(($r.Result | ConvertTo-Json -Depth 20))
} elseif ($r.Text) {
  [Console]::Out.WriteLine($r.Text)
}
exit ([int]$r.ExitCode)
