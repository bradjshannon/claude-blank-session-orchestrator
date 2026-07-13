#Requires -Version 5.1
<#
.SYNOPSIS
    Ensure at least one blank, Remote-Control-enabled Claude Code session is alive.

.DESCRIPTION
    Worker invoked on an interval (by the startup loop or a scheduled task). It tracks
    the sessions it launches in a state file, prunes dead ones, detects when a session
    has been used (a user turn appears in its transcript) and releases it from the blank
    pool, then launches replacements so that -TargetBlank blank sessions remain available.

.NOTES
    Requires Claude Code (the `claude` CLI) on PATH, signed in to a Claude account with
    the `user:sessions:claude_code` scope, and `remoteControlAtStartup` (or the
    `--remote-control` flag this script passes) so launched sessions register for
    Remote Control.
#>
[CmdletBinding()]
param(
    [int]$TargetBlank = 1,
    [string]$WorkingDirectory = $env:USERPROFILE,
    [string]$ClaudePath,
    [string]$StateDirectory = (Join-Path $env:USERPROFILE '.claude\orchestrator'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    try { Add-Content -Path $script:LogPath -Value $line -Encoding utf8 } catch { }
    Write-Verbose $line
}

function Resolve-ClaudeExe {
    [CmdletBinding()]
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return $Explicit }
        throw "Specified ClaudePath not found: $Explicit"
    }
    $cmd = Get-Command -Name 'claude' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { return $cmd.Source }
    # Fallback: newest bundled build under a known install root. Two subtleties this handles:
    #   1. Env vars are read defensively -- a hidden logon process can inherit an incomplete
    #      environment, so Roaming/Local are also derived from USERPROFILE, not just APPDATA.
    #   2. The Claude desktop app ships as an MSIX package. A process running INSIDE the
    #      package container (Claude Code itself) sees claude-code at %APPDATA%\Claude, but a
    #      process launched OUTSIDE it (this loop, started from the Startup folder) does not --
    #      there the real tree lives in the package's virtualized roaming store at
    #      %LOCALAPPDATA%\Packages\<family>\LocalCache\Roaming\Claude\claude-code. Search both;
    #      the package family name is wildcarded so a repackage doesn't break resolution.
    $roamBases  = @($env:APPDATA)
    $localBases = @($env:LOCALAPPDATA)
    if ($env:USERPROFILE) {
        $roamBases  += (Join-Path $env:USERPROFILE 'AppData\Roaming')
        $localBases += (Join-Path $env:USERPROFILE 'AppData\Local')
    }
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($b in @($roamBases + $localBases)) {
        if ($b) { $roots.Add((Join-Path $b 'Claude\claude-code')) }
    }
    foreach ($b in $localBases) {
        if (-not $b) { continue }
        $pkgGlob = Join-Path $b 'Packages\*\LocalCache\Roaming\Claude\claude-code'
        foreach ($d in (Get-ChildItem -Path $pkgGlob -Directory -ErrorAction SilentlyContinue)) {
            $roots.Add($d.FullName)
        }
    }
    $uniqueRoots = @($roots | Select-Object -Unique)
    $best = $null
    foreach ($root in $uniqueRoots) {
        if (Test-Path -LiteralPath $root) {
            $exe = Get-ChildItem -Path $root -Recurse -Filter 'claude.exe' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($exe -and ((-not $best) -or ($exe.LastWriteTime -gt $best.LastWriteTime))) { $best = $exe }
        }
    }
    if ($best) { return $best.FullName }
    throw "Could not locate the claude executable (searched PATH and: $($uniqueRoots -join '; ')). Pass -ClaudePath explicitly."
}

function Test-SessionBlank {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uuid)
    # A session is "blank" until a real user turn is written to its transcript.
    # No transcript yet -> just launched -> blank.
    $projects = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path -LiteralPath $projects)) { return $true }
    $file = Get-ChildItem -Path $projects -Recurse -Filter "$Uuid.jsonl" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $file) { return $true }
    $used = Select-String -Path $file.FullName -Pattern '"type":"user"' -SimpleMatch -Quiet
    return (-not $used)
}

function Test-ProcessAlive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId, [string]$ExpectedName)
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    if ($ExpectedName -and $proc.ProcessName -ne $ExpectedName) { return $false }
    return $true
}

try {
    if (-not (Test-Path -LiteralPath $StateDirectory)) {
        New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    }
    $script:LogPath = Join-Path $StateDirectory 'orchestrator.log'
    $statePath = Join-Path $StateDirectory 'state.json'
    $lockPath  = Join-Path $StateDirectory 'worker.lock'

    # Single-instance guard: exclusive lock; if held, another cycle is running.
    $lock = $null
    try {
        $lock = [System.IO.File]::Open(
            $lockPath, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch {
        Write-Log -Message 'Another worker instance holds the lock; exiting.' -Level 'WARN'
        return
    }

    try {
        $claude = Resolve-ClaudeExe -Explicit $ClaudePath

        $sessions = @()
        if (Test-Path -LiteralPath $statePath) {
            try {
                $raw = Get-Content -LiteralPath $statePath -Raw -Encoding utf8
                if ($raw -and $raw.Trim()) { $sessions = @($raw | ConvertFrom-Json) }
            } catch {
                Write-Log -Message "State file unreadable, starting fresh: $($_.Exception.Message)" -Level 'WARN'
                $sessions = @()
            }
        }

        $alive = [System.Collections.Generic.List[object]]::new()
        foreach ($s in $sessions) {
            if (Test-ProcessAlive -ProcessId $s.Pid -ExpectedName $s.ProcessName) {
                $isBlank = Test-SessionBlank -Uuid $s.Uuid
                if ((-not $isBlank) -and (-not $s.Released)) {
                    $s.Released = $true
                    Write-Log -Message "Session '$($s.Name)' ($($s.Uuid)) is now in use; released from blank pool."
                }
                $s.Blank = $isBlank
                $alive.Add($s)
            } else {
                Write-Log -Message "Pruning dead session '$($s.Name)' (pid $($s.Pid))."
            }
        }

        $blankAvailable = @($alive | Where-Object { $_.Blank -and (-not $_.Released) })
        Write-Log -Message ("Alive managed: {0}; blank available: {1}; target: {2}." -f $alive.Count, $blankAvailable.Count, $TargetBlank)

        $toSpawn = [Math]::Max(0, $TargetBlank - $blankAvailable.Count)
        for ($i = 0; $i -lt $toSpawn; $i++) {
            $uuid = [guid]::NewGuid().ToString()
            $name = 'blank-{0:MMdd-HHmmss}-{1}' -f (Get-Date), ($uuid.Substring(0, 4))
            if ($DryRun) {
                Write-Log -Message "[DryRun] Would launch blank RC session '$name' (uuid $uuid) in '$WorkingDirectory'."
                continue
            }
            try {
                $proc = Start-Process -FilePath $claude `
                    -ArgumentList @('--session-id', $uuid, '--remote-control', $name) `
                    -WorkingDirectory $WorkingDirectory `
                    -WindowStyle Hidden `
                    -PassThru
                $entry = [pscustomobject]@{
                    Uuid        = $uuid
                    Name        = $name
                    Pid         = $proc.Id
                    ProcessName = $proc.ProcessName
                    StartedUtc  = (Get-Date).ToUniversalTime().ToString('o')
                    Released    = $false
                    Blank       = $true
                }
                $alive.Add($entry)
                Write-Log -Message "Launched blank RC session '$name' (uuid $uuid, pid $($proc.Id))."
            } catch {
                Write-Log -Message "Failed to launch session '$name': $($_.Exception.Message)" -Level 'ERROR'
            }
        }

        if (-not $DryRun) {
            $alive.ToArray() | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding utf8
        }

        $summary = [pscustomobject]@{
            AliveManaged   = $alive.Count
            BlankAvailable = @($alive | Where-Object { $_.Blank -and (-not $_.Released) }).Count
            Launched       = $toSpawn
            DryRun         = [bool]$DryRun
        }
        Write-Host ("Orchestrator: {0} managed, {1} blank available, {2} launched this cycle." -f `
            $summary.AliveManaged, $summary.BlankAvailable, $summary.Launched)
        return $summary
    }
    finally {
        if ($lock) { $lock.Close(); $lock.Dispose() }
    }
}
catch {
    Write-Error "Orchestrator worker failed: $($_.Exception.Message)"
    throw
}
