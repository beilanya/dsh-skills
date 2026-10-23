<#
uia.ps1 — 用 Windows UI Automation 按名称操作桌面窗口（Electron/Chromium、WPF、WinUI、Win32/WinForms 都适用）。
给 dsh 执行者做电脑操作用：按元素名称定位，不依赖坐标；输出精简，一条命令完成一步。

用法（PowerShell 5.1 / 7 均可）：
  uia.ps1 windows                                   列出可见顶层窗口（标题 | pid | 类名）
  uia.ps1 tree  -Window <标题子串> [-Type Button] [-Name 关键字] [-Max 200] [-All]
                                                    列出窗口内的元素：[序号] 类型 "名称" 状态（默认只列有名称的元素和输入框）
  uia.ps1 text  -Window <标题子串> [-Max 300]        读取窗口内可见文字（去重，按出现顺序）
  uia.ps1 click -Window <标题子串> -Name <名称> [-Type Button] [-Exact] [-Index 0]
                                                    依次尝试 Invoke/Toggle/Select/Expand、Win32 按钮消息，最后才用鼠标点元素中心
  uia.ps1 set   -Window <标题子串> [-Name <名称>] [-Type Edit] [-Index 0] -Value <文本>
                                                    设置输入框的值（不支持时改为聚焦后键入）
  uia.ps1 keys  -Window <标题子串> -Value <SendKeys 语法，如 "{ENTER}"、"^a">
  uia.ps1 wait  -Window <标题子串> -Name <名称> [-Type ...] [-Gone] [-Timeout 15]
                                                    等元素出现（加 -Gone 等它消失）
  uia.ps1 focus|maximize -Window <标题子串>
通用参数：-WindowPid <pid> 可代替 -Window；-Name 默认不区分大小写的子串匹配，-Exact 精确匹配；
          -Type 取 ControlType 名称（Button、Edit、MenuItem、ListItem、Hyperlink、CheckBox、TabItem、Text、Document 等）。
退出码：0 成功；1 参数或执行错误；2 找不到窗口或元素（输出里会列出候选，便于换名称重试）。
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet('windows', 'tree', 'text', 'click', 'set', 'keys', 'wait', 'focus', 'maximize')]
  [string]$Action = 'windows',
  [string]$Window,
  [int]$WindowPid,
  [string]$Name,
  [switch]$Exact,
  [string]$Type,
  [int]$Index = 0,
  [string]$Value,
  [int]$Max = 200,
  [int]$Timeout = 15,
  [switch]$Gone,
  [switch]$All
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8

# 先声明 DPI 感知，UIA 返回的坐标和鼠标坐标才都是物理像素（缩放 150% 时不再漂移）
Add-Type -Namespace UiaNative -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, System.UIntPtr e);
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr SendMessage(System.IntPtr h, uint msg, System.IntPtr w, string l);
'@
[void][UiaNative.W]::SetProcessDPIAware()
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

# 函数内的提示一律直接写控制台，避免混进函数返回值或被管道过滤掉
function Say($s) { [Console]::Out.WriteLine($s) }
function Fail($code, $msg) { Say "ERROR: $msg"; exit $code }

if ($Type -and -not [System.Windows.Automation.ControlType].GetField($Type)) {
  Fail 1 "未知的 -Type '$Type'（例：Button、Edit、MenuItem、ListItem、Hyperlink、CheckBox、TabItem、Text）"
}

# 托管 UIA 客户端不给 Win32/WinForms 控件套代理，它们一律显示为 Pane；按窗口类名还原真实类型
function Get-ElType($el) {
  $t = $el.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
  if ($t -ne 'Pane') { return $t }
  $cls = $el.Current.ClassName
  if ($cls -match '(^|\.)BUTTON(\.|$)') { return 'Button' }
  if ($cls -match '(^|\.)(EDIT|RichEdit\w*)(\.|$)') { return 'Edit' }
  if ($cls -match '(^|\.)STATIC(\.|$)') { return 'Text' }
  if ($cls -match '(^|\.)COMBOBOX(\.|$)') { return 'ComboBox' }
  if ($cls -match '(^|\.)LISTBOX(\.|$)|SysListView32') { return 'List' }
  if ($cls -match 'SysTreeView32') { return 'Tree' }
  return $t
}
function Test-Win32Class($el, $pattern) { $el.Current.NativeWindowHandle -ne 0 -and $el.Current.ClassName -match "(^|\.)$pattern(\.|$)" }

function Get-TopWindows {
  $AE::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { try { $_.Current.Name -and -not $_.Current.IsOffscreen } catch { $false } }
}

function Find-Window {
  if (-not $Window -and -not $WindowPid) { Fail 1 '需要 -Window <标题子串> 或 -WindowPid <pid>' }
  $wins = @(Get-TopWindows)
  $hit = @($wins | Where-Object {
      if ($WindowPid) { $_.Current.ProcessId -eq $WindowPid } else { $_.Current.Name -like "*$Window*" }
    })
  if (-not $hit.Count) {
    Say "ERROR: 找不到窗口 '$Window$WindowPid'。可见窗口："
    $wins | Select-Object -First 30 | ForEach-Object { Say ("  {0} | pid {1}" -f $_.Current.Name, $_.Current.ProcessId) }
    exit 2
  }
  $hit[0]
}

function Show-Window($w) {
  $h = [IntPtr]$w.Current.NativeWindowHandle
  if ($h -ne [IntPtr]::Zero) {
    if ([UiaNative.W]::IsIconic($h)) { [void][UiaNative.W]::ShowWindow($h, 9) }
    [void][UiaNative.W]::SetForegroundWindow($h)
  }
}

# 窗口内全部可见元素（按 -Type 过滤，类型按 Get-ElType 判断）
function Get-Elements($w) {
  $all = [System.Windows.Automation.Condition]::TrueCondition
  # Chromium/Electron 首次被 UIA 访问时才构建页面无障碍树：还没有 Document 元素就稍等再取（最多 3 次）
  if ($w.Current.ClassName -like 'Chrome_WidgetWin*') {
    $docCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)
    for ($k = 0; $k -lt 3 -and -not $w.FindFirst($TS::Descendants, $docCond); $k++) { Start-Sleep -Milliseconds 1000 }
  }
  $els = @($w.FindAll($TS::Descendants, $all))
  @($els | Where-Object {
      try { -not $_.Current.IsOffscreen -and (-not $Type -or (Get-ElType $_) -eq $Type) } catch { $false }
    })
}

function Test-NameMatch($el) {
  if (-not $Name) { return $true }
  $n = $el.Current.Name
  if (-not $n) { return $false }
  if ($Exact) { return $n -eq $Name }
  return $n.IndexOf($Name, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Format-El($i, $el) {
  $c = $el.Current
  $flags = @()
  if (-not $c.IsEnabled) { $flags += 'disabled' }
  try { $flags += 'toggle=' + $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState } catch {}
  try { $v = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value; if ($v) { if ($v.Length -gt 60) { $v = $v.Substring(0, 60) + '…' }; $flags += "value=`"$v`"" } } catch {}
  $n = $c.Name; if ($n.Length -gt 80) { $n = $n.Substring(0, 80) + '…' }
  ('[{0}] {1} "{2}"{3}' -f $i, (Get-ElType $el), $n, $(if ($flags.Count) { ' ' + ($flags -join ' ') } else { '' }))
}

# tree 默认列出的元素：有名称的，或者是无名的输入框（输入框常常没有名称）
function Test-Listable($el) { $All -or $el.Current.Name -or (Get-ElType $el) -in @('Edit', 'ComboBox') }

function Find-Target($w) {
  $els = @(Get-Elements $w | Where-Object { Test-NameMatch $_ })
  if ($els.Count -le $Index) {
    Say "ERROR: 在窗口 '$($w.Current.Name)' 里找不到匹配 $(if ($Name) { "-Name '$Name' " })$(if ($Type) { "-Type $Type " })的元素（匹配 $($els.Count) 个，-Index $Index）。候选："
    $saveType = $script:Type; $script:Type = $null
    $cand = @(Get-Elements $w | Where-Object { Test-Listable $_ } | Select-Object -First 40)
    $script:Type = $saveType
    for ($i = 0; $i -lt $cand.Count; $i++) { Say ('  ' + (Format-El $i $cand[$i])) }
    exit 2
  }
  if ($els.Count -gt 1) { Say "提示: 匹配到 $($els.Count) 个元素，使用第 $Index 个（-Index 可改）" }
  $els[$Index]
}

function Invoke-MouseClick($el) {
  $r = $el.Current.BoundingRectangle
  if ($r.IsEmpty -or $r.Width -le 0) { Fail 1 '元素没有可点击的区域' }
  $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2)
  [void][UiaNative.W]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 80
  [UiaNative.W]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  [UiaNative.W]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  "mouse($x,$y)"
}

function Send-Text($s) {
  # SendKeys 里 + ^ % ~ ( ) { } [ ] 有特殊含义，逐字转义
  $esc = -join ($s.ToCharArray() | ForEach-Object { if ('+^%~(){}[]'.Contains([string]$_)) { '{' + $_ + '}' } else { [string]$_ } })
  [System.Windows.Forms.SendKeys]::SendWait($esc)
}

try {
  switch ($Action) {
    'windows' {
      Get-TopWindows | ForEach-Object { Write-Output ('{0} | pid {1} | {2}' -f $_.Current.Name, $_.Current.ProcessId, $_.Current.ClassName) }
    }
    'tree' {
      $w = Find-Window
      $els = @(Get-Elements $w | Where-Object { (Test-Listable $_) -and (Test-NameMatch $_) })
      Write-Output "窗口: $($w.Current.Name) | pid $($w.Current.ProcessId) | 元素 $($els.Count) 个"
      $n = [Math]::Min($Max, $els.Count)
      for ($i = 0; $i -lt $n; $i++) { Write-Output (Format-El $i $els[$i]) }
      if ($els.Count -gt $n) { Write-Output "…还有 $($els.Count - $n) 个，用 -Type/-Name 过滤或加大 -Max" }
    }
    'text' {
      $w = Find-Window
      $seen = New-Object 'System.Collections.Generic.HashSet[string]'
      $out = New-Object System.Collections.Generic.List[string]
      foreach ($el in (Get-Elements $w)) {
        if ($out.Count -ge $Max) { break }
        $s = $el.Current.Name
        try { $v = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value; if ($v) { $s = $v } } catch {}
        if ($s -and $s.Trim() -and $seen.Add($s.Trim())) { $out.Add($s.Trim()) }
      }
      Write-Output "窗口: $($w.Current.Name)"
      $out | ForEach-Object { Write-Output $_ }
    }
    'click' {
      if (-not $Name) { Fail 1 'click 需要 -Name' }
      $w = Find-Window; $el = Find-Target $w
      $desc = Format-El $Index $el
      if (-not $el.Current.IsEnabled) { Fail 1 "元素已禁用: $desc" }
      $how = $null
      foreach ($p in @(
          @([System.Windows.Automation.InvokePattern]::Pattern, { param($o) $o.Invoke() }, 'invoke'),
          @([System.Windows.Automation.TogglePattern]::Pattern, { param($o) $o.Toggle() }, 'toggle'),
          @([System.Windows.Automation.SelectionItemPattern]::Pattern, { param($o) $o.Select() }, 'select'),
          @([System.Windows.Automation.ExpandCollapsePattern]::Pattern, { param($o) $o.Expand() }, 'expand'))) {
        $obj = $null
        if ($el.TryGetCurrentPattern($p[0], [ref]$obj)) { & $p[1] $obj; $how = $p[2]; break }
      }
      if (-not $how -and (Test-Win32Class $el 'BUTTON')) {
        # Win32 按钮（含复选框）：发 BM_CLICK，不依赖鼠标和前台；用 Post 避免弹出模态框时阻塞
        [void][UiaNative.W]::PostMessage([IntPtr]$el.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero); $how = 'bm_click'
      }
      if (-not $how) { Show-Window $w; Start-Sleep -Milliseconds 150; $how = Invoke-MouseClick $el }
      Write-Output "已点击 ($how): $desc"
    }
    'set' {
      if (-not $Name -and -not $Type) { Fail 1 'set 需要 -Name 或 -Type' }
      if ($null -eq $Value) { Fail 1 'set 需要 -Value' }
      $w = Find-Window; $el = Find-Target $w
      $obj = $null
      if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$obj) -and -not $obj.Current.IsReadOnly) {
        $obj.SetValue($Value); $how = 'value'
      } elseif (Test-Win32Class $el '(EDIT|RichEdit\w*)') {
        [void][UiaNative.W]::SendMessage([IntPtr]$el.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, $Value); $how = 'wm_settext'
      } else {
        Show-Window $w; $el.SetFocus(); Start-Sleep -Milliseconds 150
        [System.Windows.Forms.SendKeys]::SendWait('^a'); Send-Text $Value; $how = 'keys'
      }
      # 回显设置后的实际状态，便于确认是否写入
      Start-Sleep -Milliseconds 100
      Write-Output "已设置 ($how): $(Format-El $Index $el)"
    }
    'keys' {
      if (-not $Value) { Fail 1 'keys 需要 -Value（SendKeys 语法）' }
      $w = Find-Window; Show-Window $w; Start-Sleep -Milliseconds 150
      [System.Windows.Forms.SendKeys]::SendWait($Value)
      Write-Output "已发送按键: $Value"
    }
    'wait' {
      if (-not $Name -and -not $Type) { Fail 1 'wait 需要 -Name 或 -Type' }
      $deadline = (Get-Date).AddSeconds($Timeout)
      do {
        $w = Find-Window
        $els = @(Get-Elements $w | Where-Object { Test-NameMatch $_ })
        if ($Gone -and -not $els.Count) { Write-Output "已消失: '$Name'"; exit 0 }
        if (-not $Gone -and $els.Count) { Write-Output "已出现: $(Format-El 0 $els[0])"; exit 0 }
        Start-Sleep -Milliseconds 800
      } while ((Get-Date) -lt $deadline)
      Fail 2 "等待 $Timeout 秒超时：'$Name' $(if ($Gone) { '仍然存在' } else { '仍未出现' })"
    }
    'focus' { $w = Find-Window; Show-Window $w; Write-Output "已切到前台: $($w.Current.Name)" }
    'maximize' {
      $w = Find-Window; Show-Window $w
      $obj = $null
      if ($w.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$obj)) {
        $obj.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Maximized)
      } else { [void][UiaNative.W]::ShowWindow([IntPtr]$w.Current.NativeWindowHandle, 3) }
      Write-Output "已最大化: $($w.Current.Name)"
    }
  }
} catch {
  Fail 1 $_.Exception.Message
}
