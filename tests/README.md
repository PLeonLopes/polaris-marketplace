# Tests

Test suite for the Polaris marketplace tooling.

## Structure

The tree mirrors the repository layout: the test for `X/Y/Z.py` lives in `tests/X/Y/`.
Hidden directories drop their leading dot (`.githooks/` → `tests/githooks/`).

```
tests/
├── githooks/
│   └── test_commit_msg.py            # .githooks/commit-msg
├── plugins/
│   └── monitor/
│       └── scripts/
│           ├── window/
│           │   ├── test_assets.py        # plugins/monitor/scripts/window/*.json (mascots, themes)
│           │   └── test_window.py        # plugins/monitor/scripts/window/ (renders both windows)
│           ├── test_beep.py              # plugins/monitor/scripts/beep.sh (+ hooks.json wiring)
│           ├── test_open_window.py       # plugins/monitor/scripts/open-window.sh (+ its command)
│           ├── test_session.py           # plugins/monitor/scripts/session.sh (+ hooks.json wiring)
│           ├── test_setup_statusline.py  # plugins/monitor/scripts/setup-statusline.sh
│           └── test_statusline.py        # plugins/monitor/scripts/statusline.sh
├── png.py                            # read_png/count_color: check the colors a window drew
├── shell.py                          # BASH: the interpreter shell tests must use
└── scripts/
    └── ci/
        ├── test_check_commit_messages.py  # scripts/ci/check-commit-messages.sh
        ├── test_check_plugin_versions.py  # scripts/ci/check-plugin-versions.py
        ├── test_determine_bump.py         # scripts/ci/determine-bump.sh
        └── test_validate_marketplace.py   # scripts/ci/validate-marketplace.py
```

## Quick start

```bash
uv sync

# Run all tests (what pre-commit and CI run)
uv run pytest

# With coverage
uv run pytest --cov=scripts
```

## Conventions

- **Hyphenated CI scripts** (`scripts/ci/<name>.py`) are entry points, not import targets. Load them with `importlib` under a private module name (see `tests/scripts/ci/test_validate_marketplace.py`) and exercise the exit-code contract via `subprocess`.
- **Isolation:** build fixtures under pytest's `tmp_path`; never read or modify the real `plugins/` tree. Scripts that read git history are tested against a throwaway repository created with `git init` inside `tmp_path`, with a local commit identity.
- **Shell scripts that call external programs** (sound players, `powershell.exe`) are tested with fake executables placed first on `PATH` that log their arguments (see `tests/plugins/monitor/scripts/test_beep.py`). Never let a test reach the real program.
- **Windows that draw** (the monitor window) are rendered off screen in a snapshot mode that saves a PNG and a text report; tests assert on the report and on pixel colors with `tests.png`. Each window's tests run only where it can (Windows PowerShell on Windows, `xcrun swiftc` on macOS) and skip elsewhere.
- **Cross-platform:** CI runs the suite on Ubuntu, macOS and Windows. Run shell scripts through `tests.shell.BASH`, skip tests that need symlinks with `os.name == "nt"`, and point `HOME`/`CLAUDE_CONFIG_DIR` at `tmp_path` for anything that touches Claude settings.
- **Markers** (configured in `pyproject.toml`):
  - `@pytest.mark.slow` — slow tests (skip with `-m "not slow"`)
