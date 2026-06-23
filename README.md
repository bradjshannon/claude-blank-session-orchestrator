# Claude Blank-Session Orchestrator

Keep a **blank, Remote-Control-enabled [Claude Code](https://code.claude.com) session
available at all times** on a Windows machine, so you can connect to a fresh session
from the Claude mobile or web app whenever you want — without leaving a terminal open or
manually starting one each time.

## Why

Claude Code [Remote Control](https://code.claude.com/docs/en/remote-control) lets you
drive a session running on your machine from your phone or the web — but it only attaches
to a session that is **already running**. It will not spawn one on demand. This
orchestrator keeps one warm, blank session alive and waiting, and replaces it as soon as
you start using it, so there is always a clean session ready to connect to.

## How it works

- A worker runs on an interval (a per-user Startup loop by default, or a Windows
  Scheduled Task).
- Each managed session is launched with a known `--session-id`, so the worker can locate
  its transcript and tell **blank** from **in use**.
- A session is **blank** until a user turn appears in its transcript. When you connect
  via Remote Control and type, that session is **released** from the pool (left running,
  history preserved) and the next cycle launches a fresh blank replacement.
- Sessions you close (`/exit`) are pruned from state on the next cycle.

So there is always at least one `blank-...` session you can connect to, and your working
sessions are never disturbed.

## Requirements

- Windows with **PowerShell 7+** (`pwsh`).
- **Claude Code** installed with the `claude` CLI on `PATH`.
- Signed in to a Claude account (Pro/Max/Team) — Remote Control needs the
  `user:sessions:claude_code` scope, not just an API key.
- The machine must be **awake and logged in** for sessions to run and be reachable.

## Install

```powershell
git clone https://github.com/bradjshannon/claude-blank-session-orchestrator.git
cd claude-blank-session-orchestrator

# No-admin install (Startup loop) + start now
pwsh -File .\install.ps1

# Or the sturdier Scheduled Task (run from an ELEVATED PowerShell)
pwsh -File .\install.ps1 -ScheduledTask

# Preview without changing anything
pwsh -File .\install.ps1 -DryRun
```

Then open the Claude app, go to Remote Control, and connect to the session named
`blank-...`.

## Uninstall

```powershell
# Startup loop
pwsh -File .\Install-StartupLoop.ps1 -Remove

# Scheduled task (elevated)
pwsh -File .\Install-Orchestrator.ps1 -Remove
```

## Files

| File | Role |
|------|------|
| `install.ps1` | One-step installer (prereq check, first cycle, auto-start). |
| `Ensure-BlankSession.ps1` | Worker — keeps `-TargetBlank` blank sessions available. |
| `Run-OrchestratorLoop.ps1` | The interval loop used by the no-admin install. |
| `Install-StartupLoop.ps1` | Installs/removes the per-user Startup shortcut. |
| `Install-Orchestrator.ps1` | Installs/removes the Windows Scheduled Task. |

State and logs live in `~/.claude/orchestrator/` (`state.json`, `orchestrator.log`).

## Configuration

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-TargetBlank` | `1` | How many blank sessions to keep available. |
| `-IntervalMinutes` | `3` | How often to check. |
| `-WorkingDirectory` | `$env:USERPROFILE` | Where blank sessions launch. A directory Claude has not "trusted" yet may show a one-time trust prompt that blocks the session — run `claude` there once manually first, or point this at an already-trusted folder. |
| `-ClaudePath` | auto | Explicit path to `claude.exe` if it is not on `PATH`. |

## Caveats

- **Interactive process host.** Sessions run in a minimized console attached to your
  logged-on desktop. They survive within your login session but end on logout/reboot;
  the auto-start relaunches them at next logon. This targets convenient availability,
  not strict 24/7 uptime.
- **`/clear` + Remote Control is unverified.** Whether issuing `/clear` inside a
  `--remote-control` session keeps the same process and Remote Control registration alive
  is not documented. The orchestrator does not depend on it: if you would rather not rely
  on `/clear`, just close a used session and a fresh blank one appears within a cycle.
- **Windows only** (PowerShell + Task Scheduler / Startup folder). The same idea works on
  macOS/Linux with launchd/systemd, but that is not included here.

## License

MIT — see [LICENSE](LICENSE).
