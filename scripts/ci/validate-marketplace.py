#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml>=6.0.2"]
# ///
"""Validate the Polaris marketplace structure and conventions.

Complements `claude plugin validate` (schema checks) with the repository's own rules:

- every plugin directory is registered in marketplace.json, and vice versa;
- plugin names follow `polaris-<domain>` and match their manifest;
- plugin versions are semver;
- skills are flat (`skills/<name>/SKILL.md`) with valid frontmatter;
- no hardcoded user-specific paths inside plugins.

Usage:
    uv run scripts/ci/validate-marketplace.py [repo-root]

Exit codes:
    0 - The marketplace follows every convention
    1 - One or more violations were found (each printed on its own line)
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

PLUGIN_PREFIX = "polaris-"
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
KEBAB_CASE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SKILL_NAME_MAX = 64
DESCRIPTION_MAX = 1024
HARDCODED_PATH = re.compile(r"(/home/[^/\s]+/|/Users/[^/\s]+/|[A-Za-z]:\\Users\\)")
TEXT_SUFFIXES = {".md", ".json", ".yaml", ".yml", ".py", ".sh", ".txt", ".toml"}


def load_json(path: Path, errors: list[str]) -> dict | None:
    """Load a JSON object, recording an error instead of raising."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        errors.append(f"{path}: file not found")
        return None
    except json.JSONDecodeError as exc:
        errors.append(f"{path}: invalid JSON ({exc})")
        return None
    if not isinstance(data, dict):
        errors.append(f"{path}: expected a JSON object")
        return None
    return data


def parse_frontmatter(text: str) -> dict | None:
    """Return the YAML frontmatter of a Markdown document, or None if absent/invalid."""
    match = re.match(r"^---\r?\n(.*?)\r?\n---\r?\n", text, re.DOTALL)
    if not match:
        return None
    try:
        data = yaml.safe_load(match.group(1))
    except yaml.YAMLError:
        return None
    return data if isinstance(data, dict) else None


def validate_skills(plugin_dir: Path, errors: list[str]) -> None:
    """Check every SKILL.md in a plugin: flat layout, name and description."""
    skills_dir = plugin_dir / "skills"
    if not skills_dir.is_dir():
        return

    for skill_md in sorted(skills_dir.rglob("SKILL.md")):
        skill_dir = skill_md.parent
        if skill_dir.parent != skills_dir:
            errors.append(f"{skill_md}: skills must be flat (skills/<name>/SKILL.md)")
            continue

        frontmatter = parse_frontmatter(skill_md.read_text(encoding="utf-8"))
        if frontmatter is None:
            errors.append(f"{skill_md}: missing or invalid YAML frontmatter")
            continue

        name = frontmatter.get("name")
        if not isinstance(name, str) or name != skill_dir.name:
            errors.append(f"{skill_md}: name '{name}' must equal directory '{skill_dir.name}'")
        elif not KEBAB_CASE.match(name) or len(name) > SKILL_NAME_MAX:
            errors.append(f"{skill_md}: name must be kebab-case, at most {SKILL_NAME_MAX} chars")

        description = frontmatter.get("description")
        if not isinstance(description, str) or not description.strip():
            errors.append(f"{skill_md}: description is required")
        elif len(description) > DESCRIPTION_MAX:
            errors.append(f"{skill_md}: description exceeds {DESCRIPTION_MAX} chars")


def validate_paths(plugin_dir: Path, errors: list[str]) -> None:
    """Flag user-specific absolute paths; plugins must use ${CLAUDE_PLUGIN_ROOT}."""
    for path in sorted(plugin_dir.rglob("*")):
        if not path.is_file() or path.suffix not in TEXT_SUFFIXES:
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if HARDCODED_PATH.search(line):
                errors.append(f"{path}:{lineno}: hardcoded user path, use ${{CLAUDE_PLUGIN_ROOT}}")


def validate_plugin(root: Path, entry: dict, errors: list[str]) -> Path | None:
    """Check one marketplace entry against its plugin directory and manifest."""
    name = entry.get("name")
    source = entry.get("source")
    label = f"marketplace entry '{name}'"

    if not isinstance(name, str) or not name.startswith(PLUGIN_PREFIX):
        errors.append(f"{label}: name must start with '{PLUGIN_PREFIX}'")
    if not entry.get("description"):
        errors.append(f"{label}: description is required")
    if not isinstance(source, str) or not source.startswith("./plugins/"):
        errors.append(f"{label}: source must be './plugins/<domain>'")
        return None

    plugin_dir = (root / source).resolve()
    if not plugin_dir.is_dir():
        errors.append(f"{label}: source directory {source} does not exist")
        return None

    manifest = load_json(plugin_dir / ".claude-plugin" / "plugin.json", errors)
    if manifest is not None:
        if manifest.get("name") != name:
            errors.append(f"{label}: plugin.json name '{manifest.get('name')}' differs")
        if not SEMVER.match(str(manifest.get("version", ""))):
            errors.append(f"{label}: plugin.json version must be semver (X.Y.Z)")
        if not manifest.get("description"):
            errors.append(f"{label}: plugin.json description is required")

    validate_skills(plugin_dir, errors)
    validate_paths(plugin_dir, errors)
    return plugin_dir


def validate(root: Path) -> list[str]:
    """Validate the marketplace rooted at `root` and return a list of error messages."""
    errors: list[str] = []
    marketplace = load_json(root / ".claude-plugin" / "marketplace.json", errors)
    if marketplace is None:
        return errors

    if not marketplace.get("name"):
        errors.append("marketplace.json: name is required")
    if not SEMVER.match(str(marketplace.get("metadata", {}).get("version", ""))):
        errors.append("marketplace.json: metadata.version must be semver (X.Y.Z)")

    entries = marketplace.get("plugins")
    if not isinstance(entries, list):
        errors.append("marketplace.json: plugins must be a list")
        return errors

    names = [entry.get("name") for entry in entries]
    for duplicate in sorted({n for n in names if names.count(n) > 1}):
        errors.append(f"marketplace.json: duplicate plugin name '{duplicate}'")

    registered = {validate_plugin(root, entry, errors) for entry in entries}

    plugins_root = root / "plugins"
    if plugins_root.is_dir():
        for plugin_dir in sorted(p for p in plugins_root.iterdir() if p.is_dir()):
            if plugin_dir.resolve() not in registered:
                errors.append(f"{plugin_dir}: plugin directory not registered in marketplace.json")

    return errors


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    errors = validate(root)
    if errors:
        print(f"Marketplace validation failed with {len(errors)} error(s):")
        for error in errors:
            print(f"  - {error}")
        return 1
    print("Marketplace validation passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
