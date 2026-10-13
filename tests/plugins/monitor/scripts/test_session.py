"""Tests for plugins/monitor/scripts/session.sh, the session state hook of the monitor window.

Each test runs the real script with a throwaway HOME that already has the monitor directory
(the window creates it), so nothing outside tmp_path is read or written. The platform is
forced to linux (windows on Windows runners), which keeps the WSL routing off unless a test
turns it on with fake cmd.exe and wslpath commands.
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
SCRIPT = REPO_ROOT / "plugins" / "monitor" / "scripts" / "session.sh"
HOOKS = REPO_ROOT / "plugins" / "monitor" / "hooks" / "hooks.json"

pytestmark = pytest.mark.skipif(shutil.which("jq") is None, reason="session.sh needs jq")

PLATFORM = "windows" if os.name == "nt" else "linux"
UNSET = ("CLAUDE_CONFIG_DIR", "CLAUDE_CODE_REMOTE", "CLAUDE_CODE_ENTRYPOINT", "WSL_DISTRO_NAME")


class Home:
    """A fake home whose ~/.polaris-monitor exists, as after opening the window."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.monitor = root / ".polaris-monitor"
        self.monitor.mkdir()
        self.env = {key: value for key, value in os.environ.items() if key not in UNSET}
        self.env.update(HOME=str(root), POLARIS_MONITOR_PLATFORM=PLATFORM)

    def run(self, event: str, payload: object) -> subprocess.CompletedProcess[str]:
        stdin = payload if isinstance(payload, str) else json.dumps(payload)
        return subprocess.run(
            [BASH, SCRIPT, event],
            input=stdin,
            env=self.env,
            capture_output=True,
            encoding="utf-8",
            check=True,
        )

    def sessions(self, folder: Path | None = None) -> dict[str, dict[str, object]]:
        folder = (folder or self.monitor) / "sessions"
        if not folder.exists():
            return {}
        return {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in folder.glob("*.json")}

    def session(self, session_id: str = "s1") -> dict[str, object]:
        return self.sessions()[session_id]

    def subagents(self, session_id: str = "s1") -> list[dict[str, object]]:
        agents = self.session(session_id)["subagents"]
        assert isinstance(agents, list)
        return agents

    def write_transcripts(self, session_id: str, agent_id: str, prompt: str) -> Path:
        """A session transcript under ~/.claude/projects and the subagent's own transcript."""
        folder = self.root / ".claude" / "projects" / "proj"
        (folder / session_id / "subagents").mkdir(parents=True)
        parent = folder / f"{session_id}.jsonl"
        parent.write_text(json.dumps({"type": "user", "message": {"content": "hello"}}) + "\n")
        own = folder / session_id / "subagents" / f"agent-{agent_id}.jsonl"
        own.write_text(json.dumps({"type": "user", "message": {"content": prompt}}) + "\n")
        return parent


@pytest.fixture
def home(tmp_path: Path) -> Home:
    return Home(tmp_path)


# Main session events


def test_prompt_marks_the_session_as_working(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp/project"})

    assert home.session()["state"] == "working"
    assert home.session()["name"] == "project"


def test_stop_marks_the_session_as_finished_and_end_removes_it(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("waiting", {"session_id": "s1", "cwd": "/tmp"})
    assert home.session()["state"] == "waiting"

    home.run("end", {"session_id": "s1"})
    assert home.sessions() == {}


@pytest.mark.parametrize("bad_id", ["../../evil", "a/b", "", "x" * 200])
def test_unsafe_session_ids_write_nothing(home: Home, bad_id: str) -> None:
    home.run("working", {"session_id": bad_id, "cwd": "/tmp"})

    assert home.sessions() == {}
    assert not list(home.root.rglob("evil*"))


@pytest.mark.parametrize("payload", ["not json", "[1, 2]", {"session_id": 42}])
def test_unusable_input_writes_nothing(home: Home, payload: object) -> None:
    home.run("working", payload)

    assert home.sessions() == {}


def test_stop_coming_from_a_subagent_does_not_finish_the_session(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("waiting", {"session_id": "s1", "cwd": "/tmp", "agent_id": "a1"})

    assert home.session()["state"] == "working"


def test_permission_request_from_a_subagent_still_counts(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    payload = {"session_id": "s1", "agent_id": "a1", "notification_type": "permission_prompt"}
    home.run("notification", payload)

    assert home.session()["state"] == "permission"


def test_idle_notice_marks_the_session_as_waiting(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("notification", {"session_id": "s1", "message": "Claude is waiting for your input"})

    assert home.session()["state"] == "waiting"


def test_the_same_state_keeps_its_start_time_except_permission(home: Home) -> None:
    home.run("waiting", {"session_id": "s1", "cwd": "/tmp"})
    since = home.session()["since"]
    time.sleep(1.1)
    home.run("notification", {"session_id": "s1", "message": "Claude is waiting for your input"})
    assert home.session()["since"] == since

    permission = {"session_id": "s1", "notification_type": "permission_prompt"}
    home.run("notification", permission)
    since = home.session()["since"]
    time.sleep(1.1)
    home.run("notification", permission)
    assert home.session()["since"] != since


# Session name


def test_the_title_from_the_transcript_wins_over_the_folder_name(home: Home) -> None:
    transcript = home.write_transcripts("s1", "a1", "prompt")
    lines = [
        {"type": "ai-title", "sessionId": "s1", "aiTitle": "Automatic title"},
        {"type": "custom-title", "sessionId": "s1", "customTitle": "Renamed"},
        {"type": "ai-title", "sessionId": "s1", "aiTitle": "Newer automatic title"},
        {"type": "custom-title", "sessionId": "other", "customTitle": "Another session"},
    ]
    with transcript.open("a", encoding="utf-8") as file:
        file.writelines(json.dumps(line) + "\n" for line in lines)
        file.write("{broken line\n")
    payload = {"session_id": "s1", "cwd": "/tmp/project", "transcript_path": str(transcript)}

    home.run("working", payload)

    assert home.session()["name"] == "Renamed"


def test_without_a_custom_title_the_latest_automatic_one_is_used(home: Home) -> None:
    transcript = home.write_transcripts("s1", "a1", "prompt")
    with transcript.open("a", encoding="utf-8") as file:
        for title in ("First", "Second"):
            file.write(json.dumps({"type": "ai-title", "sessionId": "s1", "aiTitle": title}) + "\n")

    home.run("working", {"session_id": "s1", "cwd": "/tmp", "transcript_path": str(transcript)})

    assert home.session()["name"] == "Second"


def test_a_transcript_outside_the_projects_folder_is_not_read_for_the_title(
    home: Home, tmp_path: Path
) -> None:
    home.write_transcripts("s1", "a1", "prompt")
    outside = tmp_path / "outside.jsonl"
    outside.write_text(json.dumps({"type": "custom-title", "customTitle": "secret"}) + "\n")

    home.run(
        "working", {"session_id": "s1", "cwd": "/tmp/project", "transcript_path": str(outside)}
    )

    assert home.session()["name"] == "project"


def test_without_cwd_the_name_falls_back_to_the_session_id(home: Home) -> None:
    home.run("working", {"session_id": "abcdef0123456789"})

    assert home.session("abcdef0123456789")["name"] == "abcdef01"


# Subagents


def test_subagent_start_and_stop_update_only_the_list(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp/project", "transcript_path": ""})
    before = home.session()

    start = {"session_id": "s1", "agent_id": "a1", "agent_type": "Explore", "cwd": "/elsewhere"}
    home.run("subagent-start", start)
    after_start = home.session()
    assert [a["id"] for a in home.subagents()] == ["a1"]
    assert home.subagents()[0]["type"] == "Explore"
    for key in ("name", "state", "cwd", "since", "updated"):
        assert after_start[key] == before[key]

    home.run("subagent-stop", {"session_id": "s1", "agent_id": "a1"})
    assert home.subagents() == []


def test_main_events_keep_the_subagent_list(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("subagent-start", {"session_id": "s1", "agent_id": "a1", "agent_type": "Plan"})
    home.run("subagent-start", {"session_id": "s1", "agent_id": "a2", "agent_type": "Explore"})

    home.run("notification", {"session_id": "s1", "notification_type": "permission_prompt"})
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})

    assert sorted(str(a["id"]) for a in home.subagents()) == ["a1", "a2"]


def test_subagent_start_is_idempotent_and_keeps_the_first_start_time(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    start = {"session_id": "s1", "agent_id": "a1", "agent_type": "Explore"}
    home.run("subagent-start", start)
    first = home.subagents()[0]["since"]
    time.sleep(1.1)
    home.run("subagent-start", start)

    assert len(home.subagents()) == 1
    assert home.subagents()[0]["since"] == first


def test_subagent_event_for_an_unknown_session_is_ignored(home: Home) -> None:
    home.run("subagent-start", {"session_id": "ghost", "agent_id": "a1"})

    assert home.sessions() == {}


@pytest.mark.parametrize("bad_agent", ["", "a b", "../x", "x" * 200])
def test_unsafe_agent_ids_are_ignored(home: Home, bad_agent: str) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("subagent-start", {"session_id": "s1", "agent_id": bad_agent})

    assert home.subagents() == []


def test_the_subagent_list_is_capped(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    for i in range(20):
        home.run("subagent-start", {"session_id": "s1", "agent_id": f"a{i}"})

    assert len(home.subagents()) == 12


def test_agent_type_is_sanitized(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    start = {"session_id": "s1", "agent_id": "a1", "agent_type": "Ex<b>plore\n"}
    home.run("subagent-start", start)

    assert home.subagents()[0]["type"] == "Exbplore"


def test_stale_subagents_are_dropped(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    file = home.monitor / "sessions" / "s1.json"
    session = json.loads(file.read_text())
    session["subagents"] = [{"id": "old", "type": "Explore", "since": 0, "updated": 0}]
    file.write_text(json.dumps(session))

    home.run("working", {"session_id": "s1", "cwd": "/tmp"})

    assert home.subagents() == []


# Subagent descriptions


def test_two_subagents_with_the_same_prompt_get_their_own_descriptions(home: Home) -> None:
    parent = home.write_transcripts("s1", "a1", "same prompt")
    folder = parent.parent / "s1" / "subagents"
    (folder / "agent-a2.jsonl").write_text(
        json.dumps({"type": "user", "message": {"content": "same prompt"}}) + "\n"
    )
    (folder / "agent-a1.meta.json").write_text(json.dumps({"description": "First title"}))
    (folder / "agent-a2.meta.json").write_text(json.dumps({"description": "Second title"}))
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    for agent in ("a1", "a2"):
        start = {"session_id": "s1", "agent_id": agent, "transcript_path": str(parent)}
        home.run("subagent-start", start)

    descriptions = {a["id"]: a["desc"] for a in home.subagents()}
    assert descriptions == {"a1": "First title", "a2": "Second title"}


def test_prompt_first_line_is_not_used_while_a_better_description_may_still_appear(
    home: Home,
) -> None:
    parent = home.write_transcripts("s1", "a1", "Count the lines of README.md\nthen reply")
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run(
        "subagent-start", {"session_id": "s1", "agent_id": "a1", "transcript_path": str(parent)}
    )

    # No meta file yet: the description stays empty. A background process keeps looking, and
    # the prompt's first line is only the last resort, after 15 seconds.
    assert home.subagents()[0]["desc"] == ""


def test_transcripts_outside_the_projects_folder_are_not_read(home: Home, tmp_path: Path) -> None:
    home.write_transcripts("s1", "a1", "prompt")
    outside = tmp_path / "outside.jsonl"
    outside.write_text(json.dumps({"type": "user", "message": {"content": "secret"}}) + "\n")
    (tmp_path / "s1" / "subagents").mkdir(parents=True)
    meta = tmp_path / "s1" / "subagents" / "agent-a1.meta.json"
    meta.write_text(json.dumps({"description": "secret"}))
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    start = {"session_id": "s1", "agent_id": "a1", "transcript_path": str(outside)}
    home.run("subagent-start", start)

    assert home.subagents()[0]["desc"] == ""


def test_subagent_description_is_read_from_its_meta_file(home: Home) -> None:
    parent = home.write_transcripts("s1", "a1", "some prompt")
    meta = parent.parent / "s1" / "subagents" / "agent-a1.meta.json"
    meta.write_text(json.dumps({"agentType": "Explore", "description": "Meta\nfile   title"}))
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run(
        "subagent-start", {"session_id": "s1", "agent_id": "a1", "transcript_path": str(parent)}
    )

    assert home.subagents()[0]["desc"] == "Meta file title"


def test_description_is_filled_in_later_when_the_meta_file_appears_after_the_start(
    home: Home,
) -> None:
    parent = home.write_transcripts("s1", "a1", "some prompt")
    meta = parent.parent / "s1" / "subagents" / "agent-a1.meta.json"
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run(
        "subagent-start", {"session_id": "s1", "agent_id": "a1", "transcript_path": str(parent)}
    )
    assert home.subagents()[0]["desc"] == ""

    meta.write_text(json.dumps({"description": "Filled in later"}))
    deadline = time.time() + 8
    while time.time() < deadline and not home.subagents()[0]["desc"]:
        time.sleep(0.2)

    assert home.subagents()[0]["desc"] == "Filled in later"


# Held-back stop while subagents run


def test_stop_while_a_subagent_runs_keeps_the_session_working_until_it_ends(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("subagent-start", {"session_id": "s1", "agent_id": "a1"})
    home.run("waiting", {"session_id": "s1", "cwd": "/tmp"})
    assert home.session()["state"] == "working"

    home.run("subagent-stop", {"session_id": "s1", "agent_id": "a1"})
    assert home.session()["state"] == "waiting"
    assert home.subagents() == []


def test_the_session_finishes_only_when_the_last_of_several_subagents_ends(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    for agent in ("a1", "a2"):
        home.run("subagent-start", {"session_id": "s1", "agent_id": agent})
    home.run("waiting", {"session_id": "s1", "cwd": "/tmp"})

    home.run("subagent-stop", {"session_id": "s1", "agent_id": "a1"})
    assert home.session()["state"] == "working"
    home.run("subagent-stop", {"session_id": "s1", "agent_id": "a2"})
    assert home.session()["state"] == "waiting"


def test_a_subagent_ending_during_the_turn_does_not_finish_the_session(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("subagent-start", {"session_id": "s1", "agent_id": "a1"})
    home.run("subagent-stop", {"session_id": "s1", "agent_id": "a1"})

    assert home.session()["state"] == "working"


def test_idle_notice_while_a_subagent_runs_does_not_finish_the_session(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("subagent-start", {"session_id": "s1", "agent_id": "a1"})
    home.run("notification", {"session_id": "s1", "message": "Claude is waiting for your input"})

    assert home.session()["state"] == "working"


def test_a_new_prompt_clears_a_held_back_stop(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("subagent-start", {"session_id": "s1", "agent_id": "a1"})
    home.run("waiting", {"session_id": "s1", "cwd": "/tmp"})
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("subagent-stop", {"session_id": "s1", "agent_id": "a1"})

    assert home.session()["state"] == "working"


def test_stop_without_subagents_still_finishes_the_session(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("waiting", {"session_id": "s1", "cwd": "/tmp"})

    assert home.session()["state"] == "waiting"


def test_subagents_ending_at_the_same_time_are_all_removed(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    agents = [f"a{i}" for i in range(12)]
    for agent in agents:
        home.run("subagent-start", {"session_id": "s1", "agent_id": agent})
    assert len(home.subagents()) == 12

    # Each process gets its input before any of them is waited on, so they really overlap.
    procs: list[subprocess.Popen[str]] = []
    for agent in agents:
        proc = subprocess.Popen(
            [BASH, SCRIPT, "subagent-stop"], stdin=subprocess.PIPE, env=home.env, text=True
        )
        assert proc.stdin is not None
        proc.stdin.write(json.dumps({"session_id": "s1", "agent_id": agent}))
        proc.stdin.close()
        procs.append(proc)
    for proc in procs:
        proc.wait(timeout=30)

    assert home.subagents() == []
    assert not list((home.monitor / "sessions").glob("*.lock"))


# Where and how files are written


def test_nothing_is_written_until_the_monitor_folder_exists(home: Home) -> None:
    shutil.rmtree(home.monitor)

    home.run("working", {"session_id": "s1", "cwd": "/tmp"})

    assert not home.monitor.exists()


def test_cloud_sessions_are_not_recorded(home: Home) -> None:
    home.env["CLAUDE_CODE_REMOTE"] = "true"

    home.run("working", {"session_id": "s1", "cwd": "/tmp"})

    assert home.sessions() == {}


def test_the_hook_prints_nothing(home: Home) -> None:
    # UserPromptSubmit adds a hook's stdout to Claude's context.
    result = home.run("working", {"session_id": "s1", "cwd": "/tmp"})

    assert result.stdout == ""


def test_the_entrypoint_is_recorded(home: Home) -> None:
    home.env["CLAUDE_CODE_ENTRYPOINT"] = "claude-vscode"

    home.run("working", {"session_id": "s1", "cwd": "/tmp"})

    assert home.session()["entrypoint"] == "claude-vscode"


@pytest.mark.skipif(os.name == "nt", reason="POSIX file modes")
def test_session_files_are_private(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})

    folder = home.monitor / "sessions"
    assert stat.S_IMODE(folder.stat().st_mode) == 0o700
    assert stat.S_IMODE((folder / "s1.json").stat().st_mode) == 0o600


@pytest.mark.skipif(os.name == "nt", reason="the process tree is only read on macOS and Linux")
def test_the_claude_process_id_is_recorded_once(home: Home) -> None:
    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    pid = home.session()["pid"]
    assert isinstance(pid, int)
    assert pid > 1

    file = home.monitor / "sessions" / "s1.json"
    session = json.loads(file.read_text())
    session["pid"] = 4242
    file.write_text(json.dumps(session))
    home.run("waiting", {"session_id": "s1", "cwd": "/tmp"})
    assert home.session()["pid"] == 4242


def test_windows_sessions_have_no_process_id(home: Home) -> None:
    home.env["POLARIS_MONITOR_PLATFORM"] = "windows"

    home.run("working", {"session_id": "s1", "cwd": "/tmp"})

    assert home.session()["pid"] is None


def fake_command(folder: Path, name: str, body: str) -> None:
    script = folder / name
    script.write_text(f"#!/usr/bin/env bash\n{body}\n")
    script.chmod(0o755)


def fake_windows(home: Home, tmp_path: Path) -> Path:
    """Fake cmd.exe and wslpath that resolve the Windows profile to a folder in tmp_path."""
    windows_monitor = tmp_path / "c" / "Users" / "me" / ".polaris-monitor"
    tools = tmp_path / "tools"
    tools.mkdir()
    fake_command(tools, "cmd.exe", "printf 'C:\\\\Users\\\\me\\r\\n'")
    fake_command(
        tools,
        "wslpath",
        f'[ "$2" = "C:\\\\Users\\\\me\\\\.polaris-monitor" ] && echo "{windows_monitor}"',
    )
    home.env["PATH"] = f"{tools}{os.pathsep}{home.env['PATH']}"
    home.env["POLARIS_MONITOR_PLATFORM"] = "wsl"
    return windows_monitor


@pytest.mark.skipif(os.name == "nt", reason="fakes WSL commands with extensionless scripts")
def test_wsl_writes_to_the_windows_profile_once_the_window_was_opened(
    home: Home, tmp_path: Path
) -> None:
    windows_monitor = fake_windows(home, tmp_path)
    windows_monitor.mkdir(parents=True)

    home.run("working", {"session_id": "s1", "cwd": "/tmp"})

    assert home.sessions(windows_monitor)["s1"]["state"] == "working"
    assert home.sessions(windows_monitor)["s1"]["pid"] is None
    assert home.sessions() == {}
    assert (home.monitor / "winpath").read_text().strip() == str(windows_monitor)


@pytest.mark.skipif(os.name == "nt", reason="fakes WSL commands with extensionless scripts")
def test_wsl_keeps_sessions_local_while_the_windows_folder_is_missing(
    home: Home, tmp_path: Path
) -> None:
    windows_monitor = fake_windows(home, tmp_path)

    home.run("working", {"session_id": "s1", "cwd": "/tmp"})

    assert home.session()["state"] == "working"
    assert not windows_monitor.exists()


@pytest.mark.skipif(os.name == "nt", reason="fakes WSL commands with extensionless scripts")
@pytest.mark.parametrize(
    "cached", ["relative/.polaris-monitor", "/a/../b/.polaris-monitor", "/tmp/elsewhere"]
)
def test_wsl_ignores_a_tampered_path_cache(home: Home, tmp_path: Path, cached: str) -> None:
    windows_monitor = fake_windows(home, tmp_path)
    windows_monitor.mkdir(parents=True)
    (home.monitor / "winpath").write_text(cached)

    home.run("working", {"session_id": "s1", "cwd": "/tmp"})

    assert "s1" in home.sessions(windows_monitor)


@pytest.mark.skipif(os.name == "nt", reason="fakes WSL commands with extensionless scripts")
def test_a_failed_windows_lookup_is_cached(home: Home, tmp_path: Path) -> None:
    tools = tmp_path / "tools"
    tools.mkdir()
    calls = tmp_path / "calls"
    fake_command(tools, "cmd.exe", f"echo called >> '{calls}'; exit 1")
    home.env["PATH"] = f"{tools}{os.pathsep}{home.env['PATH']}"
    home.env["POLARIS_MONITOR_PLATFORM"] = "wsl"

    home.run("working", {"session_id": "s1", "cwd": "/tmp"})
    home.run("waiting", {"session_id": "s1", "cwd": "/tmp"})

    assert calls.read_text().count("called") == 1
    assert (home.monitor / "winpath.fail").exists()
    assert home.session()["state"] == "waiting"


@pytest.mark.skipif(os.name == "nt", reason="the real jq.exe already ends lines with CRLF")
def test_crlf_from_jq_on_windows_is_ignored(home: Home, tmp_path: Path) -> None:
    tools = tmp_path / "tools"
    tools.mkdir()
    fake_command(tools, "jq", f"'{shutil.which('jq')}' \"$@\" | sed 's/$/\\r/'")
    home.env["PATH"] = f"{tools}{os.pathsep}{home.env['PATH']}"

    home.run("working", {"session_id": "s1", "cwd": "/tmp/project"})
    home.run("subagent-start", {"session_id": "s1", "agent_id": "a1", "agent_type": "Explore"})

    assert home.session()["name"] == "project"
    assert home.subagents()[0]["type"] == "Explore"


# Registration


def test_hooks_call_session_sh_for_every_tracked_event() -> None:
    hooks = json.loads(HOOKS.read_text())["hooks"]
    expected = {
        "UserPromptSubmit": "working",
        "Stop": "waiting",
        "Notification": "notification",
        "SubagentStart": "subagent-start",
        "SubagentStop": "subagent-stop",
        "SessionEnd": "end",
    }
    for event, argument in expected.items():
        groups = [g for g in hooks[event] if "matcher" not in g]
        commands = [h["command"] for g in groups for h in g["hooks"]]
        assert f'bash "${{CLAUDE_PLUGIN_ROOT}}/scripts/session.sh" {argument}' in commands, event
