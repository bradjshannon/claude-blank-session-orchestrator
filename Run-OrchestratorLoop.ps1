#Requires -Version 5.1
<#
.SYNOPSIS
    No-admin alternative to the scheduled task: a long-lived loop that runs the
    blank-session worker every -IntervalMinutes. Intended to be launched hidden at
    logon (see Install-StartupLoop.ps1).

.DESCRIPTION
    Self-healing: on every cycle it ensures the per-user Startup shortcut points at THIS
    script's current location ($PSCommandPath). So if the repo folder is moved, the next
    time the loop runs from the new location it rewrites the shortcut to match -- a move
    can no longer silently break auto-start.
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 3,
    [int]$TargetBlank = 1
)

$ErrorActionPreference = 'Stop'

$worker = Join-Path $PSScriptRoot 'Ensure-BlankSession.ps1'
$loopScript = $PSCommandPath
$orchDir = Join-Path $env:USERPROFILE '.claude\orchestrator'
$logPath = Join-Path $orchDir 'loop.log'

function Repair-StartupShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LoopScript,
        [int]$Interval
    )
    # Returns $true if the shortcut was (re)written this call, else $false.
    try {
        $linkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude-BlankSessionOrchestrator.lnk'
        $pwshCmd = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
        $pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Command -Name 'powershell').Source }
        $desiredArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -IntervalMinutes {1}' -f $LoopScript, $Interval

        $shell = New-Object -ComObject WScript.Shell
        if (Test-Path -LiteralPath $linkPath) {
            $existing = $shell.CreateShortcut($linkPath)
            if ($existing.TargetPath -eq $pwshPath -and $existing.Arguments -eq $desiredArgs) {
                return $false
            }
        }
        $sc = $shell.CreateShortcut($linkPath)
        $sc.TargetPath = $pwshPath
        $sc.Arguments = $desiredArgs
        $sc.WorkingDirectory = Split-Path -Parent $LoopScript
        $sc.WindowStyle = 7  # minimized
        $sc.Description = 'Keeps a blank Remote-Control Claude session available'
        $sc.Save()
        return $true
    } catch {
        return $false
    }
}

if (-not (Test-Path -LiteralPath $worker)) {
    throw "Worker script not found at $worker"
}
if (-not (Test-Path -LiteralPath $orchDir)) {
    New-Item -ItemType Directory -Path $orchDir -Force | Out-Null
}

while ($true) {
    $healed = Repair-StartupShortcut -LoopScript $loopScript -Interval $IntervalMinutes
    try {
        & $worker -TargetBlank $TargetBlank | Out-Null
        $msg = 'cycle ok'
    } catch {
        $msg = 'ERROR ' + $_.Exception.Message
    }
    if ($healed) { $msg += ' (startup shortcut repaired)' }
    $stamp = '{0:yyyy-MM-dd HH:mm:ss} [INFO] {1}' -f (Get-Date), $msg
    try { Add-Content -Path $logPath -Value $stamp -Encoding utf8 } catch { }
    Start-Sleep -Seconds ($IntervalMinutes * 60)
}
