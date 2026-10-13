#!/usr/bin/env bash
# Points the Claude Code statusLine setting at the polaris-monitor usage status line.
#
# Usage:
#   bash setup-statusline.sh <plugin-data-dir>            # set it up (keeps another status line)
#   bash setup-statusline.sh <plugin-data-dir> --force    # replace another status line
#   bash setup-statusline.sh <plugin-data-dir> --remove   # remove it, if it is ours
#   bash setup-statusline.sh <plugin-data-dir> --sync     # SessionStart hook: refresh the copy
#
# Plugins cannot set statusLine themselves, and ${CLAUDE_PLUGIN_ROOT} changes on every
# plugin update, so the setting points at a copy of statusline.sh in the plugin data
# directory, which survives updates. The SessionStart hook runs --sync to refresh that
# copy, and only when the user has opted in (the copy exists). Only setup and --remove
# write settings.json: after a backup, atomically, keeping its mode and any symlink.
#
# Exit codes: 0 done or nothing to do, 1 refused (see message), 2 usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLED="$SCRIPT_DIR/statusline.sh"

DATA_DIR="${1:-}"
MODE="${2:-setup}"
if [ -z "$DATA_DIR" ]; then
    echo "usage: setup-statusline.sh <plugin-data-dir> [--force|--remove|--sync]" >&2
    exit 2
fi
COPY="$DATA_DIR/statusline.sh"
COMMAND="bash \"$COPY\""

SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

case "$MODE" in
    setup | --force | --remove) ;;
    --sync)
        if [ -f "$COPY" ] && ! cmp -s "$BUNDLED" "$COPY"; then
            cp "$BUNDLED" "$COPY" 2>/dev/null || true
        fi
        exit 0
        ;;
    *)
        echo "usage: setup-statusline.sh <plugin-data-dir> [--force|--remove|--sync]" >&2
        exit 2
        ;;
esac

if ! command -v jq > /dev/null 2>&1; then
    echo "jq is required: install it (apt install jq, brew install jq or winget install jqlang.jq) and run this again."
    exit 1
fi

# Follow symlinks so a dotfiles setup keeps its link.
resolve() {
    local path=$1 link
    while [ -L "$path" ]; do
        link="$(readlink "$path")"
        case "$link" in
            /*) path="$link" ;;
            *) path="$(dirname "$path")/$link" ;;
        esac
    done
    echo "$path"
}

TARGET="$(resolve "$SETTINGS")"
if [ -f "$TARGET" ]; then
    if ! jq empty "$TARGET" > /dev/null 2>&1; then
        echo "$SETTINGS is not valid JSON: fix it first. Nothing was changed."
        exit 1
    fi
    CURRENT="$(jq -r '.statusLine.command // empty' "$TARGET" | tr -d '\r')"
else
    CURRENT=""
fi

is_ours() {
    [ "$1" = "$COMMAND" ] || [[ "$1" == *polaris-monitor*statusline.sh* ]]
}

# Applies a jq filter to settings.json: backup, temp file in the same directory, rename.
write_settings() {
    local filter=$1 tmp
    mkdir -p "$(dirname "$TARGET")"
    [ -f "$TARGET" ] || echo '{}' > "$TARGET"
    cp -p "$TARGET" "$TARGET.bak-polaris-monitor"
    tmp="$(mktemp "$TARGET.XXXXXX")" || return 1
    cp -p "$TARGET" "$tmp"
    if jq --arg command "$COMMAND" "$filter" "$TARGET" > "$tmp" && mv -f "$tmp" "$TARGET"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

if [ "$MODE" = "--remove" ]; then
    if [ -n "$CURRENT" ] && is_ours "$CURRENT"; then
        write_settings 'del(.statusLine)' || exit 1
        rm -f "$COPY"
        echo "Removed the polaris-monitor status line from $SETTINGS."
    else
        echo "The status line in $SETTINGS is not polaris-monitor's. Nothing was changed."
    fi
    exit 0
fi

if [ -n "$CURRENT" ] && ! is_ours "$CURRENT" && [ "$MODE" != "--force" ]; then
    echo "You already have a status line: $CURRENT"
    echo "Nothing was changed. Run /polaris-monitor:setup-statusline --force to replace it."
    exit 1
fi

mkdir -p "$DATA_DIR"
cp "$BUNDLED" "$COPY"
if [ "$CURRENT" = "$COMMAND" ]; then
    echo "The polaris-monitor status line is already configured in $SETTINGS."
    exit 0
fi
# shellcheck disable=SC2016 # $command is a jq variable (--arg), not a shell one
write_settings '.statusLine = {"type": "command", "command": $command}' || exit 1
echo "Configured the polaris-monitor status line in $SETTINGS (backup: $TARGET.bak-polaris-monitor)."
echo "It shows up after Claude's next response in a Pro or Max session."
