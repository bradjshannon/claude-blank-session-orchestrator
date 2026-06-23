#Requires -Version 7.0
<#
.SYNOPSIS
    No-admin alternative to the scheduled task: a long-lived loop that runs the
    blank-session worker every -IntervalMinutes. Intended to be launched hidden at
    logon (see Install-StartupLoop.ps1).
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 3,
    [int]$TargetBlank = 1
)

$ErrorActionPreference = 'Stop'

$worker = Join-Path $PSScriptRoot 'Ensure-BlankSession.ps1'
$logPath = Join-Path (Join-Path $env:USERPROFILE '.claude\orchestrator') 'loop.log'

if (-not (Test-Path -LiteralPath $worker)) {
    throw "Worker script not found at $worker"
}

while ($true) {
    try {
        & $worker -TargetBlank $TargetBlank | Out-Null
        $stamp = '{0:yyyy-MM-dd HH:mm:ss} [INFO] cycle ok' -f (Get-Date)
    } catch {
        $stamp = '{0:yyyy-MM-dd HH:mm:ss} [ERROR] {1}' -f (Get-Date), $_.Exception.Message
    }
    try { Add-Content -Path $logPath -Value $stamp -Encoding utf8 } catch { }
    Start-Sleep -Seconds ($IntervalMinutes * 60)
}
