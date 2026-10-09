"""Tests for scripts/ci/check-commit-messages.sh.

The script resolves the hook from the repository it runs in, so each test builds a
throwaway git repository with a copy of .githooks/commit-msg.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "scripts" / "ci" / "check-commit-messages.sh"
HOOK = REPO_ROOT / ".githooks" / "commit-msg"


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)


def commit(repo: Path, message: str) -> None:
    git(repo, "commit", "-q", "--allow-empty", "-m", message)


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    git(tmp_path, "init", "-q", "-b", "main")
    git(tmp_path, "config", "user.email", "test@example.com")
    git(tmp_path, "config", "user.name", "Test")
    (tmp_path / ".githooks").mkdir()
    shutil.copy2(HOOK, tmp_path / ".githooks" / "commit-msg")
    git(tmp_path, "add", "-A")
    commit(tmp_path, "chore: initial")
    git(tmp_path, "checkout", "-q", "-b", "feature")
    return tmp_path


def run(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", SCRIPT, *args], cwd=repo, capture_output=True, text=True, check=False
    )


def test_all_valid_commits_pass(repo: Path) -> None:
    commit(repo, "feat: add something")
    commit(repo, "fix(docs): correct typo")
    result = run(repo, "main")
    assert result.returncode == 0
    assert "All 2 commit(s)" in result.stdout


def test_invalid_commits_are_listed(repo: Path) -> None:
    commit(repo, "feat: add something")
    commit(repo, "updated stuff")
    commit(repo, "WIP")
    result = run(repo, "main")
    assert result.returncode == 1
    assert "2 of 3 commit(s)" in result.stdout
    assert "updated stuff" in result.stdout
    assert "WIP" in result.stdout


def test_merge_commits_are_accepted(repo: Path) -> None:
    commit(repo, "Merge pull request #1 from user/feat/x")
    assert run(repo, "main").returncode == 0


def test_empty_range_passes(repo: Path) -> None:
    result = run(repo, "main")
    assert result.returncode == 0
    assert "All 0 commit(s)" in result.stdout


def test_explicit_head_ref(repo: Path) -> None:
    commit(repo, "bad message")
    git(repo, "branch", "good", "main")
    assert run(repo, "main", "good").returncode == 0
    assert run(repo, "main", "feature").returncode == 1


def test_missing_base_is_usage_error(repo: Path) -> None:
    assert run(repo).returncode == 2
