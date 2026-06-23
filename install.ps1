#Requires -Version 7.0
<#
.SYNOPSIS
    One-step installer for the Claude blank-session orchestrator.

.DESCRIPTION
    Checks prerequisites, runs one cycle so a blank Remote-Control session exists
    immediately, then installs an auto-start mechanism:

      * default  -> per-user Startup loop (no admin required)
      * -ScheduledTask -> Windows Scheduled Task (sturdier; must run elevated)

.EXAMPLE
    pwsh -File .\install.ps1
    pwsh -File .\install.ps1 -IntervalMinutes 5
    pwsh -File .\install.ps1 -ScheduledTask      # run from an elevated PowerShell
    pwsh -File .\install.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 3,
    [switch]$ScheduledTask,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Test-Prerequisite {
    [CmdletBinding()]
    param()
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7+ is required (found $($PSVersionTable.PSVersion))."
    }
    $claude = Get-Command -Name 'claude' -ErrorAction SilentlyContinue
    if (-not $claude) {
        Write-Warning "The 'claude' CLI was not found on PATH. The worker will try to auto-detect a bundled build, but installing Claude Code and signing in is recommended."
    } else {
        Write-Host "Found claude: $($claude.Source)"
    }
}

try {
    Test-Prerequisite

    $worker = Join-Path $PSScriptRoot 'Ensure-BlankSession.ps1'
    if (-not (Test-Path -LiteralPath $worker)) { throw "Worker script missing: $worker" }

    Write-Host "Running one cycle so a blank session exists now..."
    if ($DryRun) {
        & $worker -DryRun -Verbose
    } else {
        & $worker | Out-Null
    }

    if ($ScheduledTask) {
        Write-Host "Installing Windows Scheduled Task (requires elevation)..."
        $installer = Join-Path $PSScriptRoot 'Install-Orchestrator.ps1'
        & $installer -IntervalMinutes $IntervalMinutes -DryRun:$DryRun
    } else {
        Write-Host "Installing per-user Startup loop (no admin required)..."
        $installer = Join-Path $PSScriptRoot 'Install-StartupLoop.ps1'
        & $installer -IntervalMinutes $IntervalMinutes -DryRun:$DryRun
        if (-not $DryRun) {
            $pwsh = (Get-Command -Name 'pwsh').Source
            $loop = Join-Path $PSScriptRoot 'Run-OrchestratorLoop.ps1'
            $loopArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -IntervalMinutes {1}' -f $loop, $IntervalMinutes
            Start-Process -FilePath $pwsh -ArgumentList $loopArgs -WindowStyle Hidden
            Write-Host "Started the loop now (hidden)."
        }
    }

    Write-Host ""
    Write-Host "Done. A session named 'blank-...' should be visible in the Claude app under Remote Control."
}
catch {
    Write-Error "Install failed: $($_.Exception.Message)"
    throw
}
