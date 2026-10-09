#!/usr/bin/env bash
# Validates every commit in <base>..<head> with .githooks/commit-msg, so CI applies
# exactly the same Conventional Commits rule as the local hook.
#
# Usage:
#   bash scripts/ci/check-commit-messages.sh <base-ref> [head-ref]
#   bash scripts/ci/check-commit-messages.sh origin/main          # local check
#
# Exit codes:
#   0 - every commit message is valid
#   1 - at least one commit message is invalid (each is listed)
#   2 - usage error

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: check-commit-messages.sh <base-ref> [head-ref]" >&2
    exit 2
fi

BASE="$1"
HEAD="${2:-HEAD}"
HOOK="$(git rev-parse --show-toplevel)/.githooks/commit-msg"
MESSAGE_FILE="$(mktemp)"
trap 'rm -f "$MESSAGE_FILE"' EXIT

INVALID=0
CHECKED=0
for sha in $(git rev-list --reverse "$BASE..$HEAD"); do
    git log -1 --format=%B "$sha" > "$MESSAGE_FILE"
    CHECKED=$((CHECKED + 1))
    if ! "$HOOK" "$MESSAGE_FILE" 2>/dev/null; then
        echo "  ✗ $(git log -1 --format='%h %s' "$sha")"
        INVALID=$((INVALID + 1))
    fi
done

if [ "$INVALID" -gt 0 ]; then
    echo ""
    echo "ERROR: $INVALID of $CHECKED commit(s) do not follow Conventional Commits."
    echo "Expected: <type>[(scope)][!]: <description> — see CONTRIBUTING.md."
    echo "Fix them with an interactive rebase (git rebase -i $BASE) and force-push."
    exit 1
fi

echo "All $CHECKED commit(s) follow Conventional Commits."
