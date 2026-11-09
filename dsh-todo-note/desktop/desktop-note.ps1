# 桌面待办卡：无边框、置顶、可拖；粘一段话就拆成待办。
#
# 拆分靠 DSH 里的模型，这个进程自己没有模型可用，所以走文件信箱：
#   本程序写 request.json  →  DSH 宿主那一半读它、调模型、写 result.json
#   本程序读 result.json   →  拆好了就摆出确认条
# 三个文件各只有一个写者，不用锁：todos.json 只由本程序写，request.json 只由本程序写，
# result.json 只由 DSH 写。
#
# 关掉 DSH 时粘进来的话会一直停在「等 DSH」，DSH 一起来就自动拆完。

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# 不声明 DPI 感知，系统会按缩放比再乘一次坐标，窗口会被推到屏幕外面。
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DpiFix {
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
try { [void][DpiFix]::SetProcessDpiAwareness(1) } catch { try { [void][DpiFix]::SetProcessDPIAware() } catch { } }

# 只留一个：双击两次不该叠出两张卡片。
$script:Mutex = New-Object System.Threading.Mutex($false, 'dsh-todo-note-window')
if (-not $script:Mutex.WaitOne(0)) { exit }

# 数据目录必须和宿主半边算成同一个：DSH_HOME 优先，没有就退回 ~\.dsh。
# 两边各算各的路径，一旦不一致就会出现「卡片记了、宿主读不到」这种幽灵问题。
$script:DshHome = $env:DSH_HOME
if ([string]::IsNullOrWhiteSpace($script:DshHome)) { $script:DshHome = Join-Path $env:USERPROFILE '.dsh' }
$script:DataDir = Join-Path $script:DshHome 'todo-note'
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
$script:DataFile = Join-Path $script:DataDir 'todos.json'
$script:PosFile = Join-Path $script:DataDir 'window.json'
$script:ReqFile = Join-Path $script:DataDir 'request.json'
$script:ResFile = Join-Path $script:DataDir 'result.json'
# 日志写进数据目录，别往程序目录里丢垃圾——那里以后是 git 仓库。
$script:LogFile = Join-Path $script:DataDir 'run.log'
$script:Enc = [Text.UTF8Encoding]::new($false)

$script:State = $null
$script:Stamp = [DateTime]::MinValue
$script:Win = $null
$script:Panel = $null
$script:Mode = 'collapsed'
$script:Tab = 'list'
$script:Today = (Get-Date).Date
$script:ViewYear = (Get-Date).Year
$script:ViewMonth = (Get-Date).Month
$script:PickedDay = $null
$script:Pending = $null
$script:Awaiting = $null
$script:AwaitSince = $null
$script:Draft = ''
$script:Submitted = ''
$script:Msg = ''

# 配色是整组换的，不是只换背景。深色底配浅字、浅色底配深字，
# 单换背景底色，字色不变，马上就是白底白字。
$script:Themes = [ordered]@{
  carbon = @{ label = '碳黑（默认）'; bg = '#1B1B20'; input = '#232329'; txt = '#E6EDF3'; dim = '#8B8B95'; mute = '#6E6E78'; late = '#E5534B'; line = '#33333A'; cell = '#2A2A31'; today = '#31313C'; picked = '#2F3040'; alt = '#202026' }
  ocean  = @{ label = '深海蓝'; bg = '#101820'; input = '#16212B'; txt = '#E3EDF5'; dim = '#8FA3B4'; mute = '#6E8294'; late = '#F2705F'; line = '#22303C'; cell = '#1B2833'; today = '#233B4E'; picked = '#24384A'; alt = '#152029' }
  forest = @{ label = '墨绿'; bg = '#101A15'; input = '#16221C'; txt = '#E2EFE6'; dim = '#8FA99A'; mute = '#6E8A7B'; late = '#E8705F'; line = '#1F2E27'; cell = '#1A2620'; today = '#254135'; picked = '#22392E'; alt = '#141F19' }
  dusk   = @{ label = '夜紫'; bg = '#151221'; input = '#1D1930'; txt = '#E8E4F5'; dim = '#9C93B8'; mute = '#7B719A'; late = '#F2705F'; line = '#2A2440'; cell = '#231E38'; today = '#332B54'; picked = '#2E2549'; alt = '#1A1628' }
  paper  = @{ label = '纸白'; bg = '#F5F3EE'; input = '#E9E6DF'; txt = '#23242A'; dim = '#5C5F68'; mute = '#8A8D96'; late = '#C0392B'; line = '#D8D4CA'; cell = '#CFCABE'; today = '#E8DEC4'; picked = '#DCD3BF'; alt = '#EFEBE3' }
}
$script:ThemeKey = 'carbon'

# 下面这组是"当前主题"的展开值，渲染时直接读；换主题就重赋一遍再重画。
$C_TXT = '#E6EDF3'
$C_DIM = '#8B8B95'
$C_MUTE = '#6E6E78'
$C_LATE = '#E5534B'
$C_LINE = '#33333A'
$C_BG = '#1B1B20'
$C_INPUT = '#232329'
$C_CELL = '#2A2A31'
$C_TODAY = '#26262E'
$C_PICKED = '#2F3040'
$C_ALT = '#202026'

function Brush([string]$hex) {
  return ([Windows.Media.BrushConverter]::new()).ConvertFromString($hex)
}

# 把主题表里的那一组颜色摊到 $C_* 上。改的是 script 作用域，界面上各
# 渲染函数读的就是同一批变量，所以换完重画一遍即生效。
function Apply-Theme([string]$key) {
  if (-not $script:Themes.Contains($key)) { $key = 'carbon' }
  $t = $script:Themes[$key]
  $script:ThemeKey = $key
  $script:C_TXT = $t.txt
  $script:C_DIM = $t.dim
  $script:C_MUTE = $t.mute
  $script:C_LATE = $t.late
  $script:C_LINE = $t.line
  $script:C_BG = $t.bg
  $script:C_INPUT = $t.input
  $script:C_CELL = $t.cell
  $script:C_TODAY = $t.today
  $script:C_PICKED = $t.picked
  $script:C_ALT = $t.alt
}


function Save-Position {
  $pos = [pscustomobject]@{ x = [int]$script:Win.Left; y = [int]$script:Win.Top; theme = $script:ThemeKey }
  try {
    [IO.File]::WriteAllText($script:PosFile, ($pos | ConvertTo-Json -Compress), $script:Enc)
  } catch { }
}

# 换主题：窗口和卡片是启动时一次性刷的，不重设就只换字色不换底。
function Set-Theme([string]$key) {
  Apply-Theme $key
  if ($null -ne $script:Win) { $script:Win.Background = Brush $script:C_BG }
  if ($null -ne $script:CardRef) {
    $script:CardRef.Background = Brush $script:C_BG
    $script:CardRef.BorderBrush = Brush $script:C_LINE
  }
  Save-Position
  Render-All
}

function Log([string]$line) {
  try { [IO.File]::AppendAllText($script:LogFile, (Get-Date -Format 'HH:mm:ss') + ' ' + $line + [Environment]::NewLine, $script:Enc) } catch { }
}

# ---- 数据 ----

function Read-State {
  if (-not (Test-Path -LiteralPath $script:DataFile)) {
    return [pscustomobject]@{ version = 1; seq = 0; items = @() }
  }
  $raw = [IO.File]::ReadAllText($script:DataFile, [Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return [pscustomobject]@{ version = 1; seq = 0; items = @() }
  }
  try { $st = $raw | ConvertFrom-Json } catch { return [pscustomobject]@{ version = 1; seq = 0; items = @() } }
  # 只有一条时 ConvertFrom-Json 给对象不给数组。
  $st | Add-Member -NotePropertyName items -NotePropertyValue @($st.items) -Force
  return $st
}

function Write-State($st) {
  $json = $st | ConvertTo-Json -Depth 8
  $tmp = "$($script:DataFile).tmp"
  [IO.File]::WriteAllText($tmp, $json, $script:Enc)
  for ($i = 0; $i -lt 10; $i++) {
    try {
      Move-Item -LiteralPath $tmp -Destination $script:DataFile -Force
      break
    } catch {
      Start-Sleep -Milliseconds 40
    }
  }
  $script:Stamp = (Get-Item -LiteralPath $script:DataFile).LastWriteTimeUtc
}

function Next-Id {
  $st = Read-State
  $n = 0
  if ($null -ne $st.seq) { $n = [int]$st.seq }
  $n = $n + 1
  $st.seq = $n
  Write-State $st
  return ('t{0}-{1}' -f ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()), $n)
}

function Add-Item([string]$title, $time, [string]$place, [string]$timeText, $requirements, $actions) {
  $st = Read-State
  $n = 0
  if ($null -ne $st.seq) { $n = [int]$st.seq }
  $n = $n + 1
  $st.seq = $n
  $id = 't{0}-{1}' -f ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()), $n
  $reqs = @()
  if ($null -ne $requirements) {
    $reqs = @($requirements | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
  }
  $acts = @()
  if ($null -ne $actions) {
    $acts = @($actions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
  }
  $it = [pscustomobject]@{
    id           = $id
    title        = $title
    actions      = $acts
    place        = $place
    time         = $time
    timeText     = $timeText
    requirements = $reqs
    done         = $false
    archived     = $false
    createdAt    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  }
  $st.items = @($st.items) + $it
  Write-State $st
  $script:State = $st
  return $id
}

function Patch-Item([string]$id, $patch) {
  $st = Read-State
  foreach ($it in $st.items) {
    if ($it.id -eq $id) {
      foreach ($k in $patch.Keys) { $it | Add-Member -NotePropertyName $k -NotePropertyValue $patch[$k] -Force }
    }
  }
  Write-State $st
  $script:State = $st
}

function Remove-ItemById([string]$id) {
  $st = Read-State
  $st.items = @($st.items | Where-Object { $_.id -ne $id })
  Write-State $st
  $script:State = $st
}

function Set-Done([string]$id, [bool]$value) {
  Patch-Item $id @{ done = $value }
}

# ---- 时间显示 ----

function Test-HasTime($ts) {
  if ($null -eq $ts) { return $false }
  return ([double]$ts -gt 0)
}

function Get-Bucket($it) {
  if ($it.done -or $it.archived) { return 3 }
  if (Test-HasTime $it.time) {
    if ([double]$it.time -lt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { return 0 }
    return 1
  }
  return 2
}

function Format-When($ts) {
  $d = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ts).ToLocalTime()
  if ($d.Hour -eq 0 -and $d.Minute -eq 0) { return ('{0}/{1}' -f $d.Month, $d.Day) }
  return ('{0}/{1} {2:00}:{3:00}' -f $d.Month, $d.Day, $d.Hour, $d.Minute)
}

function Sorted-Rows($items) {
  $rows = @()
  foreach ($it in $items) {
    if ($it.archived) { continue }
    $t = [double]0
    if (Test-HasTime $it.time) { $t = [double]$it.time }
    $c = [double]0
    if ($null -ne $it.createdAt) { $c = [double]$it.createdAt }
    $rows += [pscustomobject]@{ b = (Get-Bucket $it); t = $t; c = $c; item = $it }
  }
  return @($rows | Sort-Object b, t, c)
}

# ---- 信箱 ----

function Submit-Text([string]$text) {
  $text = $text.Trim()
  if ($text.Length -eq 0) { return }
  if ($text.Length -gt 2000) {
    $script:Msg = '这段太长（超过 2000 字），没提交'
    Render-All
    return
  }
  $id = 'r' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $body = [pscustomobject]@{ id = $id; text = $text; at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
  [IO.File]::WriteAllText($script:ReqFile, ($body | ConvertTo-Json -Compress), $script:Enc)
  $script:Awaiting = $id
  $script:AwaitSince = Get-Date
  $script:Submitted = $text
  $script:Draft = ''
  $script:Msg = '拆解中…'
  Render-All
}

function Poll-Result {
  if ($null -eq $script:Awaiting) { return }
  $res = $null
  if (Test-Path -LiteralPath $script:ResFile) {
    try {
      $res = [IO.File]::ReadAllText($script:ResFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
      $res = $null
    }
  }
  if ($null -ne $res -and [string]$res.id -eq [string]$script:Awaiting) {
    $script:Awaiting = $null
    $script:AwaitSince = $null
    $list = @($res.items)
    if ($list.Count -eq 0) {
      $why = [string]$res.note
      if ($why -eq 'no-todo') {
        $script:Msg = '没识别出待办，原文放回输入框了'
      } elseif ($why -eq 'no-llm' -or $why -eq 'no-model') {
        $script:Msg = 'DSH 那边还没接上模型，原文先留着，等会儿再按回车'
      } elseif ($why -eq 'too-long') {
        $script:Msg = '这段太长（超过 2000 字），拆不出来'
      } elseif ($why -like 'llm*') {
        $script:Msg = '拆的时候出错了，原文放回输入框'
      } else {
        $script:Msg = '没识别出待办'
      }
      $script:Draft = [string]$script:Submitted
      $script:Pending = $null
    } else {
      $script:Pending = [pscustomobject]@{ text = ''; items = $list }
      $script:Msg = ('拆出 {0} 条，勾中的才存' -f $list.Count)
    }
    Render-All
    return
  }
  # 八秒还没回音，多半是 DSH 没在跑。
  if ($null -ne $script:AwaitSince -and ((Get-Date) - $script:AwaitSince).TotalSeconds -gt 8) {
    if ($script:Msg -ne 'DSH 没在跑，等它起来就自动拆') {
      $script:Msg = 'DSH 没在跑，等它起来就自动拆'
      Render-All
    }
  }
}

# ---- 部件 ----

function New-Text([string]$text, [double]$size, [string]$color, [string]$weight) {
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = $text
  $t.FontSize = $size
  $t.Foreground = Brush $color
  $t.TextWrapping = 'Wrap'
  if ($weight) { $t.FontWeight = $weight }
  return $t
}

function New-Link([string]$text) {
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = $text
  $t.FontSize = 10.5
  $t.Foreground = Brush $C_DIM
  $t.Cursor = 'Hand'
  $t.Margin = [Windows.Thickness]::new(0, 0, 10, 0)
  return $t
}

function New-ItemRow($it, [bool]$editable) {
  $dp = New-Object Windows.Controls.DockPanel
  $dp.Margin = [Windows.Thickness]::new(0, 6, 0, 0)
  $dp.LastChildFill = $true

  $cb = New-Object Windows.Controls.CheckBox
  $cb.IsChecked = [bool]$it.done
  $cb.VerticalAlignment = 'Top'
  $cb.Margin = [Windows.Thickness]::new(0, 3, 8, 0)
  $cb.Tag = [string]$it.id
  $cb.Add_Click({
    param($s, $e)
    Set-Done ([string]$s.Tag) ([bool]$s.IsChecked)
    Render-All
  })

  $late = $false
  if ((-not $it.done) -and (Test-HasTime $it.time)) {
    $late = ([double]$it.time -lt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  }

  $timeBlock = New-Object Windows.Controls.TextBlock
  $timeBlock.Text = ''
  if (Test-HasTime $it.time) { $timeBlock.Text = Format-When $it.time }
  $timeBlock.FontSize = 10.5
  $timeBlock.Margin = [Windows.Thickness]::new(8, 3, 0, 0)
  $timeBlock.VerticalAlignment = 'Top'
  if ($late) {
    $timeBlock.Foreground = Brush $C_LATE
  } elseif ($it.done) {
    $timeBlock.Foreground = Brush $C_MUTE
  } else {
    $timeBlock.Foreground = Brush $C_DIM
  }

  $stack = New-Object Windows.Controls.StackPanel

  # 打勾表示完成，不删；要让它消失点最右的 ×。
  if ($editable -and -not $it.done) {
    $title = New-Object Windows.Controls.TextBox
    $title.Text = [string]$it.title
    $title.FontSize = 12.5
    $title.Foreground = Brush $C_TXT
    $title.Background = [Windows.Media.Brushes]::Transparent
    $title.BorderThickness = [Windows.Thickness]::new(0)
    $title.Padding = [Windows.Thickness]::new(0)
    $title.TextWrapping = 'Wrap'
    $title.AcceptsReturn = $false
    $title.Tag = [string]$it.id
    $title.Add_LostFocus({
      param($s, $e)
      $v = ([string]$s.Text).Trim()
      if ($v.Length -gt 0) { Patch-Item ([string]$s.Tag) @{ title = $v } }
    })
    $title.Add_KeyDown({
      param($s, $e)
      if ($e.Key -eq [Windows.Input.Key]::Return) {
        $v = ([string]$s.Text).Trim()
        if ($v.Length -gt 0) { Patch-Item ([string]$s.Tag) @{ title = $v } }
        $script:Win.Focus() | Out-Null
        $e.Handled = $true
      }
    })
    $stack.Children.Add($title) | Out-Null
  } else {
    $title = New-Text ([string]$it.title) 12.5 $C_TXT ''
    if ($it.done) {
      $title.Foreground = Brush $C_MUTE
      $title.TextDecorations = [Windows.TextDecorations]::Strikethrough
    }
    $stack.Children.Add($title) | Out-Null
  }

  # 事项：这件事具体要做哪几步。原文没写细分动作就没有这一行。
  $acts = @()
  if ($it.PSObject.Properties['actions'] -and $null -ne $it.actions) {
    $acts = @($it.actions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  }
  if ($acts.Count -gt 0) {
    $actLine = New-Text ($acts -join ' · ') 11 $C_TXT ''
    if ($it.done) { $actLine.Foreground = Brush $C_MUTE }
    $actLine.Margin = [Windows.Thickness]::new(0, 1, 0, 0)
    $stack.Children.Add($actLine) | Out-Null
  }

  $place = [string]$it.place
  if (-not [string]::IsNullOrWhiteSpace($place)) {
    $meta = New-Text $place 10.5 $C_DIM ''
    $meta.Margin = [Windows.Thickness]::new(0, 1, 0, 0)
    $stack.Children.Add($meta) | Out-Null
  }

  # 原话比右边那个「11/21 08:45」信息量大时（签到、正式开始这种），展开态再补一行。
  $whenText = [string]$it.timeText
  if ($editable -and -not [string]::IsNullOrWhiteSpace($whenText)) {
    $wt = New-Text ('时间 · ' + $whenText) 10.5 $C_DIM ''
    $wt.Margin = [Windows.Thickness]::new(0, 1, 0, 0)
    $stack.Children.Add($wt) | Out-Null
  }

  # 第四维：要求。老条目上没有这个键，别当成空数组去渲染。
  $reqs = @()
  if ($it.PSObject.Properties['requirements'] -and $null -ne $it.requirements) {
    $reqs = @($it.requirements | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  }
  if ($reqs.Count -gt 0) {
    if ($editable) {
      # 展开态全列出来，一条一行，前面带序号。
      for ($i = 0; $i -lt $reqs.Count; $i++) {
        $one = New-Text ('{0}. {1}' -f ($i + 1), [string]$reqs[$i]) 10.5 $C_DIM ''
        $one.Margin = [Windows.Thickness]::new(0, 2, 0, 0)
        $stack.Children.Add($one) | Out-Null
      }
    } else {
      # 折叠态只有 300 宽，塞不下整段：先露第一条，再报还有几条。
      $first = New-Text ('要求 · ' + [string]$reqs[0]) 10.5 $C_DIM ''
      $first.TextWrapping = [Windows.TextWrapping]::NoWrap
      $first.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
      $first.Margin = [Windows.Thickness]::new(0, 2, 0, 0)
      $first.Cursor = 'Hand'
      $first.Add_MouseLeftButtonUp({
        param($s, $e)
        $e.Handled = $true
        if ($script:Mode -ne 'expanded') { Set-Mode 'expanded' } else { Render-All }
      })
      $stack.Children.Add($first) | Out-Null
      if ($reqs.Count -gt 1) {
        $moreReq = New-Text ('还有 {0} 条要求 ›' -f ($reqs.Count - 1)) 10.5 $C_DIM ''
        $moreReq.Margin = [Windows.Thickness]::new(0, 1, 0, 0)
        $moreReq.Cursor = 'Hand'
        $moreReq.TextDecorations = [Windows.TextDecorations]::Underline
        $moreReq.Add_MouseLeftButtonUp({
          param($s, $e)
          $e.Handled = $true
          if ($script:Mode -ne 'expanded') { Set-Mode 'expanded' } else { Render-All }
        })
        $stack.Children.Add($moreReq) | Out-Null
      }
    }
  }

  # 同一段抽出多条时，要求只挂在其中一条上，其余指向它，不重复铺一遍。
  $reqRef = ''
  if ($it.PSObject.Properties['reqRef']) { $reqRef = [string]$it.reqRef }
  if (($reqs.Count -eq 0) -and ($reqRef -ne '')) {
    $ownerTitle = $reqRef
    if ($script:TitleById -and $script:TitleById.ContainsKey($reqRef)) {
      $ownerTitle = [string]$script:TitleById[$reqRef]
    }
    $refLine = New-Text ('要求见「' + $ownerTitle + '」') 10.5 $C_DIM ''
    $refLine.Margin = [Windows.Thickness]::new(0, 2, 0, 0)
    $refLine.Cursor = 'Hand'
    $refLine.Add_MouseLeftButtonUp({
      param($s, $e)
      $e.Handled = $true
      if ($script:Mode -ne 'expanded') { Set-Mode 'expanded' } else { Render-All }
    })
    $stack.Children.Add($refLine) | Out-Null
  }

  if ($editable) {
    $acts = New-Object Windows.Controls.StackPanel
    $acts.Orientation = 'Horizontal'
    $acts.Margin = [Windows.Thickness]::new(0, 2, 0, 0)
    $id = [string]$it.id
    $arch = New-Link '归档'
    $arch.Add_MouseLeftButtonUp({
      param($s, $e)
      Patch-Item $id @{ archived = $true }
      Render-All
    })
    $acts.Children.Add($arch) | Out-Null
    $stack.Children.Add($acts) | Out-Null
  }

  # 最右那个 × 才是删除；打勾只管完成。
  $kill = New-Object Windows.Controls.TextBlock
  $kill.Text = [string][char]0x00D7
  $kill.FontSize = 12
  $kill.Margin = [Windows.Thickness]::new(8, 2, 0, 0)
  $kill.VerticalAlignment = 'Top'
  $kill.Foreground = Brush $C_MUTE
  $kill.Cursor = 'Hand'
  $kill.Tag = [string]$it.id
  $kill.Add_MouseLeftButtonUp({
    param($s, $e)
    Remove-ItemById ([string]$s.Tag)
    Render-All
    $e.Handled = $true
  })

  [Windows.Controls.DockPanel]::SetDock($cb, [Windows.Controls.Dock]::Left)
  [Windows.Controls.DockPanel]::SetDock($kill, [Windows.Controls.Dock]::Right)
  [Windows.Controls.DockPanel]::SetDock($timeBlock, [Windows.Controls.Dock]::Right)
  $dp.Children.Add($cb) | Out-Null
  $dp.Children.Add($kill) | Out-Null
  $dp.Children.Add($timeBlock) | Out-Null
  $dp.Children.Add($stack) | Out-Null
  return $dp
}

function New-InputBox {
  $grid = New-Object Windows.Controls.Grid
  $grid.Margin = [Windows.Thickness]::new(0, 8, 0, 2)

  $tb = New-Object Windows.Controls.TextBox
  $tb.FontSize = 12
  $tb.Padding = [Windows.Thickness]::new(8, 6, 8, 6)
  $tb.Foreground = Brush $C_TXT
  $tb.Background = Brush $C_INPUT
  $tb.BorderThickness = [Windows.Thickness]::new(0)
  $tb.CaretBrush = Brush $C_TXT
  # 单行 TextBox 会把粘贴内容在第一个换行处截断，一整段通知只剩标题。
  # 必须 AcceptsReturn，多行才存得下；回车提交交给下面的 KeyDown，Shift+回车才是换行。
  $tb.AcceptsReturn = $true
  $tb.TextWrapping = [Windows.TextWrapping]::Wrap
  $tb.VerticalScrollBarVisibility = [Windows.Controls.ScrollBarVisibility]::Auto
  $tb.MinHeight = 34
  $tb.MaxHeight = 132
  $tb.Tag = 'input'
  # 界面每次重画都会换掉输入框，草稿得单独记着，否则「等 DSH」那段提示一出现就把它吞了。
  $tb.Text = [string]$script:Draft

  $hint = New-Object Windows.Controls.TextBlock
  $hint.Text = '粘一整段，回车提交'
  $hint.FontSize = 12
  $hint.Foreground = Brush $C_MUTE
  $hint.Margin = [Windows.Thickness]::new(9, 9, 0, 0)
  $hint.VerticalAlignment = 'Top'
  $hint.IsHitTestVisible = $false
  if ($script:Draft.Length -gt 0) { $hint.Visibility = 'Collapsed' }

  $tb.Add_TextChanged({
    param($s, $e)
    $script:Draft = [string]$s.Text
    $script:HintBox.Visibility = 'Collapsed'
    if ($s.Text.Length -eq 0) { $script:HintBox.Visibility = 'Visible' }
  })
  # 必须挂 PreviewKeyDown：AcceptsReturn 的 TextBox 在类处理器里先把回车吃掉了，
  # 挂 KeyDown 根本轮不到我们，回车只会换行。
  $tb.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq [Windows.Input.Key]::Return) {
      # Shift+回车留给换行，其余回车一律提交。
      if (($e.KeyboardDevice.Modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0) { return }
      $text = [string]$s.Text
      $s.Text = ''
      Submit-Text $text
      $e.Handled = $true
    }
  })

  $grid.Children.Add($tb) | Out-Null
  $grid.Children.Add($hint) | Out-Null
  $script:HintBox = $hint
  $script:InputBox = $tb
  return $grid
}

function New-PendingBlock {
  $box = New-Object Windows.Controls.StackPanel
  $box.Margin = [Windows.Thickness]::new(0, 6, 0, 2)

  $items = @($script:Pending.items)
  for ($i = 0; $i -lt $items.Count; $i++) {
    $p = $items[$i]
    $dp = New-Object Windows.Controls.DockPanel
    $dp.Margin = [Windows.Thickness]::new(0, 5, 0, 0)

    $cb = New-Object Windows.Controls.CheckBox
    $cb.IsChecked = $true
    $cb.VerticalAlignment = 'Top'
    $cb.Margin = [Windows.Thickness]::new(0, 3, 8, 0)
    $cb.Tag = [string]$i
    $cb.Add_Click({
      param($s, $e)
      $idx = [int]$s.Tag
      $script:Pending.items[$idx] | Add-Member -NotePropertyName keep -NotePropertyValue ([bool]$s.IsChecked) -Force
    })
    $dp.Children.Add($cb) | Out-Null
    [Windows.Controls.DockPanel]::SetDock($cb, [Windows.Controls.Dock]::Left)

    $when = ''
    if (Test-HasTime $p.time) { $when = Format-When $p.time }
    $tb2 = New-Text $when 10.5 $C_DIM ''
    $tb2.VerticalAlignment = 'Top'
    $tb2.Margin = [Windows.Thickness]::new(8, 3, 0, 0)
    [Windows.Controls.DockPanel]::SetDock($tb2, [Windows.Controls.Dock]::Right)
    $dp.Children.Add($tb2) | Out-Null

    $stack = New-Object Windows.Controls.StackPanel
    $t = New-Text ([string]$p.title) 12.5 $C_TXT ''
    $stack.Children.Add($t) | Out-Null
    $pacts = @()
    if ($p.PSObject.Properties['actions'] -and $null -ne $p.actions) {
      $pacts = @($p.actions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    if ($pacts.Count -gt 0) {
      $pal = New-Text ($pacts -join ' · ') 11 $C_TXT ''
      $pal.Margin = [Windows.Thickness]::new(0, 1, 0, 0)
      $stack.Children.Add($pal) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$p.place)) {
      $pl = New-Text ([string]$p.place) 10.5 $C_DIM ''
      $pl.Margin = [Windows.Thickness]::new(0, 1, 0, 0)
      $stack.Children.Add($pl) | Out-Null
    }
    # 存之前就让人看见要求，别等落库了才发现少了东西。
    if ($p.PSObject.Properties['requirements'] -and $null -ne $p.requirements) {
      $preqs = @($p.requirements | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
      for ($k = 0; $k -lt $preqs.Count; $k++) {
        $rl = New-Text ('{0}. {1}' -f ($k + 1), [string]$preqs[$k]) 10.5 $C_DIM ''
        $rl.Margin = [Windows.Thickness]::new(0, 2, 0, 0)
        $stack.Children.Add($rl) | Out-Null
      }
    }
    $dp.Children.Add($stack) | Out-Null
    $box.Children.Add($dp) | Out-Null
  }

  $btns = New-Object Windows.Controls.StackPanel
  $btns.Orientation = 'Horizontal'
  $btns.Margin = [Windows.Thickness]::new(0, 8, 0, 0)

  $save = New-Object Windows.Controls.Button
  $save.Content = '保存'
  $save.FontSize = 11.5
  $save.Padding = [Windows.Thickness]::new(14, 5, 14, 5)
  $save.BorderThickness = [Windows.Thickness]::new(0)
  $save.Background = Brush $C_TXT
  $save.Foreground = Brush $C_BG
  $save.Cursor = 'Hand'
  $save.Add_Click({ Save-Pending })
  $btns.Children.Add($save) | Out-Null

  $cancel = New-Object Windows.Controls.Button
  $cancel.Content = '取消'
  $cancel.FontSize = 11.5
  $cancel.Padding = [Windows.Thickness]::new(14, 5, 14, 5)
  $cancel.Margin = [Windows.Thickness]::new(8, 0, 0, 0)
  $cancel.BorderThickness = [Windows.Thickness]::new(0)
  $cancel.Background = Brush $C_INPUT
  $cancel.Foreground = Brush $C_DIM
  $cancel.Cursor = 'Hand'
  $cancel.Add_Click({
    $script:Pending = $null
    $script:Msg = ''
    Render-All
  })
  $btns.Children.Add($cancel) | Out-Null

  $box.Children.Add($btns) | Out-Null
  return $box
}

function Save-Pending {
  $items = @($script:Pending.items)
  $ids = @{}
  $n = 0
  for ($i = 0; $i -lt $items.Count; $i++) {
    $p = $items[$i]
    # 没勾的就不存：勾选状态在 Pending 里用 keep 标着。
    if ($p.PSObject.Properties['keep'] -and -not $p.keep) { continue }
    $reqs = $null
    if ($p.PSObject.Properties['requirements']) { $reqs = $p.requirements }
    $acts = $null
    if ($p.PSObject.Properties['actions']) { $acts = $p.actions }
    $newId = Add-Item ([string]$p.title) $p.time ([string]$p.place) ([string]$p.timeText) $reqs $acts
    $ids[[string]$i] = [string]$newId
    $n += 1
  }
  # 要求只在一条上，其余记下挂在谁身上。reqOf 是这批里的下标。
  for ($i = 0; $i -lt $items.Count; $i++) {
    $p = $items[$i]
    if ($p.PSObject.Properties['keep'] -and -not $p.keep) { continue }
    if (-not ($p.PSObject.Properties['reqOf'])) { continue }
    $me = [string]$i
    $owner = [string]$p.reqOf
    if (-not $ids.ContainsKey($me)) { continue }
    if (-not $ids.ContainsKey($owner)) { continue }
    Patch-Item $ids[$me] @{ reqRef = $ids[$owner] }
  }
  $script:Pending = $null
  $script:Msg = ''
  if ($n -eq 0) { $script:Msg = '一条都没勾，没存' }
  Render-All
}

# ---- 视图 ----

function Render-Header {
  $head = New-Object Windows.Controls.DockPanel
  $head.LastChildFill = $false
  $head.Margin = [Windows.Thickness]::new(0, 2, 0, 2)
  # DockPanel 的 Background 默认是 $null，空处不参与命中测试，
  # 结果只有正好压在「待办」那几个字上才拖得动。给个 Transparent 整条才算可抓。
  $head.Background = [Windows.Media.Brushes]::Transparent
  $head.MinHeight = 20
  $head.Cursor = 'SizeAll'
  $head.Add_MouseLeftButtonDown({
    try {
      $script:Win.DragMove()
      Save-Position
    } catch { }
  })

  $label = New-Text '待办' 12.5 $C_TXT 'SemiBold'
  [Windows.Controls.DockPanel]::SetDock($label, [Windows.Controls.Dock]::Left)

  $close = New-Object Windows.Controls.TextBlock
  $close.Text = [string][char]0x00D7
  $close.FontSize = 13
  $close.Padding = [Windows.Thickness]::new(6, 0, 0, 0)
  $close.Foreground = Brush $C_MUTE
  $close.Cursor = 'Hand'
  $close.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $script:Win.Close()
  })
  [Windows.Controls.DockPanel]::SetDock($close, [Windows.Controls.Dock]::Right)

  $toggle = New-Object Windows.Controls.TextBlock
  $toggle.Text = [string][char]0x25A6
  $toggle.FontSize = 12
  $toggle.Padding = [Windows.Thickness]::new(6, 0, 0, 0)
  $toggle.Foreground = Brush $C_DIM
  $toggle.Cursor = 'Hand'
  $toggle.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    if ($script:Mode -eq 'expanded') { Set-Mode 'collapsed' } else { Set-Mode 'expanded' }
  })
  [Windows.Controls.DockPanel]::SetDock($toggle, [Windows.Controls.Dock]::Right)

  $head.Children.Add($label) | Out-Null
  $head.Children.Add($close) | Out-Null
  $head.Children.Add($toggle) | Out-Null
  $script:Panel.Children.Add($head) | Out-Null
}

function Render-Status {
  if ([string]::IsNullOrWhiteSpace($script:Msg)) { return }
  $t = New-Text $script:Msg 10.5 $C_DIM ''
  $t.Margin = [Windows.Thickness]::new(0, 6, 0, 0)
  $script:Panel.Children.Add($t) | Out-Null
}

function Render-Collapsed {
  $items = @()
  if ($null -ne $script:State -and $null -ne $script:State.items) { $items = @($script:State.items) }
  # 完成的不从列表里消失，只是变灰划掉、沉到最后。
  $rows = Sorted-Rows $items
  if ($rows.Count -eq 0) {
    $t = New-Text '还没有待办' 11.5 $C_DIM ''
    $t.Margin = [Windows.Thickness]::new(0, 6, 0, 0)
    $script:Panel.Children.Add($t) | Out-Null
    return
  }
  $shown = 0
  foreach ($r in $rows) {
    if ($shown -ge 6) { break }
    $script:Panel.Children.Add((New-ItemRow $r.item $false)) | Out-Null
    $shown += 1
  }
  if ($rows.Count -gt 6) {
    $more = New-Link ('还有 {0} 条' -f ($rows.Count - 6))
    $more.Margin = [Windows.Thickness]::new(0, 8, 0, 0)
    $more.Add_MouseLeftButtonUp({ Set-Mode 'expanded' })
    $script:Panel.Children.Add($more) | Out-Null
  }
}

function Render-Tabs {
  $bar = New-Object Windows.Controls.StackPanel
  $bar.Orientation = 'Horizontal'
  $bar.Margin = [Windows.Thickness]::new(0, 8, 0, 6)

  foreach ($pair in @(@('list', '列表'), @('month', '月历'))) {
    $key = $pair[0]; $text = $pair[1]
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $text
    $t.FontSize = 11.5
    $t.Padding = [Windows.Thickness]::new(0, 3, 16, 3)
    $t.Cursor = 'Hand'
    if ($script:Tab -eq $key) { $t.Foreground = Brush $C_TXT } else { $t.Foreground = Brush $C_DIM }
    $t.Tag = $key
    $t.Add_MouseLeftButtonUp({
      param($s, $e)
      $script:Tab = [string]$s.Tag
      $script:PickedDay = $null
      Render-All
    })
    $bar.Children.Add($t) | Out-Null
  }
  $script:Panel.Children.Add($bar) | Out-Null
}

function Render-ExpandedList {
  $items = @()
  if ($null -ne $script:State -and $null -ne $script:State.items) { $items = @($script:State.items) }

  $unscheduled = @($items | Where-Object { -not $_.archived -and -not (Test-HasTime $_.time) })
  if ($unscheduled.Count -gt 0) {
    $h = New-Text '待安排' 10.5 $C_MUTE ''
    $h.Margin = [Windows.Thickness]::new(0, 2, 0, 2)
    $script:Panel.Children.Add($h) | Out-Null
    foreach ($it in $unscheduled) {
      $script:Panel.Children.Add((New-ItemRow $it $true)) | Out-Null
    }
  }

  $rows = Sorted-Rows ($items | Where-Object { Test-HasTime $_.time })
  if ($rows.Count -eq 0) {
    $t = New-Text '还没有待办' 11.5 $C_DIM ''
    $t.Margin = [Windows.Thickness]::new(0, 6, 0, 0)
    $script:Panel.Children.Add($t) | Out-Null
    return
  }
  foreach ($r in $rows) {
    $script:Panel.Children.Add((New-ItemRow $r.item $true)) | Out-Null
  }
}

function Get-LocalDay($ts) {
  return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ts).ToLocalTime().Date
}

function Render-Month {
  $nav = New-Object Windows.Controls.DockPanel
  $nav.LastChildFill = $false
  $nav.Margin = [Windows.Thickness]::new(0, 2, 0, 6)

  $prev = New-Link '‹'
  $prev.FontSize = 14
  $prev.Add_MouseLeftButtonUp({ shiftMonth -1 })
  [Windows.Controls.DockPanel]::SetDock($prev, [Windows.Controls.Dock]::Left)
  $next = New-Link '›'
  $next.FontSize = 14
  $next.Add_MouseLeftButtonUp({ shiftMonth 1 })
  [Windows.Controls.DockPanel]::SetDock($next, [Windows.Controls.Dock]::Right)
  $titleT = New-Text ('{0} 年 {1} 月' -f $script:ViewYear, $script:ViewMonth) 12 $C_TXT 'SemiBold'
  $titleT.HorizontalAlignment = 'Center'
  $nav.Children.Add($prev) | Out-Null
  $nav.Children.Add($next) | Out-Null
  $nav.Children.Add($titleT) | Out-Null
  $script:Panel.Children.Add($nav) | Out-Null

  $wk = New-Object Windows.Controls.Primitives.UniformGrid
  $wk.Columns = 7
  $wk.Margin = [Windows.Thickness]::new(0, 0, 0, 4)
  foreach ($w in @('一', '二', '三', '四', '五', '六', '日')) {
    $t = New-Text $w 10 $C_MUTE ''
    $t.HorizontalAlignment = 'Center'
    $wk.Children.Add($t) | Out-Null
  }
  $script:Panel.Children.Add($wk) | Out-Null

  $items = @()
  if ($null -ne $script:State -and $null -ne $script:State.items) { $items = @($script:State.items) }
  $byDay = @{}
  foreach ($it in $items) {
    if ($it.archived) { continue }
    if (-not (Test-HasTime $it.time)) { continue }
    $d = Get-LocalDay $it.time
    $k = $d.ToString('yyyy-MM-dd')
    if (-not $byDay.ContainsKey($k)) { $byDay[$k] = @() }
    $byDay[$k] = @($byDay[$k]) + $it
  }

  $first = New-Object DateTime($script:ViewYear, $script:ViewMonth, 1)
  $offset = (([int]$first.DayOfWeek) + 6) % 7
  $start = $first.AddDays(-$offset)

  $grid = New-Object Windows.Controls.Primitives.UniformGrid
  $grid.Columns = 7
  $grid.Rows = 6
  $grid.Height = 300

  for ($i = 0; $i -lt 42; $i++) {
    $day = $start.AddDays($i)
    $k = $day.ToString('yyyy-MM-dd')
    $cell = New-Object Windows.Controls.Border
    $cell.BorderThickness = [Windows.Thickness]::new(0, 0, 1, 1)
    $cell.BorderBrush = Brush $C_CELL
    $cell.Padding = [Windows.Thickness]::new(4, 3, 3, 3)
    $cell.Tag = $day.ToString('yyyy-MM-dd')
    $cell.Cursor = 'Hand'
    # 相邻两天交替底色：7 列是奇数，按格序取模正好得到棋盘格，
    # 横竖两个方向的邻居都不同色。今日/选中态优先，覆盖在上面。
    # 没有底色的 Border 不参与命中测试，空白格就只剩数字能吃点击；
    # 所以每格都得给画刷，不用交替色的那种给 Transparent。
    if (($i % 2) -eq 0) { $cell.Background = Brush $C_ALT } else { $cell.Background = [Windows.Media.Brushes]::Transparent }
    if ($day.Month -ne $script:ViewMonth) { $cell.Opacity = 0.45 }
    if ($day.Date -eq $script:Today) { $cell.Background = Brush $C_TODAY }
    if ($null -ne $script:PickedDay -and $day.Date -eq ([datetime]$script:PickedDay).Date) {
      $cell.Background = Brush $C_PICKED
    }
    $cell.Add_MouseLeftButtonUp({
      param($s, $e)
      $script:PickedDay = [datetime]::ParseExact([string]$s.Tag, 'yyyy-MM-dd', $null)
      Render-All
    })

    $inner = New-Object Windows.Controls.StackPanel
    $num = New-Text ([string]$day.Day) 9.5 $C_DIM ''
    $inner.Children.Add($num) | Out-Null

    if ($byDay.ContainsKey($k)) {
      $list = @($byDay[$k])
      $max = 2
      for ($j = 0; $j -lt [Math]::Min($max, $list.Count); $j++) {
        $line = New-Text ([string]$list[$j].title) 8.5 $C_TXT ''
        $line.TextTrimming = 'CharacterEllipsis'
        $line.TextWrapping = 'NoWrap'
        $line.Margin = [Windows.Thickness]::new(0, 1, 0, 0)
        $inner.Children.Add($line) | Out-Null
      }
      if ($list.Count -gt $max) {
        $more = New-Text ('+{0}' -f ($list.Count - $max)) 8.5 $C_DIM ''
        $inner.Children.Add($more) | Out-Null
      }
    }
    $cell.Child = $inner
    $grid.Children.Add($cell) | Out-Null
  }
  $script:Panel.Children.Add($grid) | Out-Null

  if ($null -ne $script:PickedDay) {
    Render-DayPanel ($byDay)
  }
}

function Render-DayPanel($byDay) {
  $d = [datetime]$script:PickedDay
  $k = $d.ToString('yyyy-MM-dd')
  $sep = New-Object Windows.Controls.Border
  $sep.Height = 1
  $sep.Background = Brush $C_LINE
  $sep.Margin = [Windows.Thickness]::new(0, 10, 0, 8)
  $script:Panel.Children.Add($sep) | Out-Null

  $head = New-Text ('{0} 月 {1} 日' -f $d.Month, $d.Day) 11.5 $C_TXT 'SemiBold'
  $script:Panel.Children.Add($head) | Out-Null

  $list = @()
  if ($byDay.ContainsKey($k)) { $list = @($byDay[$k]) }
  if ($list.Count -eq 0) {
    $t = New-Text '这天没有安排' 10.5 $C_DIM ''
    $t.Margin = [Windows.Thickness]::new(0, 4, 0, 0)
    $script:Panel.Children.Add($t) | Out-Null
  } else {
    foreach ($it in $list) {
      $script:Panel.Children.Add((New-ItemRow $it $true)) | Out-Null
    }
  }

  $box = New-Object Windows.Controls.TextBox
  $box.FontSize = 11.5
  $box.Padding = [Windows.Thickness]::new(8, 5, 8, 5)
  $box.Margin = [Windows.Thickness]::new(0, 8, 0, 0)
  $box.Foreground = Brush $C_TXT
  $box.Background = Brush $C_INPUT
  $box.BorderThickness = [Windows.Thickness]::new(0)
  $box.CaretBrush = Brush $C_TXT
  $box.Tag = $k
  $box.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [Windows.Input.Key]::Return) {
      $v = ([string]$s.Text).Trim()
      if ($v.Length -gt 0) {
        $day = [datetime]::ParseExact([string]$s.Tag, 'yyyy-MM-dd', $null)
        $ts = [DateTimeOffset]::new($day.Date).ToUnixTimeMilliseconds()
        Add-Item $v $ts '' '' | Out-Null
        $s.Text = ''
        Render-All
      }
      $e.Handled = $true
    }
  })
  $script:Panel.Children.Add($box) | Out-Null
}

function shiftMonth([int]$delta) {
  $m = $script:ViewMonth + $delta
  $y = $script:ViewYear
  while ($m -lt 1) { $m += 12; $y -= 1 }
  while ($m -gt 12) { $m -= 12; $y += 1 }
  $script:ViewMonth = $m
  $script:ViewYear = $y
  Render-All
}

function Render-All {
  $script:State = Read-State
  $script:TitleById = @{}
  foreach ($x in @($script:State.items)) {
    if ($null -ne $x.id) { $script:TitleById[[string]$x.id] = [string]$x.title }
  }
  $script:Panel.Children.Clear()
  Render-Header

  if ($script:Mode -eq 'expanded') {
    Render-Tabs
  }

  $script:Panel.Children.Add((New-InputBox)) | Out-Null
  Render-Status

  if ($null -ne $script:Pending) {
    $script:Panel.Children.Add((New-PendingBlock)) | Out-Null
    return
  }

  if ($script:Mode -eq 'collapsed') {
    Render-Collapsed
  } else {
    if ($script:Tab -eq 'month') { Render-Month } else { Render-ExpandedList }
  }
}

function Set-Mode([string]$mode) {
  $script:Mode = $mode
  if ($mode -eq 'expanded') {
    $script:Win.SizeToContent = [Windows.SizeToContent]::Manual
    $script:Win.Width = 880
    $script:Win.Height = 620
    # 靠右放的时候展开会顶出屏幕，往左挪回来。
    $area = [Windows.SystemParameters]::WorkArea
    if ($script:Win.Left + 880 -gt $area.Width) { $script:Win.Left = [Math]::Max(0, $area.Width - 900) }
    if ($script:Win.Top + 620 -gt $area.Height) { $script:Win.Top = [Math]::Max(0, $area.Height - 640) }
  } else {
    $script:Win.Height = [double]::NaN
    $script:Win.SizeToContent = [Windows.SizeToContent]::Height
    $script:Win.Width = 300
    $script:PickedDay = $null
  }
  Render-All
}


function Export-Json {
  $dlg = New-Object Microsoft.Win32.SaveFileDialog
  $dlg.FileName = ('待办-{0}.json' -f (Get-Date -Format 'yyyyMMdd'))
  $dlg.Filter = 'JSON (*.json)|*.json'
  if ($dlg.ShowDialog() -ne $true) { return }
  $st = Read-State
  $out = @()
  foreach ($it in @($st.items)) {
    $when = ''
    if (Test-HasTime $it.time) { $when = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$it.time).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    $state = '未完成'
    if ($it.archived) { $state = '已归档' } elseif ($it.done) { $state = '已完成' }
    $reqs = @()
    if ($it.PSObject.Properties['requirements'] -and $null -ne $it.requirements) {
      $reqs = @($it.requirements | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    }
    $acts = @()
    if ($it.PSObject.Properties['actions'] -and $null -ne $it.actions) {
      $acts = @($it.actions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    }
    $out += [pscustomobject]@{
      标题 = [string]$it.title
      事项 = ($acts -join '、')
      地点 = [string]$it.place
      时间 = $when
      原话 = [string]$it.timeText
      要求 = $reqs
      状态 = $state
    }
  }
  [IO.File]::WriteAllText($dlg.FileName, ($out | ConvertTo-Json -Depth 5), $script:Enc)
}

# ---- 窗口 ----

$win = New-Object Windows.Window
$win.WindowStyle = [Windows.WindowStyle]::None
$win.ResizeMode = [Windows.ResizeMode]::NoResize
$win.BorderThickness = [Windows.Thickness]::new(0)
# 不用分层透明窗口：这台机器上 AllowsTransparency=true 的窗口画得出来但桌面上看不见。
$win.AllowsTransparency = $false
$win.Background = Brush $C_BG
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.SizeToContent = [Windows.SizeToContent]::Height
$win.Width = 300
$win.WindowStartupLocation = [Windows.WindowStartupLocation]::Manual
$win.FontFamily = 'Microsoft YaHei UI'
$win.Title = 'todo-note-window'
$script:Win = $win

# 回车提交放在窗口这一层做。文本框自己是 AcceptsReturn，回车在它的类处理器里
# 就被吃掉了；窗口的 PreviewKeyDown 是最先拿到事件的，抢得到。
$win.Add_PreviewKeyDown({
  param($s, $e)
  if ($e.Key -ne [Windows.Input.Key]::Return) { return }
  if (($e.KeyboardDevice.Modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0) { return }
  $box = $script:InputBox
  if ($null -eq $box) { return }
  if (-not $box.IsKeyboardFocusWithin) { return }
  $text = [string]$box.Text
  $box.Text = ''
  Submit-Text $text
  $e.Handled = $true
})

$card = New-Object Windows.Controls.Border
$card.CornerRadius = [Windows.CornerRadius]::new(10)
$card.BorderThickness = [Windows.Thickness]::new(1)
$card.BorderBrush = Brush $C_LINE
$card.Background = Brush $C_BG
$card.Padding = [Windows.Thickness]::new(10, 8, 10, 10)
$script:CardRef = $card
$win.Content = $card

$scroll = New-Object Windows.Controls.ScrollViewer
$scroll.VerticalScrollBarVisibility = 'Auto'
$scroll.HorizontalScrollBarVisibility = 'Disabled'
$card.Child = $scroll

$panel = New-Object Windows.Controls.StackPanel
$scroll.Content = $panel
$script:Panel = $panel

$area = [Windows.SystemParameters]::WorkArea
$px = $area.Width - 340
$py = $area.Height - 300
$script:SavedTheme = ''
if (Test-Path -LiteralPath $script:PosFile) {
  try {
    $saved = [IO.File]::ReadAllText($script:PosFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($null -ne $saved -and $null -ne $saved.x) {
      $px = [double]$saved.x
      $py = [double]$saved.y
    }
    if ($null -ne $saved -and $null -ne $saved.theme) { $script:SavedTheme = [string]$saved.theme }
  } catch { }
}
# 环境里给了就优先，方便出验收快照时指定配色。
if (-not [string]::IsNullOrWhiteSpace($env:TODO_NOTE_THEME)) { $script:SavedTheme = $env:TODO_NOTE_THEME }
if (-not [string]::IsNullOrWhiteSpace($script:SavedTheme)) {
  Apply-Theme $script:SavedTheme
  $win.Background = Brush $C_BG
  $card.Background = Brush $C_BG
  $card.BorderBrush = Brush $C_LINE
}
if ($px -lt 0 -or $px -gt ($area.Width - 120)) { $px = $area.Width - 340 }
if ($py -lt 0 -or $py -gt ($area.Height - 80)) { $py = $area.Height - 300 }
$win.Left = $px
$win.Top = $py

$ctxMenu = New-Object Windows.Controls.ContextMenu
$miRefresh = New-Object Windows.Controls.MenuItem
$miRefresh.Header = '刷新'
$miRefresh.Add_Click({ Render-All })
$miExport = New-Object Windows.Controls.MenuItem
$miExport.Header = '导出'
$miExport.Add_Click({ Export-Json })
# 背景色：整套配色一起换，不是只换底色。
# 子项必须在建菜单时就填进去。空着的 MenuItem 在 WPF 里不会展开子菜单，
# 靠 SubmenuOpened 再去塞条目，那一下永远等不到。
$miTheme = New-Object Windows.Controls.MenuItem
$miTheme.Header = '背景色'
foreach ($k in @($script:Themes.Keys)) {
  $mi = New-Object Windows.Controls.MenuItem
  $mi.Header = $script:Themes[$k].label
  $mi.IsCheckable = $true
  $mi.Tag = $k
  $mi.Add_Click({
    param($s, $e)
    Set-Theme ([string]$s.Tag)
  })
  $miTheme.Items.Add($mi) | Out-Null
}
# 每次打开右键菜单顺手对齐勾选状态，条目本身不重建。
$miTheme.Add_SubmenuOpened({
  foreach ($it in $miTheme.Items) {
    if ($null -ne $it.Tag) { $it.IsChecked = ([string]$it.Tag -eq $script:ThemeKey) }
  }
})
$miQuit = New-Object Windows.Controls.MenuItem
$miQuit.Header = '退出'
$miQuit.Add_Click({ $script:Win.Close() })
$ctxMenu.Items.Add($miRefresh) | Out-Null
$ctxMenu.Items.Add($miExport) | Out-Null
$ctxMenu.Items.Add($miTheme) | Out-Null
$ctxMenu.Items.Add($miQuit) | Out-Null
$card.ContextMenu = $ctxMenu

Render-All

# 粘进来先交给信箱，拆好了再刷新界面。
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
  Poll-Result
  if ((Test-Path -LiteralPath $script:DataFile)) {
    $stamp = (Get-Item -LiteralPath $script:DataFile).LastWriteTimeUtc
    if ($stamp -ne $script:Stamp) {
      $script:Stamp = $stamp
      Render-All
    }
  }
})
$timer.Start()

$probe = New-Object Windows.Threading.DispatcherTimer
$probe.Interval = [TimeSpan]::FromSeconds(2)
$probe.Add_Tick({
  $probe.Stop()
  Log ('probe visible=' + $win.IsVisible + ' actual=' + [int]$win.ActualWidth + 'x' + [int]$win.ActualHeight + ' at ' + [int]$win.Left + ',' + [int]$win.Top + ' children=' + $panel.Children.Count)
  if ($env:TODO_NOTE_SNAP -eq '1') {
    try {
      $wpx = [int]$win.ActualWidth
      $hpx = [int]$win.ActualHeight
      $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($wpx, $hpx, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
      $rtb.Render($win.Content)
      $coder = New-Object Windows.Media.Imaging.PngBitmapEncoder
      $coder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
      $fs = [IO.File]::Create((Join-Path $env:TEMP 'snap.png'))
      $coder.Save($fs)
      $fs.Close()
      Log ('snap ' + $wpx + 'x' + $hpx)
    } catch {
      Log ('snap failed ' + $_.Exception.Message)
    }
  }
})
$probe.Start()

Log ('show at ' + [int]$win.Left + ',' + [int]$win.Top + ' w=' + [int]$win.Width + ' items=' + (@($script:State.items)).Count)

# 只为自检：让窗口把某个形态渲成图片再退出，不用盯着屏幕看。
$script:SnapMode = [string]$env:TODO_NOTE_SNAP
if ($script:SnapMode -eq 'list' -or $script:SnapMode -eq 'month' -or $script:SnapMode -eq 'pending') {
  $snapTimer = New-Object Windows.Threading.DispatcherTimer
  $snapTimer.Interval = [TimeSpan]::FromMilliseconds(900)
  $snapTimer.Add_Tick({
    $snapTimer.Stop()
    if ($script:SnapMode -eq 'month') { $script:Tab = 'month' }
    if ($script:SnapMode -eq 'pending') {
      $script:Pending = [pscustomobject]@{
        text = ''
        items = @(
          [pscustomobject]@{ title = '参加学院第14期青廉读书会并担任点评嘉宾'; place = '学院学科馆'; time = [double]1794652800000; timeText = '11月11日 16:00' }
          [pscustomobject]@{ title = '把调研提纲发到群里'; place = ''; time = $null; timeText = '' }
        )
      }
      $script:Msg = '拆出 2 条，勾中的才存'
    } else {
      Set-Mode 'expanded'
    }
    Render-All
    $script:InnerTimer = New-Object Windows.Threading.DispatcherTimer
    $script:InnerTimer.Interval = [TimeSpan]::FromMilliseconds(800)
    $script:InnerTimer.Add_Tick({
      $script:InnerTimer.Stop()
      try {
        $wpx = [int]$win.ActualWidth
        $hpx = [int]$win.ActualHeight
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($wpx, $hpx, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($win.Content)
        $coder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $coder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create((Join-Path $env:TEMP ('snap-' + $script:SnapMode + '.png')))
        $coder.Save($fs)
        $fs.Close()
        Log ('snap ' + $script:SnapMode + ' ' + $wpx + 'x' + $hpx)
      } catch {
        Log ('snap failed ' + $_.Exception.Message)
      }
      $script:Win.Close()
    })
    $script:InnerTimer.Start()
  })
  $snapTimer.Start()
}

[void]$win.ShowDialog()
