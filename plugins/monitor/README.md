# polaris-monitor

Keeps you in the loop while Claude Code works, so you can leave sessions running and switch to other tasks: it beeps when Claude finishes a turn, asks you a question or needs permission, and shows your 5-hour and weekly usage limits and how full the context window is in the status line.

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

## Usage status line

```text
5h ██░░░░░░░░ 24% 2h 14m · 7d ████░░░░░░ 41% 4d 6h · ctx ███░░░░░░░ 34% 68k/200k
```

| Segment | Shows |
|---------|-------|
| `5h`, `7d` | Each usage limit, the same numbers `/usage` shows, with the time until the window resets |
| `ctx` | How full the context window is, with the input tokens it holds and its size. Set `POLARIS_MONITOR_CONTEXT=off` to hide it |

Bars turn yellow at 80% and red at 95%; set `NO_COLOR` to drop the colors.

Plugins cannot set the status line themselves, so turn it on once with:

```
/polaris-monitor:setup-statusline
```

| Command | Effect |
|---------|--------|
| `/polaris-monitor:setup-statusline` | Points `statusLine` in your user `settings.json` at the plugin. Refuses if you already have another status line |
| `/polaris-monitor:setup-statusline --force` | Replaces your current status line |
| `/polaris-monitor:setup-statusline --remove` | Removes it, only if it is the plugin's |

How it works:

- **Stable path.** The setting points at a copy of `statusline.sh` in the plugin data directory (`~/.claude/plugins/data/<plugin-id>/`), not at the install directory, which changes on every update. A `SessionStart` hook refreshes that copy after updates, and only once you have opted in. It never touches `settings.json`.
- **Safe writes.** Before writing, the command backs up `settings.json` to `settings.json.bak-polaris-monitor`. The write is atomic, keeps the file mode and follows a symlinked `settings.json`. A file with invalid JSON is left alone.
- **Uninstalling** the plugin deletes its data directory, so run `--remove` first, or delete the `statusLine` key afterwards.

Requirements: [`jq`](https://jqlang.org) (`apt install jq`, `brew install jq` or `winget install jqlang.jq`). Usage limits only exist for Claude Pro and Max subscriptions and appear after Claude's first response in a session; with an API key, only `ctx` shows.

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
| `POLARIS_MONITOR_CONTEXT=off` | Hides the `ctx` segment of the status line |
| `POLARIS_MONITOR_PLATFORM=windows\|wsl\|macos\|linux` | Forces the sound backend when detection picks the wrong one |

## Testing

Play each pattern directly:

```bash
echo '{}' | bash plugins/monitor/scripts/beep.sh done
echo '{}' | bash plugins/monitor/scripts/beep.sh attention
```

Render the status line from a sample payload (`resets_at` is Unix epoch seconds):

```bash
echo '{"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":'$(($(date +%s) + 8040))'}},"context_window":{"used_percentage":34,"total_input_tokens":68000,"context_window_size":200000}}' \
  | bash plugins/monitor/scripts/statusline.sh
```

Inside a session, `/hooks` lists the registered hooks. The automated tests use fake sound backends and a throwaway `settings.json`: `uv run pytest tests/plugins/monitor`.

## Roadmap

- An always-on-top window that tracks every running session, adapted from the open-source [ticlins-claude-monitor](https://github.com/LucasM-Maciel/ticlins-claude-monitor) (MIT).
