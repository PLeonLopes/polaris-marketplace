"""Tests for plugins/monitor/scripts/open-window.sh, the launcher of the monitor window.

The platform is forced and every external program (powershell.exe, cmd.exe, wslpath, cygpath,
xcode-select, xcrun) is a fake on PATH that logs how it was called, so no window opens and
nothing outside tmp_path is touched.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from tests.shell import BASH

REPO_ROOT = Path(__file__).resolve().parents[4]
SCRIPT = REPO_ROOT / "plugins" / "monitor" / "scripts" / "open-window.sh"
WINDOW_DIR = REPO_ROOT / "plugins" / "monitor" / "scripts" / "window"
COMMAND = REPO_ROOT / "plugins" / "monitor" / "commands" / "open-window.md"

pytestmark = pytest.mark.skipif(os.name == "nt", reason="fakes programs with extensionless scripts")


class Machine:
    """A fake home and a folder of fake programs placed first on PATH."""

    def __init__(self, root: Path, platform: str) -> None:
        self.root = root
        self.home = root / "home"
        self.home.mkdir()
        self.tools = root / "tools"
        self.tools.mkdir()
        self.log = root / "calls.log"
        self.env = {key: value for key, value in os.environ.items() if key != "WSLENV"}
        self.env.update(
            HOME=str(self.home),
            POLARIS_MONITOR_PLATFORM=platform,
            PATH=f"{self.tools}{os.pathsep}{os.environ['PATH']}",
        )

    @property
    def monitor(self) -> Path:
        return self.home / ".polaris-monitor"

    def fake(self, name: str, body: str = "") -> None:
        script = self.tools / name
        script.write_text(
            f'#!/usr/bin/env bash\necho "{name} $(echo "$*" | tr "\\n" " ") | cwd=$PWD '
            f'| POLARIS_WINDOW=${{POLARIS_WINDOW:-}} | WSLENV=${{WSLENV:-}}" >> "{self.log}"\n'
            f"{body}\n"
        )
        script.chmod(0o755)

    def calls(self) -> list[str]:
        return self.log.read_text().splitlines() if self.log.exists() else []

    def run(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [BASH, SCRIPT], env=self.env, capture_output=True, encoding="utf-8", check=False
        )


def test_linux_has_no_window(tmp_path: Path) -> None:
    machine = Machine(tmp_path, "linux")

    result = machine.run()

    assert result.returncode == 1
    assert "runs on Windows, WSL and macOS" in result.stdout
    assert not machine.monitor.exists()


def assert_installed(folder: Path, window: str) -> None:
    """The window, the mascots and the themes are copied, and custom/ waits for the user's."""
    for name in (window, "mascots.json", "themes.json"):
        assert (folder / name).read_bytes() == (WINDOW_DIR / name).read_bytes(), name
    assert (folder / "custom").is_dir()


# Windows (Git Bash)


def windows_machine(tmp_path: Path) -> Machine:
    machine = Machine(tmp_path, "windows")
    machine.fake("cygpath", 'echo "C:\\\\Users\\\\me\\\\.polaris-monitor\\\\window.ps1"')
    machine.fake("powershell.exe")
    return machine


def test_windows_installs_and_starts_the_window(tmp_path: Path) -> None:
    machine = windows_machine(tmp_path)

    result = machine.run()

    assert result.returncode == 0, result.stdout
    assert "window opened" in result.stdout
    assert_installed(machine.monitor, "window.ps1")
    assert (machine.monitor / "sessions").is_dir()
    [launch] = [c for c in machine.calls() if c.startswith("powershell.exe")]
    assert "Start-Process" in launch
    assert "POLARIS_WINDOW=C:\\Users\\me\\.polaris-monitor\\window.ps1 " in launch


def test_an_unchanged_window_keeps_its_timestamp(tmp_path: Path) -> None:
    machine = windows_machine(tmp_path)
    machine.run()
    installed = machine.monitor / "window.ps1"
    os.utime(installed, (1_000_000_000, 1_000_000_000))

    machine.run()

    assert installed.stat().st_mtime == 1_000_000_000


def test_the_users_custom_files_are_never_touched(tmp_path: Path) -> None:
    machine = windows_machine(tmp_path)
    (machine.monitor / "custom").mkdir(parents=True)
    mine = machine.monitor / "custom" / "mascots.json"
    mine.write_text('{"mine": {}}')

    machine.run()

    assert mine.read_text() == '{"mine": {}}'


def test_an_outdated_window_is_replaced(tmp_path: Path) -> None:
    machine = windows_machine(tmp_path)
    machine.run()
    installed = machine.monitor / "window.ps1"
    installed.write_text("# an older version\n")

    machine.run()

    assert installed.read_bytes() == (WINDOW_DIR / "window.ps1").read_bytes()


def test_windows_without_powershell_fails_cleanly(tmp_path: Path) -> None:
    machine = Machine(tmp_path, "windows")
    machine.env["PATH"] = str(machine.tools) + os.pathsep + "/usr/bin" + os.pathsep + "/bin"

    result = machine.run()

    assert result.returncode == 1
    assert "powershell.exe was not found" in result.stdout


# WSL


@pytest.mark.parametrize("profile", ["C:\\Users\\me", "C:\\Users\\Pedro Lopes"])
def test_wsl_opens_the_window_on_windows(tmp_path: Path, profile: str) -> None:
    machine = Machine(tmp_path, "wsl")
    windows_monitor = tmp_path / "c" / "Users" / profile.split("\\")[-1] / ".polaris-monitor"
    machine.fake("cmd.exe", f"printf '%s\\r\\n' '{profile}'")
    machine.fake("wslpath", f'echo "{windows_monitor}"')
    machine.fake("powershell.exe")
    (machine.monitor).mkdir()
    (machine.monitor / "winpath.fail").touch()

    result = machine.run()

    assert result.returncode == 0, result.stdout
    assert_installed(windows_monitor, "window.ps1")
    assert (windows_monitor / "sessions").is_dir()
    assert (machine.monitor / "winpath").read_text().strip() == str(windows_monitor)
    assert not (machine.monitor / "winpath.fail").exists()
    [launch] = [c for c in machine.calls() if c.startswith("powershell.exe")]
    assert f"POLARIS_WINDOW={profile}\\.polaris-monitor\\window.ps1 " in launch
    assert "WSLENV=POLARIS_WINDOW" in launch
    assert f"cwd={windows_monitor} " in launch


def test_wsl_without_a_windows_profile_fails_cleanly(tmp_path: Path) -> None:
    machine = Machine(tmp_path, "wsl")
    machine.fake("cmd.exe", "exit 1")
    machine.fake("powershell.exe")

    result = machine.run()

    assert result.returncode == 1
    assert "could not find the Windows profile" in result.stdout
    assert not [c for c in machine.calls() if c.startswith("powershell.exe")]


# macOS


# Sets $out to the argument after -o, in a fake compiler.
FIND_OUTPUT = (
    "for ((i = 1; i <= $#; i++)); do\n"
    '    [ "${!i}" = "-o" ] && { j=$((i + 1)); out="${!j}"; }\n'
    "done\n"
)


def mac_machine(tmp_path: Path) -> Machine:
    machine = Machine(tmp_path, "macos")
    started = tmp_path / "started"
    machine.fake("xcode-select", "echo /Library/Developer/CommandLineTools")
    # the fake compiler writes a "binary" that records that it ran
    machine.fake(
        "xcrun",
        FIND_OUTPUT
        + f'printf \'#!/usr/bin/env bash\\necho ran >> "{started}"\\n\' > "$out"; chmod +x "$out"',
    )
    return machine


def wait_for(path: Path) -> str:
    for _ in range(50):
        if path.exists() and path.read_text():
            break
        subprocess.run(["sleep", "0.1"], check=True)
    return path.read_text() if path.exists() else ""


def test_macos_compiles_on_the_first_run_and_starts_the_window(tmp_path: Path) -> None:
    machine = mac_machine(tmp_path)

    result = machine.run()

    assert result.returncode == 0, result.stdout
    assert "compiling the window" in result.stdout
    assert_installed(machine.monitor, "window.swift")
    compiles = [c for c in machine.calls() if c.startswith("xcrun swiftc")]
    assert len(compiles) == 1
    assert "-swift-version 5" in compiles[0]
    assert wait_for(tmp_path / "started") == "ran\n"


def test_macos_compiles_again_only_after_an_update(tmp_path: Path) -> None:
    machine = mac_machine(tmp_path)
    machine.run()

    machine.run()
    assert len([c for c in machine.calls() if c.startswith("xcrun swiftc")]) == 1

    # new mascots or themes: copied, and the window reloads them by itself
    (machine.monitor / "mascots.json").write_text("{}")
    machine.run()
    assert len([c for c in machine.calls() if c.startswith("xcrun swiftc")]) == 1
    assert_installed(machine.monitor, "window.swift")

    (machine.monitor / "window.swift").write_text("// an older version\n")
    machine.run()
    assert len([c for c in machine.calls() if c.startswith("xcrun swiftc")]) == 2


def test_macos_without_the_command_line_tools_fails_cleanly(tmp_path: Path) -> None:
    machine = mac_machine(tmp_path)
    machine.fake("xcode-select", "exit 2")

    result = machine.run()

    assert result.returncode == 1
    assert "xcode-select --install" in result.stdout
    assert not (machine.monitor / "PolarisMonitor").exists()


def test_a_failed_compile_leaves_no_binary(tmp_path: Path) -> None:
    machine = mac_machine(tmp_path)
    # a compiler that dies halfway leaves a partial output behind
    machine.fake("xcrun", FIND_OUTPUT + 'echo partial > "$out"; exit 1')

    result = machine.run()

    assert result.returncode == 1
    assert "could not compile the window" in result.stdout
    assert [p.name for p in machine.monitor.iterdir() if p.name.startswith("PolarisMonitor")] == []


# Command


def test_the_command_runs_the_launcher() -> None:
    text = COMMAND.read_text()

    assert 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/open-window.sh"' in text
    assert text.startswith("---\ndescription: ")
