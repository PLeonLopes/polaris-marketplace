"""Tests for scripts/ci/determine-bump.sh."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "scripts" / "ci" / "determine-bump.sh"


def bump(subjects: str) -> str:
    result = subprocess.run(
        ["bash", SCRIPT], input=subjects, capture_output=True, text=True, check=True
    )
    return result.stdout.strip()


@pytest.mark.parametrize(
    ("subjects", "expected"),
    [
        ("fix: a\ndocs: b\nchore: c\n", "patch"),
        ("fix: a\nfeat: b\n", "minor"),
        ("feat(documentation): add skill\n", "minor"),
        ("feat: a\nrefactor!: b\nfix: c\n", "major"),
        ("fix(ci)!: drop old workflow\n", "major"),
        ("- feat: prefixed by the PR commit list format\n", "minor"),
        ("Merge pull request #1 from user/feat/x\nchore: y\n", "patch"),
        ("", "patch"),
    ],
)
def test_bump_from_commit_types(subjects: str, expected: str) -> None:
    assert bump(subjects) == expected


def test_last_line_without_trailing_newline_is_read() -> None:
    assert bump("fix: a\nfeat: b") == "minor"


@pytest.mark.parametrize(
    "subject",
    [
        "feature: legacy alias is not a valid type",
        "feat:missing space",
        "Feat: capitalized type",
        "feat!feat: malformed",
    ],
)
def test_non_conventional_subjects_are_patch(subject: str) -> None:
    assert bump(f"{subject}\n") == "patch"
