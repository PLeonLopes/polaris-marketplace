#!/usr/bin/env bash
# Reads commit subjects from stdin (one per line, an optional leading "- " is
# stripped) and writes the highest applicable semver bump to stdout:
# major, minor or patch.
#
# Bump rules (highest wins; stops early on major):
#   Breaking change  <type>(<scope>)!:  → major
#   New feature      feat(<scope>):     → minor
#   Everything else                     → patch
#
# Usage:
#   git log --format=%s v1.2.0..HEAD | bash scripts/ci/determine-bump.sh

set -euo pipefail

TYPES='feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert'
BUMP="patch"

# "|| -n" keeps the last line when the input has no trailing newline
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    subject="${raw_line#- }"

    # Skip auto-generated merge commits
    if [[ "$subject" =~ ^Merge\ (branch|pull\ request|remote) ]]; then
        continue
    fi

    # Breaking change → MAJOR: nothing outranks it, stop immediately
    if [[ "$subject" =~ ^($TYPES)(\([^\)]+\))?!:\  ]]; then
        BUMP="major"
        break
    fi

    # New feature → MINOR: keep reading in case a breaking change follows
    if [[ "$subject" =~ ^feat(\([^\)]+\))?:\  ]]; then
        BUMP="minor"
    fi
done

echo "$BUMP"
