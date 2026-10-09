"""Tests for scripts/ci/check-plugin-versions.py.

Each test builds a throwaway git repository: `main` holds a marketplace with one plugin
(`polaris-docs` 1.0.0, marketplace 0.1.0) and the test commits its changes on a branch.
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT_PATH = REPO_ROOT / "scripts" / "ci" / "check-plugin-versions.py"


def _load_script():
    spec = importlib.util.spec_from_file_location("_check_plugin_versions", SCRIPT_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check = _load_script().check


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def plugin_manifest(repo: Path, domain: str) -> Path:
    return repo / "plugins" / domain / ".claude-plugin" / "plugin.json"


def marketplace_manifest(repo: Path) -> Path:
    return repo / ".claude-plugin" / "marketplace.json"


def set_version(path: Path, version: str, key: str = "version") -> None:
    data = json.loads(path.read_text())
    if key == "metadata.version":
        data["metadata"]["version"] = version
    else:
        data[key] = version
    write_json(path, data)


def add_plugin(repo: Path, domain: str, version: str) -> None:
    write_json(
        plugin_manifest(repo, domain),
        {"name": f"polaris-{domain}", "version": version, "description": "x"},
    )
    data = json.loads(marketplace_manifest(repo).read_text())
    data["plugins"].append(
        {"name": f"polaris-{domain}", "source": f"./plugins/{domain}", "description": "x"}
    )
    write_json(marketplace_manifest(repo), data)


def commit_all(repo: Path, message: str = "chore: change") -> None:
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    git(tmp_path, "init", "-q", "-b", "main")
    git(tmp_path, "config", "user.email", "test@example.com")
    git(tmp_path, "config", "user.name", "Test")
    write_json(
        marketplace_manifest(tmp_path),
        {"name": "polaris", "metadata": {"version": "0.1.0"}, "plugins": []},
    )
    add_plugin(tmp_path, "docs", "1.0.0")
    (tmp_path / "plugins" / "docs" / "README.md").write_text("# Docs\n", encoding="utf-8")
    commit_all(tmp_path, "feat: initial")
    git(tmp_path, "checkout", "-q", "-b", "feature")
    return tmp_path


def touch_plugin(repo: Path) -> None:
    (repo / "plugins" / "docs" / "README.md").write_text("# Docs v2\n", encoding="utf-8")


def test_no_plugin_changes_pass(repo: Path) -> None:
    (repo / "README.md").write_text("# Root\n", encoding="utf-8")
    commit_all(repo)
    assert check(repo, "main") == []


def test_changed_plugin_without_bump_fails(repo: Path) -> None:
    touch_plugin(repo)
    commit_all(repo)
    errors = check(repo, "main")
    assert len(errors) == 1
    assert "plugins/docs: files changed but version was not bumped" in errors[0]


def test_bumped_plugin_and_marketplace_pass(repo: Path) -> None:
    touch_plugin(repo)
    set_version(plugin_manifest(repo, "docs"), "1.1.0")
    set_version(marketplace_manifest(repo), "0.2.0", key="metadata.version")
    commit_all(repo)
    assert check(repo, "main") == []


def test_bumped_plugin_without_marketplace_bump_fails(repo: Path) -> None:
    touch_plugin(repo)
    set_version(plugin_manifest(repo, "docs"), "1.0.1")
    commit_all(repo)
    errors = check(repo, "main")
    assert len(errors) == 1
    assert "metadata.version was not bumped" in errors[0]


@pytest.mark.parametrize("version", ["1.0.0", "0.9.0", "not-semver"])
def test_version_not_greater_fails(repo: Path, version: str) -> None:
    touch_plugin(repo)
    set_version(plugin_manifest(repo, "docs"), version)
    set_version(marketplace_manifest(repo), "0.2.0", key="metadata.version")
    commit_all(repo)
    errors = check(repo, "main")
    assert len(errors) == 1
    assert "version was not bumped" in errors[0]


def test_semver_compares_numerically(repo: Path) -> None:
    touch_plugin(repo)
    set_version(plugin_manifest(repo, "docs"), "1.10.0")
    set_version(marketplace_manifest(repo), "0.10.0", key="metadata.version")
    commit_all(repo)
    assert check(repo, "main") == []


def test_new_plugin_at_initial_version_passes(repo: Path) -> None:
    add_plugin(repo, "git", "1.0.0")
    set_version(marketplace_manifest(repo), "0.2.0", key="metadata.version")
    commit_all(repo)
    assert check(repo, "main") == []


def test_new_plugin_with_other_version_fails(repo: Path) -> None:
    add_plugin(repo, "git", "0.1.0")
    set_version(marketplace_manifest(repo), "0.2.0", key="metadata.version")
    commit_all(repo)
    errors = check(repo, "main")
    assert len(errors) == 1
    assert "new plugin must start at 1.0.0" in errors[0]


def test_removed_plugin_requires_marketplace_bump(repo: Path) -> None:
    shutil.rmtree(repo / "plugins" / "docs")
    data = json.loads(marketplace_manifest(repo).read_text())
    data["plugins"] = []
    write_json(marketplace_manifest(repo), data)
    commit_all(repo)
    errors = check(repo, "main")
    assert len(errors) == 1
    assert "metadata.version was not bumped" in errors[0]

    set_version(marketplace_manifest(repo), "1.0.0", key="metadata.version")
    commit_all(repo)
    assert check(repo, "main") == []


def test_uncommitted_changes_are_ignored(repo: Path) -> None:
    touch_plugin(repo)
    assert check(repo, "main") == []


def test_unknown_base_ref_fails(repo: Path) -> None:
    errors = check(repo, "does-not-exist")
    assert len(errors) == 1
    assert "cannot find merge base" in errors[0]


def run_cli(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, SCRIPT_PATH, *args],
        cwd=repo,
        capture_output=True,
        text=True,
        check=False,
    )


def test_cli_exit_codes(repo: Path) -> None:
    assert run_cli(repo, "main").returncode == 0

    touch_plugin(repo)
    commit_all(repo)
    result = run_cli(repo, "main")
    assert result.returncode == 1
    assert "1 error(s)" in result.stdout

    assert run_cli(repo).returncode == 2
