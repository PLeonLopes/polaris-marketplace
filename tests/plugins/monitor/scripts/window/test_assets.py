"""Checks the mascots and themes shipped with the monitor window against the rules both
windows apply when they load them (an entry that breaks a rule is silently skipped there)."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[5]
WINDOW_DIR = REPO_ROOT / "plugins" / "monitor" / "scripts" / "window"

KEY = re.compile(r"^[a-z0-9-]{1,32}$")
COLOR = re.compile(r"^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$")
THEME_COLORS = {
    "card", "text", "muted", "faint", "accent", "divider", "track", "bar", "barWarning",
    "barCritical", "working", "finished", "question", "permission",
}  # fmt: skip

MASCOTS = json.loads((WINDOW_DIR / "mascots.json").read_text())
THEMES = json.loads((WINDOW_DIR / "themes.json").read_text())


def test_the_built_in_mascots_and_themes_are_there() -> None:
    assert list(MASCOTS) == ["star", "clawd"]
    assert list(THEMES) == ["dark", "light", "midnight", "contrast"]


@pytest.mark.parametrize("key", list(MASCOTS))
def test_mascots_follow_the_loading_rules(key: str) -> None:
    mascot = MASCOTS[key]
    sprite, (pw, ph), colors = mascot["sprite"], mascot["pixel"], mascot["colors"]

    assert KEY.match(key)
    assert mascot["name"].strip()
    assert sprite
    assert len({len(row) for row in sprite}) == 1, "rows must have the same width"
    assert set("".join(sprite)) <= set(".#ouAB")
    assert pw >= 0.5
    assert ph >= 0.5
    assert len(sprite) * ph <= 32, "taller than the room above the card"
    assert len(sprite[0]) * pw <= 64
    for part in ("body", "face", "feet"):
        assert COLOR.match(colors[part]), part
    assert "outline" not in colors or COLOR.match(colors["outline"])


@pytest.mark.parametrize("key", list(THEMES))
def test_themes_define_every_color(key: str) -> None:
    theme = THEMES[key]

    assert KEY.match(key)
    assert theme["name"].strip()
    assert set(theme) - {"name"} == THEME_COLORS
    for color in THEME_COLORS:
        assert COLOR.match(theme[color]), color


def test_clawd_is_about_as_big_as_the_star() -> None:
    def area(key: str) -> float:
        sprite, (pw, ph) = MASCOTS[key]["sprite"], MASCOTS[key]["pixel"]
        return len(sprite[0]) * pw * len(sprite) * ph

    assert area("clawd") >= 0.85 * area("star")
