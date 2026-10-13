"""Tests for plugins/monitor/scripts/setup-statusline.sh and its SessionStart hook.

Every test points HOME and CLAUDE_CONFIG_DIR at tmp_path, so the real
~/.claude/settings.json is never read or written.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from tests.shell import BASH

REPO_ROOT = Path(__file__).resolve().parents[4]
PLUGIN_DIR = REPO_ROOT / "plugins" / "monitor"
SCRIPT = PLUGIN_DIR / "scripts" / "setup-statusline.sh"
BUNDLED = PLUGIN_DIR / "scripts" / "statusline.sh"
HOOKS = PLUGIN_DIR / "hooks" / "hooks.json"

needs_jq = pytest.mark.skipif(shutil.which("jq") is None, reason="setup-statusline.sh needs jq")

FOREIGN = {"type": "command", "command": "~/.claude/my-statusline.sh"}


class Sandbox:
    """A fake home with a Claude config directory and a plugin data directory."""

    def __init__(self, root: Path) -> None:
        self.config = root / "home" / ".claude"
        self.settings = self.config / "settings.json"
        self.data = root / "data"
        self.env = {key: value for key, value in os.environ.items() if key != "CLAUDE_CONFIG_DIR"}
        self.env["HOME"] = str(root / "home")
        self.env["CLAUDE_CONFIG_DIR"] = str(self.config)

    @property
    def command(self) -> str:
        return f'bash "{self.data}/statusline.sh"'

    def write(self, settings: dict[str, object]) -> None:
        self.config.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(settings, indent=2) + "\n")

    def read(self) -> dict[str, object]:
        return json.loads(self.settings.read_text())

    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [BASH, SCRIPT, str(self.data), *args],
            env=self.env,
            capture_output=True,
            encoding="utf-8",
            check=False,
        )


@pytest.fixture
def box(tmp_path: Path) -> Sandbox:
    return Sandbox(tmp_path)


@needs_jq
def test_creates_settings_and_copies_the_script(box: Sandbox) -> None:
    result = box.run()

    assert result.returncode == 0, result.stdout
    assert box.read() == {"statusLine": {"type": "command", "command": box.command}}
    assert (box.data / "statusline.sh").read_bytes() == BUNDLED.read_bytes()


@needs_jq
def test_keeps_other_settings_and_the_file_mode(box: Sandbox) -> None:
    box.write({"model": "opus", "enabledPlugins": {"x@y": True}})
    box.settings.chmod(0o600)

    assert box.run().returncode == 0

    settings = box.read()
    assert settings["model"] == "opus"
    assert settings["enabledPlugins"] == {"x@y": True}
    assert settings["statusLine"] == {"type": "command", "command": box.command}
    if os.name != "nt":
        assert stat.S_IMODE(box.settings.stat().st_mode) == 0o600


@needs_jq
def test_refuses_to_replace_another_status_line(box: Sandbox) -> None:
    box.write({"statusLine": FOREIGN})
    before = box.settings.read_text()

    result = box.run()

    assert result.returncode == 1
    assert "You already have a status line" in result.stdout
    assert "--force" in result.stdout
    assert box.settings.read_text() == before


@needs_jq
def test_force_replaces_it_and_keeps_a_backup(box: Sandbox) -> None:
    box.write({"statusLine": FOREIGN})

    assert box.run("--force").returncode == 0

    assert box.read()["statusLine"] == {"type": "command", "command": box.command}
    backup = json.loads((box.config / "settings.json.bak-polaris-monitor").read_text())
    assert backup == {"statusLine": FOREIGN}


@needs_jq
def test_running_twice_changes_nothing(box: Sandbox) -> None:
    box.run()
    before = box.settings.read_text()

    result = box.run()

    assert result.returncode == 0
    assert "already configured" in result.stdout
    assert box.settings.read_text() == before


@needs_jq
def test_repoints_an_old_polaris_monitor_path(box: Sandbox) -> None:
    old = {"type": "command", "command": 'bash "/gone/polaris-monitor-x/statusline.sh"'}
    box.write({"statusLine": old})

    assert box.run().returncode == 0
    assert box.read()["statusLine"] == {"type": "command", "command": box.command}


@needs_jq
def test_remove_deletes_only_our_status_line(box: Sandbox) -> None:
    box.write({"model": "opus"})
    box.run()

    result = box.run("--remove")

    assert result.returncode == 0
    assert box.read() == {"model": "opus"}
    assert not (box.data / "statusline.sh").exists()


@needs_jq
def test_remove_leaves_another_status_line_alone(box: Sandbox) -> None:
    box.write({"statusLine": FOREIGN})
    before = box.settings.read_text()

    result = box.run("--remove")

    assert result.returncode == 0
    assert "not polaris-monitor's" in result.stdout
    assert box.settings.read_text() == before


@needs_jq
def test_invalid_settings_are_never_rewritten(box: Sandbox) -> None:
    box.config.mkdir(parents=True)
    box.settings.write_text('{"model": "opus",')

    result = box.run()

    assert result.returncode == 1
    assert "not valid JSON" in result.stdout
    assert box.settings.read_text() == '{"model": "opus",'


@needs_jq
@pytest.mark.skipif(os.name == "nt", reason="symlinks need extra privileges on Windows")
def test_a_symlinked_settings_file_stays_a_symlink(box: Sandbox, tmp_path: Path) -> None:
    dotfiles = tmp_path / "dotfiles" / "settings.json"
    dotfiles.parent.mkdir()
    dotfiles.write_text("{}\n")
    box.config.mkdir(parents=True)
    box.settings.symlink_to(dotfiles)

    assert box.run().returncode == 0

    assert box.settings.is_symlink()
    assert json.loads(dotfiles.read_text())["statusLine"]["command"] == box.command


@needs_jq
def test_the_configured_command_renders_usage(box: Sandbox) -> None:
    box.run()
    payload = {"rate_limits": {"five_hour": {"used_percentage": 50, "resets_at": 0}}}

    env = {**box.env, "NO_COLOR": "1"}
    result = subprocess.run(
        [BASH, "-c", box.command],
        input=json.dumps(payload),
        env=env,
        capture_output=True,
        encoding="utf-8",
        check=True,
    )

    assert result.stdout.strip() == "5h █████░░░░░ 50% now"


def test_sync_does_nothing_until_the_user_opts_in(box: Sandbox) -> None:
    assert box.run("--sync").returncode == 0
    assert not box.data.exists()
    assert not box.settings.exists()


def test_sync_refreshes_a_stale_copy(box: Sandbox) -> None:
    box.data.mkdir()
    (box.data / "statusline.sh").write_text("# from an older plugin version\n")

    assert box.run("--sync").returncode == 0
    assert (box.data / "statusline.sh").read_bytes() == BUNDLED.read_bytes()
    assert not box.settings.exists()


@pytest.mark.parametrize("args", [(), ("--data-dir-missing",)])
def test_usage_errors_exit_two(box: Sandbox, args: tuple[str, ...]) -> None:
    command = [BASH, SCRIPT] if not args else [BASH, SCRIPT, str(box.data), *args]
    result = subprocess.run(
        command, env=box.env, capture_output=True, encoding="utf-8", check=False
    )
    assert result.returncode == 2
    assert "usage: setup-statusline.sh" in result.stderr


@pytest.mark.skipif(os.name == "nt", reason="builds a PATH of symlinks")
def test_asks_for_jq_and_changes_nothing_without_it(box: Sandbox, tmp_path: Path) -> None:
    tools = tmp_path / "tools"
    tools.mkdir()
    for name in ("bash", "cat", "cmp", "cp", "dirname", "mkdir", "readlink"):
        found = shutil.which(name)
        assert found is not None
        (tools / name).symlink_to(found)
    box.env["PATH"] = str(tools)

    result = box.run()

    assert result.returncode == 1
    assert "jq is required" in result.stdout
    assert not box.settings.exists()


def test_session_start_hook_only_syncs() -> None:
    groups = json.loads(HOOKS.read_text())["hooks"]["SessionStart"]
    commands = [hook["command"] for group in groups for hook in group["hooks"]]
    assert commands == [
        'bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-statusline.sh" "${CLAUDE_PLUGIN_DATA}" --sync'
    ]
