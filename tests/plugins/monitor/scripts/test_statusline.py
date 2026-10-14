"""Tests for plugins/monitor/scripts/statusline.sh.

Reset times are built relative to the current clock with a 30-second margin, so the
rendered "time to reset" stays stable while the test runs. Every test gets its own HOME, so
the usage file shared with the monitor window never lands in the real one.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import time
from pathlib import Path

import pytest

from tests.shell import BASH

REPO_ROOT = Path(__file__).resolve().parents[4]
SCRIPT = REPO_ROOT / "plugins" / "monitor" / "scripts" / "statusline.sh"

needs_jq = pytest.mark.skipif(shutil.which("jq") is None, reason="statusline.sh needs jq")

GREEN, YELLOW, RED, RESET = "\033[32m", "\033[33m", "\033[31m", "\033[0m"


@pytest.fixture(autouse=True)
def fake_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    return home


def window(percent: float, seconds_to_reset: int) -> dict[str, float]:
    return {"used_percentage": percent, "resets_at": int(time.time()) + seconds_to_reset + 30}


def render(payload: object, *, color: bool = False, env: dict[str, str] | None = None) -> str:
    run_env = dict(os.environ if env is None else env)
    run_env.pop("NO_COLOR", None)
    if not color:
        run_env["NO_COLOR"] = "1"
    stdin = payload if isinstance(payload, str) else json.dumps(payload)
    result = subprocess.run(
        [BASH, SCRIPT],
        input=stdin,
        env=run_env,
        capture_output=True,
        encoding="utf-8",
        check=True,
    )
    return result.stdout.rstrip("\n")


@needs_jq
def test_renders_both_windows_on_one_line() -> None:
    payload = {
        "rate_limits": {
            "five_hour": window(23.5, 2 * 3600 + 14 * 60),
            "seven_day": window(41.2, 4 * 86400 + 6 * 3600),
        }
    }
    assert render(payload) == "5h ██░░░░░░░░ 24% 2h 14m · 7d ████░░░░░░ 41% 4d 6h"


@needs_jq
@pytest.mark.parametrize(
    "payload",
    [
        {"model": {"display_name": "Opus"}},
        {"rate_limits": {}},
        "not json",
    ],
    ids=["no-rate-limits", "empty-rate-limits", "invalid-json"],
)
def test_prints_nothing_without_usage_data(payload: object) -> None:
    assert render(payload) == ""


@needs_jq
def test_a_missing_window_is_skipped() -> None:
    payload = {"rate_limits": {"seven_day": window(10, 3 * 86400)}}
    assert render(payload) == "7d █░░░░░░░░░ 10% 3d 0h"


@needs_jq
@pytest.mark.parametrize(
    ("seconds", "expected"),
    [(37 * 60, "37m"), (5 * 3600, "5h 0m"), (-120, "now")],
)
def test_time_to_reset_format(seconds: int, expected: str) -> None:
    payload = {"rate_limits": {"five_hour": window(50, seconds)}}
    assert render(payload).endswith(f" 50% {expected}")


@needs_jq
@pytest.mark.parametrize(
    ("percent", "bar"),
    [(0, "░" * 10), (4, "░" * 10), (5, "█" + "░" * 9), (100, "█" * 10), (130, "█" * 10)],
)
def test_bar_fills_to_the_nearest_tenth(percent: int, bar: str) -> None:
    payload = {"rate_limits": {"five_hour": window(percent, 3600)}}
    assert render(payload).startswith(f"5h {bar} ")


@needs_jq
@pytest.mark.parametrize(
    ("percent", "color"),
    [(79, GREEN), (80, YELLOW), (94, YELLOW), (95, RED)],
)
def test_bar_color_follows_thresholds(percent: int, color: str) -> None:
    payload = {"rate_limits": {"five_hour": window(percent, 3600)}}
    output = render(payload, color=True)
    assert output.startswith(f"5h {color}")
    assert RESET in output


@needs_jq
def test_no_color_disables_escape_codes() -> None:
    payload = {"rate_limits": {"five_hour": window(99, 3600)}}
    assert "\033[" not in render(payload)


def context(percent: float | None, used: int, size: int = 200_000) -> dict[str, object]:
    return {"used_percentage": percent, "total_input_tokens": used, "context_window_size": size}


@needs_jq
def test_context_comes_after_the_usage_windows() -> None:
    payload = {
        "rate_limits": {"five_hour": window(23.5, 2 * 3600 + 14 * 60)},
        "context_window": context(34, 68_000),
    }
    assert render(payload) == "5h ██░░░░░░░░ 24% 2h 14m · ctx ███░░░░░░░ 34% 68k/200k"


@needs_jq
def test_context_shows_without_rate_limits() -> None:
    payload = {"context_window": context(8, 15_500)}
    assert render(payload) == "ctx █░░░░░░░░░ 8% 16k/200k"


@needs_jq
def test_context_without_a_percentage_prints_nothing() -> None:
    payload = {"context_window": context(None, 0)}
    assert render(payload) == ""


@needs_jq
def test_context_can_be_turned_off() -> None:
    payload = {
        "rate_limits": {"seven_day": window(10, 3 * 86400)},
        "context_window": context(34, 68_000),
    }
    env = {**os.environ, "POLARIS_MONITOR_CONTEXT": "off"}
    assert render(payload, env=env) == "7d █░░░░░░░░░ 10% 3d 0h"


@needs_jq
@pytest.mark.parametrize(
    ("used", "size", "expected"),
    [
        (800, 200_000, "800/200k"),
        (999_400, 1_000_000, "999k/1M"),
        (999_600, 1_000_000, "1M/1M"),
        (1_250_000, 1_000_000, "1.3M/1M"),
    ],
)
def test_context_token_format(used: int, size: int, expected: str) -> None:
    payload = {"context_window": context(50, used, size)}
    assert render(payload).endswith(f" 50% {expected}")


@needs_jq
@pytest.mark.skipif(os.name == "nt", reason="the real jq.exe already ends lines with CRLF")
def test_crlf_from_jq_on_windows_is_ignored(tmp_path: Path) -> None:
    tools = tmp_path / "tools"
    tools.mkdir()
    fake_jq = tools / "jq"
    fake_jq.write_text(f"#!/usr/bin/env bash\n'{shutil.which('jq')}' \"$@\" | sed 's/$/\\r/'\n")
    fake_jq.chmod(0o755)
    env = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}
    payload = {
        "rate_limits": {"five_hour": window(23.5, 2 * 3600 + 14 * 60)},
        "context_window": context(34, 68_000),
    }
    assert render(payload, env=env) == "5h ██░░░░░░░░ 24% 2h 14m · ctx ███░░░░░░░ 34% 68k/200k"


@pytest.mark.skipif(os.name == "nt", reason="builds a PATH of symlinks")
def test_asks_for_jq_when_it_is_missing(tmp_path: Path) -> None:
    tools = tmp_path / "tools"
    tools.mkdir()
    for name in ("bash", "cat", "date"):
        found = shutil.which(name)
        assert found is not None
        (tools / name).symlink_to(found)
    env = {"PATH": str(tools), "HOME": str(tmp_path)}

    assert render({}, env=env) == "polaris-monitor: install jq to see usage limits"


# Usage shared with the monitor window


USAGE = {
    "rate_limits": {
        "five_hour": {"used_percentage": 23.5, "resets_at": 1_800_000_000},
        "seven_day": {"used_percentage": 41.2, "resets_at": 1_800_100_000},
    }
}


@needs_jq
def test_usage_is_not_saved_until_the_window_was_opened(fake_home: Path) -> None:
    render(USAGE)

    assert list(fake_home.iterdir()) == []


@needs_jq
def test_usage_is_saved_for_the_monitor_window(fake_home: Path) -> None:
    monitor = fake_home / ".polaris-monitor"
    monitor.mkdir()
    before = int(time.time())

    output = render(USAGE)

    saved = json.loads((monitor / "usage.json").read_text())
    assert saved["five_hour"] == USAGE["rate_limits"]["five_hour"]
    assert saved["seven_day"] == USAGE["rate_limits"]["seven_day"]
    assert saved["updated"] >= before
    assert output.startswith("5h ")
    assert [p.name for p in monitor.iterdir()] == ["usage.json"]


@needs_jq
def test_a_render_without_limits_keeps_the_last_saved_usage(fake_home: Path) -> None:
    monitor = fake_home / ".polaris-monitor"
    monitor.mkdir()
    render(USAGE)
    saved = (monitor / "usage.json").read_text()

    render({"context_window": context(34, 68_000)})

    assert (monitor / "usage.json").read_text() == saved


@needs_jq
@pytest.mark.skipif(os.name == "nt", reason="POSIX file modes")
def test_the_usage_file_is_private(fake_home: Path) -> None:
    monitor = fake_home / ".polaris-monitor"
    monitor.mkdir()

    render(USAGE)

    assert stat.S_IMODE((monitor / "usage.json").stat().st_mode) == 0o600


@needs_jq
@pytest.mark.skipif(os.name == "nt", reason="the WSL cache holds a POSIX path")
def test_on_wsl_usage_goes_to_the_cached_windows_folder(fake_home: Path, tmp_path: Path) -> None:
    monitor = fake_home / ".polaris-monitor"
    monitor.mkdir()
    windows_monitor = tmp_path / "c" / "Users" / "me" / ".polaris-monitor"
    windows_monitor.mkdir(parents=True)
    (monitor / "winpath").write_text(str(windows_monitor))

    render(USAGE)

    assert (windows_monitor / "usage.json").exists()
    assert not (monitor / "usage.json").exists()


@needs_jq
@pytest.mark.skipif(os.name == "nt", reason="the WSL cache holds a POSIX path")
@pytest.mark.parametrize("cached", ["relative/.polaris-monitor", "/a/../b/.polaris-monitor"])
def test_a_tampered_windows_folder_cache_is_ignored(fake_home: Path, cached: str) -> None:
    monitor = fake_home / ".polaris-monitor"
    monitor.mkdir()
    (monitor / "winpath").write_text(cached)

    render(USAGE)

    assert (monitor / "usage.json").exists()
