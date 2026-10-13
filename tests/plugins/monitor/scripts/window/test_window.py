"""Renders the real monitor window off screen and checks what it drew.

window.ps1 runs on Windows (Windows PowerShell 5.1 and WPF) and window.swift on macOS (compiled
with xcrun swiftc). Both get the same sessions and must report and draw the same things: each
test is skipped where its window cannot run.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path

import pytest

from tests.png import count_color, read_png

REPO_ROOT = Path(__file__).resolve().parents[5]
WINDOW_DIR = REPO_ROOT / "plugins" / "monitor" / "scripts" / "window"

GREEN, YELLOW, RED, BLUE, AMBER = "#22C55E", "#FACC15", "#EF4444", "#699BFB", "#F59E0B"
STAR_OUTLINE, CLAWD = "#854D0E", "#D77757"

Snapshot = Callable[..., tuple[list[str], Path]]


def menu(theme: str = "Dark", size: str = "Normal") -> str:
    """The right-click menu as the snapshot reports it ("*" = checked, "-" = separator)."""
    themes = ", ".join(
        t + ("*" if t == theme else "") for t in ("Dark", "Light", "Midnight", "High contrast")
    )
    sizes = ", ".join(z + ("*" if z == size else "") for z in ("Small", "Normal", "Large"))
    return (
        "menu: Show mascot* | Mascot: Polaris star* | Mascot: Clawd | - | "
        f"Theme > {themes} | Size > {sizes} | - | "
        "Show usage* | Show subagents* | Window sound | Opacity | Volume | - | Close"
    )


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value), encoding="utf-8")


def session(name: str, state: str, age: int, **extra: object) -> dict[str, object]:
    now = int(time.time())
    return {
        "name": name,
        "cwd": "/tmp",
        "state": state,
        "since": now - age,
        "updated": now - age,
        "pid": None,
        "transcript": "",
        "subagents": [],
        **extra,
    }


def make_folder(folder: Path) -> Path:
    """A monitor folder with four sessions, a stale one, previous situations and usage."""
    now = int(time.time())
    sessions = folder / "sessions"
    sessions.mkdir(parents=True)
    subagents = [
        {
            "id": "a1",
            "type": "Explore",
            "desc": "List the plugin READMEs",
            "since": now - 40,
            "updated": now,
        },
        {"id": "a2", "type": "Plan", "desc": "", "since": now - 10, "updated": now},
    ]
    write_json(
        sessions / "s1.json", session("Fix the login flow", "working", 90, subagents=subagents)
    )
    write_json(sessions / "s2.json", session("Pricing page", "waiting", 1500))
    write_json(sessions / "s3.json", session("Migrate the database", "permission", 30))
    write_json(sessions / "ghost.json", session("Ghost", "working", 7 * 3600))
    write_json(folder / "previous.json", {"s2": "working", "s3": "working"})
    usage = folder / "usage.json"
    write_json(
        usage,
        {
            "updated": now,
            "five_hour": {"used_percentage": 38, "resets_at": now + 5340},
            "seven_day": {"used_percentage": 84.4, "resets_at": now + 259_200},
        },
    )
    return usage


@pytest.fixture(scope="module")
def mac_binary(tmp_path_factory: pytest.TempPathFactory) -> Path:
    if sys.platform != "darwin" or shutil.which("xcrun") is None:
        pytest.skip("window.swift runs on macOS with the Xcode command line tools")
    build = tmp_path_factory.mktemp("build")
    binary = build / "PolarisMonitor"
    subprocess.run(
        ["xcrun", "swiftc", "-swift-version", "5", "-O", "-o", binary, WINDOW_DIR / "window.swift"],
        check=True,
        timeout=600,
    )
    # the window reads the mascots and themes next to its binary, as open-window.sh installs them
    for name in ("mascots.json", "themes.json"):
        shutil.copy(WINDOW_DIR / name, build / name)
    return binary


@pytest.fixture(params=["windows", "macos"])
def snapshot(request: pytest.FixtureRequest, tmp_path: Path) -> Snapshot:
    """Renders the window of one platform and returns its report lines and the PNG path."""
    platform = request.param
    if platform == "windows" and (os.name != "nt" or shutil.which("powershell.exe") is None):
        pytest.skip("window.ps1 runs on Windows")
    binary = request.getfixturevalue("mac_binary") if platform == "macos" else None

    def render(folder: Path, usage: Path | None = None, pulse: str = "0") -> tuple[list[str], Path]:
        png = tmp_path / f"{platform}.png"
        if platform == "windows":
            command = [
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(WINDOW_DIR / "window.ps1"),
                "-Snapshot", str(png), "-Folder", str(folder), "-Pulse", pulse,
            ]  # fmt: skip
            if usage:
                command += ["-UsageFile", str(usage)]
        else:
            command = [
                str(binary),
                "--snapshot",
                str(png),
                "--folder",
                str(folder),
                "--pulse",
                pulse,
            ]
            if usage:
                command += ["--usage", str(usage)]
        subprocess.run(command, check=True, timeout=120, capture_output=True)
        report = Path(f"{png}.txt").read_text(encoding="utf-8").splitlines()
        return report, png

    return render


def test_the_window_reports_every_live_session(snapshot: Snapshot, tmp_path: Path) -> None:
    folder = tmp_path / "monitor"
    usage = make_folder(folder)

    report, _ = snapshot(folder, usage)

    assert report == [
        "session: Migrate the database | hook=permission | window=permission | subagents=0",
        "session: Fix the login flow | hook=working | window=working | subagents=2",
        "session: Pricing page | hook=waiting | window=finished | subagents=0",
        "mascot: star jumping",
        "look: dark normal",
        "usage: 5h=38 7d=84",
        "sound: question",
        menu(),
    ]


def test_dead_sessions_are_removed_from_the_folder(snapshot: Snapshot, tmp_path: Path) -> None:
    folder = tmp_path / "monitor"
    make_folder(folder)

    snapshot(folder)

    assert sorted(p.name for p in (folder / "sessions").iterdir()) == [
        "s1.json",
        "s2.json",
        "s3.json",
    ]


def test_the_window_draws_dots_bars_and_the_star(snapshot: Snapshot, tmp_path: Path) -> None:
    folder = tmp_path / "monitor"
    usage = make_folder(folder)

    _, png = snapshot(folder, usage)

    width, height, pixels = read_png(png)
    assert (width, height) == (320, 440)
    for color in (GREEN, YELLOW, RED, BLUE, AMBER, STAR_OUTLINE):
        assert count_color(pixels, color) >= 20, color
    assert count_color(pixels, CLAWD) == 0


def test_clawd_replaces_the_star_when_chosen(snapshot: Snapshot, tmp_path: Path) -> None:
    folder = tmp_path / "monitor"
    make_folder(folder)
    write_json(folder / "config.json", {"character": "clawd"})

    report, png = snapshot(folder)

    assert "mascot: clawd jumping" in report
    _, _, pixels = read_png(png)
    # 2x4 px per sprite pixel: about 36x20 px of Clawd, not the 27x15 of the original
    assert count_color(pixels, CLAWD) >= 350
    assert count_color(pixels, STAR_OUTLINE) == 0


def test_the_light_theme_recolors_the_card(snapshot: Snapshot, tmp_path: Path) -> None:
    folder = tmp_path / "monitor"
    usage = make_folder(folder)
    write_json(folder / "config.json", {"theme": "light"})

    report, png = snapshot(folder, usage)

    assert "look: light normal" in report
    _, _, pixels = read_png(png)
    assert count_color(pixels, "#F8FAFC") > 10_000  # the light card
    assert count_color(pixels, "#1C1D2F") < 1_000  # the dark one is gone (the star's face remains)
    assert count_color(pixels, "#16A34A") >= 20  # the light theme's working dot


def test_themes_and_sizes_are_submenus_that_mark_the_choice(
    snapshot: Snapshot, tmp_path: Path
) -> None:
    folder = tmp_path / "monitor"
    make_folder(folder)
    write_json(folder / "config.json", {"theme": "midnight", "size": "large"})

    report, _ = snapshot(folder)

    assert report[-1] == menu(theme="Midnight", size="Large")


def test_the_large_size_scales_the_window(snapshot: Snapshot, tmp_path: Path) -> None:
    folder = tmp_path / "monitor"
    make_folder(folder)
    write_json(folder / "config.json", {"size": "large"})

    report, png = snapshot(folder)

    assert "look: dark large" in report
    width, height, pixels = read_png(png)
    assert (width, height) == (400, 550)
    assert count_color(pixels, STAR_OUTLINE) > 400  # the star grows with the card


def test_custom_mascots_and_themes_are_used(snapshot: Snapshot, tmp_path: Path) -> None:
    folder = tmp_path / "monitor"
    make_folder(folder)
    custom = folder / "custom"
    custom.mkdir()
    robot = {"sprite": ["#o#", "###", "A.B"], "pixel": [4, 4]}
    robot["colors"] = {"body": "#00FF88", "face": "#000000", "feet": "#00FF88"}
    write_json(custom / "mascots.json", {"robot": {"name": "Robot", **robot}})
    write_json(
        custom / "themes.json",
        {"neon": {"name": "Neon", "working": "#FF00FF", "bar": "not-a-color"}},
    )
    write_json(folder / "config.json", {"character": "robot", "theme": "neon"})

    report, png = snapshot(folder)

    assert "mascot: robot jumping" in report
    assert "look: neon normal" in report
    _, _, pixels = read_png(png)
    assert count_color(pixels, "#00FF88") >= 50
    assert count_color(pixels, "#FF00FF") >= 20  # its working dot
    assert count_color(pixels, "#1C1D2F") > 10_000  # colors it leaves out come from Dark


def test_broken_custom_files_and_unknown_choices_fall_back(
    snapshot: Snapshot, tmp_path: Path
) -> None:
    folder = tmp_path / "monitor"
    make_folder(folder)
    custom = folder / "custom"
    custom.mkdir()
    (custom / "themes.json").write_text("{not json")
    uneven = {"sprite": ["##", "#"], "pixel": [2, 2]}
    uneven["colors"] = {"body": "#00FF88", "face": "#000000", "feet": "#00FF88"}
    write_json(custom / "mascots.json", {"uneven": uneven, "Bad Name": uneven})
    write_json(folder / "config.json", {"character": "uneven", "theme": "nope", "size": "huge"})

    report, png = snapshot(folder)

    assert "mascot: star jumping" in report
    assert "look: dark normal" in report
    assert read_png(png)[:2] == (320, 440)


def test_the_opacity_dims_the_mascot_too(snapshot: Snapshot, tmp_path: Path) -> None:
    folder = tmp_path / "monitor"
    make_folder(folder)
    write_json(folder / "config.json", {"opacity": 0.5})

    _, png = snapshot(folder)

    _, _, pixels = read_png(png)
    assert count_color(pixels, STAR_OUTLINE) == 0
    assert count_color(pixels, YELLOW) == 0


def test_options_hide_the_mascot_and_the_subagent_rows(snapshot: Snapshot, tmp_path: Path) -> None:
    folder = tmp_path / "monitor"
    make_folder(folder)
    write_json(folder / "config.json", {"mascot": False, "subagents": False})

    report, png = snapshot(folder)

    assert "mascot: off" in report
    _, _, pixels = read_png(png)
    assert count_color(pixels, STAR_OUTLINE) == 0


def test_without_sessions_or_usage_the_mascot_stands(snapshot: Snapshot, tmp_path: Path) -> None:
    folder = tmp_path / "monitor"
    (folder / "sessions").mkdir(parents=True)

    report, _ = snapshot(folder)

    assert report == [
        "mascot: star standing",
        "look: dark normal",
        "usage: unavailable",
        "sound: none",
        menu(),
    ]


def test_the_working_dot_pulses(snapshot: Snapshot, tmp_path: Path) -> None:
    folder = tmp_path / "monitor"
    (folder / "sessions").mkdir(parents=True)
    write_json(folder / "sessions" / "s1.json", session("Only one", "working", 5))

    def dot_green(png: Path) -> int:
        # only the left part of the card, where the dot is: the elapsed time on the right is
        # green too, and it does not pulse
        width, _, pixels = read_png(png)
        return count_color([p for i, p in enumerate(pixels) if i % width < 120], GREEN)

    # each snapshot overwrites the same PNG: count before taking the next one
    bright = dot_green(snapshot(folder, pulse="0")[1])
    dim = dot_green(snapshot(folder, pulse="0.5")[1])

    assert bright >= 20
    assert dim < bright / 4
