#!/usr/bin/env bash
# Claude Code status line: the 5-hour and weekly usage limits, with time to reset,
# and how full the context window is.
#
# Usage (configured by /polaris-monitor:setup-statusline, status line JSON on stdin):
#   bash statusline.sh
#
# Output, one line, colored green / yellow (>= 80%) / red (>= 95%):
#   5h ██░░░░░░░░ 23% 2h 14m · 7d ████░░░░░░ 41% 4d 6h · ctx ███░░░░░░░ 34% 68k/200k
#
# rate_limits only exists for Pro and Max subscribers, after the session's first
# response, and each window can be missing on its own. context_window exists on every
# plan, but its percentage is null early in a session. Missing data prints nothing.
#
# Environment:
#   NO_COLOR                     any value disables colors (https://no-color.org)
#   POLARIS_MONITOR_CONTEXT=off  hides the context window segment

set -uo pipefail

BAR_WIDTH=10

if ! command -v jq > /dev/null 2>&1; then
    echo "polaris-monitor: install jq to see usage limits"
    exit 0
fi

INPUT="$(cat)"

# One line per segment that is present, in display order (tr drops the CR that jq.exe
# adds on Windows):
#   "5h|7d <percent> <resets_at>" and "ctx <percent> <used_tokens> <window_size>".
SEGMENTS="$(jq -r --arg context "${POLARIS_MONITOR_CONTEXT:-on}" '
    def window($label):
        select(.used_percentage != null and .resets_at != null)
        | "\($label) \(.used_percentage | round) \(.resets_at | floor)";
    (.rate_limits.five_hour | window("5h")),
    (.rate_limits.seven_day | window("7d")),
    (.context_window
        | select($context != "off" and .used_percentage != null)
        | "ctx \(.used_percentage | round) \(.total_input_tokens // 0 | floor) \(.context_window_size // 0 | floor)")
' <<< "$INPUT" 2>/dev/null | tr -d '\r')"

# Remaining time as "4d 6h", "2h 14m", "37m" or "now".
format_remaining() {
    local seconds=$1
    if ((seconds <= 0)); then
        echo "now"
    elif ((seconds >= 86400)); then
        echo "$((seconds / 86400))d $((seconds % 86400 / 3600))h"
    elif ((seconds >= 3600)); then
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
    else
        echo "$((seconds / 60))m"
    fi
}

# Token counts as "800", "68k" or "1.2M".
format_tokens() {
    local tokens=$1 tenths
    if ((tokens < 1000)); then
        echo "$tokens"
    elif ((tokens < 999500)); then
        echo "$(((tokens + 500) / 1000))k"
    else
        tenths=$(((tokens + 50000) / 100000))
        if ((tenths % 10 == 0)); then
            echo "$((tenths / 10))M"
        else
            echo "$((tenths / 10)).$((tenths % 10))M"
        fi
    fi
}

render_bar() {
    local percent=$1 filled bar="" i
    filled=$(((percent * BAR_WIDTH + 50) / 100))
    ((filled > BAR_WIDTH)) && filled=$BAR_WIDTH
    for ((i = 0; i < BAR_WIDTH; i++)); do
        if ((i < filled)); then bar+="█"; else bar+="░"; fi
    done
    echo "$bar"
}

color_for() {
    local percent=$1
    if [ -n "${NO_COLOR:-}" ]; then
        echo ""
    elif ((percent >= 95)); then
        printf '\033[31m'
    elif ((percent >= 80)); then
        printf '\033[33m'
    else
        printf '\033[32m'
    fi
}

NOW="$(date +%s)"
LINE=""
while read -r label percent first second; do
    [ -n "$label" ] || continue
    color="$(color_for "$percent")"
    reset=""
    [ -n "$color" ] && reset=$'\033[0m'
    segment="$label ${color}$(render_bar "$percent")${reset} ${percent}%"
    if [ "$label" != ctx ]; then
        segment+=" $(format_remaining $((first - NOW)))"
    elif ((second > 0)); then
        segment+=" $(format_tokens "$first")/$(format_tokens "$second")"
    fi
    LINE="${LINE:+$LINE · }$segment"
done <<< "$SEGMENTS"

[ -n "$LINE" ] && echo "$LINE"
exit 0
