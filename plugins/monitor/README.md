# polaris-monitor

Keeps you in the loop while Claude Code works, so you can leave sessions running and switch to other tasks: it beeps when Claude finishes a turn, asks you a question or needs permission, shows your 5-hour and weekly usage limits and how full the context window is in the status line, and opens an always-on-top window that tracks every running session.

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

## Monitor window

```
/polaris-monitor:open-window
```

A small always-on-top card in the bottom-right corner of the screen with every running Claude Code session and the usage bars, so you can leave several sessions running and see at a glance which one needs you. Windows, WSL and macOS.

| Dot | Meaning |
|-----|---------|
| green, pulsing | working |
| red | finished, waiting for you |
| blue | asked you a question |
| yellow | waiting for a permission |

- **Time** on the right: how long the session has been in that state.
- **Subagents** show as indented rows under their session, with what each one is doing and for how long; a long description scrolls sideways. The arrow on the session collapses them (it then shows how many there are).
- **Usage bars**: the same 5-hour and weekly limits as the status line, which saves them for the window. They turn amber at 80% and red at 95%. With your own status line, the bars stay empty.
- **Mascot**: the Polaris star walks around the card while a session works, jumps on top while one waits for you and stands still when everything is quiet. Clawd, the Claude Code mascot, is available instead, and you can draw your own (see [Customizing](#customizing)).
- **Drag** the card to move it. **Right-click** for: remove a session from the list (on a session row), show or hide the mascot, the mascot, a **Theme** submenu (Dark, Light, Midnight, High contrast and your own), a **Size** submenu (Small, Normal, Large), show usage, show subagents, window sound (off by default, since the beeps already alert you), opacity (card and mascot), volume and close. The choices are saved in `config.json`.
- **Sounds.** With window sound on, it plays the system sounds; to use your own, put `question`, `finished` and `all-done` files (`.wav` or `.mp3`) in the monitor folder's `sounds/`, then reopen the window.

How it opens:

| Platform | Window | First run |
|----------|--------|-----------|
| Windows | PowerShell and WPF, from `~/.polaris-monitor` | nothing to install |
| WSL | the same, on the Windows side: the files go to the Windows profile's `.polaris-monitor` | nothing to install |
| macOS | Swift and AppKit, compiled in `~/.polaris-monitor` | needs the Xcode command line tools (`xcode-select --install`); compiles once, and again after updates |

### Customizing

Mascots and color themes are plain JSON files: the plugin ships `mascots.json` and `themes.json` next to the window, and your own go in the monitor folder's `custom/` (`~/.polaris-monitor/custom/`, on WSL the Windows profile's `.polaris-monitor\custom\`). Yours add to the plugin's, or replace an entry with the same key, and plugin updates never touch them. The window reloads both files within 2 seconds of a save, so you can draw with the window open; new entries show up in the right-click menu.

A mascot is a grid of characters: `#` body, `o` eyes and `u` mouth (face color), `A` and `B` the two pairs of feet, which alternate while it walks, `.` empty. `pixel` is the width and height of one grid cell in pixels:

```json
{
  "robot": {
    "name": "Robot",
    "sprite": [
      ".#####.",
      "#o###o#",
      "#######",
      "##uuu##",
      ".A.B.A."
    ],
    "pixel": [3, 3],
    "colors": { "body": "#94A3B8", "face": "#0F172A", "feet": "#475569", "outline": "#1E293B" }
  }
}
```

Rows must have the same width, the mascot must fit in 32 px of height and 64 px of width, and colors are `#RRGGBB` or `#AARRGGBB` (`outline` is optional).

A theme sets any of these colors, and takes the Dark theme's for the ones it leaves out:

| Key | Used for |
|-----|----------|
| `card`, `divider` | card background and the line above the usage bars |
| `text`, `muted`, `faint`, `accent` | session names, secondary text, times, the subagent arrow |
| `track`, `bar`, `barWarning`, `barCritical` | usage bars: empty part, below 80%, from 80%, from 95% |
| `working`, `finished`, `question`, `permission` | the dots and their times |

```json
{ "ocean": { "name": "Ocean", "card": "#F2082F49", "bar": "#22D3EE", "working": "#2DD4BF" } }
```

An entry that breaks a rule is skipped (the window writes why to `monitor.log` on Windows), and a choice that no longer exists falls back to the star and the Dark theme.

### Updates

A single window runs at a time. After a plugin update, run the command again: the open window closes and the new version takes its place. The window never updates or relaunches itself, never reads your Claude login and never calls an API.

Adapted from the open-source [ticlins-claude-monitor](https://github.com/LucasM-Maciel/ticlins-claude-monitor) (MIT); its license is kept in [`scripts/window/LICENSE-ticlins-claude-monitor.txt`](scripts/window/LICENSE-ticlins-claude-monitor.txt).

### Session tracking

Hooks record the state of every running session for the window:

| Hook event | Recorded |
|------------|----------|
| `UserPromptSubmit` | `working` |
| `Stop` | `waiting` (Claude finished its turn) |
| `Notification` | `permission` for a permission request, `waiting` for the idle notice |
| `SubagentStart`, `SubagentStop` | the session's subagents, with what each one is doing |
| `SessionEnd` | the session is forgotten |

- **Opt-in.** Nothing is written until the folder `~/.polaris-monitor` exists; opening the window creates it. On WSL the files go to the Windows profile's `.polaris-monitor` once it exists, because the window runs on Windows.
- **One file per session** in `sessions/<session_id>.json`, written atomically, readable only by you (files `0600`, folder `0700`). Session and subagent ids are validated before they become file names.
- **Subagents.** Each subagent shows what it is doing, read from the description Claude Code stores next to its transcript. When Claude finishes its turn while subagents still run, the session keeps showing as working until the last one stops. A subagent whose stop was missed is dropped after 2 hours.
- **Names.** A session is named after its `/rename` title, then its automatic title, then its folder. Transcripts are only read when they are regular files under `~/.claude/projects` (or `$CLAUDE_CONFIG_DIR/projects`).

- **Cleanup.** A session disappears when it ends. One that ended without telling (a closed terminal) is dropped by the window, and its file deleted, once its process is gone or, on Windows and WSL, after 6 hours without activity.

Cloud sessions are not recorded. Requires `jq`, like the status line; without it the hooks do nothing.

To stop tracking, close the window and delete `~/.polaris-monitor` (on WSL, also the Windows profile's `.polaris-monitor`).

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

Render the window off screen with sample sessions and check what it drew (`out.png` and `out.png.txt`):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File plugins/monitor/scripts/window/window.ps1 -Snapshot out.png -Folder <folder>   # Windows
xcrun swiftc -swift-version 5 -o /tmp/PolarisMonitor plugins/monitor/scripts/window/window.swift
/tmp/PolarisMonitor --snapshot out.png --folder <folder>                                                                 # macOS
```

Inside a session, `/hooks` lists the registered hooks. The automated tests use fake sound backends and programs, a throwaway home and a throwaway `settings.json`; on Windows and macOS they also render both windows and check their pixels: `uv run pytest tests/plugins/monitor`.

## Roadmap

- The monitor window on native Linux.
