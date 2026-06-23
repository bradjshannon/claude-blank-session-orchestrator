#Requires -Version 7.0
<#
.SYNOPSIS
    Register (or remove) the scheduled task that keeps a blank Remote-Control
    Claude session available.

.DESCRIPTION
    Creates a per-user scheduled task that runs Ensure-BlankSession.ps1 at logon and
    every -IntervalMinutes thereafter. Uses Interactive logon type so spawned sessions
    attach to the user's desktop (required for Remote Control to register correctly).

.EXAMPLE
    pwsh -File .\Install-Orchestrator.ps1 -DryRun
    pwsh -File .\Install-Orchestrator.ps1 -IntervalMinutes 3
    pwsh -File .\Install-Orchestrator.ps1 -Remove
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 3,
    [string]$TaskName = 'Claude-BlankSessionOrchestrator',
    [switch]$Remove,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

try {
    $workerPath = Join-Path $PSScriptRoot 'Ensure-BlankSession.ps1'

    $pwshCmd = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
    $pwsh = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Command -Name 'powershell').Source }

    if ($Remove) {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing) {
            if ($DryRun) { Write-Host "[DryRun] Would unregister task '$TaskName'."; return }
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Removed scheduled task '$TaskName'."
        } else {
            Write-Host "Task '$TaskName' not found; nothing to remove."
        }
        return
    }

    if (-not (Test-Path -LiteralPath $workerPath)) {
        throw "Worker script not found at $workerPath"
    }

    $action = New-ScheduledTaskAction -Execute $pwsh `
        -Argument ('-NonInteractive -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $workerPath)

    # AtLogOn covers cold start; the repetition keeps it topped up every N minutes.
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $trigger.Repetition = $repeat.Repetition

    $principal = New-ScheduledTaskPrincipal `
        -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive

    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    if ($DryRun) {
        Write-Host "[DryRun] Would register task '$TaskName':"
        Write-Host ("  Run:      {0} -File {1}" -f $pwsh, $workerPath)
        Write-Host ("  Triggers: at logon + every {0} minute(s)" -f $IntervalMinutes)
        Write-Host  "  Principal: $($principal.UserId) (Interactive)"
        return
    }

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null

    Write-Host "Registered scheduled task '$TaskName' (at logon + every $IntervalMinutes min)."
    Write-Host "Run one cycle now: pwsh -File `"$workerPath`" -Verbose"
    Write-Host "Inspect log:       Get-Content `"$(Join-Path $env:USERPROFILE '.claude\orchestrator\orchestrator.log')`" -Tail 20"
}
catch {
    Write-Error "Install failed: $($_.Exception.Message)"
    throw
}
