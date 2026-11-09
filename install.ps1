#Requires -Version 5.1
<#
    安装桌面待办卡片。

    - 注册一个登录时自动运行的计划任务（不依赖 DSH 是否开着）
    - 在桌面放一个快捷方式，想手动开就双击它

    重复运行是安全的：任务和快捷方式都会被覆盖，不会堆出多份。
#>
[CmdletBinding()]
param(
    [switch]$NoShortcut,
    [string]$TaskName = 'DSH Todo Note'
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$vbs = Join-Path $root 'desktop\start-note.vbs'
$ps1 = Join-Path $root 'desktop\desktop-note.ps1'

if (-not (Test-Path $vbs)) { throw "缺少文件：$vbs" }
if (-not (Test-Path $ps1)) { throw "缺少文件：$ps1" }

$dataDir = Join-Path $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }) 'todo-note'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

# ── 计划任务 ─────────────────────────────────────────────
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"')
$user = $env:USERDOMAIN + '\' + $env:USERNAME
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Description '桌面待办卡片（dsh-todo-note）' -Force | Out-Null
Write-Host "已注册计划任务：$TaskName"

# ── 桌面快捷方式 ─────────────────────────────────────────
if (-not $NoShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop) {
        $lnk = Join-Path $desktop '待办小窗.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($lnk)
        $sc.TargetPath = "$env:SystemRoot\System32\wscript.exe"
        $sc.Arguments = '"' + $vbs + '"'
        $sc.WorkingDirectory = $root
        $sc.WindowStyle = 7
        $sc.Description = '桌面待办卡片'
        $sc.Save()
        Write-Host "已创建快捷方式：$lnk"
    }
}

# ── 现在就跑起来 ─────────────────────────────────────────
Start-ScheduledTask -TaskName $TaskName
Write-Host "已启动。数据目录：$dataDir"
Write-Host "若看不到卡片，看数据目录里的 run.log。"
