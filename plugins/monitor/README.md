# polaris-monitor

Keeps you in the loop while Claude Code works, so you can leave sessions running and switch to other tasks: it beeps when Claude finishes a turn, asks you a question or needs permission.

## Install

```
/plugin marketplace add PLeonLopes/polaris-marketplace
/plugin install polaris-monitor@polaris
```

The hooks are active in new sessions right away. In a session that was already open, run `/reload-plugins`.

## Beeps

| Hook event | Matcher | Pattern | When |
|------------|---------|---------|------|
| `Stop` | (all) | **done**: 2 low beeps | Claude finished its turn and is waiting for you |
| `PreToolUse` | `AskUserQuestion` | **attention**: 3 high beeps | Claude is about to ask you a question |
| `Notification` | `permission_prompt` | **attention**: 3 high beeps | Claude needs permission to run a tool |

Two patterns tell you, without looking, whether Claude is just done or is blocked on you.

Hook events fired inside a subagent are ignored, so only the main session beeps. The hooks are informational: they never block or change what Claude does, and they return immediately because the sound plays in the background.

## Platforms

### Operating systems

| Platform | Backend | Status |
|----------|---------|--------|
| Windows (native) | `powershell.exe` calling `[console]::beep` | Untested on a real machine |
| WSL 2 | `powershell.exe` calling `[console]::beep` on the Windows host | Tested |
| macOS | `afplay` with the system `Tink` (done) and `Ping` (attention) sounds | Untested on a real machine |
| Linux | `paplay` (PulseAudio/PipeWire) with the freedesktop sounds, falling back to the terminal bell | Untested on a real machine |

"Untested" platforms are covered by the automated tests with fake sound backends, which check the commands the script runs but not that a sound comes out.

- **Windows** runs hooks in Git Bash, which the script detects from `uname` (`MINGW`, `MSYS` or `CYGWIN`). Without Git Bash, Claude Code runs hooks in PowerShell, where the `bash` command of the hooks does not exist and nothing plays.
- **Linux:** the terminal bell is written to `/dev/tty`, because Claude Code captures hook output. Without a controlling terminal it fails silently.
- **Background playback:** the sound runs in a new session (`setsid`), so it survives Claude Code ending the hook's process group. Where `setsid` is missing (macOS, possibly Git Bash), the script ignores the hang-up and termination signals instead.

Run `bash plugins/monitor/scripts/beep.sh --detect` to see which platform the script picked.

### Claude surfaces

The beeps come from a shell script on the machine that runs Claude Code, so they only help where that machine is yours:

| Surface | Beeps |
|---------|-------|
| Claude Code in a terminal | Yes |
| IDE extensions (VS Code, JetBrains) | Expected, same hooks on your machine |
| Desktop app, Code tab, local session | Expected, untested |
| Cloud sessions (Claude Code on the web) | No: hooks run on a remote machine, so the script stays silent when `CLAUDE_CODE_REMOTE=true` |
| Claude chat (web, desktop, mobile) | No: chat has no hooks |

### Settings

Set these in your shell or in the `env` block of `~/.claude/settings.json`:

| Variable | Effect |
|----------|--------|
| `POLARIS_MONITOR_BEEP=off` | Silences every beep |
| `POLARIS_MONITOR_PLATFORM=windows\|wsl\|macos\|linux` | Forces the sound backend when detection picks the wrong one |

## Testing

Play each pattern directly:

```bash
echo '{}' | bash plugins/monitor/scripts/beep.sh done
echo '{}' | bash plugins/monitor/scripts/beep.sh attention
```

Inside a session, `/hooks` lists the registered hooks. The automated tests use fake sound backends: `uv run pytest tests/plugins/monitor`.

## Roadmap

- Usage status line with the 5-hour and weekly limits.
- An always-on-top window that tracks every running session, adapted from the open-source [ticlins-claude-monitor](https://github.com/LucasM-Maciel/ticlins-claude-monitor) (MIT).
