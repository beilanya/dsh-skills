# dsh-delegate-kit 维护子命令：stats / diag / rules / uninstall
# 由 kit.ps1 dot-source。兼容 Windows PowerShell 5.1。
# 所有函数返回 @{ ExitCode=<int>; Result=<可转 JSON 的对象>; Text=<给人看的多行中文文本> }，
# 内部不直接 Write-Output（避免混进返回值）。

if (-not $script:KitUtf8) { $script:KitUtf8 = New-Object System.Text.UTF8Encoding($false) }

# ---------------------------------------------------------------- 通用小工具

function Test-KitHasProp($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  if ($obj -is [System.Collections.IDictionary]) { return $obj.Contains($name) }
  return ($null -ne $obj.PSObject.Properties[$name])
}

function ConvertTo-KitNumber($value, [double]$default = 0.0) {
  if ($null -eq $value) { return $default }
  if ($value -is [bool]) { return $default }
  $d = 0.0
  if ([double]::TryParse([string]$value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
  return $default
}

function Test-KitTruthy($value) {
  if ($null -eq $value) { return $false }
  if ($value -is [bool]) { return [bool]$value }
  $s = ([string]$value).Trim().ToLowerInvariant()
  return ($s -eq 'true' -or $s -eq '1' -or $s -eq 'yes')
}

function Get-KitAverage([double[]]$values) {
  if ($null -eq $values -or $values.Count -eq 0) { return $null }
  $sum = 0.0
  foreach ($v in $values) { $sum += $v }
  return [math]::Round($sum / $values.Count, 2)
}

function Get-KitMedian([double[]]$values) {
  if ($null -eq $values -or $values.Count -eq 0) { return $null }
  $sorted = @($values | Sort-Object)
  $n = $sorted.Count
  $mid = [int][math]::Floor($n / 2)
  if (($n % 2) -eq 1) { return [math]::Round([double]$sorted[$mid], 2) }
  return [math]::Round(([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0, 2)
}

function Format-KitNumber($value, [string]$format = '0.00') {
  if ($null -eq $value) { return '-' }
  return ([double]$value).ToString($format, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-KitDisplayWidth([string]$s) {
  if (-not $s) { return 0 }
  $w = 0
  foreach ($ch in $s.ToCharArray()) {
    $c = [int]$ch
    if (($c -ge 0x1100 -and $c -le 0x115F) -or
        ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
        ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
        ($c -ge 0xF900 -and $c -le 0xFAFF) -or
        ($c -ge 0xFE30 -and $c -le 0xFE4F) -or
        ($c -ge 0xFF00 -and $c -le 0xFF60) -or
        ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
  }
  return $w
}

function Format-KitCell([string]$s, [int]$width, [bool]$right) {
  if ($null -eq $s) { $s = '' }
  $sw = Get-KitDisplayWidth $s
  if ($sw -ge $width) { return $s }
  $pad = ' ' * ($width - $sw)
  if ($right) { return $pad + $s }
  return $s + $pad
}

function Write-KitTextBom([string]$path, [string]$text, [bool]$withBom) {
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $enc = New-Object System.Text.UTF8Encoding($withBom)
  [IO.File]::WriteAllText($path, $text, $enc)
}

# ---------------------------------------------------------------- 脱敏

function ConvertTo-KitRedacted([string]$text) {
  if ($null -eq $text) { return '' }
  # authorization 整段替换（含值里的空格），再单独处理 Bearer；保留值的引号使 JSON 仍合法
  $text = [regex]::Replace($text, '(?i)(["'']?authorization["'']?\s*[:=]\s*")([^"]*)(")', '${1}<redacted>${3}')
  $text = [regex]::Replace($text, '(?i)(["'']?authorization["'']?\s*[:=]\s*'')([^'']*)('')', '${1}<redacted>${3}')
  $text = [regex]::Replace($text, '(?i)(["'']?authorization["'']?\s*[:=]\s*)(?=[^"''\s,)}\]])([^\r\n,)}\]]+)', '${1}"<redacted>"')
  # Bearer 只吃令牌本身，保留两侧引号/括号（修复 JSON 结尾引号被吃掉的问题）
  $text = [regex]::Replace($text, '(?i)\bBearer\s+[^"''\s,)}\]]+', 'Bearer <redacted>')
  # URL 查询参数
  $text = [regex]::Replace($text, '(?i)([?&](?:key|api_key|apikey|access_token|token)=)[^"''\s,&)}\]]+', '${1}<redacted>')
  # 常见令牌前缀
  foreach ($pat in @(
      'sk-[A-Za-z0-9_\-]{8,}',
      'gsk_[A-Za-z0-9_\-]{6,}',
      'AIza[0-9A-Za-z_\-]{8,}',
      'ghp_[A-Za-z0-9_\-]{8,}',
      'github_pat_[A-Za-z0-9_\-]{8,}',
      'xoxb-[A-Za-z0-9_\-]{6,}',
      'xoxp-[A-Za-z0-9_\-]{6,}',
      'AKIA[0-9A-Z]{8,}')) {
    $text = [regex]::Replace($text, $pat, '<redacted>')
  }
  # 键名两侧允许引号；值匹配到引号/空白/逗号/右括号为止；无引号的值补双引号以保持 JSON 合法
  $keyRe = New-Object System.Text.RegularExpressions.Regex('(?i)(?<![?&\w.\-])(?<q>["'']?)(?<k>[A-Za-z0-9_.\-]*(?:api[_-]?key|apikey|access[_-]?token|token|secret|password)[A-Za-z0-9_.\-]*)(?<q2>["'']?)(?<sep>\s*[:=]\s*)(?<vq>["'']?)(?<v>[^"''\s,)}\]]+)')
  $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    $prefix = $m.Groups['q'].Value + $m.Groups['k'].Value + $m.Groups['q2'].Value + $m.Groups['sep'].Value
    $vq = $m.Groups['vq'].Value
    if ($vq) { return $prefix + $vq + '<redacted>' }
    return $prefix + '"<redacted>"'
  }
  $text = $keyRe.Replace($text, $evaluator)
  return $text
}

function Write-KitJsonRedacted([string]$path, $obj) {
  $json = $obj | ConvertTo-Json -Depth 20
  Write-KitText $path (ConvertTo-KitRedacted $json)
}

# ---------------------------------------------------------------- 规则文件

function Get-KitRulesTarget([string]$hostName, [string]$override) {
  if ($override) { return [IO.Path]::GetFullPath($override) }
  if ($hostName -eq 'claude') { return (Join-Path $HOME '.claude\CLAUDE.md') }
  if ($hostName -eq 'codex') {
    $root = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    return (Join-Path $root 'AGENTS.md')
  }
  return $null
}

function Read-KitRulesFileInfo([string]$path) {
  $r = [ordered]@{ Exists = $false; Bom = $false; EncodingOk = $true; EncodingError = ''; Text = ''; Nl = "`n"; EndsWithNewline = $false }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $r }
  $r.Exists = $true
  $enc = Test-KitUtf8TextFile $path
  $r.EncodingOk = [bool]$enc.Ok
  if (-not $enc.Ok) { $r.EncodingError = '规则文件不是 UTF-8 编码，请先转成 UTF-8 再运行' }
  $r.Bom = Test-KitBom $path
  $t = Read-KitText $path
  if ($null -eq $t) { $t = '' }
  $r.Text = $t
  if ($t.Contains("`r`n")) { $r.Nl = "`r`n" }
  $r.EndsWithNewline = $t.EndsWith("`n")
  return $r
}

function Get-KitRulesRender([string]$hostName) {
  $paths = Get-KitPaths
  $tplPath = Join-Path $paths.Templates ('rules-' + $hostName + '.md')
  $tpl = Read-KitText $tplPath
  if ($null -eq $tpl) { return $null }
  $tpl = $tpl.Replace("`r`n", "`n").Replace("`r", "`n")

  $state = Read-KitState
  $modelObj = Get-KitProp $state 'model'

  $modelText = 'setup 选定的模型'
  if ($modelObj) {
    $provider = [string](Get-KitProp $modelObj 'provider')
    $id = [string](Get-KitProp $modelObj 'id')
    if ($provider -and $id) { $modelText = "$provider/$id" }
    elseif ($provider) { $modelText = $provider }
    elseif ($id) { $modelText = $id }
  }

  $effortDesc = '使用服务商默认档'
  if ($modelObj) {
    $known = Get-KitProp $modelObj 'effortsKnown'
    $effortMode = [string](Get-KitProp $state 'effortMode')
    if ($known -eq $false) {
      $effortDesc = '使用服务商默认档'
    } elseif ($effortMode -eq 'fixed') {
      $def = [string](Get-KitProp $state 'defaultEffort')
      if ($def) { $effortDesc = "固定为 $def" } else { $effortDesc = '使用服务商默认档' }
    } elseif ($effortMode -eq 'auto') {
      $efforts = @(Get-KitProp $modelObj 'efforts' | Where-Object { $_ })
      if ($efforts.Count -gt 0) {
        $effortDesc = '由主 Agent 按任务在 ' + ($efforts -join '/') + ' 中选择'
      } else {
        $effortDesc = '使用服务商默认档'
      }
    }
  }

  $mode = [string](Get-KitProp $state 'mode')
  if (-not $mode) { $mode = '未配置' }

  $tpl = $tpl.Replace('{{DATE}}', (Get-Date).ToString('yyyy-MM-dd'))
  $tpl = $tpl.Replace('{{MODEL}}', $modelText)
  $tpl = $tpl.Replace('{{EFFORT_DESC}}', $effortDesc)
  $tpl = $tpl.Replace('{{MODE}}', $mode)
  return $tpl.TrimEnd()
}

function Get-KitRulesBlock([string]$hostName, [string]$sep, [string]$nl) {
  $body = Get-KitRulesRender $hostName
  if ($null -eq $body) { return $null }
  if ($nl -ne "`n") { $body = $body.Replace("`n", $nl) }
  $n = $sep.Length
  return $sep + '<!-- dsh-delegate-kit:begin v1 sep=' + $n + ' -->' + $nl + $body + $nl + '<!-- dsh-delegate-kit:end -->' + $nl
}

function Get-KitRulesMarker([string]$text) {
  # 解析 begin/end 标记；写法以 Apply 生成的为准，允许多余空白。Test 与移除逻辑共用
  $r = [ordered]@{ Found = $false; Index = 0; Length = 0; Sep = 0; Begin = ''; EndFound = $false; EndStart = -1; EndLength = 0; End = '' }
  if ($null -eq $text) { return $r }
  $m = [regex]::Match($text, '<!--[ \t]*dsh-delegate-kit:begin[ \t]+v1[ \t]+sep[ \t]*=[ \t]*(\d+)[ \t]*-->')
  if (-not $m.Success) { return $r }
  $r.Found = $true
  $r.Index = $m.Index
  $r.Length = $m.Length
  $r.Sep = [int]$m.Groups[1].Value
  $r.Begin = $m.Value
  $endRe = New-Object System.Text.RegularExpressions.Regex('<!--[ \t]*dsh-delegate-kit:end[ \t]*-->')
  $e = $endRe.Match($text, $m.Index + $m.Length)
  if ($e.Success) {
    $r.EndFound = $true
    $r.EndStart = $e.Index
    $r.EndLength = $e.Length
    $r.End = $e.Value
  }
  return $r
}

function Test-KitRulesInstalled([string]$text) {
  if ($null -eq $text) { return $false }
  $m = Get-KitRulesMarker $text
  return [bool]$m.Found
}

function Set-KitRulesRecord([string]$hostName, $record) {
  $paths = Get-KitPaths
  $all = [ordered]@{}
  $existing = Read-KitJson (Join-Path $paths.Home 'rules.json')
  if ($existing) {
    foreach ($p in $existing.PSObject.Properties) { $all[$p.Name] = $p.Value }
  }
  $all[$hostName] = $record
  Write-KitJson (Join-Path $paths.Home 'rules.json') $all
}

function Remove-KitRulesRecord([string]$hostName) {
  $paths = Get-KitPaths
  $rulesPath = Join-Path $paths.Home 'rules.json'
  $existing = Read-KitJson $rulesPath
  if (-not $existing) { return }
  $all = [ordered]@{}
  foreach ($p in $existing.PSObject.Properties) {
    if ($p.Name -ne $hostName) { $all[$p.Name] = $p.Value }
  }
  if ($all.Count -eq 0) {
    Remove-Item -LiteralPath $rulesPath -Force -ErrorAction SilentlyContinue
  } else {
    Write-KitJson $rulesPath $all
  }
}

# ---------------------------------------------------------------- stats

function Invoke-KitStats {
  param([int]$Days = 0)

  if ($Days -lt 0) {
    return [ordered]@{
      ExitCode = 2
      Result = [ordered]@{ error = '-Days 不能为负数' }
      Text = '-Days 不能为负数（参数错误）。'
    }
  }

  $paths = Get-KitPaths
  $sources = @(
    [ordered]@{ Host = 'claude'; Path = (Join-Path $paths.Logs 'index.jsonl') },
    [ordered]@{ Host = 'codex'; Path = (Join-Path $paths.LogsCodex 'index.jsonl') }
  )

  $bad = 0
  $skippedByDays = 0
  $legacy = 0
  $valid = 0
  $okTotal = 0
  $groups = @{}
  $hostTotals = @{}
  $cutoff = $null
  if ($Days -gt 0) { $cutoff = (Get-Date).AddDays(-$Days) }

  foreach ($src in $sources) {
    $text = Read-KitText $src.Path
    if ($null -eq $text) { continue }
    foreach ($line in ($text -split "`n")) {
      $ln = $line.TrimEnd("`r")
      if (-not $ln.Trim()) { continue }
      $rec = $null
      try { $rec = $ln | ConvertFrom-Json } catch { $bad++; continue }
      if ($null -eq $rec) { $bad++; continue }

      if ($cutoff) {
        $endedRaw = Get-KitProp $rec 'endedAt'
        $dt = [datetime]::MinValue
        if (-not $endedRaw -or -not [datetime]::TryParse([string]$endedRaw, [ref]$dt)) { $skippedByDays++; continue }
        if ($dt -lt $cutoff) { $skippedByDays++; continue }
      }

      $hasElapsed = (Test-KitHasProp $rec 'elapsedSec') -and ($null -ne (Get-KitProp $rec 'elapsedSec'))
      $hasSteps = (Test-KitHasProp $rec 'steps') -and ($null -ne (Get-KitProp $rec 'steps'))
      if (-not $hasElapsed -or -not $hasSteps) { $legacy++; continue }

      $hostName = [string](Get-KitProp $rec 'host')
      if (-not $hostName) { $hostName = $src.Host }
      $effort = [string](Get-KitProp $rec 'effort')
      if (-not $effort) { $effort = '(未记录)' }
      $browser = 'no-browser'
      if (Test-KitTruthy (Get-KitProp $rec 'browser')) { $browser = 'browser' }
      $status = [string](Get-KitProp $rec 'status')
      $isOk = ($status -ieq 'OK')
      if (-not $status) {
        $exitVal = Get-KitProp $rec 'exit'
        if ($null -ne $exitVal -and [int]$exitVal -eq 0) { $isOk = $true }
      }

      $elapsed = ConvertTo-KitNumber (Get-KitProp $rec 'elapsedSec')
      $steps = ConvertTo-KitNumber (Get-KitProp $rec 'steps')
      $toolCalls = ConvertTo-KitNumber (Get-KitProp $rec 'toolCalls')
      $toolErrors = ConvertTo-KitNumber (Get-KitProp $rec 'toolErrors')
      $inTok = ConvertTo-KitNumber (Get-KitProp $rec 'inTok')
      $outTok = ConvertTo-KitNumber (Get-KitProp $rec 'outTok')
      $cacheTok = ConvertTo-KitNumber (Get-KitProp $rec 'cacheTok')
      $thinkChars = ConvertTo-KitNumber (Get-KitProp $rec 'thinkChars')

      $valid++
      if ($isOk) { $okTotal++ }

      $gkey = $effort + '|' + $browser
      if (-not $groups.ContainsKey($gkey)) {
        $groups[$gkey] = [ordered]@{
          effort = $effort; browser = $browser
          hosts = New-Object System.Collections.ArrayList
          count = 0; ok = 0
          elapsed = New-Object System.Collections.ArrayList
          steps = New-Object System.Collections.ArrayList
          toolCalls = New-Object System.Collections.ArrayList
          toolErrors = New-Object System.Collections.ArrayList
          inTok = New-Object System.Collections.ArrayList
          outTok = New-Object System.Collections.ArrayList
          cacheTok = New-Object System.Collections.ArrayList
          thinkChars = New-Object System.Collections.ArrayList
        }
      }
      $g = $groups[$gkey]
      if (-not $g['hosts'].Contains($hostName)) { [void]$g['hosts'].Add($hostName) }
      $g['count'] = [int]$g['count'] + 1
      if ($isOk) { $g['ok'] = [int]$g['ok'] + 1 }
      [void]$g['elapsed'].Add($elapsed)
      [void]$g['steps'].Add($steps)
      [void]$g['toolCalls'].Add($toolCalls)
      [void]$g['toolErrors'].Add($toolErrors)
      [void]$g['inTok'].Add($inTok)
      [void]$g['outTok'].Add($outTok)
      [void]$g['cacheTok'].Add($cacheTok)
      [void]$g['thinkChars'].Add($thinkChars)

      if (-not $hostTotals.ContainsKey($hostName)) {
        $hostTotals[$hostName] = [ordered]@{
          host = $hostName; count = 0; ok = 0
          elapsed = New-Object System.Collections.ArrayList
          steps = New-Object System.Collections.ArrayList
          toolCalls = New-Object System.Collections.ArrayList
          toolErrors = New-Object System.Collections.ArrayList
          inTok = New-Object System.Collections.ArrayList
          outTok = New-Object System.Collections.ArrayList
          cacheTok = New-Object System.Collections.ArrayList
          thinkChars = New-Object System.Collections.ArrayList
        }
      }
      $h = $hostTotals[$hostName]
      $h['count'] = [int]$h['count'] + 1
      if ($isOk) { $h['ok'] = [int]$h['ok'] + 1 }
      [void]$h['elapsed'].Add($elapsed)
      [void]$h['steps'].Add($steps)
      [void]$h['toolCalls'].Add($toolCalls)
      [void]$h['toolErrors'].Add($toolErrors)
      [void]$h['inTok'].Add($inTok)
      [void]$h['outTok'].Add($outTok)
      [void]$h['cacheTok'].Add($cacheTok)
      [void]$h['thinkChars'].Add($thinkChars)
    }
  }

  $groupResults = @()
  foreach ($key in ($groups.Keys | Sort-Object)) {
    $g = $groups[$key]
    $groupResults += [ordered]@{
      effort = $g['effort']; browser = $g['browser']; hosts = @($g['hosts'].ToArray())
      count = [int]$g['count']; ok = [int]$g['ok']
      elapsedSecAvg = Get-KitAverage ([double[]]$g['elapsed'].ToArray()); elapsedSecMedian = Get-KitMedian ([double[]]$g['elapsed'].ToArray())
      stepsAvg = Get-KitAverage ([double[]]$g['steps'].ToArray())
      toolCallsAvg = Get-KitAverage ([double[]]$g['toolCalls'].ToArray())
      toolErrorsAvg = Get-KitAverage ([double[]]$g['toolErrors'].ToArray())
      inTokAvg = Get-KitAverage ([double[]]$g['inTok'].ToArray())
      outTokAvg = Get-KitAverage ([double[]]$g['outTok'].ToArray())
      cacheTokAvg = Get-KitAverage ([double[]]$g['cacheTok'].ToArray())
      thinkCharsAvg = Get-KitAverage ([double[]]$g['thinkChars'].ToArray())
    }
  }

  $hostResults = @()
  foreach ($key in ($hostTotals.Keys | Sort-Object)) {
    $h = $hostTotals[$key]
    $hostResults += [ordered]@{
      host = $h['host']; count = [int]$h['count']; ok = [int]$h['ok']
      elapsedSecAvg = Get-KitAverage ([double[]]$h['elapsed'].ToArray()); elapsedSecMedian = Get-KitMedian ([double[]]$h['elapsed'].ToArray())
      stepsAvg = Get-KitAverage ([double[]]$h['steps'].ToArray())
      toolCallsAvg = Get-KitAverage ([double[]]$h['toolCalls'].ToArray())
      toolErrorsAvg = Get-KitAverage ([double[]]$h['toolErrors'].ToArray())
      inTokAvg = Get-KitAverage ([double[]]$h['inTok'].ToArray())
      outTokAvg = Get-KitAverage ([double[]]$h['outTok'].ToArray())
      cacheTokAvg = Get-KitAverage ([double[]]$h['cacheTok'].ToArray())
      thinkCharsAvg = Get-KitAverage ([double[]]$h['thinkChars'].ToArray())
    }
  }

  $result = [ordered]@{
    days = $Days; total = $valid; ok = $okTotal; legacyCount = $legacy
    badLines = $bad; skippedByDays = $skippedByDays
    groups = @($groupResults); hosts = @($hostResults)
  }

  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add('委派效率统计（' + $(if ($Days -gt 0) { "最近 $Days 天" } else { '全部记录' }) + '）')
  [void]$lines.Add("有效记录：$valid 条（OK $okTotal 条）")
  if ($legacy -gt 0) { [void]$lines.Add("旧口径记录 $legacy 条（缺 elapsedSec 或 steps，未计入统计）") }
  if ($bad -gt 0) { [void]$lines.Add("跳过无法解析的坏行 $bad 行") }
  if ($skippedByDays -gt 0) { [void]$lines.Add("按时间范围跳过 $skippedByDays 条") }

  if ($valid -eq 0) {
    if ($legacy -eq 0 -and $bad -eq 0 -and $skippedByDays -eq 0) {
      $text = '还没有委派记录'
    } else {
      $text = ($lines -join "`n") + "`n`n还没有可统计的委派记录。"
    }
    return [ordered]@{ ExitCode = 0; Result = $result; Text = $text }
  }

  $headers = @('分组', '次数', 'OK', '平均耗时(s)', '中位耗时(s)', '步数', '工具调用', '工具错误', '输入tok', '输出tok', '缓存tok', '思考字符')
  $widths = @(30, 6, 5, 13, 13, 8, 10, 10, 12, 12, 12, 10)
  $table = New-Object System.Collections.ArrayList
  $headLine = ''
  for ($i = 0; $i -lt $headers.Count; $i++) {
    if ($i -gt 0) { $headLine += ' | ' }
    $headLine += Format-KitCell $headers[$i] $widths[$i] $false
  }
  [void]$table.Add($headLine)
  [void]$table.Add(('-' * (Get-KitDisplayWidth $headLine)))

  foreach ($row in $groupResults) {
    $cells = @(
      ($row.effort + ' / ' + $row.browser),
      [string]$row.count,
      [string]$row.ok,
      (Format-KitNumber $row.elapsedSecAvg),
      (Format-KitNumber $row.elapsedSecMedian),
      (Format-KitNumber $row.stepsAvg),
      (Format-KitNumber $row.toolCallsAvg),
      (Format-KitNumber $row.toolErrorsAvg),
      (Format-KitNumber $row.inTokAvg '0.0'),
      (Format-KitNumber $row.outTokAvg '0.0'),
      (Format-KitNumber $row.cacheTokAvg '0.0'),
      (Format-KitNumber $row.thinkCharsAvg '0.0')
    )
    $line = ''
    for ($i = 0; $i -lt $cells.Count; $i++) {
      if ($i -gt 0) { $line += ' | ' }
      $line += Format-KitCell ([string]$cells[$i]) $widths[$i] ($i -gt 0)
    }
    [void]$table.Add($line)
  }
  foreach ($row in $hostResults) {
    $cells = @(
      ($row.host + ' 合计'),
      [string]$row.count,
      [string]$row.ok,
      (Format-KitNumber $row.elapsedSecAvg),
      (Format-KitNumber $row.elapsedSecMedian),
      (Format-KitNumber $row.stepsAvg),
      (Format-KitNumber $row.toolCallsAvg),
      (Format-KitNumber $row.toolErrorsAvg),
      (Format-KitNumber $row.inTokAvg '0.0'),
      (Format-KitNumber $row.outTokAvg '0.0'),
      (Format-KitNumber $row.cacheTokAvg '0.0'),
      (Format-KitNumber $row.thinkCharsAvg '0.0')
    )
    $line = ''
    for ($i = 0; $i -lt $cells.Count; $i++) {
      if ($i -gt 0) { $line += ' | ' }
      $line += Format-KitCell ([string]$cells[$i]) $widths[$i] ($i -gt 0)
    }
    [void]$table.Add($line)
  }

  $text = ($lines -join "`n") + "`n`n" + ($table -join "`n")
  return [ordered]@{ ExitCode = 0; Result = $result; Text = $text }
}

# ---------------------------------------------------------------- diag

function Get-KitLastLines([string]$path, [int]$count) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $text = Read-KitText $path
  if ($null -eq $text) { return $null }
  $lines = @($text -split "`n")
  if ($lines.Count -eq 1 -and $lines[0] -eq '') { return '' }
  if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
    if ($lines.Count -eq 1) { return '' }
    $lines = @($lines[0..($lines.Count - 2)])
  }
  if ($lines.Count -eq 0) { return '' }
  $start = [Math]::Max(0, $lines.Count - $count)
  return (($lines[$start..($lines.Count - 1)]) -join "`n")
}

function Invoke-KitDiag {
  $paths = Get-KitPaths
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $dir = Join-Path $paths.Diag ('diag-' + $stamp)
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $files = New-Object System.Collections.ArrayList

  $dsh = Find-KitDsh

  # versions.txt
  $v = New-Object System.Collections.ArrayList
  [void]$v.Add('kitVersion: ' + $script:KitVersion)
  [void]$v.Add('dshVersion: ' + $(if ($dsh.Found) { $dsh.Version } else { '(不可用)' }))
  [void]$v.Add('dshPackageDir: ' + $(if ($dsh.PackageDir) { $dsh.PackageDir } else { '(不可用)' }))
  [void]$v.Add('dshBin: ' + $(if ($dsh.Bin) { $dsh.Bin } else { '(不可用)' }))
  [void]$v.Add('dshBase: ' + $(if ($dsh.Base) { $dsh.Base } else { '(不可用)' }))
  [void]$v.Add('dshError: ' + $(if ($dsh.Error) { $dsh.Error } else { '' }))
  [void]$v.Add('node: ' + $(if ($dsh.Node) { $dsh.Node } else { '(不可用)' }))
  [void]$v.Add('nodeVersion: ' + $(if ($dsh.NodeVersion) { $dsh.NodeVersion } else { '(不可用)' }))
  [void]$v.Add('os: ' + [Environment]::OSVersion.VersionString)
  [void]$v.Add('powershell: ' + $PSVersionTable.PSVersion.ToString())
  [void]$v.Add('kitHome: ' + $paths.Home)
  [void]$v.Add('dshHome: ' + $paths.DshHome)
  $p = Join-Path $dir 'versions.txt'
  Write-KitText $p (ConvertTo-KitRedacted ($v -join "`n"))
  [void]$files.Add('versions.txt')

  # check.json
  $checkPath = Join-Path $dir 'check.json'
  $checkCmd = Get-Command Invoke-KitCheck -ErrorAction SilentlyContinue
  if ($checkCmd) {
    try {
      $checkResult = Invoke-KitCheck
      $checkObj = if ($null -ne $checkResult -and (Test-KitHasProp $checkResult 'Result')) { $checkResult.Result } else { $checkResult }
      Write-KitJsonRedacted $checkPath $checkObj
    } catch {
      Write-KitJsonRedacted $checkPath ([ordered]@{ error = $_.Exception.Message })
    }
  } else {
    Write-KitJsonRedacted $checkPath ([ordered]@{ skipped = 'check 不可用' })
  }
  [void]$files.Add('check.json')

  # state.json（脱敏副本）
  $statePath = Join-Path $dir 'state.json'
  $stateText = Read-KitText $paths.State
  if ($null -eq $stateText) {
    Write-KitJsonRedacted $statePath ([ordered]@{ skipped = 'state.json 不存在' })
  } else {
    Write-KitText $statePath (ConvertTo-KitRedacted $stateText)
  }
  [void]$files.Add('state.json')

  # plugins.json
  $pluginsPath = Join-Path $dir 'plugins.json'
  if ($dsh.Found) {
    try { Write-KitJsonRedacted $pluginsPath (Get-KitPluginStatus $dsh) }
    catch { Write-KitJsonRedacted $pluginsPath ([ordered]@{ error = $_.Exception.Message }) }
  } else {
    Write-KitJsonRedacted $pluginsPath ([ordered]@{ error = 'dsh 不可用'; detail = $dsh.Error })
  }
  [void]$files.Add('plugins.json')

  # index-tail.jsonl（两个 index 各最后 10 行）
  $tailPath = Join-Path $dir 'index-tail.jsonl'
  $tailLines = New-Object System.Collections.ArrayList
  $indexSources = @(
    [ordered]@{ Name = 'logs'; Path = (Join-Path $paths.Logs 'index.jsonl') },
    [ordered]@{ Name = 'logs-codex'; Path = (Join-Path $paths.LogsCodex 'index.jsonl') }
  )
  foreach ($src in $indexSources) {
    $tail = Get-KitLastLines $src.Path 10
    if ($null -ne $tail) {
      foreach ($ln in ($tail -split "`n")) {
        if (-not $ln.Trim()) { continue }
        [void]$tailLines.Add(([ordered]@{ source = $src.Name; raw = (ConvertTo-KitRedacted $ln) } | ConvertTo-Json -Compress -Depth 5))
      }
    }
  }
  Write-KitText $tailPath ($tailLines -join "`n")
  [void]$files.Add('index-tail.jsonl')

  # 最近 5 次运行
  $runsDir = Join-Path $dir 'runs'
  New-Item -ItemType Directory -Force -Path $runsDir | Out-Null
  $runRecords = New-Object System.Collections.ArrayList
  foreach ($src in $indexSources) {
    $text = Read-KitText $src.Path
    if ($null -eq $text) { continue }
    foreach ($line in ($text -split "`n")) {
      $ln = $line.TrimEnd("`r")
      if (-not $ln.Trim()) { continue }
      try { $rec = $ln | ConvertFrom-Json } catch { continue }
      if ($null -eq $rec) { continue }
      $logPrefix = [string](Get-KitProp $rec 'log')
      if (-not $logPrefix) { continue }
      if (-not [IO.Path]::IsPathRooted($logPrefix)) {
        $logPrefix = Join-Path (Split-Path -Parent $src.Path) $logPrefix
      }
      $sortKey = [string](Get-KitProp $rec 'endedAt')
      if (-not $sortKey) { $sortKey = [string](Get-KitProp $rec 'startedAt') }
      [void]$runRecords.Add([ordered]@{
        Source = $src.Name; Prefix = $logPrefix; SortKey = $sortKey
        Status = [string](Get-KitProp $rec 'status'); Host = [string](Get-KitProp $rec 'host')
      })
    }
  }
  $recent = @($runRecords | Sort-Object -Property SortKey -Descending | Select-Object -First 5)
  $runInfo = New-Object System.Collections.ArrayList
  $runningList = New-Object System.Collections.ArrayList
  $idx = 0
  foreach ($run in $recent) {
    $idx++
    $base = [IO.Path]::GetFileName($run.Prefix)
    if (-not $base) { $base = 'run' + $idx }
    $safe = [regex]::Replace($base, '[^\w\.\-]', '_')
    $errPath = $run.Prefix + '.err.log'
    $runningPath = $run.Prefix + '.running'
    $tail = Get-KitLastLines $errPath 40
    if ($null -eq $tail) { $tail = '(err.log 不存在)' }
    $tailName = ('run{0}-{1}.err.tail.txt' -f $idx, $safe)
    Write-KitText (Join-Path $runsDir $tailName) (ConvertTo-KitRedacted $tail)
    [void]$files.Add('runs\' + $tailName)
    $isRunning = Test-Path -LiteralPath $runningPath -PathType Leaf
    if ($isRunning) { [void]$runningList.Add($runningPath) }
    [void]$runInfo.Add(('{0}. {1} | {2} | {3} | running={4} | err={5}' -f $idx, $run.Source, $run.Host, $run.Status, $isRunning, $errPath))
  }
  if ($recent.Count -eq 0) { [void]$runInfo.Add('(index 中没有带 log 的记录)') }
  [void]$runInfo.Add('')
  if ($runningList.Count -gt 0) {
    [void]$runInfo.Add('残留 .running 文件：')
    foreach ($rp in $runningList) { [void]$runInfo.Add($rp) }
  } else {
    [void]$runInfo.Add('没有残留 .running 文件。')
  }
  $runInfoPath = Join-Path $runsDir 'runs.txt'
  Write-KitText $runInfoPath (ConvertTo-KitRedacted ($runInfo -join "`n"))
  [void]$files.Add('runs\runs.txt')

  # 文件清单（相对目录）
  $actualFiles = @(Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object { $_.FullName.Substring($dir.Length + 1) } | Sort-Object)
  $actualFiles = @($actualFiles | Where-Object { $_ -ne 'diag.zip' })

  # 打包
  $zip = Join-Path $paths.Diag ('diag-' + $stamp + '.zip')
  $zipError = $null
  try {
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $zip -CompressionLevel Optimal -Force
  } catch {
    $zipError = $_.Exception.Message
  }

  $result = [ordered]@{
    dir = $dir
    zip = $(if ($zipError) { $null } else { $zip })
    files = @($actualFiles)
    zipError = $zipError
  }
  $textLines = @(
    '诊断包已生成：',
    "  目录：$dir",
    $(if ($zipError) { "  ZIP：生成失败（$zipError）" } else { "  ZIP：$zip" }),
    "  文件：$($actualFiles.Count) 个",
    '  说明：已脱敏；未读取 .credentials.yaml，也未复制 profiles 目录。'
  )
  return [ordered]@{ ExitCode = $(if ($zipError) { 1 } else { 0 }); Result = $result; Text = ($textLines -join "`n") }
}

# ---------------------------------------------------------------- rules

function Invoke-KitRules {
  param(
    [string]$HostName = '',
    [switch]$Show,
    [switch]$Apply,
    [string]$RulesFile
  )

  $h = if ($HostName) { $HostName.Trim().ToLowerInvariant() } else { '' }
  if (-not $h) {
    return [ordered]@{ ExitCode = 2; Result = [ordered]@{ error = '必须指定 -Host claude|codex' }; Text = '必须指定 -Host claude|codex。' }
  }
  if ($h -ne 'claude' -and $h -ne 'codex') {
    return [ordered]@{ ExitCode = 2; Result = [ordered]@{ error = 'Host 只能是 claude 或 codex' }; Text = 'Host 只能是 claude 或 codex。' }
  }

  $paths = Get-KitPaths
  $file = Get-KitRulesTarget $h $RulesFile
  $info = Read-KitRulesFileInfo $file
  if ($Apply -and $info.Exists -and -not $info.EncodingOk) {
    $msg = '规则文件不是 UTF-8 编码，请先转成 UTF-8 再运行'
    return [ordered]@{ ExitCode = 1; Result = [ordered]@{ file = $file; encoding = 'non-utf8'; error = $msg }; Text = ($msg + '：' + $file) }
  }
  $sep = ''
  if ($info.Exists -and $info.Text.Length -gt 0) {
    if ($info.EndsWithNewline) { $sep = $info.Nl } else { $sep = $info.Nl + $info.Nl }
  }
  $block = Get-KitRulesBlock $h $sep $info.Nl
  if ($null -eq $block) {
    $msg = "找不到规则模板：$(Join-Path $paths.Templates ('rules-' + $h + '.md'))"
    return [ordered]@{ ExitCode = 1; Result = [ordered]@{ error = $msg; file = $file }; Text = $msg }
  }
  $already = Test-KitRulesInstalled $info.Text

  if (-not $Apply) {
    $lines = @(
      "目标文件：$file",
      "文件存在：$(if ($info.Exists) { '是' } else { '否' })",
      "已安装规则段落：$(if ($already) { '是' } else { '否' })",
      "换行风格：$(if ($info.Nl -eq "`r`n") { 'CRLF' } else { 'LF' })",
      "写入前会备份到 $($paths.Backups)",
      '',
      '将要追加的内容：',
      ''
    )
    $text = ($lines -join "`n") + $block
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    return [ordered]@{
      ExitCode = 0
      Result = [ordered]@{ file = $file; exists = [bool]$info.Exists; alreadyInstalled = $already; block = $block }
      Text = $text
    }
  }

  if ($already) {
    $msg = "目标文件已包含 dsh-delegate-kit 规则段落，请先运行 uninstall 再追加：$file"
    return [ordered]@{ ExitCode = 1; Result = [ordered]@{ file = $file; alreadyInstalled = $true; error = $msg }; Text = $msg }
  }

  try {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backup = $null
    if ($info.Exists) {
      if (-not (Test-Path -LiteralPath $paths.Backups)) { New-Item -ItemType Directory -Force -Path $paths.Backups | Out-Null }
      $fileName = Split-Path -Leaf $file
      $backup = Join-Path $paths.Backups ($h + '-' + $fileName + '.' + $stamp + '.bak')
      [IO.File]::Copy($file, $backup, $true)
    }
    $shaBefore = Get-KitSha256 $file
    $installedAt = (Get-Date).ToString('o')
    $newText = $info.Text + $block
    Write-KitTextBom $file $newText $info.Bom
    $shaAfter = Get-KitSha256 $file
    Set-KitRulesRecord $h ([ordered]@{
      file = $file; backup = $backup; installedAt = $installedAt
      sha256Before = $shaBefore; sha256After = $shaAfter
      createdByKit = (-not $info.Exists)
    })
    $result = [ordered]@{
      file = $file; backup = $backup; installedAt = $installedAt
      sha256Before = $shaBefore; sha256After = $shaAfter; alreadyInstalled = $false
      createdByKit = (-not $info.Exists)
    }
    $lines = @(
      "已追加 dsh 委派规则：$file",
      "备份：$(if ($backup) { $backup } else { '(原文件不存在，无备份)' })",
      "换行风格：$(if ($info.Nl -eq "`r`n") { 'CRLF' } else { 'LF' })",
      "BOM：$(if ($info.Bom) { '保留' } else { '无' })"
    )
    return [ordered]@{ ExitCode = 0; Result = $result; Text = ($lines -join "`n") }
  } catch {
    $msg = "追加规则失败：$($_.Exception.Message)"
    return [ordered]@{ ExitCode = 1; Result = [ordered]@{ file = $file; error = $_.Exception.Message }; Text = $msg }
  }
}

# ---------------------------------------------------------------- uninstall

function Get-KitSelfSkillDir([string]$hostName) {
  # kit.ps1 位于 <skillDir>\scripts；<skillDir> 带 .kit-install.json 且 host 匹配时作为默认候选
  $scriptDir = $script:KitScriptDir
  if (-not $scriptDir) { return $null }
  $skillDir = Split-Path -Parent $scriptDir
  if (-not $skillDir) { return $null }
  $markerPath = Join-Path $skillDir '.kit-install.json'
  if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $null }
  $marker = $null
  try { $marker = Read-KitJson $markerPath } catch { $marker = $null }
  $mh = [string](Get-KitProp $marker 'host')
  if ($mh -and $mh -ieq $hostName) { return [IO.Path]::GetFullPath($skillDir) }
  return $null
}

function Get-KitSkillTarget([string]$hostName, [string]$skillsDir) {
  $r = [ordered]@{ Target = $null; Source = '' }
  if ($hostName -ne 'claude' -and $hostName -ne 'codex') { return $r }
  if ($skillsDir) {
    $r.Target = Join-Path ([IO.Path]::GetFullPath($skillsDir)) 'dsh-delegate-kit'
    $r.Source = 'param'
    return $r
  }
  $envName = if ($hostName -eq 'claude') { 'DSH_KIT_CLAUDE_SKILLS_DIR' } else { 'DSH_KIT_CODEX_SKILLS_DIR' }
  $envDir = [Environment]::GetEnvironmentVariable($envName)
  if ($envDir) {
    $r.Target = Join-Path ([IO.Path]::GetFullPath($envDir)) 'dsh-delegate-kit'
    $r.Source = 'env'
    return $r
  }
  $self = Get-KitSelfSkillDir $hostName
  if ($self) { $r.Target = $self; $r.Source = 'self'; return $r }
  if ($hostName -eq 'claude') {
    $root = Join-Path $HOME '.claude\skills'
  } else {
    $base = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $root = Join-Path $base 'skills'
  }
  $r.Target = Join-Path $root 'dsh-delegate-kit'
  $r.Source = 'default'
  return $r
}

function Remove-KitSkill([string]$hostName, [string]$skillsDir = '') {
  $step = [ordered]@{ host = $hostName; action = 'remove-skill'; target = $null; source = ''; status = 'skipped'; message = '' }
  $cand = Get-KitSkillTarget $hostName $skillsDir
  $step.target = $cand.Target
  $step.source = $cand.Source
  if (-not $cand.Target) { $step.message = "未知 host：$hostName"; return $step }
  $target = $cand.Target
  $leaf = [IO.Path]::GetFileName($target.TrimEnd([char[]]@('\', '/')))
  if ($leaf -eq 'dsh-delegate') {
    $step.status = 'refused'; $step.message = '叶子名为 dsh-delegate 的目录永远不删除'
    return $step
  }
  if ($leaf -ne 'dsh-delegate-kit') {
    $step.status = 'refused'; $step.message = "叶子名不是 dsh-delegate-kit：$leaf"
    return $step
  }
  if (-not (Test-Path -LiteralPath $target)) { $step.message = '目录不存在，跳过'; return $step }
  $item = Get-Item -LiteralPath $target -Force
  if (-not $item.PSIsContainer) { $step.status = 'refused'; $step.message = '目标不是目录，拒绝删除'; return $step }
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    $step.status = 'refused'; $step.message = '目标是 reparse point（junction/symlink），拒绝删除'
    return $step
  }
  if (-not (Test-Path -LiteralPath (Join-Path $target '.kit-install.json') -PathType Leaf)) {
    $step.status = 'refused'; $step.message = '目录里没有 .kit-install.json，拒绝删除（用 npx skills 安装的请运行：npx skills remove dsh-delegate-kit -g）'
    return $step
  }
  try {
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
    $step.status = 'removed'; $step.message = '已删除'
  } catch {
    $step.status = 'failed'; $step.message = $_.Exception.Message
  }
  return $step
}

function Remove-KitRulesBlock([string]$hostName, [string]$file, [string]$stamp) {
  $res = [ordered]@{ host = $hostName; file = $file; status = 'skipped'; backup = $null; warning = $null; message = ''; createdByKit = $false; deleted = $false }
  $info = Read-KitRulesFileInfo $file
  if (-not $info.Exists) { $res.message = '文件不存在，跳过'; return $res }
  if (-not $info.EncodingOk) {
    $res.status = 'failed'; $res.message = '规则文件不是 UTF-8 编码，请先转成 UTF-8 再运行'
    return $res
  }

  $marker = Get-KitRulesMarker $info.Text
  if (-not $marker.Found) { $res.message = '未找到 dsh-delegate-kit 规则标记，跳过'; return $res }
  if (-not $marker.EndFound) {
    $res.status = 'warn'; $res.message = '找到 begin 标记但缺少 end 标记，未修改文件'
    return $res
  }

  $n = [int]$marker.Sep
  $start = $marker.Index
  if ($n -gt 0) {
    if ($marker.Index -ge $n) {
      $pre = $info.Text.Substring($marker.Index - $n, $n)
      $allNl = $true
      foreach ($ch in $pre.ToCharArray()) {
        if ($ch -ne "`r" -and $ch -ne "`n") { $allNl = $false; break }
      }
      if ($allNl) {
        $start = $marker.Index - $n
      } else {
        $res.warning = 'begin 前不是换行符，未吞掉分隔换行'
      }
    } else {
      $res.warning = 'begin 前没有足够的分隔换行，未吞掉分隔换行'
    }
  }

  $end = $marker.EndStart + $marker.EndLength
  if ($end -lt $info.Text.Length -and $info.Text[$end] -eq "`r" -and ($end + 1) -lt $info.Text.Length -and $info.Text[$end + 1] -eq "`n") {
    $end += 2
  } elseif ($end -lt $info.Text.Length -and $info.Text[$end] -eq "`n") {
    $end += 1
  }

  $paths = Get-KitPaths
  $rulesJson = $null
  try { $rulesJson = Read-KitJson (Join-Path $paths.Home 'rules.json') } catch { $rulesJson = $null }
  $record = Get-KitProp $rulesJson $hostName
  $res.createdByKit = Test-KitTruthy (Get-KitProp $record 'createdByKit')

  $backup = $null
  try {
    if (-not (Test-Path -LiteralPath $paths.Backups)) { New-Item -ItemType Directory -Force -Path $paths.Backups | Out-Null }
    $backup = Join-Path $paths.Backups ($hostName + '-uninstall-' + $stamp + '.bak')
    [IO.File]::Copy($file, $backup, $true)
    $newText = $info.Text.Remove($start, $end - $start)
    if ($res.createdByKit -and $newText.Length -eq 0) {
      Remove-Item -LiteralPath $file -Force -ErrorAction Stop
      $res.deleted = $true
      $res.message = '已移除规则段落并删除由 kit 创建的空文件'
    } else {
      Write-KitTextBom $file $newText $info.Bom
      $res.message = '已移除规则段落'
    }
    $res.status = 'removed'
    $res.backup = $backup
  } catch {
    $res.status = 'failed'
    $res.message = $_.Exception.Message
  }
  return $res
}

function Test-KitSamePath([string]$a, [string]$b) {
  if (-not $a -or -not $b) { return $false }
  $x = [IO.Path]::GetFullPath($a).TrimEnd([char[]]@('\', '/'))
  $y = [IO.Path]::GetFullPath($b).TrimEnd([char[]]@('\', '/'))
  return [string]::Equals($x, $y, [StringComparison]::OrdinalIgnoreCase)
}

function Get-KitCleanupBlockReason($paths) {
  # 清理前校验 kit 归属：state.json 可解析且 schemaVersion=1、有 kitVersion；路径不能指向 DshHome 公共目录
  $state = $null
  try { $state = Read-KitState } catch { $state = $null }
  if ($null -eq $state) { return 'state.json 不存在或无法解析，无法确认目录由本 kit 创建' }
  $schema = [string](Get-KitProp $state 'schemaVersion')
  if ($schema -ne '1') { return "state.json 的 schemaVersion 不是 1（$schema），拒绝清理" }
  $kitVersion = [string](Get-KitProp $state 'kitVersion')
  if (-not $kitVersion) { return 'state.json 缺少 kitVersion，拒绝清理' }
  if (Test-KitSamePath $paths.Patches (Join-Path $paths.DshHome 'patches')) {
    return "Patches 目录等于 DshHome\patches（$($paths.Patches)），拒绝清理"
  }
  if (Test-KitSamePath $paths.Home $paths.DshHome) {
    return "KIT_HOME 等于 DshHome（$($paths.Home)），拒绝清理"
  }
  return $null
}

function Invoke-KitUninstall {
  param(
    [string]$HostName = '',
    [string]$RulesFile,
    [switch]$RemoveSkills,
    [switch]$PurgeLogs,
    [string]$ClaudeSkillsDir = '',
    [string]$CodexSkillsDir = ''
  )

  $h = if ($HostName) { $HostName.Trim().ToLowerInvariant() } else { 'all' }
  if ($h -ne 'claude' -and $h -ne 'codex' -and $h -ne 'all') {
    return [ordered]@{ ExitCode = 2; Result = [ordered]@{ error = 'Host 只能是 claude、codex 或 all' }; Text = 'Host 只能是 claude、codex 或 all。' }
  }
  if ($h -eq 'all' -and $RulesFile) {
    return [ordered]@{ ExitCode = 2; Result = [ordered]@{ error = '-RulesFile 只能在单个 host 时使用' }; Text = '-RulesFile 只能在单个 host 时使用；all 会同时处理 claude 和 codex。' }
  }

  $paths = Get-KitPaths
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $hosts = if ($h -eq 'all') { @('claude', 'codex') } else { @($h) }
  $ruleResults = New-Object System.Collections.ArrayList
  $skillResults = New-Object System.Collections.ArrayList
  $textLines = New-Object System.Collections.ArrayList

  foreach ($hostName in $hosts) {
    $file = Get-KitRulesTarget $hostName $RulesFile
    $rr = Remove-KitRulesBlock $hostName $file $stamp
    [void]$ruleResults.Add($rr)
    if ($rr.status -eq 'removed') {
      Remove-KitRulesRecord $hostName
      [void]$textLines.Add("[$hostName] 已移除规则段落：$file")
      [void]$textLines.Add("  备份：$($rr.backup)")
    } elseif ($rr.status -eq 'warn') {
      [void]$textLines.Add("[$hostName] 警告：$($rr.message)（$file）")
    } elseif ($rr.status -eq 'failed') {
      [void]$textLines.Add("[$hostName] 移除失败：$($rr.message)")
    } else {
      [void]$textLines.Add("[$hostName] 跳过：$($rr.message)（$file）")
    }
    if ($rr.warning) { [void]$textLines.Add("  注意：$($rr.warning)") }
  }

  if ($RemoveSkills) {
    foreach ($hostName in $hosts) {
      $skillsDir = if ($hostName -eq 'claude') { $ClaudeSkillsDir } else { $CodexSkillsDir }
      $sr = Remove-KitSkill $hostName $skillsDir
      [void]$skillResults.Add($sr)
      [void]$textLines.Add("[$hostName] Skill 目录：$($sr.status) - $($sr.message)（$($sr.target)）")
    }
  }

  $ruleFailures = @($ruleResults | Where-Object { $_.status -eq 'warn' -or $_.status -eq 'failed' })
  $cleanupError = $null
  if ($ruleFailures.Count -gt 0) {
    $cleanupError = "规则移除未全部成功（$($ruleFailures.Count) 项），已跳过清理"
    [void]$textLines.Add($cleanupError)
    foreach ($rf in $ruleFailures) {
      [void]$textLines.Add("  失败项：$($rf.host) · $($rf.status) · $($rf.message)")
    }
  }

  $cleanup = [ordered]@{}
  if ($h -eq 'all') {
    $targets = @(
      [ordered]@{ Key = 'patches'; Path = $paths.Patches; Label = '补丁目录' },
      [ordered]@{ Key = 'state'; Path = $paths.State; Label = 'state.json' },
      [ordered]@{ Key = 'rules'; Path = (Join-Path $paths.Home 'rules.json'); Label = 'rules.json' },
      [ordered]@{ Key = 'spec'; Path = (Join-Path $paths.Home 'spec.json'); Label = 'spec.json' },
      [ordered]@{ Key = 'check'; Path = (Join-Path $paths.Home 'check'); Label = 'check 目录' }
    )
    if ($PurgeLogs) { $targets += [ordered]@{ Key = 'logs'; Path = $paths.Logs; Label = '日志目录' } }
    if (-not $cleanupError) { $cleanupError = Get-KitCleanupBlockReason $paths }
    if ($cleanupError) {
      foreach ($t in $targets) {
        $cleanup[$t.Key] = [ordered]@{ path = $t.Path; status = 'skipped'; message = $cleanupError }
      }
      [void]$textLines.Add("清理已跳过：$cleanupError")
    } else {
      foreach ($t in $targets) {
        $item = [ordered]@{ path = $t.Path; status = 'skipped'; message = '' }
        if (Test-Path -LiteralPath $t.Path) {
          try {
            Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
            $item.status = 'removed'; $item.message = '已删除'
            [void]$textLines.Add("[$($t.Key)] 已删除$($t.Label)：$($t.Path)")
          } catch {
            $item.status = 'failed'; $item.message = $_.Exception.Message
            [void]$textLines.Add("[$($t.Key)] 删除失败：$($_.Exception.Message)")
          }
        } else {
          $item.message = '不存在，跳过'
          [void]$textLines.Add("[$($t.Key)] $($t.Label)不存在，跳过：$($t.Path)")
        }
        $cleanup[$t.Key] = $item
      }
      if (-not $PurgeLogs) {
        [void]$textLines.Add("[logs] 日志目录保留：$($paths.Logs)（加 -PurgeLogs 可删除）")
      }
      [void]$textLines.Add("备份目录永远保留：$($paths.Backups)")
    }
  }

  $failedCleanup = @($cleanup.Values | Where-Object { $_.status -eq 'failed' })
  $exitCode = 0
  if ($ruleFailures.Count -gt 0 -or $cleanupError -or $failedCleanup.Count -gt 0) { $exitCode = 1 }

  $result = [ordered]@{
    host = $h
    rules = @($ruleResults)
    skills = @($skillResults)
    cleanup = $cleanup
    backups = $paths.Backups
    ruleFailures = @($ruleFailures | ForEach-Object { [ordered]@{ host = $_.host; file = $_.file; status = $_.status; message = $_.message } })
  }
  if ($cleanupError) { $result.cleanupSkipped = $cleanupError }
  return [ordered]@{ ExitCode = $exitCode; Result = $result; Text = ($textLines -join "`n") }
}

# ---------------------------------------------------------------- update

function ConvertTo-KitUpdateVersion([string]$version) {
  if (-not $version) { return $null }
  $core = ($version -split '-', 2)[0]
  try { return [version]$core } catch { return $null }
}

function Get-KitUpdateManualSteps([string]$npxSource) {
  return (@(
    '手动更新：',
    '  npx skills update dsh-delegate-kit -g',
    '之前不是用 npx 安装的（skill 目录里有 .kit-install.json）：先删除旧的 dsh-delegate-kit skill 目录，再运行',
    ('  npx skills add ' + $npxSource + ' --skill dsh-delegate-kit -g'),
    '配置、补丁和日志都在 KIT_HOME（默认 ~\.dsh\dsh-delegate-kit），更新或重装都不受影响。'
  ) -join "`n")
}

function Get-KitUpdateOutputTail([string]$text, [int]$count) {
  $lines = @(([string]$text) -split "`r?`n" | Where-Object { $_.Trim() })
  if ($lines.Count -eq 0) { return '' }
  return (($lines | Select-Object -Last $count) -join "`n")
}

function Invoke-KitUpdate {
  param(
    [switch]$Apply,
    [switch]$Force
  )

  $currentVersion = [string]$script:KitVersion
  $meta = Get-KitMeta
  $source = [string]$meta.updateSource
  $branch = [string]$meta.updateBranch
  $packagePath = [string]$meta.packagePath
  $npxSource = [string]$meta.npxSource
  if (-not $branch) { $branch = 'main' }
  if (-not $packagePath) { $packagePath = 'dsh-delegate-kit' }
  if (-not $npxSource) { $npxSource = 'beilanya/dsh-skills' }
  $manual = Get-KitUpdateManualSteps $npxSource
  $skillDir = Split-Path -Parent $script:KitScriptDir
  $legacy = Test-Path -LiteralPath (Join-Path $skillDir '.kit-install.json') -PathType Leaf
  $textLines = New-Object System.Collections.ArrayList
  $result = [ordered]@{
    currentVersion  = $currentVersion
    latestVersion   = $null
    updateAvailable = $false
    changes         = @()
    source          = $source
    skillDir        = $skillDir
    legacyInstall   = [bool]$legacy
    npxCommand      = 'npx skills update dsh-delegate-kit -g'
    dshVersion      = $null
    dshTestedInNew  = $false
  }

  # ---- 查询最新版本：浅克隆到临时目录读版本号和变更记录（需要 git；没有 git 时跳过查询）----
  $gitCmd = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  $paths = Get-KitPaths
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $rand = -join (1..4 | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
  $base = if (Test-Path -LiteralPath $paths.Home -PathType Container) { Join-Path $paths.Home 'update' } else { Join-Path ([IO.Path]::GetTempPath()) 'dsh-delegate-kit-update' }
  $tmp = Join-Path $base ($stamp + '-' + $rand)
  $queryNote = ''
  try {
    if (-not $gitCmd -or -not $gitCmd.Source) {
      $queryNote = '找不到 git，无法查询最新版本和更新内容'
    } else {
      New-Item -ItemType Directory -Force -Path $tmp | Out-Null
      $repo = Join-Path $tmp 'repo'
      $cloneArgs = @('clone', '--depth', '1', '--branch', $branch, '--quiet', $source, $repo)
      # 公开仓库不需要凭据；禁止 git 弹出凭据提示或窗口，避免后台卡住
      $prevPrompt = $env:GIT_TERMINAL_PROMPT
      $prevGcm = $env:GCM_INTERACTIVE
      $env:GIT_TERMINAL_PROMPT = '0'
      $env:GCM_INTERACTIVE = 'never'
      try {
        $clone = Invoke-KitProcess $gitCmd.Source $cloneArgs (Get-KitWorkDir) 180
      } finally {
        $env:GIT_TERMINAL_PROMPT = $prevPrompt
        $env:GCM_INTERACTIVE = $prevGcm
      }
      if ($clone.TimedOut -or $clone.ExitCode -ne 0) {
        $reason = Get-KitUpdateOutputTail $clone.Err 4
        if (-not $reason) { $reason = 'git clone 退出码 ' + $clone.ExitCode }
        $queryNote = "查询最新版本失败（$source）：$reason"
      } else {
        $newPkg = Join-Path $repo $packagePath
        $latestVersion = $null
        foreach ($vf in @('scripts\lib\common.ps1', 'install.ps1')) {
          $vt = Read-KitText (Join-Path $newPkg $vf)
          if (-not $vt) { continue }
          $vm = [regex]::Match($vt, '\$script:KitVersion\s*=\s*''([^'']+)''')
          if ($vm.Success) { $latestVersion = $vm.Groups[1].Value; break }
        }
        if (-not $latestVersion) {
          $queryNote = '读不到新版的版本号'
        } else {
          $cmpCurrent = ConvertTo-KitUpdateVersion $currentVersion
          $cmpLatest = ConvertTo-KitUpdateVersion $latestVersion
          if ($null -ne $cmpCurrent -and $null -ne $cmpLatest) { $updateAvailable = ($cmpLatest -gt $cmpCurrent) } else { $updateAvailable = ($latestVersion -ne $currentVersion) }
          $changes = New-Object System.Collections.ArrayList
          $maintText = Read-KitText (Join-Path $newPkg 'docs\MAINTENANCE.md')
          if ($maintText) {
            foreach ($ln in ($maintText -split "`r?`n")) {
              $cm = [regex]::Match($ln, '^- (\d+\.\d+\.\d+)（')
              if (-not $cm.Success) { continue }
              $cmpLine = ConvertTo-KitUpdateVersion $cm.Groups[1].Value
              $isNewer = if ($null -ne $cmpLine -and $null -ne $cmpCurrent) { $cmpLine -gt $cmpCurrent } else { $cm.Groups[1].Value -ne $currentVersion }
              if ($isNewer) { [void]$changes.Add($ln.TrimEnd()) }
            }
          }
          $dshInfo = Find-KitDsh
          $dshVersion = [string]$dshInfo.Version
          if (-not $dshVersion) { $dshVersion = $null }
          $newMeta = $null
          try { $newMeta = Read-KitJson (Join-Path $newPkg 'scripts\lib\kit-meta.json') } catch { $newMeta = $null }
          $tested = @()
          $testedVal = Get-KitProp $newMeta 'testedDshVersions'
          if ($testedVal) { $tested = @($testedVal | ForEach-Object { [string]$_ }) }
          $result.latestVersion = $latestVersion
          $result.updateAvailable = $updateAvailable
          $result.changes = @($changes)
          $result.dshVersion = $dshVersion
          $result.dshTestedInNew = [bool]($dshVersion -and ($tested -contains $dshVersion))
        }
      }
    }
  } finally {
    if (Test-Path -LiteralPath $tmp) {
      try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop } catch { }
    }
  }
  if ($queryNote) { $result.queryNote = $queryNote }

  # ---- 只查询 ----
  if (-not $Apply) {
    [void]$textLines.Add("当前版本：$currentVersion")
    if ($queryNote) {
      [void]$textLines.Add($queryNote)
      [void]$textLines.Add('仍可运行 kit.ps1 update -Apply（或直接运行 npx skills update dsh-delegate-kit -g）尝试更新。')
    } elseif ($result.updateAvailable) {
      [void]$textLines.Add('最新版本：' + $result.latestVersion)
      [void]$textLines.Add('')
      [void]$textLines.Add('更新内容：')
      if (@($result.changes).Count -eq 0) { [void]$textLines.Add('  （新版没有比当前版本更新的变更记录）') }
      foreach ($c in @($result.changes)) { [void]$textLines.Add('  ' + $c) }
      if (-not $result.dshTestedInNew -and $result.dshVersion) { [void]$textLines.Add('提示：新版也没有验证过本机 dsh ' + $result.dshVersion) }
      [void]$textLines.Add('')
      [void]$textLines.Add('确认更新请运行：kit.ps1 update -Apply')
    } else {
      [void]$textLines.Add('已是最新版本')
    }
    if ($legacy) {
      [void]$textLines.Add('')
      [void]$textLines.Add('注意：当前副本是旧安装脚本装的，npx 无法更新它，需要先迁移。')
      [void]$textLines.Add($manual)
    }
    return [ordered]@{ ExitCode = 0; Result = $result; Text = ($textLines -join "`n") }
  }

  # ---- 更新 ----
  if (-not $queryNote -and -not $result.updateAvailable -and -not $Force) {
    [void]$textLines.Add("已是最新版本 $currentVersion，无需更新（加 -Force 可强制更新）")
    return [ordered]@{ ExitCode = 0; Result = $result; Text = ($textLines -join "`n") }
  }
  if ($legacy) {
    [void]$textLines.Add('当前副本是旧安装脚本装的（目录里有 .kit-install.json），npx 无法更新它。请先迁移：')
    [void]$textLines.Add('  1. 删除旧的 skill 目录：' + $skillDir + '（另一个宿主也装过的话一并删除）')
    [void]$textLines.Add('  2. 运行：npx skills add ' + $npxSource + ' --skill dsh-delegate-kit -g')
    [void]$textLines.Add('配置、补丁和日志都在 KIT_HOME，迁移后不需要重新 setup。')
    return [ordered]@{ ExitCode = 1; Result = $result; Text = ($textLines -join "`n") }
  }
  $npxCmd = Get-Command npx -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $npxCmd) {
    [void]$textLines.Add('找不到 npx（随 Node.js 一起安装），无法更新。')
    return [ordered]@{ ExitCode = 1; Result = $result; Text = ($textLines -join "`n") }
  }

  # npx 会替换当前 skill 目录；先把当前目录切到 KIT_HOME，结束后恢复
  $oldLocation = (Get-Location).Path
  $oldCurrentDir = [Environment]::CurrentDirectory
  $workDir = Get-KitWorkDir
  try {
    Set-Location -LiteralPath $workDir -ErrorAction Stop
    [Environment]::CurrentDirectory = $workDir
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $ur = Invoke-KitProcess $cmdExe @('/d', '/c', 'npx', '-y', 'skills', 'update', 'dsh-delegate-kit', '-g', '-y') $workDir 300
    $updateOk = [bool]($ur.ExitCode -eq 0 -and -not $ur.TimedOut)
    $result.npx = [ordered]@{ exitCode = [int]$ur.ExitCode; timedOut = [bool]$ur.TimedOut; output = (Get-KitUpdateOutputTail (($ur.Out + "`n" + $ur.Err) -replace '\x1b\[[0-9;?]*[A-Za-z]', '') 12) }
    if (-not $updateOk) {
      [void]$textLines.Add('npx skills update 失败（' + $(if ($ur.TimedOut) { '超时' } else { '退出码 ' + $ur.ExitCode }) + '）：')
      [void]$textLines.Add($result.npx.output)
      [void]$textLines.Add('')
      [void]$textLines.Add($manual)
      return [ordered]@{ ExitCode = 1; Result = $result; Text = ($textLines -join "`n") }
    }

    # 自检：用更新后的 kit.ps1 跑 check，不通过再 repair；没有 state.json 说明还没 setup
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $checkKit = Join-Path $skillDir 'scripts\kit.ps1'
    $selfCheck = ''
    if (-not (Test-Path -LiteralPath $paths.State -PathType Leaf)) {
      $selfCheck = '还没有 setup，跳过自检'
    } elseif (-not (Test-Path -LiteralPath $checkKit -PathType Leaf)) {
      $selfCheck = '找不到更新后的 kit.ps1，跳过自检：' + $checkKit
    } else {
      $cr = Invoke-KitProcess $psExe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checkKit, 'check', '-Json', '-UpdateBaseline') $workDir 180
      $checkJson = $null
      try { if ($cr.Out -and $cr.Out.Trim()) { $checkJson = $cr.Out | ConvertFrom-Json } } catch { $checkJson = $null }
      if ([bool](Get-KitProp $checkJson 'ok')) {
        $selfCheck = 'check 通过'
      } else {
        $rr = Invoke-KitProcess $psExe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checkKit, 'repair', '-Json') $workDir 180
        $repairJson = $null
        try { if ($rr.Out -and $rr.Out.Trim()) { $repairJson = $rr.Out | ConvertFrom-Json } } catch { $repairJson = $null }
        $selfCheck = if ([bool](Get-KitProp $repairJson 'ok')) { 'check 未通过，repair 后通过' } else { 'check 未通过，repair 后仍未通过，请运行 check 查看原因' }
      }
    }
    $result.selfCheck = $selfCheck
    $target = if ($result.latestVersion) { $result.latestVersion } else { '最新版本' }
    [void]$textLines.Add("已通过 npx skills update 更新到 $target（原版本 $currentVersion）")
    [void]$textLines.Add('自检：' + $selfCheck)
    [void]$textLines.Add('Claude Code 和 Codex 需要新开会话（Codex 桌面端可能需要重启）才会加载新的 SKILL.md')
    return [ordered]@{ ExitCode = 0; Result = $result; Text = ($textLines -join "`n") }
  } finally {
    try { Set-Location -LiteralPath $oldLocation -ErrorAction Stop } catch { }
    try { [Environment]::CurrentDirectory = $oldCurrentDir } catch { }
  }
}

# ---------------------------------------------------------------- 导出给 kit.ps1（dot-source 后直接可用）
# Invoke-KitStats / Invoke-KitDiag / Invoke-KitRules / Invoke-KitUninstall / Invoke-KitUpdate
