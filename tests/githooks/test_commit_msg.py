"""Tests for the Conventional Commits hook at .githooks/commit-msg."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
HOOK = REPO_ROOT / ".githooks" / "commit-msg"


def run_hook(tmp_path: Path, message: str) -> int:
    message_file = tmp_path / "COMMIT_EDITMSG"
    message_file.write_text(f"{message}\n", encoding="utf-8")
    return subprocess.run([HOOK, message_file], capture_output=True, check=False).returncode


@pytest.mark.parametrize(
    "message",
    [
        "feat: add polaris marketplace registry",
        "fix(documentation): handle detached HEAD",
        "feat!: rename plugin",
        "build(deps)!: drop python 3.11",
        "chore: update dependencies\n\nLonger body is ignored.",
        "Merge pull request #1 from PLeonLopes/chore/bootstrap-repo",
        "Merge branch 'main' into feat/pr-description-skill",
        'Revert "feat: add something"',
        "fixup! feat: add something",
    ],
)
def test_accepts_valid_messages(tmp_path: Path, message: str) -> None:
    assert run_hook(tmp_path, message) == 0


@pytest.mark.parametrize(
    "message",
    [
        "added new skill",
        "Feat: capitalized type",
        "feat - wrong separator",
        "feat:missing space",
        "wip: unknown type",
        "feat(Docs): uppercase scope",
        "feat: ",
    ],
)
def test_rejects_invalid_messages(tmp_path: Path, message: str) -> None:
    assert run_hook(tmp_path, message) == 1
