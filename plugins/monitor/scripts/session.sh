#!/usr/bin/env bash
# Records the state of a Claude Code session for the polaris-monitor window.
#
# Usage (from hooks/hooks.json, with the hook input JSON on stdin):
#   bash session.sh working          # UserPromptSubmit: Claude is working
#   bash session.sh waiting          # Stop: Claude finished its turn
#   bash session.sh notification     # Notification: permission request or idle notice
#   bash session.sh end              # SessionEnd: forget the session
#   bash session.sh subagent-start   # SubagentStart: add a subagent row
#   bash session.sh subagent-stop    # SubagentStop: remove it
#
# Each session is one JSON file, <monitor dir>/sessions/<session_id>.json:
#   {name, cwd, state, since, updated, pid, entrypoint, transcript, subagents, deferredStop}
# state is working | waiting | permission; the window derives "asked a question" from the
# transcript. Nothing is written until the monitor directory exists (opening the window
# creates it), so the hooks stay idle for anyone who never opens it:
#   ~/.polaris-monitor, or on WSL the Windows profile's .polaris-monitor, because the window
#   runs on Windows there.
#
# A Stop while subagents are still running is held back (deferredStop): the session keeps
# showing as working until the last subagent stops. Writes are atomic (temp file + mv) and
# serialized per session with a mkdir lock, files are 0600 in a 0700 folder, and session and
# agent ids are validated before they become file names. Transcripts are only read when they
# are regular files under the Claude config directory's projects folder.
#
# Environment:
#   POLARIS_MONITOR_PLATFORM    force windows | wsl | macos | linux instead of detecting it
#   CLAUDE_CODE_REMOTE=true     set by Claude Code in cloud sessions: nothing is recorded
#
# The script always exits 0: a hook must never break Claude Code.

set -uo pipefail
umask 077

SUBAGENT_MAX=12
SUBAGENT_TTL=7200
SESSION_ID_RE='^[A-Za-z0-9_-]{1,128}$'
AGENT_ID_RE='^[A-Za-z0-9_.:-]{1,128}$'
NUMBER_RE='^[0-9]+$'
SEP=$'\x1f'

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOCAL_DIR="$HOME/.polaris-monitor"

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

# WSL: the Windows profile's .polaris-monitor, resolved once (cmd.exe is slow) and cached in
# ~/.polaris-monitor/winpath. Any path wslpath returns is accepted (the mount root can be
# changed in /etc/wsl.conf), as long as it is absolute and has no ".." or control
# characters. A failed lookup is not retried for 10 minutes.
windows_monitor_dir() {
    local cache="$LOCAL_DIR/winpath" dir="" profile
    local valid='^/[^[:cntrl:]]+/\.polaris-monitor$' windows_path='^[A-Za-z]:\\[^[:cntrl:]]*$'
    [ -r "$cache" ] && dir="$(head -c 400 "$cache")"
    if ! [[ $dir =~ $valid && $dir != *..* ]]; then
        dir=""
        if [ -n "$(find "$cache.fail" -mmin -10 2>/dev/null)" ]; then
            return 1
        fi
        # from a Windows folder when there is one: cmd.exe warns about a Linux working directory
        profile="$({ cd /mnt/c 2>/dev/null || cd /; } && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
        if [[ $profile =~ $windows_path ]]; then
            dir="$(wslpath -u "$profile\\.polaris-monitor" 2>/dev/null)"
            [[ $dir =~ $valid && $dir != *..* ]] || dir=""
        fi
        if [ -d "$LOCAL_DIR" ]; then
            if [ -n "$dir" ]; then echo "$dir" > "$cache"; else : > "$cache.fail"; fi
        fi
    fi
    [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] && echo "$dir"
}

# Where session files go, or nothing when the window was never opened.
monitor_dir() {
    local win
    if [ "$PLATFORM" = "wsl" ] && win="$(windows_monitor_dir)"; then
        echo "$win"
    elif [ -d "$LOCAL_DIR" ] && [ ! -L "$LOCAL_DIR" ]; then
        echo "$LOCAL_DIR"
    else
        return 1
    fi
}

# Git Bash gets Windows paths, with backslashes, from Claude Code.
to_posix() {
    if [ "$PLATFORM" = "windows" ]; then echo "${1//\\//}"; else echo "$1"; fi
}

# True for a regular file (not a link) under the Claude config directory's projects folder.
inside_projects() {
    local file root dir
    file="$(to_posix "$1")"
    [ -n "$file" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 1
    root="$(cd -P "$CONFIG_DIR/projects" 2>/dev/null && pwd -P)" || return 1
    dir="$(cd -P "$(dirname "$file")" 2>/dev/null && pwd -P)" || return 1
    case "$dir/" in
        "$root"/*) return 0 ;;
    esac
    return 1
}

# /rename writes "custom-title" to the transcript and Claude Code writes an automatic
# "ai-title": the latest custom title wins, then the latest automatic one.
session_title() {
    local transcript=$1
    inside_projects "$transcript" || return 0
    grep -E '"(custom-title|ai-title)"' "$(to_posix "$transcript")" 2>/dev/null \
        | jq -Rrn --arg sid "$SESSION_ID" '
            [inputs | fromjson? | objects | select((.sessionId // $sid) == $sid)] as $lines
            | ([$lines[] | select(.type == "custom-title") | .customTitle | strings | select(. != "")] | last)
              // ([$lines[] | select(.type == "ai-title") | .aiTitle | strings | select(. != "")] | last)
              // empty' 2>/dev/null | tr -d '\r'
}

# The Claude Code process: the first ancestor named claude or, failing that (npm installs
# run as node, native ones as a versioned binary), the first one that is not a shell.
# Only on macOS and Linux; Windows and WSL sessions fall back to the window's 6-hour rule.
claude_pid() {
    local pid=$PPID first="" line ppid name i
    for ((i = 0; i < 15; i++)); do
        line="$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)" || break
        read -r ppid name <<< "$line"
        [ -n "${ppid:-}" ] || break
        name="${name##*/}"
        name="${name#-}"
        [ "$name" = "claude" ] && { echo "$pid"; return; }
        case "$name" in
            sh | bash | zsh | dash | fish | cmd | powershell | pwsh | conhost) ;;
            *) [ -n "$first" ] || first=$pid ;;
        esac
        [ "$ppid" -gt 1 ] 2>/dev/null || break
        pid=$ppid
    done
    [ -n "$first" ] && echo "$first"
}

clean_text() {
    jq -Rrs --argjson max "$1" '
        gsub("[\u0000-\u001f\u007f]+"; " ") | gsub("\\s+"; " ")
        | sub("^ "; "") | sub(" $"; "") | .[:$max]' 2>/dev/null | tr -d '\r'
}

# What a subagent is doing: the description Claude Code stores in agent-<id>.meta.json next
# to the subagent transcript. As a last resort, after waiting for that file, the first line
# of the subagent's own prompt.
describe_subagent() {
    local transcript agent=$2 last_resort=${3:-false} folder text
    transcript="$(to_posix "$1")"
    inside_projects "$transcript" || return 0
    folder="$(dirname "$transcript")/$SESSION_ID/subagents"
    if inside_projects "$folder/agent-$agent.meta.json"; then
        text="$(head -c 65536 "$folder/agent-$agent.meta.json" \
            | jq -r '.description // empty | strings' 2>/dev/null | clean_text 160)"
        [ -n "$text" ] && { echo "$text"; return; }
    fi
    if [ "$last_resort" = true ] && inside_projects "$folder/agent-$agent.jsonl"; then
        head -n 1 "$folder/agent-$agent.jsonl" | head -c 262144 | jq -r '
            .message.content
            | if type == "string" then . elif type == "array" then map(.text? // "") | join("") else "" end
            | split("\n")[0]' 2>/dev/null | clean_text 120
    fi
}

# Serializes the read-modify-write of a session file between hook processes. A lock older
# than 5 seconds is stale. If locking is impossible the update goes ahead unlocked.
acquire_lock() {
    local lock="$1.lock" i stamp
    for ((i = 0; i < 250; i++)); do
        if mkdir "$lock" 2>/dev/null; then
            date +%s > "$lock/time"
            return 0
        fi
        stamp="$(cat "$lock/time" 2>/dev/null)"
        if [ -n "$stamp" ] && (($(date +%s) - stamp > 5)); then
            rm -rf "$lock"
        fi
        sleep 0.02
    done
    return 1
}

release_lock() {
    rm -rf "$1.lock"
}

read_session() {
    jq -c 'if type == "object" then . else {} end' "$1" 2>/dev/null | tr -d '\r' || true
}

write_session() {
    local file=$1 tmp="$1.$$.tmp"
    if cat > "$tmp" && mv -f "$tmp" "$file"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# The new session object, from the previous one, the hook input and the event.
# Prints nothing when the event must not write (subagent event for an unknown session).
next_session() {
    jq -cn \
        --argjson prev "$1" --argjson input "$INPUT" --arg event "$EVENT" --argjson now "$NOW" \
        --arg name "${2:-}" --argjson pid "${3:-null}" --arg desc "${4:-}" \
        --argjson max "$SUBAGENT_MAX" --argjson ttl "$SUBAGENT_TTL" \
        --arg entrypoint "${CLAUDE_CODE_ENTRYPOINT:-}" '
        def prune:
            [(. // [])[] | objects | select((.id | type) == "string" and ($now - (.updated // 0)) < $ttl)]
            | .[:$max];
        def agent_type:
            (. // "agent" | tostring | gsub("[^A-Za-z0-9 ._:-]"; "") | .[:40])
            | if . == "" then "agent" else . end;
        def notification_state:
            ($input.notification_type // "" | tostring | ascii_downcase) as $kind
            | ($input.message // "" | tostring | ascii_downcase) as $message
            | if ($kind | contains("permission")) or ($message | contains("permission"))
                 or ($kind | contains("elicitation"))
              then "permission" else "waiting" end;

        if $event == "subagent-start" or $event == "subagent-stop" then
            if ($prev.state // null) == null then empty else
                $input.agent_id as $id
                | ($prev.subagents | prune | map(select(.id != $id))) as $others
                | ([($prev.subagents // [])[] | objects | select(.id == $id)] | first) as $before
                | (if $event == "subagent-start" and ($others | length) < $max then
                       $others + [{
                           id: $id,
                           type: ($input.agent_type | agent_type),
                           desc: (($before.desc // "") | if . == "" then $desc else . end),
                           since: ($before.since // $now),
                           updated: $now
                       }]
                   else $others end) as $list
                | $prev + {subagents: $list}
                | if $event == "subagent-stop" and ($list | length) == 0
                     and ($prev.deferredStop // false) and $prev.state == "working"
                  then .state = "waiting" | .since = $now | .deferredStop = false
                  else . end
            end
        else
            (if $event == "notification" then notification_state else $event end) as $reported
            | ($prev.subagents | prune) as $active
            | ($reported == "waiting" and ($active | length) > 0) as $defer
            | (if $defer then "working" else $reported end) as $state
            | {
                name: $name,
                cwd: ($input.cwd // "" | tostring),
                state: $state,
                since: (if $prev.state == $state and $prev.since != null and $state != "permission"
                        then $prev.since else $now end),
                updated: $now,
                pid: ($prev.pid // $pid),
                entrypoint: (if $entrypoint != "" then $entrypoint else ($prev.entrypoint // null) end),
                transcript: ($input.transcript_path // "" | tostring),
                subagents: $active,
                deferredStop: ($defer or ($event == "notification" and ($prev.deferredStop // false)))
              }
        end' 2>/dev/null | tr -d '\r'
}

# Runs detached after a SubagentStart whose description was not written yet: Claude Code
# creates the meta file only after the hook returns. Waits up to 15 seconds, then patches
# the session file.
fill_description_later() {
    local file=$1 agent=$2 transcript=$3 waited desc="" current
    for ((waited = 0; waited <= 75; waited++)); do
        desc="$(describe_subagent "$transcript" "$agent" "$([ "$waited" -eq 75 ] && echo true)")"
        [ -n "$desc" ] && break
        sleep 0.2
    done
    [ -n "$desc" ] || return 0
    acquire_lock "$file"
    current="$(read_session "$file")"
    if [ -n "$current" ]; then
        jq -c --arg id "$agent" --arg desc "$desc" '
            .subagents = [(.subagents // [])[] | if .id == $id and (.desc // "") == "" then .desc = $desc else . end]
        ' <<< "$current" 2>/dev/null | tr -d '\r' | write_session "$file"
    fi
    release_lock "$file"
}

command -v jq > /dev/null 2>&1 || exit 0
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && exit 0
PLATFORM="$(detect_platform)"

if [ "${1:-}" = "--describe" ]; then
    SESSION_ID="${3:-}"
    fill_description_later "${2:-}" "${4:-}" "${5:-}"
    exit 0
fi

EVENT="${1:-}"
case "$EVENT" in
    working | waiting | notification | end | subagent-start | subagent-stop) ;;
    *) exit 0 ;;
esac

INPUT="$(cat 2>/dev/null)"
INPUT="$(jq -c 'if type == "object" then . else {} end' <<< "$INPUT" 2>/dev/null | tr -d '\r')"
[ -n "$INPUT" ] || INPUT='{}'

IFS="$SEP" read -r SESSION_ID AGENT_ID CWD TRANSCRIPT < <(
    jq -r --arg sep "$SEP" '
        [.session_id, .agent_id, .cwd, .transcript_path]
        | map(if type == "string" then . else "" end) | join($sep)' <<< "$INPUT" | tr -d '\r'
)

[[ ${SESSION_ID:-} =~ $SESSION_ID_RE ]] || exit 0
# A subagent finishing its turn must not mark the whole session as finished.
[ "$EVENT" = "waiting" ] && [ -n "${AGENT_ID:-}" ] && exit 0
case "$EVENT" in
    subagent-*) [[ ${AGENT_ID:-} =~ $AGENT_ID_RE ]] || exit 0 ;;
esac

DIR="$(monitor_dir)" || exit 0
mkdir -p "$DIR/sessions" 2>/dev/null || exit 0
FILE="$DIR/sessions/$SESSION_ID.json"

if [ "$EVENT" = "end" ]; then
    rm -f "$FILE"
    exit 0
fi

NOW="$(date +%s)"
NAME="" DESC="" SPAWN_DESCRIBER=false
case "$EVENT" in
    subagent-start) DESC="$(describe_subagent "${TRANSCRIPT:-}" "$AGENT_ID")" ;;
    subagent-stop) ;;
    *)
        NAME="$(session_title "${TRANSCRIPT:-}")"
        if [ -z "$NAME" ]; then
            NAME="${CWD:-}"
            NAME="${NAME%"${NAME##*[!/\\]}"}"
            NAME="${NAME##*[/\\]}"
        fi
        [ -n "$NAME" ] || NAME="${SESSION_ID:0:8}"
        ;;
esac

LOCKED=false
acquire_lock "$FILE" && LOCKED=true
PREVIOUS="$(read_session "$FILE")"
[ -n "$PREVIOUS" ] || PREVIOUS='{}'

PID=null
if [ "$EVENT" != "subagent-start" ] && [ "$EVENT" != "subagent-stop" ] \
    && [ "$DIR" = "$LOCAL_DIR" ] && { [ "$PLATFORM" = "macos" ] || [ "$PLATFORM" = "linux" ]; } \
    && [ "$(jq -r '.pid // empty' <<< "$PREVIOUS" | tr -d '\r')" = "" ]; then
    PID="$(claude_pid)"
    [[ $PID =~ $NUMBER_RE ]] || PID=null
fi

UPDATED="$(next_session "$PREVIOUS" "$NAME" "$PID" "$DESC")"
if [ -n "$UPDATED" ]; then
    printf '%s\n' "$UPDATED" | write_session "$FILE"
    if [ "$EVENT" = "subagent-start" ] && [ -z "$DESC" ] && inside_projects "${TRANSCRIPT:-}" \
        && [ "$(jq -r --arg id "$AGENT_ID" '.subagents[] | select(.id == $id) | .desc' <<< "$UPDATED" | tr -d '\r')" = "" ]; then
        SPAWN_DESCRIBER=true
    fi
fi
[ "$LOCKED" = true ] && release_lock "$FILE"

if [ "$SPAWN_DESCRIBER" = true ]; then
    if command -v setsid > /dev/null 2>&1; then
        setsid bash "${BASH_SOURCE[0]}" --describe "$FILE" "$SESSION_ID" "$AGENT_ID" "$TRANSCRIPT" \
            < /dev/null > /dev/null 2>&1 &
    else
        (
            trap '' HUP INT TERM
            fill_description_later "$FILE" "$AGENT_ID" "$TRANSCRIPT"
        ) < /dev/null > /dev/null 2>&1 &
    fi
fi
exit 0
