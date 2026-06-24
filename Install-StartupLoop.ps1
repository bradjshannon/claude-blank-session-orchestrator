#Requires -Version 5.1
<#
.SYNOPSIS
    No-admin install: drop a hidden launcher shortcut in the user's Startup folder so
    Run-OrchestratorLoop.ps1 starts at logon. Removes it with -Remove.

.EXAMPLE
    pwsh -File .\Install-StartupLoop.ps1 -DryRun
    pwsh -File .\Install-StartupLoop.ps1 -IntervalMinutes 3
    pwsh -File .\Install-StartupLoop.ps1 -Remove
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 3,
    [switch]$Remove,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

try {
    $startup = [Environment]::GetFolderPath('Startup')
    $linkPath = Join-Path $startup 'Claude-BlankSessionOrchestrator.lnk'
    $loopScript = Join-Path $PSScriptRoot 'Run-OrchestratorLoop.ps1'

    if ($Remove) {
        if (Test-Path -LiteralPath $linkPath) {
            if ($DryRun) { Write-Host "[DryRun] Would remove $linkPath"; return }
            Remove-Item -LiteralPath $linkPath -Force
            Write-Host "Removed startup shortcut: $linkPath"
        } else {
            Write-Host "No startup shortcut found; nothing to remove."
        }
        return
    }

    if (-not (Test-Path -LiteralPath $loopScript)) {
        throw "Loop script not found at $loopScript"
    }

    $pwshCmd = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
    $pwsh = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Command -Name 'powershell').Source }
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -IntervalMinutes {1}' -f $loopScript, $IntervalMinutes

    if ($DryRun) {
        Write-Host "[DryRun] Would create startup shortcut:"
        Write-Host "  Path:   $linkPath"
        Write-Host "  Target: $pwsh"
        Write-Host "  Args:   $arguments"
        return
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($linkPath)
    $shortcut.TargetPath = $pwsh
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.WindowStyle = 7  # minimized
    $shortcut.Description = 'Keeps a blank Remote-Control Claude session available'
    $shortcut.Save()

    Write-Host "Created startup shortcut: $linkPath"
    Write-Host "Starts at next logon. To start now without rebooting:"
    Write-Host ("  Start-Process -FilePath '{0}' -ArgumentList '{1}' -WindowStyle Hidden" -f $pwsh, $arguments)
}
catch {
    Write-Error "Startup-loop install failed: $($_.Exception.Message)"
    throw
}
