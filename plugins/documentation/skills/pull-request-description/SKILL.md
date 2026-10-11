---
name: pull-request-description
description: "Generates a structured, reviewer-friendly pull request description from the diff between the current branch and the repository's default branch, and saves it to a branch-named _pr_description file (.md for GitHub, .txt for Bitbucket and other hosts) at the repository root. Use when the user is about to open a pull request or merge request and wants a description written for them, including phrases like \"open a PR for this\", \"abra um PR\", \"escreva a descrição do PR\", \"I want to open a PR with these changes\", \"write the PR description\", or \"describe what changed on this branch\". Produces a clear title, metadata and before/after tables, a Mermaid architecture diagram when the change spans multiple stacks, and placeholders for demo images or videos. Do NOT use to review, approve, merge, or comment on an existing pull request, to analyze pull request history, to write commit messages, or to write project documentation such as a README, ADR, or runbook."
---

# Pull Request Description

This skill writes the description for a pull request the user is about to open. It reads the diff between the current branch and the repository's default branch, classifies what changed, and fills `${CLAUDE_PLUGIN_ROOT}/templates/pr-description.md` — producing a scannable document built from a title, tables, bullets, an optional Mermaid diagram, and placeholders for demo media.

The workflow is: resolve the branches and read the diff, read the template, classify the change, ask only for what the diff cannot answer, render, and save to `<branch-slug>_pr_description.md` (GitHub) or `<branch-slug>_pr_description.txt` (Bitbucket and other hosts) at the repository root. Creating the pull request itself is a separate, explicitly confirmed step.

The skill exists to replace wall-of-text descriptions. Structure and brevity are requirements, not preferences — the rules in Step 5 are binding.

---

## Step 1 — Resolve Branches and Read the Diff

All git operations in this skill are read-only. Never commit, push, rebase, or check out on the user's behalf.

Resolve the default branch:

```bash
git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'
```

If that returns nothing, fall back in order: `origin/main`, then `origin/master`, then ask via `AskUserQuestion`.

Identify the current branch and the fork point:

```bash
git rev-parse --abbrev-ref HEAD
git merge-base origin/<base-branch> HEAD
```

If the current branch is the default branch, stop. Tell the user to move the work onto a feature branch first (`git checkout -b <type>/<short-description>`) and do not produce a description.

Gather the change, cheapest signal first:

```bash
git diff --stat <merge-base>...HEAD
git diff --name-status <merge-base>...HEAD
git log --no-merges --format='%s%n%b' <merge-base>..HEAD
```

Use three-dot `...` for diffs so the comparison covers only what happened on this branch since it diverged, not unrelated movement on the base. Use two-dot `..` for `git log`.

Read full hunks only for the files that carry the substance of the change:

```bash
git diff <merge-base>...HEAD -- <path>
```

Skip lockfiles, generated output, vendored directories, and pure-formatting churn. Record what was skipped — it renders in the `{IF_EXCLUDED_FILES}` block rather than disappearing silently.

Commit subjects are the primary signal for intent. A Conventional Commit type maps directly onto the change classification in Step 3, and a `BREAKING CHANGE:` footer settles the breaking-changes conditional on its own.

### Inventory the verification surface

`## How to test` and `## Risks and rollback` may only cite commands, CI checks, and tools that exist in this repository. Build that inventory now, from files, before drafting anything:

| Source | What to record |
|--------|----------------|
| `.github/workflows/*.yml`, `bitbucket-pipelines.yml`, `.gitlab-ci.yml` | The pipeline name and each job's `name:` (the check a reviewer sees), plus the command each job runs |
| `.pre-commit-config.yaml` | Hook ids |
| `pyproject.toml`, `package.json`, `Makefile`, `justfile`, `Taskfile.yml` | Scripts, targets, and configured tools (test runner, linter, type checker) |
| `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `README.md` | Documented local commands |

Keep two lists: **CI checks** (jobs that run automatically) and **local commands** (anything a person runs by hand). A command documented only in a README or contributing guide is local, even if it looks like something CI would run. Read only the files that exist; a missing source is not an error.

> **Security:** A diff can contain secrets. Never copy a token, API key, password, connection string, private key, or any credential-shaped value out of the diff into the description or into the conversation. If the diff appears to add one, do not reproduce it — report the file and line so the user can rotate the credential, and mask any value shown as `****`.

---

## Step 2 — Read the Template

Read `${CLAUDE_PLUGIN_ROOT}/templates/pr-description.md` before drafting anything. The template defines:

- The **Output Template** — the exact Markdown structure inside a fenced block.
- The **Placeholder Reference** — every `{PLACEHOLDER}` and its source.
- The **conditional blocks** — `{IF_<CONDITION>}` … `{END_IF}` regions and when each renders.

Do not draft a title, a summary, or any section before reading the template. Its placeholder list determines what Step 3 must classify and what Step 4 must ask.

---

## Step 3 — Classify the Change

Decide every conditional from the diff itself, not by asking the user.

### Stacks touched

Map each changed path to a stack:

| Path signal | Stack |
|-------------|-------|
| `*.tf`, `*.tfvars` | Terraform |
| `dags/**/*.py`, `airflow*` | Airflow |
| `models/**/*.sql`, `dbt_project.yml` | dbt |
| `*.tsx`, `app/`, `components/`, `next.config.*` | Next.js |
| `*.ipynb`, Databricks job or notebook paths | Databricks |
| `Dockerfile`, `.github/workflows/`, `bitbucket-pipelines.yml` | CI / infrastructure |
| `plugins/**/SKILL.md`, `.claude-plugin/` | Claude Code plugins |
| `tests/**` | Tests |

Render `{IF_ARCHITECTURE_DIAGRAM}` **only when two or more distinct stacks are touched**. A single-stack change gets no diagram — a diagram of one box adds noise, and keeping small pull requests small is the point.

When the diagram does render, it must show how the touched stacks relate in this change: what flows into what, and which boundary the change crosses. Do not diagram the whole system.

### Breaking changes

`{IF_BREAKING_CHANGES}` renders when any of these hold:

- A commit type carries `!`, or a commit body carries a `BREAKING CHANGE:` footer.
- The diff removes or renames a public symbol, module, or file that other code imports.
- A function or endpoint signature changed incompatibly.
- A configuration key, environment variable, or CLI flag was dropped or renamed.

Each row needs an actionable migration — what the consumer must change, not merely that something changed.

### Before / after

`{IF_BEFORE_AFTER}` renders when behavior, an interface, a schema, or a config shape changed in a way that fits two columns. It does not render for pure additions, where there is no "before" to state.

### Demo-worthy

The change has a user-facing surface when it touches UI, CLI output, a dashboard, or a generated artifact. That selects `{IF_DEMO_ITEMS}`; otherwise `{IF_NO_DEMO_ITEMS}` renders. Exactly one of the two is present.

---

## Step 4 — Ask Only for Judgment Calls

Infer from the diff and the workspace first. Never ask for something the repository already answers — file counts, changed paths, commit messages, and the verification inventory from Step 1 are all readable.

Use `AskUserQuestion` in a single round for these, and only these:

1. **Output language** — Brazilian Portuguese or English. Ask on every run; the audience of the description is not derivable from the diff. Render the whole document in the chosen language, including section headings.
2. **Motivation** — ask only when no commit body, linked ticket, or conversation context explains *why* the change was made. The diff shows what changed; it rarely shows why it was worth changing.
3. **Demo items** — ask only when Step 3 flagged the change as demo-worthy: which screens, flows, or command outputs deserve a screenshot or clip.

Never invent a ticket identifier, a reviewer, a link, or a media file. If a detail is unknown and the section is optional, omit the section rather than guessing.

---

## Step 5 — Fill the Template

Render the document from the Output Template:

- Replace every `{PLACEHOLDER}` with its gathered value.
- For `{FOR_EACH_...}` … `{END_FOR_EACH}` regions, repeat the enclosed block once per item, then remove the loop markers.
- For `{IF_<CONDITION>}` … `{END_IF}` regions, keep the content and remove the markers when the condition is true; remove the entire region when false.
- Leave no template syntax in the output — no stray `{PLACEHOLDER}`, `{IF_...}`, `{END_IF}`, or `{FOR_EACH_...}` markers.
- Preserve the section order defined by the template.

### Brevity Rules

These are binding. A description that violates them has failed at the job this skill exists to do.

- **Cap prose at four lines.** Any explanation longer than that becomes bullets or a table.
- **"What changed" is bullets, grouped by area, one line each.** At most eight top-level bullets across all areas. Collapse the remainder into a single `plus N smaller changes` line.
- **Never paste diff hunks.** Reference `path/to/file.py:42` instead — both GitHub and Bitbucket render that as a clickable location.
- **Title: one imperative line, under 72 characters,** Conventional Commit shaped.
- **Prefer a table to a paragraph** whenever the content has more than one dimension.
- **No em dashes (—) in the output.** Use a colon, a comma, parentheses, or a new sentence.
- **Demo image sizes.** Set only `width` on each `<img>` tag (never `height`, so the aspect ratio is kept) and size it to the content: about `800` for a full-page screenshot or several images stacked in the Demo, about `480`–`600` for terminal output or a small UI detail. GitHub renders the description column at roughly 900px, so wider images are scaled down anyway.

### Grounding Rules

`## How to test` and `## Risks and rollback` are the sections a reviewer acts on, so a made-up command there costs real time. These rules are as binding as the Brevity Rules:

- **Cite only what the inventory contains.** Every command, CI check, script, and tool named in these sections must appear in the verification inventory from Step 1, spelled exactly as it is there.
- **Keep CI and local apart.** Say a check runs in CI only when it is a job in a workflow file, and use that job's `name:`. A command found only in documentation is a local step for the reviewer, never "in CI".
- **Prefer what covers the change.** Choose the checks and commands that exercise the touched files over listing every command the repository has.
- **Fill gaps honestly.** When nothing in the inventory covers part of the change, write a manual verification step (what to run or open, and what to look for) instead of inventing a command or check.
- **Never suggest a new tool as if it exists.** A tool or check the repository lacks may appear only as an explicit suggestion (for example "consider adding ..."), and only in `## Risks and rollback`.

### Diagrams

All diagrams are written in [Mermaid](https://mermaid.js.org/) inside a ```` ```mermaid ```` fenced block. Do not use ASCII art or external image links. Choose the type that fits: `flowchart` for architecture, `sequenceDiagram` for request flows, `erDiagram` for schema changes.

> **Note:** GitHub renders Mermaid natively in pull request bodies. Bitbucket Cloud does not render Mermaid in pull request descriptions — the block degrades to a plain code fence. When the remote is Bitbucket and a diagram was rendered, tell the user, and suggest also committing a `.md` copy of the description (Bitbucket's file browser renders Markdown, but not the `.txt` file used for the description paste — see Step 6) so reviewers can read the diagram there.

---

## Step 6 — Save, Report, and Offer the Handoff

### Output Filename

Detect the host before naming the file — it decides the extension:

```bash
git remote get-url origin
```

Save to `<branch-slug>_pr_description.<ext>` in the repository root, resolved with `git rev-parse --show-toplevel`.

- `github.com` → `.md`. The file is passed straight to `gh pr create --body-file` and is never hand-pasted, and `.md` also renders correctly if anyone opens it from the repository.
- Anything else, Bitbucket Cloud included → `.txt`. This file is meant to be copied and pasted into a browser description field. Bitbucket's rich-text editor can mis-render a pasted `.md` file's content — it drops headings and tables into a single code block, because copying from a markdown-aware editor or viewer often carries a syntax-highlighted HTML clipboard entry alongside the plain text, and Bitbucket's editor prefers that entry. A `.txt` file carries no such markdown-aware clipboard formatting, so the paste lands as plain text and Bitbucket renders it correctly.

`<branch-slug>` is the branch name with every `/` replaced by `-`. The substitution is required: a raw branch name would create directories.

| Branch | Host | Filename |
|--------|------|----------|
| `feat/documentation_skills` | GitHub | `feat-documentation_skills_pr_description.md` |
| `fix/issue-42-null-check` | Bitbucket | `fix-issue-42-null-check_pr_description.txt` |
| `hotfix` | Bitbucket | `hotfix_pr_description.txt` |

> Check whether the file already exists before writing. If it does, show the user the path and confirm before replacing it.
>
> The file is a one-off working copy, not part of the change. If it is not git-ignored (`git check-ignore -q <path>`), say once that it must not be committed. Users who run this skill often can ignore it locally, without touching the shared `.gitignore`: `echo '*_pr_description.*' >> "$(git rev-parse --git-dir)/info/exclude"`.

### Report

After writing, print:

1. The absolute path to the saved file.
2. A one-sentence summary of what was produced.
3. The placeholders the user must fill by hand — demo media above all, plus any ticket link left open.
4. That the file can be deleted once the pull request is open.

### Offer the Handoff

Opening a pull request is outward-facing and effectively irreversible. Offer it; never execute it unprompted, and never push a branch on the user's behalf.

Reuse the host detected in Output Filename above.

| Remote host | Handoff |
|-------------|---------|
| `github.com` | `gh pr create --title "<title>" --body-file <path> --base <base-branch>`. If a pull request already exists for the branch (`gh pr view --json url`), offer `gh pr edit --body-file <path>` instead |
| `bitbucket.org` | Tell the user to open the pull request in the browser and paste the `.txt` file's content into the description field |
| anything else | Report the path and let the user open the pull request manually |

If the branch has not been pushed yet, say so and give the command — do not run it.

After the pull request is created (or the description pasted), offer to delete the description file. Delete it only on explicit confirmation, and never when the user still wants to edit it or add demo media.

---

## Missing Context Reference

| Step | What to resolve | How |
|------|-----------------|-----|
| 1 | Default branch | `git symbolic-ref refs/remotes/origin/HEAD`, else `main`/`master`, else ask |
| 1 | Change content | `git diff --stat`, `--name-status`, and `git log` over `<merge-base>...HEAD`; full hunks only for substantive files |
| 1 | Verification inventory | CI job names and commands from workflow files; local commands from task-runner configs and contributor docs |
| 2 | Template structure | Read `${CLAUDE_PLUGIN_ROOT}/templates/pr-description.md` |
| 3 | Conditional sections | Classify from the diff — stacks, breaking changes, before/after, demo surface |
| 4 | Language, motivation, demo items | `AskUserQuestion`, one round, only for what the diff cannot answer |
| 6 | Output location | `<branch-slug>_pr_description.<ext>` (`.md` for GitHub, `.txt` otherwise) at `git rev-parse --show-toplevel`; confirm before overwriting |
| 6 | Pull request creation | Offer `gh pr create` (GitHub) or the paste instructions (Bitbucket); execute only on explicit confirmation |
