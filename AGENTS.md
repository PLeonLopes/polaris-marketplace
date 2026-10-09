# AGENTS.md

Guidance for AI coding agents (Claude Code and others) working in this repository.

## What this repository is

**Polaris** is a personal [Claude Code](https://claude.com/claude-code) plugin marketplace. It distributes plugins that bundle skills, agents, commands, hooks and MCP servers.

- `.claude-plugin/marketplace.json` is the registry: it lists every plugin, and its `name` (`polaris`) is the suffix used on install (`/plugin install <plugin>@polaris`).
- Each plugin lives in `plugins/<domain>/` and has its own manifest at `plugins/<domain>/.claude-plugin/plugin.json`.

## Repository layout

```
.claude-plugin/marketplace.json     ← registry of all plugins
plugins/
  <domain>/
    .claude-plugin/plugin.json      ← plugin manifest (name, version, description)
    skills/<skill-name>/SKILL.md    ← one directory per skill (flat, no domain nesting)
    agents/<agent-name>.md          ← subagents
    commands/<command-name>.md      ← slash commands
    hooks/hooks.json                ← event hooks
    .mcp.json                       ← MCP servers shipped with the plugin
    scripts/                        ← executables used by skills and hooks
    templates/                      ← output templates
    README.md                       ← what the plugin offers and how to use it
```

Only the directories a plugin actually needs should exist. Claude Code discovers `skills/`, `agents/`, `commands/`, `hooks/hooks.json` and `.mcp.json` by convention, so `plugin.json` does not need to list them.

## Development environment

Tooling is managed by [uv](https://docs.astral.sh/uv/); `pyproject.toml` only pins development dependencies (this repository is not a Python package).

```bash
uv sync                                   # create .venv with dev tools
uv run pre-commit install                 # install pre-commit + commit-msg hooks (once per clone)

uv run pre-commit run --all-files         # run every quality gate
uv run pytest -m "not api"                # tests that need no API access
uv run basedpyright                       # type checking
uv run scripts/ci/validate-marketplace.py # repository conventions
claude plugin validate .                  # Claude Code manifest schema
```

`scripts/ci/validate-marketplace.py` enforces the conventions below (registration, naming, semver, flat skills, frontmatter, no hardcoded user paths). When a convention changes, update the validator and its tests in `tests/scripts/ci/` in the same PR.

CI scripts in `scripts/ci/` are hyphenated entry points (`#!/usr/bin/env python3` + PEP 723 inline metadata), run with `uv run scripts/ci/<name>.py`. Tests mirror the repository layout — see [tests/README.md](tests/README.md).

Spell checking runs with `--write-changes`: Portuguese words it would wrongly "fix" are listed in `[tool.codespell]` in `pyproject.toml`. Add new ones there instead of disabling the hook.

## Conventions

- **Language:** all repository content (code, docs, skill frontmatter, YAML keys) is written in English.
- **Naming:**
  - Plugin directory: `plugins/<domain>` (e.g. `plugins/documentation`).
  - Plugin `name`: `polaris-<domain>` (e.g. `polaris-documentation`).
  - Skills, agents and commands: kebab-case. A skill's frontmatter `name` must equal its directory name.
- **Paths:** reference files inside a plugin with `${CLAUDE_PLUGIN_ROOT}`. Never hardcode absolute or user-specific paths.
- **Skill descriptions are triggers:** the `description` must state what the skill does, when to use it, and when **not** to use it.
- **Registration:** every plugin directory must have a matching entry in `marketplace.json`, and vice versa.
- **Indentation:** 2 spaces in JSON/YAML, 4 spaces in Python and shell.

## Git workflow

- Never commit directly to `main`; every change goes through a pull request.
- Branch names: `<type>/<short-description>` with a single slash (e.g. `feat/pr-description-skill`).
- Commits follow [Conventional Commits](https://www.conventionalcommits.org): `<type>(<scope>)!: <description>`.
- Split a pull request into a few focused commits, one per topic. PRs are merged with **rebase and merge**, so every commit lands on `main` as-is and must be a Conventional Commit.

## Versioning

- **Plugins:** bump `version` in the plugin's `plugin.json` in the same PR that changes the plugin (`feat` → minor, `fix`/other → patch, breaking `!` → major). New plugins start at `1.0.0`.
- **Marketplace:** bump `metadata.version` in `marketplace.json` when plugins are added, removed or bumped.
- **Repository:** releases are git tags (`vX.Y.Z`) derived from commit types.

See [CONTRIBUTING.md](CONTRIBUTING.md) for step-by-step guides.

## Sensitive changes

Changes to `marketplace.json`, any `plugin.json`, or CI workflows deserve extra care: a broken manifest blocks installation for every user of the marketplace. Validate with:

```bash
claude plugin validate .
```
