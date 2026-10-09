"""Tests for scripts/ci/validate-marketplace.py.

The script name is hyphenated (a CI entry point, not an import target), so it is loaded
through importlib under a private module name. The CLI exit-code contract is exercised
via subprocess.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT_PATH = REPO_ROOT / "scripts" / "ci" / "validate-marketplace.py"


def _load_script():
    spec = importlib.util.spec_from_file_location("_validate_marketplace", SCRIPT_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validate = _load_script().validate

VALID_SKILL = """---
name: {name}
description: Does something useful. Use when the user asks for it.
---

# Skill
"""


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


@pytest.fixture
def marketplace(tmp_path: Path) -> Path:
    """A valid marketplace with one plugin and one skill."""
    write_json(
        tmp_path / ".claude-plugin" / "marketplace.json",
        {
            "name": "polaris",
            "owner": {"name": "tester"},
            "metadata": {"version": "0.1.0"},
            "plugins": [
                {
                    "name": "polaris-docs",
                    "source": "./plugins/docs",
                    "description": "Docs plugin.",
                }
            ],
        },
    )
    write_json(
        tmp_path / "plugins" / "docs" / ".claude-plugin" / "plugin.json",
        {"name": "polaris-docs", "version": "1.0.0", "description": "Docs plugin."},
    )
    skill = tmp_path / "plugins" / "docs" / "skills" / "my-skill" / "SKILL.md"
    skill.parent.mkdir(parents=True)
    skill.write_text(VALID_SKILL.format(name="my-skill"), encoding="utf-8")
    return tmp_path


def assert_single_error(root: Path, fragment: str) -> None:
    errors = validate(root)
    assert len(errors) == 1, errors
    assert fragment in errors[0]


def test_valid_marketplace_passes(marketplace: Path) -> None:
    assert validate(marketplace) == []


def test_empty_marketplace_passes(tmp_path: Path) -> None:
    write_json(
        tmp_path / ".claude-plugin" / "marketplace.json",
        {"name": "polaris", "metadata": {"version": "0.1.0"}, "plugins": []},
    )
    (tmp_path / "plugins").mkdir()
    assert validate(tmp_path) == []


def test_missing_marketplace_json(tmp_path: Path) -> None:
    assert_single_error(tmp_path, "file not found")


def test_unregistered_plugin_directory(marketplace: Path) -> None:
    (marketplace / "plugins" / "orphan").mkdir()
    assert_single_error(marketplace, "not registered")


def test_registered_plugin_without_directory(marketplace: Path) -> None:
    path = marketplace / ".claude-plugin" / "marketplace.json"
    data = json.loads(path.read_text())
    data["plugins"].append(
        {"name": "polaris-ghost", "source": "./plugins/ghost", "description": "Missing."}
    )
    write_json(path, data)
    assert_single_error(marketplace, "does not exist")


def test_plugin_name_without_prefix(marketplace: Path) -> None:
    for path in (
        marketplace / ".claude-plugin" / "marketplace.json",
        marketplace / "plugins" / "docs" / ".claude-plugin" / "plugin.json",
    ):
        data = json.loads(path.read_text())
        if "plugins" in data:
            data["plugins"][0]["name"] = "docs"
        else:
            data["name"] = "docs"
        write_json(path, data)
    assert_single_error(marketplace, "must start with 'polaris-'")


def test_manifest_name_mismatch(marketplace: Path) -> None:
    path = marketplace / "plugins" / "docs" / ".claude-plugin" / "plugin.json"
    write_json(path, {"name": "polaris-other", "version": "1.0.0", "description": "x"})
    assert_single_error(marketplace, "differs")


@pytest.mark.parametrize("version", ["1.0", "v1.0.0", "latest", ""])
def test_invalid_plugin_version(marketplace: Path, version: str) -> None:
    path = marketplace / "plugins" / "docs" / ".claude-plugin" / "plugin.json"
    write_json(path, {"name": "polaris-docs", "version": version, "description": "x"})
    assert_single_error(marketplace, "semver")


def test_duplicate_plugin_names(marketplace: Path) -> None:
    path = marketplace / ".claude-plugin" / "marketplace.json"
    data = json.loads(path.read_text())
    data["plugins"].append(dict(data["plugins"][0]))
    write_json(path, data)
    errors = validate(marketplace)
    assert any("duplicate plugin name" in error for error in errors), errors


def test_skill_name_must_match_directory(marketplace: Path) -> None:
    skill = marketplace / "plugins" / "docs" / "skills" / "my-skill" / "SKILL.md"
    skill.write_text(VALID_SKILL.format(name="other-name"), encoding="utf-8")
    assert_single_error(marketplace, "must equal directory")


def test_skill_without_frontmatter(marketplace: Path) -> None:
    skill = marketplace / "plugins" / "docs" / "skills" / "my-skill" / "SKILL.md"
    skill.write_text("# No frontmatter\n", encoding="utf-8")
    assert_single_error(marketplace, "frontmatter")


def test_skill_without_description(marketplace: Path) -> None:
    skill = marketplace / "plugins" / "docs" / "skills" / "my-skill" / "SKILL.md"
    skill.write_text("---\nname: my-skill\n---\n", encoding="utf-8")
    assert_single_error(marketplace, "description is required")


def test_skill_description_too_long(marketplace: Path) -> None:
    skill = marketplace / "plugins" / "docs" / "skills" / "my-skill" / "SKILL.md"
    skill.write_text(f"---\nname: my-skill\ndescription: {'x' * 1025}\n---\n", encoding="utf-8")
    assert_single_error(marketplace, "exceeds 1024")


def test_nested_skill_is_rejected(marketplace: Path) -> None:
    nested = marketplace / "plugins" / "docs" / "skills" / "domain" / "deep-skill" / "SKILL.md"
    nested.parent.mkdir(parents=True)
    nested.write_text(VALID_SKILL.format(name="deep-skill"), encoding="utf-8")
    assert_single_error(marketplace, "must be flat")


@pytest.mark.parametrize(
    "line",
    [
        "Run /home/someone/scripts/tool.sh",
        "Open /Users/someone/project/file.md",
        "Path C:\\Users\\someone\\file.txt",
    ],
)
def test_hardcoded_user_path(marketplace: Path, line: str) -> None:
    script = marketplace / "plugins" / "docs" / "scripts" / "run.sh"
    script.parent.mkdir()
    script.write_text(f"#!/usr/bin/env bash\n{line}\n", encoding="utf-8")
    assert_single_error(marketplace, "hardcoded user path")


def test_plugin_root_variable_is_allowed(marketplace: Path) -> None:
    script = marketplace / "plugins" / "docs" / "scripts" / "run.sh"
    script.parent.mkdir()
    script.write_text('"${CLAUDE_PLUGIN_ROOT}/scripts/tool.sh"\n', encoding="utf-8")
    assert validate(marketplace) == []


def run_cli(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, SCRIPT_PATH, root], capture_output=True, text=True, check=False
    )


def test_cli_exits_zero_when_valid(marketplace: Path) -> None:
    result = run_cli(marketplace)
    assert result.returncode == 0
    assert "passed" in result.stdout


def test_cli_exits_one_and_lists_errors(marketplace: Path) -> None:
    (marketplace / "plugins" / "orphan").mkdir()
    result = run_cli(marketplace)
    assert result.returncode == 1
    assert "1 error(s)" in result.stdout
    assert "not registered" in result.stdout


def test_skill_name_must_be_a_string(marketplace: Path) -> None:
    skill = marketplace / "plugins" / "docs" / "skills" / "my-skill" / "SKILL.md"
    skill.write_text("---\nname: 123\ndescription: Numeric name.\n---\n", encoding="utf-8")
    assert_single_error(marketplace, "must equal directory")
