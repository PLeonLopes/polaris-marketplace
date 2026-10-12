#!/usr/bin/env bash
# Plays a short beep pattern from a Claude Code hook.
#
# Usage (from hooks/hooks.json, with the hook input JSON on stdin):
#   bash beep.sh done        # Claude finished its turn: 2 low beeps
#   bash beep.sh attention   # Claude asked a question or needs permission: 3 high beeps
#   bash beep.sh --detect    # print the detected platform and exit
#
# Environment:
#   POLARIS_MONITOR_BEEP=off    silence every beep
#   POLARIS_MONITOR_PLATFORM    force windows | wsl | macos | linux instead of detecting it
#   CLAUDE_CODE_REMOTE=true     set by Claude Code in cloud sessions: no one would hear
#                               the remote machine, so the script stays silent
#
# The sound plays in the background with every stream detached, so the hook returns
# at once and never delays Claude Code. It runs in a new session (setsid re-runs this
# script with the internal --play flag), because Claude Code ends the hook's process
# group when the hook returns, which would cut the pattern after the first beep. The
# script always exits 0: a missing sound backend must never surface as a hook error.

set -uo pipefail

# Native Windows runs hooks in Git Bash, whose uname starts with MINGW (MSYS and
# Cygwin are the same family).
detect_platform() {
    if [ -n "${POLARIS_MONITOR_PLATFORM:-}" ]; then
        echo "$POLARIS_MONITOR_PLATFORM"
        return
    fi
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        MINGW* | MSYS* | CYGWIN*) echo "windows" ;;
        *)
            if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
    esac
}

if [ "${1:-}" = "--detect" ]; then
    detect_platform
    exit 0
fi

PLAY_NOW=false
if [ "${1:-}" = "--play" ]; then
    PLAY_NOW=true
    shift
fi

PATTERN="${1:-}"
case "$PATTERN" in
    done)
        COUNT=2
        FREQUENCY=660
        ;;
    attention)
        COUNT=3
        FREQUENCY=1000
        ;;
    *)
        echo "usage: beep.sh <done|attention>" >&2
        exit 0
        ;;
esac

if [ "$PLAY_NOW" = false ]; then
    if [ "${POLARIS_MONITOR_BEEP:-on}" = "off" ] || [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
        exit 0
    fi

    # Hook events fired inside a subagent carry its agent_id: only the main session beeps.
    INPUT="$(cat 2>/dev/null || true)"
    if [[ "$INPUT" =~ \"agent_id\"[[:space:]]*:[[:space:]]*\"[^\"]+\" ]]; then
        exit 0
    fi
fi

# Writes the terminal bell to /dev/tty: hook stdout is captured by Claude Code and
# never reaches the terminal. Fails silently when there is no controlling terminal.
terminal_bell() {
    local i
    for ((i = 0; i < COUNT; i++)); do
        printf '\a' > /dev/tty 2>/dev/null || return 0
        sleep 0.2
    done
}

# Windows and WSL: powershell.exe is on PATH in both.
play_powershell() {
    local script="" i
    for ((i = 0; i < COUNT; i++)); do
        script+="[console]::beep($FREQUENCY,150); Start-Sleep -Milliseconds 80; "
    done
    powershell.exe -NoProfile -NonInteractive -Command "$script"
}

play_macos() {
    local sound="/System/Library/Sounds/Tink.aiff" i
    [ "$PATTERN" = "attention" ] && sound="/System/Library/Sounds/Ping.aiff"
    for ((i = 0; i < COUNT; i++)); do
        afplay "$sound"
    done
}

play_linux() {
    local sound="/usr/share/sounds/freedesktop/stereo/complete.oga" i
    [ "$PATTERN" = "attention" ] && sound="/usr/share/sounds/freedesktop/stereo/bell.oga"
    if ! command -v paplay > /dev/null 2>&1 || [ ! -f "$sound" ]; then
        terminal_bell
        return
    fi
    for ((i = 0; i < COUNT; i++)); do
        paplay "$sound"
    done
}

play() {
    case "$(detect_platform)" in
        windows | wsl) play_powershell ;;
        macos) play_macos ;;
        *) play_linux ;;
    esac
}

if [ "$PLAY_NOW" = true ]; then
    play
elif command -v setsid > /dev/null 2>&1; then
    setsid bash "${BASH_SOURCE[0]}" --play "$PATTERN" < /dev/null > /dev/null 2>&1 &
else
    # macOS has no setsid: ignore the signals sent to the hook's process group instead.
    (
        trap '' HUP INT TERM
        play
    ) < /dev/null > /dev/null 2>&1 &
fi
exit 0
