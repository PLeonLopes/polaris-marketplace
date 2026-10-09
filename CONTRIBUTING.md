# Contributing Guide

How to add content to the Polaris marketplace and ship it through the git workflow.

## Table of contents

0. [Development setup](#development-setup)
1. [Git workflow](#git-workflow)
2. [Creating a plugin](#creating-a-plugin)
3. [Creating a skill](#creating-a-skill)
4. [Creating an agent](#creating-an-agent)
5. [Creating a command](#creating-a-command)
6. [Creating a hook](#creating-a-hook)
7. [Adding an MCP server](#adding-an-mcp-server)
8. [Versioning](#versioning)
9. [Testing locally](#testing-locally)

---

## 0. Development setup <a name="development-setup"></a>

Requirements: [uv](https://docs.astral.sh/uv/) and [Claude Code](https://claude.com/claude-code).

```bash
git clone https://github.com/PLeonLopes/polaris-marketplace.git
cd polaris-marketplace
uv sync                      # dev tools in .venv
uv run pre-commit install    # quality gates on every commit
```

From then on, every `git commit` runs formatting, linting, spell checking, the marketplace validator and the tests, and rejects messages that are not Conventional Commits. To run everything by hand:

```bash
uv run pre-commit run --all-files
```

---

## 1. Git workflow <a name="git-workflow"></a>

### Branches

Never work on `main`. Create a branch named `<type>/<short-description>` (a single slash):

```bash
git checkout main
git pull origin main
git checkout -b feat/pr-description-skill
```

| Part | Values |
|------|--------|
| `<type>` | `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`, `build`, `test` |
| `<short-description>` | kebab-case, 2–4 words (e.g. `pr-description-skill`, `bootstrap-repo`) |

### Commits

Commits follow [Conventional Commits](https://www.conventionalcommits.org):

```
<type>(<optional scope>)<optional !>: <description>
```

| Type | Version effect | When to use |
|------|----------------|-------------|
| `feat` | **MINOR** (`0.X.0`) | New skill, agent, command, hook, MCP server or plugin |
| `fix` | **PATCH** (`0.0.X`) | Bug fix in a script, prompt or configuration |
| `docs` | PATCH | Documentation only |
| `refactor` | PATCH | Restructuring without behavior change |
| `perf` | PATCH | Performance improvement |
| `test` | PATCH | Adding or fixing tests |
| `build` | PATCH | Tooling and dependencies |
| `ci` | PATCH | CI/CD workflows |
| `chore` | PATCH | Maintenance |
| `style` | PATCH | Formatting only |
| `revert` | PATCH | Reverting a previous commit |
| `<type>!` | **MAJOR** (`X.0.0`) | Breaking change: removes or renames something users depend on |

Examples:

```
feat(documentation): add pr-description skill
fix(git): handle detached HEAD in git-flow skill
feat!: rename polaris-docs plugin to polaris-documentation
docs: add MCP section to contributing guide
```

### Pull requests

1. Push the branch and open a PR targeting `main`.
2. Split the work into a few focused commits, one per topic. PRs are merged with a **merge commit**: every commit lands on `main` as-is, so each one must be a Conventional Commit, and GitHub adds a `Merge pull request #N` commit that marks the PR. Use a Conventional Commit for the PR title too.
3. Describe what changed, why, and how to test it.
4. Wait for the four PR checks (Conventional Commits, Lint & Check, Tests, Plugin versions bumped) to pass before merging.
5. Merge and clean up:

   ```bash
   gh pr merge --merge --delete-branch
   git checkout main && git pull
   git branch -d <your-branch>   # commits are preserved, so a plain -d works
   ```

---

## 2. Creating a plugin <a name="creating-a-plugin"></a>

**1. Create the directory and manifest:**

```bash
mkdir -p plugins/<domain>/.claude-plugin
```

`plugins/<domain>/.claude-plugin/plugin.json`:

```json
{
  "name": "polaris-<domain>",
  "version": "1.0.0",
  "description": "What this plugin offers, in one sentence.",
  "author": {
    "name": "PLeonLopes"
  },
  "license": "MIT",
  "keywords": ["<domain>"]
}
```

Components in the default locations (`skills/`, `agents/`, `commands/`, `hooks/hooks.json`, `.mcp.json`) are discovered automatically — there is no need to list them in `plugin.json`.

**2. Register it in `.claude-plugin/marketplace.json`:**

```json
{
  "name": "polaris-<domain>",
  "source": "./plugins/<domain>",
  "description": "Short description shown when choosing which plugin to install."
}
```

**3. Add a `plugins/<domain>/README.md`** describing what the plugin offers and how to use it, and add a row to the plugin table in the root `README.md`.

---

## 3. Creating a skill <a name="creating-a-skill"></a>

A skill is knowledge or a procedure that Claude activates **on its own** when a request matches the skill's `description`.

`plugins/<domain>/skills/<skill-name>/SKILL.md`:

```markdown
---
name: <skill-name>
description: What the skill does. Use when <concrete situations and trigger phrases>. Do NOT use for <adjacent tasks that belong elsewhere>.
---

# Skill Title

## Overview
What this skill does and when it applies.

## Workflow
1. Step one
2. Step two

## Rules
- Constraints Claude must respect.
```

Rules:

- `name` must equal the directory name: lowercase letters, digits and hyphens.
- `description` is the trigger. Be specific about **when** to use the skill and **when not to**. Keep it under 1024 characters.
- Keep `SKILL.md` focused. Move long reference material, templates and scripts into sibling files and reference them with `${CLAUDE_PLUGIN_ROOT}/...` so they are loaded only when needed.

---

## 4. Creating an agent <a name="creating-an-agent"></a>

An agent is a subagent with its own persona, tools and context window, to which Claude delegates a task.

`plugins/<domain>/agents/<agent-name>.md`:

```markdown
---
name: <agent-name>
description: When Claude should delegate to this agent.
tools: Read, Grep, Glob, Bash
model: inherit
---

You are a ... Your job is to ...
```

| Field | Meaning |
|-------|---------|
| `tools` | Tools the agent may use (omit to inherit all) |
| `model` | `inherit`, or a specific model alias |

---

## 5. Creating a command <a name="creating-a-command"></a>

A command is a `/slash-command` the user invokes **explicitly**.

`plugins/<domain>/commands/<command-name>.md`:

```markdown
---
description: One line shown in the /help menu.
argument-hint: <optional arguments>
---

Instructions Claude follows when the command runs. Use $ARGUMENTS for user input.
```

---

## 6. Creating a hook <a name="creating-a-hook"></a>

A hook runs a command automatically on a Claude Code event (`PreToolUse`, `PostToolUse`, `Stop`, …).

`plugins/<domain>/hooks/hooks.json`:

```json
{
  "description": "What these hooks do",
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/my-script.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

Hooks run on the user's machine with the user's permissions — keep them fast, safe and idempotent.

---

## 7. Adding an MCP server <a name="adding-an-mcp-server"></a>

An MCP server exposes external tools (APIs, databases…) to Claude.

`plugins/<domain>/.mcp.json`:

```json
{
  "mcpServers": {
    "<server-name>": {
      "command": "uvx",
      "args": ["<package>"],
      "env": {
        "API_TOKEN": "${API_TOKEN}"
      }
    }
  }
}
```

Never commit secrets: reference them as environment variables.

---

## 8. Versioning <a name="versioning"></a>

Polaris uses three independent [semver](https://semver.org) versions:

| What | Where | Who bumps it |
|------|-------|--------------|
| Plugin | `version` in `plugins/<domain>/.claude-plugin/plugin.json` | You, in the same PR that changes the plugin |
| Marketplace | `metadata.version` in `.claude-plugin/marketplace.json` | You, when plugins are added, removed or bumped |
| Repository | GitHub Release `vX.Y.Z` | Automatically on every push to `main` |

Bump rules follow the commit types: `feat` → minor, breaking `!` → major, anything else → patch. A new plugin starts at `1.0.0`.

The **Plugin versions bumped** check fails the PR when a changed plugin or the marketplace was not bumped. Check it locally with:

```bash
uv run scripts/ci/check-plugin-versions.py origin/main
```

Release notes are generated by GitHub from the merged pull requests, so the [Releases page](https://github.com/PLeonLopes/polaris-marketplace/releases) is the changelog.

---

## 9. Testing locally <a name="testing-locally"></a>

```bash
# Validate the marketplace and a plugin
claude plugin validate .
claude plugin validate plugins/<domain>

# Validate repository conventions (naming, registration, skills, paths)
uv run scripts/ci/validate-marketplace.py
```

Then, in a Claude Code session in **another project**:

```
/plugin marketplace add /path/to/polaris-marketplace
/plugin install polaris-<domain>@polaris
```

Ask for something that should trigger your skill and confirm Claude used it. After editing files, run `/plugin marketplace update polaris` and reinstall to pick up the changes.
