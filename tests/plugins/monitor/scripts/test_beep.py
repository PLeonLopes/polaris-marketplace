"""Tests for plugins/monitor/scripts/beep.sh and its wiring in hooks/hooks.json.

Sound backends (powershell.exe, afplay) are replaced by fakes placed first on PATH that
append their arguments to a log file, so no sound is played. The script plays in the
background, so assertions wait for the log instead of reading it right away.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from tests.shell import BASH

REPO_ROOT = Path(__file__).resolve().parents[4]
PLUGIN_DIR = REPO_ROOT / "plugins" / "monitor"
SCRIPT = PLUGIN_DIR / "scripts" / "beep.sh"
HOOKS = PLUGIN_DIR / "hooks" / "hooks.json"

FAKE_BACKEND = """#!/usr/bin/env bash
sleep "${{FAKE_DELAY:-0}}"
echo "{name} $*" >> "$FAKE_LOG"
"""


INHERITED_OVERRIDES = {"CLAUDE_CODE_REMOTE", "WSL_DISTRO_NAME"}


@pytest.fixture
def fake_env(tmp_path: Path) -> dict[str, str]:
    """Environment with fake sound backends first on PATH and an empty log."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name in ("powershell.exe", "afplay"):
        fake = bin_dir / name
        fake.write_text(FAKE_BACKEND.format(name=name))
        fake.chmod(0o755)
    # Drop inherited settings that change the outcome (e.g. when run inside a cloud session).
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("POLARIS_MONITOR_") and key not in INHERITED_OVERRIDES
    }
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["FAKE_LOG"] = str(tmp_path / "calls.log")
    return env


def run_beep(
    env: dict[str, str], *args: str, stdin: str = "{}"
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [BASH, SCRIPT, *args], input=stdin, env=env, capture_output=True, text=True, check=False
    )


def wait_for_calls(env: dict[str, str], expected: int, timeout: float = 5.0) -> list[str]:
    log = Path(env["FAKE_LOG"])
    deadline = time.monotonic() + timeout
    lines: list[str] = []
    while time.monotonic() < deadline:
        lines = log.read_text().splitlines() if log.exists() else []
        if len(lines) >= expected:
            return lines
        time.sleep(0.05)
    return lines


def assert_no_calls(env: dict[str, str]) -> None:
    time.sleep(0.5)
    assert not Path(env["FAKE_LOG"]).exists()


@pytest.mark.parametrize("platform", ["windows", "wsl"])
@pytest.mark.parametrize(
    ("pattern", "beeps", "frequency"),
    [("done", 2, 660), ("attention", 3, 1000)],
)
def test_windows_and_wsl_beep_through_powershell(
    fake_env: dict[str, str], platform: str, pattern: str, beeps: int, frequency: int
) -> None:
    fake_env["POLARIS_MONITOR_PLATFORM"] = platform
    assert run_beep(fake_env, pattern).returncode == 0

    calls = wait_for_calls(fake_env, 1)
    assert len(calls) == 1
    assert calls[0].startswith("powershell.exe -NoProfile -NonInteractive -Command")
    assert calls[0].count(f"[console]::beep({frequency},150)") == beeps


@pytest.mark.parametrize(
    ("pattern", "plays", "sound"),
    [("done", 2, "Tink.aiff"), ("attention", 3, "Ping.aiff")],
)
def test_macos_beeps_through_afplay(
    fake_env: dict[str, str], pattern: str, plays: int, sound: str
) -> None:
    fake_env["POLARIS_MONITOR_PLATFORM"] = "macos"
    assert run_beep(fake_env, pattern).returncode == 0

    calls = wait_for_calls(fake_env, plays)
    assert len(calls) == plays
    assert all(call == f"afplay /System/Library/Sounds/{sound}" for call in calls)


@pytest.mark.parametrize(
    ("uname", "platform"),
    [
        ("MINGW64_NT-10.0-26100", "windows"),  # Git Bash on native Windows
        ("MSYS_NT-10.0-26100", "windows"),
        ("CYGWIN_NT-10.0-26100", "windows"),
        ("Darwin", "macos"),
    ],
)
def test_platform_is_detected_from_uname(
    fake_env: dict[str, str], tmp_path: Path, uname: str, platform: str
) -> None:
    fake_uname = tmp_path / "bin" / "uname"
    fake_uname.write_text(f"#!/usr/bin/env bash\necho {uname}\n")
    fake_uname.chmod(0o755)

    result = run_beep(fake_env, "--detect")
    assert result.returncode == 0
    assert result.stdout.strip() == platform
    assert_no_calls(fake_env)


def test_platform_override_wins_over_detection(fake_env: dict[str, str]) -> None:
    fake_env["POLARIS_MONITOR_PLATFORM"] = "linux"
    assert run_beep(fake_env, "--detect").stdout.strip() == "linux"


def test_cloud_sessions_are_silent(fake_env: dict[str, str]) -> None:
    fake_env["POLARIS_MONITOR_PLATFORM"] = "wsl"
    fake_env["CLAUDE_CODE_REMOTE"] = "true"
    assert run_beep(fake_env, "attention").returncode == 0
    assert_no_calls(fake_env)


def test_remote_flag_other_than_true_still_beeps(fake_env: dict[str, str]) -> None:
    fake_env["POLARIS_MONITOR_PLATFORM"] = "wsl"
    fake_env["CLAUDE_CODE_REMOTE"] = "false"
    assert run_beep(fake_env, "done").returncode == 0
    assert len(wait_for_calls(fake_env, 1)) == 1


def test_returns_before_a_slow_backend_finishes(fake_env: dict[str, str]) -> None:
    fake_env["POLARIS_MONITOR_PLATFORM"] = "wsl"
    fake_env["FAKE_DELAY"] = "2"

    start = time.monotonic()
    assert run_beep(fake_env, "done").returncode == 0
    assert time.monotonic() - start < 1.0
    assert len(wait_for_calls(fake_env, 1)) == 1


SETSID = shutil.which("setsid")


@pytest.mark.skipif(SETSID is None, reason="needs setsid to build the process group")
@pytest.mark.parametrize("has_setsid", [True, False], ids=["setsid", "no-setsid-fallback"])
def test_pattern_survives_the_hook_process_group_ending(
    fake_env: dict[str, str], tmp_path: Path, has_setsid: bool
) -> None:
    """Claude Code ends the hook's process group on return: the beeps must keep playing."""
    fake_env["POLARIS_MONITOR_PLATFORM"] = "wsl"
    fake_env["FAKE_DELAY"] = "1"
    if not has_setsid:
        # Only the commands the script needs, so `command -v setsid` fails (as on macOS).
        tools = tmp_path / "tools"
        tools.mkdir()
        for name in ("bash", "cat", "grep", "sleep", "uname"):
            found = shutil.which(name)
            assert found is not None
            (tools / name).symlink_to(found)
        fake_env["PATH"] = f"{tmp_path / 'bin'}{os.pathsep}{tools}"

    hook = f"echo '{{}}' | bash '{SCRIPT}' attention; sleep 0.3; kill -TERM -$$"
    subprocess.run([str(SETSID), BASH, "-c", hook], env=fake_env, check=False)

    assert len(wait_for_calls(fake_env, 1)) == 1


@pytest.mark.parametrize(
    "stdin",
    [
        '{"agent_id": "a1b2c3", "tool_name": "AskUserQuestion"}',
        '{"session_id":"s","agent_id":"x"}',
    ],
)
def test_subagent_events_are_silent(fake_env: dict[str, str], stdin: str) -> None:
    fake_env["POLARIS_MONITOR_PLATFORM"] = "wsl"
    assert run_beep(fake_env, "attention", stdin=stdin).returncode == 0
    assert_no_calls(fake_env)


def test_empty_agent_id_still_beeps(fake_env: dict[str, str]) -> None:
    fake_env["POLARIS_MONITOR_PLATFORM"] = "wsl"
    assert run_beep(fake_env, "done", stdin='{"agent_id": ""}').returncode == 0
    assert len(wait_for_calls(fake_env, 1)) == 1


def test_off_switch_silences_every_beep(fake_env: dict[str, str]) -> None:
    fake_env["POLARIS_MONITOR_PLATFORM"] = "wsl"
    fake_env["POLARIS_MONITOR_BEEP"] = "off"
    assert run_beep(fake_env, "attention").returncode == 0
    assert_no_calls(fake_env)


@pytest.mark.parametrize("args", [(), ("loud",)])
def test_unknown_pattern_prints_usage_and_exits_zero(
    fake_env: dict[str, str], args: tuple[str, ...]
) -> None:
    fake_env["POLARIS_MONITOR_PLATFORM"] = "wsl"
    result = run_beep(fake_env, *args)
    assert result.returncode == 0
    assert "usage: beep.sh" in result.stderr
    assert_no_calls(fake_env)


@pytest.mark.parametrize(
    ("event", "matcher", "pattern"),
    [
        ("Stop", None, "done"),
        ("PreToolUse", "AskUserQuestion", "attention"),
        ("Notification", "permission_prompt", "attention"),
    ],
)
def test_hooks_wire_events_to_patterns(event: str, matcher: str | None, pattern: str) -> None:
    groups = json.loads(HOOKS.read_text())["hooks"][event]
    commands = [
        hook["command"]
        for group in groups
        if group.get("matcher") == matcher
        for hook in group["hooks"]
    ]
    assert commands == [f'bash "${{CLAUDE_PLUGIN_ROOT}}/scripts/beep.sh" {pattern}']
