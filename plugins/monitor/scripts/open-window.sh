#!/usr/bin/env bash
# Opens the polaris-monitor window (Windows, WSL and macOS).
#
# Usage (from /polaris-monitor:open-window):
#   bash open-window.sh
#
# Creates the monitor folder, which turns on session tracking (see session.sh), copies the
# window, mascots.json and themes.json there, creates custom/ for the user's own mascots and
# themes, and starts the window:
#   Windows   ~/.polaris-monitor/window.ps1, run by Windows PowerShell (WPF)
#   WSL       the Windows profile's .polaris-monitor, because the window runs on Windows; the
#             path is cached in ~/.polaris-monitor/winpath for the hooks and the status line
#   macOS     ~/.polaris-monitor/window.swift, compiled there on the first run and after
#             each update (needs the Xcode command line tools)
# A copy that did not change keeps its timestamp: an open window closes itself only when
# its file changes, and the new one waits for it to go.
#
# Environment:
#   POLARIS_MONITOR_PLATFORM    force windows | wsl | macos | linux instead of detecting it
#
# Exit codes: 0 opened, 1 could not open (see message).

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOW_DIR="$SCRIPT_DIR/window"
LOCAL_DIR="$HOME/.polaris-monitor"

fail() {
    echo "polaris-monitor: $*"
    exit 1
}

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

# Copies a file only when it changed, so an open window is not closed for nothing.
# Sets CHANGED=true when it copied.
CHANGED=false
install_file() {
    local source=$1 target=$2
    if [ -f "$target" ] && cmp -s "$source" "$target"; then
        return 0
    fi
    cp "$source" "$target" || fail "could not copy $(basename "$source") to $(dirname "$target")"
    CHANGED=true
}

# The mascots and themes, which the window reloads by itself when they change.
install_assets() {
    local dir=$1
    mkdir -p "$dir/custom" || fail "could not create $dir/custom"
    install_file "$WINDOW_DIR/mascots.json" "$dir/mascots.json"
    install_file "$WINDOW_DIR/themes.json" "$dir/themes.json"
}

# Starts window.ps1 hidden, detached from this shell. Start-Process gets the path through
# an environment variable, so spaces and quotes in it need no escaping.
start_powershell() {
    local windows_path=$1
    # shellcheck disable=SC2016 # $env:POLARIS_WINDOW is expanded by PowerShell
    POLARIS_WINDOW="$windows_path" WSLENV="POLARIS_WINDOW${WSLENV:+:$WSLENV}" powershell.exe -NoProfile -NonInteractive -Command '
        Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ("`"" + $env:POLARIS_WINDOW + "`""))
    ' < /dev/null > /dev/null 2>&1
}

open_windows() {
    command -v powershell.exe > /dev/null 2>&1 || fail "powershell.exe was not found."
    mkdir -p "$LOCAL_DIR/sessions" || fail "could not create $LOCAL_DIR"
    install_file "$WINDOW_DIR/window.ps1" "$LOCAL_DIR/window.ps1"
    install_assets "$LOCAL_DIR"
    start_powershell "$(cygpath -w "$LOCAL_DIR/window.ps1")" || fail "could not start PowerShell."
}

open_wsl() {
    local profile windows_dir
    command -v powershell.exe > /dev/null 2>&1 || fail "powershell.exe was not found (is Windows interop on?)."
    profile="$(cd / && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
    [[ $profile == [A-Za-z]:\\* ]] || fail "could not find the Windows profile folder."
    windows_dir="$(wslpath -u "$profile\\.polaris-monitor" 2>/dev/null)"
    [ -n "$windows_dir" ] || fail "could not translate the Windows profile path."
    mkdir -p "$windows_dir/sessions" "$LOCAL_DIR" || fail "could not create $windows_dir"
    # the hooks and the status line write there from now on
    echo "$windows_dir" > "$LOCAL_DIR/winpath"
    rm -f "$LOCAL_DIR/winpath.fail"
    install_file "$WINDOW_DIR/window.ps1" "$windows_dir/window.ps1"
    install_assets "$windows_dir"
    # run from a Windows folder: PowerShell warns about a Linux working directory
    (cd "$windows_dir" && start_powershell "$profile\\.polaris-monitor\\window.ps1") || fail "could not start PowerShell."
}

open_macos() {
    local binary="$LOCAL_DIR/PolarisMonitor" tmp compile
    mkdir -p "$LOCAL_DIR/sessions" || fail "could not create $LOCAL_DIR"
    install_file "$WINDOW_DIR/window.swift" "$LOCAL_DIR/window.swift"
    compile=$CHANGED
    # next to the binary, where the window looks for them
    install_assets "$LOCAL_DIR"
    if [ "$compile" = true ] || [ ! -x "$binary" ]; then
        xcode-select -p > /dev/null 2>&1 || fail "the Xcode command line tools are missing: run xcode-select --install, then try again."
        echo "polaris-monitor: compiling the window (first run and after updates only)..."
        tmp="$binary.$$.new"
        if ! xcrun swiftc -swift-version 5 -O -o "$tmp" "$LOCAL_DIR/window.swift" > /dev/null 2>&1; then
            rm -f "$tmp"
            fail "could not compile the window. Run: xcrun swiftc -swift-version 5 -o /tmp/PolarisMonitor \"$LOCAL_DIR/window.swift\""
        fi
        mv -f "$tmp" "$binary"
    fi
    (
        trap '' HUP INT TERM
        exec "$binary"
    ) < /dev/null > /dev/null 2>&1 &
}

case "$(detect_platform)" in
    windows) open_windows ;;
    wsl) open_wsl ;;
    macos) open_macos ;;
    *) fail "the monitor window runs on Windows, WSL and macOS. The beeps and the status line work here." ;;
esac
echo "polaris-monitor: window opened in the bottom-right corner of the screen. Sessions show up after their next prompt."
exit 0
