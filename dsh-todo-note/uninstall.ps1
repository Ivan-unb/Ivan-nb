#Requires -Version 5.1
<#
    卸载桌面待办卡片。

    会停掉卡片进程、删掉计划任务和桌面快捷方式。
    不会删你的数据——待办还留在数据目录里，想彻底清掉就自己删那个文件夹。
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'DSH Todo Note'
)

$ErrorActionPreference = 'Stop'

$dataDir = Join-Path $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }) 'todo-note'

# ── 停掉卡片进程 ─────────────────────────────────────────
$procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*desktop-note.ps1*' }

foreach ($p in $procs) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        Write-Host "已结束进程：$($p.ProcessId)"
    } catch {
        Write-Warning "结束进程 $($p.ProcessId) 失败：$($_.Exception.Message)"
    }
}
if (-not $procs) { Write-Host '没有正在运行的卡片。' }

# ── 计划任务 ─────────────────────────────────────────────
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "已删除计划任务：$TaskName"
} else {
    Write-Host "计划任务不存在：$TaskName"
}

# ── 桌面快捷方式 ─────────────────────────────────────────
$desktop = [Environment]::GetFolderPath('Desktop')
if ($desktop) {
    $lnk = Join-Path $desktop '待办小窗.lnk'
    if (Test-Path $lnk) {
        Remove-Item $lnk -Force
        Write-Host "已删除快捷方式：$lnk"
    }
}

Write-Host ''
Write-Host "数据保留在：$dataDir"
Write-Host '要一起删掉，执行：'
Write-Host "    Remove-Item -Recurse -Force `"$dataDir`""
Write-Host ''
Write-Host '插件本体还在 DSH 的 profile 里，要用 dsh plugin 命令移除。'
