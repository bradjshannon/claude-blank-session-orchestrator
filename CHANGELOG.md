# Changelog

All notable changes to this project are documented here. Dates are UTC.

## [Unreleased]

### Changed

- **Blank session names now include the hostname.** Names changed from
  `blank-MMdd-HHmmss-XXXX` to `<hostname>-blank-orchestrator-MMdd-HHmmss-XXXX`, so a
  session is identifiable by its originating machine (and script) when several hosts'
  sessions are visible in `claude --resume` or the Remote Control session list.

### Fixed

- **MSIX-packaged Claude installs are now resolved.** When the Claude desktop app is
  installed as an MSIX package, a process running *inside* the package container (Claude
  Code itself) sees `claude-code` under `%APPDATA%\Claude`, but the orchestrator loop runs
  *outside* the container (launched from the Startup folder) where that path does not
  exist — the real tree lives in the package's virtualized roaming store at
  `%LOCALAPPDATA%\Packages\<family>\LocalCache\Roaming\Claude\claude-code`.
  `Resolve-ClaudeExe` now also searches the package-virtualized location (family name
  wildcarded so a repackage does not break resolution), derives Roaming/Local from
  `USERPROFILE` when `APPDATA`/`LOCALAPPDATA` are absent, and picks the newest build across
  all roots. Previously the loop failed every cycle with "Could not locate the claude
  executable" on packaged installs.

### Added

- **Self-healing Startup shortcut.** On every cycle, `Run-OrchestratorLoop.ps1` rewrites
  the per-user Startup shortcut to point at its own current location
  (`$PSCommandPath`) when it does not already match. Moving the repo folder no longer
  silently breaks auto-start once the loop runs once from the new location. (`44c0a52`)

## [0.1.0] - 2026-06-23

### Added

- Initial release. Keeps at least one blank, Remote-Control-enabled Claude Code session
  available on Windows so you can connect to a fresh session from the mobile/web app at
  any time. (`ca91020`)
- `Ensure-BlankSession.ps1` worker: launches sessions with a known `--session-id`,
  detects blank vs. in-use via the transcript, releases used sessions and replaces them,
  prunes dead ones. Auto-detects `claude.exe` (no PATH requirement).
- Two install paths: per-user Startup loop (`Install-StartupLoop.ps1`, no admin) and a
  Windows Scheduled Task (`Install-Orchestrator.ps1`, elevated).
- `install.ps1` one-step installer, README, MIT license.

## Known caveats

- **`/clear` + Remote Control is unverified.** Whether issuing `/clear` inside a
  `--remote-control` session keeps the same process and Remote Control registration alive
  is not documented upstream. The orchestrator does not depend on it: closing a used
  session yields a fresh blank one within a cycle.
- **Move-while-stopped edge.** Self-heal repairs the shortcut whenever the loop runs from
  its new location. If the folder is moved while nothing is running and the machine then
  reboots, the stale shortcut fires against the old path and fails; recovery is one manual
  launch of `Run-OrchestratorLoop.ps1` from the new location, after which it self-corrects.
- **Availability.** Sessions run in a minimized console attached to the logged-on desktop;
  they end on logout/reboot and relaunch at next logon. This targets convenient
  availability, not strict 24/7 uptime.
- **Windows only.** The same approach works on macOS/Linux via launchd/systemd but is not
  included here.
