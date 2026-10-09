#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Check that a branch bumps plugin and marketplace versions when it should.

Versions are bumped by hand in the pull request (see CONTRIBUTING.md, "Versioning").
Committed state only: HEAD is compared with the merge base of <base-ref> and HEAD.

- a plugin whose files changed must have a higher `version` in its plugin.json;
- a new plugin must start at 1.0.0;
- when any plugin is added, removed or bumped, or the marketplace plugin list
  changes, `metadata.version` in marketplace.json must be higher.

Usage:
    uv run scripts/ci/check-plugin-versions.py <base-ref>
    uv run scripts/ci/check-plugin-versions.py origin/main

Exit codes:
    0 - Every required version bump is present
    1 - One or more bumps are missing (each printed on its own line)
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

MARKETPLACE = ".claude-plugin/marketplace.json"
INITIAL_PLUGIN_VERSION = "1.0.0"
SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True, check=False)


def read_json_at(repo: Path, ref: str, path: str) -> dict | None:
    """Return the JSON object at `ref:path`, or None if it does not exist there."""
    result = git(repo, "show", f"{ref}:{path}")
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def parse_version(version: object) -> tuple[int, int, int] | None:
    match = SEMVER.match(str(version))
    if match is None:
        return None
    major, minor, patch = (int(part) for part in match.groups())
    return major, minor, patch


def is_bumped(old: object, new: object) -> bool:
    old_version, new_version = parse_version(old), parse_version(new)
    return old_version is not None and new_version is not None and new_version > old_version


def changed_plugins(changed_files: list[str]) -> set[str]:
    """Plugin directory names with at least one changed file."""
    return {
        parts[1]
        for parts in (path.split("/") for path in changed_files)
        if len(parts) >= 3 and parts[0] == "plugins"
    }


def check(repo: Path, base_ref: str) -> list[str]:
    """Return the missing version bumps between the merge base of `base_ref` and HEAD."""
    merge_base = git(repo, "merge-base", base_ref, "HEAD")
    if merge_base.returncode != 0:
        return [f"cannot find merge base of '{base_ref}' and HEAD: {merge_base.stderr.strip()}"]
    base = merge_base.stdout.strip()

    diff = git(repo, "diff", "--name-only", f"{base}...HEAD")
    changed_files = diff.stdout.splitlines()

    errors: list[str] = []
    marketplace_needs_bump = False

    for plugin in sorted(changed_plugins(changed_files)):
        manifest = f"plugins/{plugin}/.claude-plugin/plugin.json"
        old = read_json_at(repo, base, manifest)
        new = read_json_at(repo, "HEAD", manifest)

        if new is None:
            marketplace_needs_bump = True  # plugin removed
        elif old is None:
            marketplace_needs_bump = True  # plugin added
            if new.get("version") != INITIAL_PLUGIN_VERSION:
                errors.append(
                    f"plugins/{plugin}: new plugin must start at {INITIAL_PLUGIN_VERSION} "
                    f"(found {new.get('version')})"
                )
        elif is_bumped(old.get("version"), new.get("version")):
            marketplace_needs_bump = True
        else:
            errors.append(
                f"plugins/{plugin}: files changed but version was not bumped in {manifest} "
                f"({old.get('version')} -> {new.get('version')})"
            )

    old_marketplace = read_json_at(repo, base, MARKETPLACE) or {}
    new_marketplace = read_json_at(repo, "HEAD", MARKETPLACE) or {}
    if old_marketplace.get("plugins") != new_marketplace.get("plugins"):
        marketplace_needs_bump = True

    old_version = old_marketplace.get("metadata", {}).get("version")
    new_version = new_marketplace.get("metadata", {}).get("version")
    if marketplace_needs_bump and not is_bumped(old_version, new_version):
        errors.append(
            f"{MARKETPLACE}: plugins were added, removed or bumped but metadata.version "
            f"was not bumped ({old_version} -> {new_version})"
        )

    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-plugin-versions.py <base-ref>", file=sys.stderr)
        return 2
    repo = Path(git(Path.cwd(), "rev-parse", "--show-toplevel").stdout.strip())
    errors = check(repo, sys.argv[1])
    if errors:
        print(f"Version check failed with {len(errors)} error(s):")
        for error in errors:
            print(f"  - {error}")
        print("Bump rules: feat -> minor, breaking (!) -> major, others -> patch.")
        return 1
    print("Version check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
