# Tests

Test suite for the Polaris marketplace tooling.

## Structure

The tree mirrors the repository layout: the test for `X/Y/Z.py` lives in `tests/X/Y/`.
Hidden directories drop their leading dot (`.githooks/` → `tests/githooks/`).

```
tests/
├── githooks/
│   └── test_commit_msg.py            # .githooks/commit-msg
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

# Run all tests
uv run pytest

# Run without API calls (what pre-commit and CI run)
uv run pytest -m "not api"

# With coverage
uv run pytest --cov=scripts
```

## Conventions

- **Hyphenated CI scripts** (`scripts/ci/<name>.py`) are entry points, not import targets. Load them with `importlib` under a private module name (see `tests/scripts/ci/test_validate_marketplace.py`) and exercise the exit-code contract via `subprocess`.
- **Isolation:** build fixtures under pytest's `tmp_path`; never read or modify the real `plugins/` tree. Scripts that read git history are tested against a throwaway repository created with `git init` inside `tmp_path`, with a local commit identity.
- **Markers** (configured in `pyproject.toml`):
  - `@pytest.mark.api` — calls the Anthropic API (skip with `-m "not api"`)
  - `@pytest.mark.slow` — slow tests (skip with `-m "not slow"`)
