# Pull Request Description Template

> **Brevity:** A pull request description is read before a review, not instead of one. Keep prose sections to four lines or fewer and express everything else as bullets, tables, or a diagram. Never paste diff hunks — reference `path/to/file.py:42` instead.
>
> **Diagrams:** All diagrams must be written in [Mermaid](https://mermaid.js.org/) inside a ```` ```mermaid ```` fenced block. Do not use ASCII art or external image links.
>
> **Punctuation:** Do not use em dashes (—) anywhere in the rendered output.

---

## Output Template

````markdown
# {PR_TITLE}

{ONE_LINE_SUMMARY}

| Field | Value |
|-------|-------|
| Source branch | `{HEAD_BRANCH}` |
| Target branch | `{BASE_BRANCH}` |
| Commits | {COMMIT_COUNT} |
| Files changed | {FILES_CHANGED} |
| Lines | +{LINES_ADDED} / -{LINES_REMOVED} |
| Stacks touched | {STACKS_TOUCHED} |

## Why

{MOTIVATION}

## What changed

{FOR_EACH_CHANGE_AREA}
**{CHANGE_AREA_NAME}**

{CHANGE_AREA_BULLETS}
{END_FOR_EACH}

{IF_EXCLUDED_FILES}
Not detailed above: {EXCLUDED_FILES_SUMMARY}.
{END_IF}

{IF_ARCHITECTURE_DIAGRAM}
## Architecture

{ARCHITECTURE_DESCRIPTION}

```mermaid
{ARCHITECTURE_DIAGRAM}
```
{END_IF}

{IF_BEFORE_AFTER}
## Before / After

| Aspect | Before | After |
|--------|--------|-------|
{BEFORE_AFTER_TABLE_ROWS}
{END_IF}

{IF_BREAKING_CHANGES}
## Breaking changes

| What breaks | Impact | Migration |
|-------------|--------|-----------|
{BREAKING_CHANGES_TABLE_ROWS}
{END_IF}

## Demo

{IF_DEMO_ITEMS}
<!-- Drag images or videos into the cells below when opening the pull request. Set only width on each <img> (about 800 for full screenshots, 480-600 for terminal output or small details). -->

| What | Media |
|------|-------|
{FOR_EACH_DEMO_ITEM}
| {DEMO_ITEM} | _(drop image or video here)_ |
{END_FOR_EACH}
{END_IF}
{IF_NO_DEMO_ITEMS}
No visual output to demonstrate: this change has no user-facing surface.
{END_IF}

## How to test

{HOW_TO_TEST}

{IF_RISKS}
## Risks and rollback

{RISKS}

Rollback: {ROLLBACK}
{END_IF}

{IF_RELATED}
## Related

{RELATED}
{END_IF}
````

---

## Placeholder Reference

### Always present

| Placeholder | Source |
|-------------|--------|
| `{PR_TITLE}` | One imperative line under 72 characters, Conventional Commit shaped (e.g., `feat(documentation): add pull request description skill`) |
| `{ONE_LINE_SUMMARY}` | A single sentence stating what a reviewer gets from merging this. Serves as the TL;DR |
| `{HEAD_BRANCH}` / `{BASE_BRANCH}` | Current branch and resolved default branch |
| `{COMMIT_COUNT}` | Number of non-merge commits since the merge base |
| `{FILES_CHANGED}` | File count from `git diff --stat` |
| `{LINES_ADDED}` / `{LINES_REMOVED}` | Insertion and deletion counts from `git diff --stat` |
| `{STACKS_TOUCHED}` | Comma-separated stacks detected from changed paths (e.g., `dbt, Airflow`). Use `n/a` when only one area is touched and it has no stack label |
| `{MOTIVATION}` | Why the change was made — the problem it solves, not the mechanics. Four lines maximum |
| `{CHANGE_AREA_NAME}` | Short label for a group of related changes (e.g., `Skill`, `Templates`, `CI`). Repeat per area |
| `{CHANGE_AREA_BULLETS}` | One-line bullets under that area, each referencing a path. At most 8 top-level bullets across all areas |
| `{HOW_TO_TEST}` | Numbered steps a reviewer runs to verify the change, with exact commands |

### Conditional blocks

| Block | Renders when |
|-------|--------------|
| `{IF_EXCLUDED_FILES}` … `{END_IF}` | Lockfiles, generated output, or pure-formatting churn were left out of the change summary |
| `{IF_ARCHITECTURE_DIAGRAM}` … `{END_IF}` | The diff touches two or more distinct stacks or architectural layers |
| `{IF_BEFORE_AFTER}` … `{END_IF}` | Behavior, an interface, a schema, or a config shape changed in a way expressible as two columns. Not for pure additions |
| `{IF_BREAKING_CHANGES}` … `{END_IF}` | A commit carries `!` or a `BREAKING CHANGE:` footer, or the diff removes/renames a public symbol, signature, config key, or env var |
| `{IF_DEMO_ITEMS}` … `{END_IF}` | The change has a user-facing surface worth showing: UI, CLI output, dashboard, or a generated artifact |
| `{IF_NO_DEMO_ITEMS}` … `{END_IF}` | The change has no visual output. Mutually exclusive with `{IF_DEMO_ITEMS}` — exactly one of the two renders |
| `{IF_RISKS}` … `{END_IF}` | The change carries deployment, data, or compatibility risk worth calling out |
| `{IF_RELATED}` … `{END_IF}` | Issues, tickets, ADRs, or prior pull requests are linked. Never invent an identifier |

### Conditional placeholders

| Placeholder | Description |
|-------------|-------------|
| `{EXCLUDED_FILES_SUMMARY}` | What was left out and why (e.g., `uv.lock and 3 generated fixtures`) |
| `{ARCHITECTURE_DESCRIPTION}` | One or two lines introducing the diagram — what it shows and how to read it |
| `{ARCHITECTURE_DIAGRAM}` | Mermaid body only, without the fence. `flowchart` for architecture, `sequenceDiagram` for request flows, `erDiagram` for schema changes |
| `{BEFORE_AFTER_TABLE_ROWS}` | One `\| aspect \| before \| after \|` row per changed behavior |
| `{BREAKING_CHANGES_TABLE_ROWS}` | One `\| what breaks \| impact \| migration \|` row per breaking change. Migration must be actionable |
| `{DEMO_ITEM}` | Name of one screen, flow, or command output worth a screenshot or clip. Repeat per item. Never fabricate a media link |
| `{RISKS}` | Bullet list of risks introduced by the change |
| `{ROLLBACK}` | How to undo the change if it misbehaves in production |
| `{RELATED}` | Bullet list of links to issues, tickets, ADRs, or prior pull requests |

### Rendering rules

- Exactly one of `{IF_DEMO_ITEMS}` / `{IF_NO_DEMO_ITEMS}` renders — the `## Demo` heading itself is always present.
- Never substitute a credential-shaped value read from the diff into any placeholder.
- Leave no template syntax in the output: no stray `{PLACEHOLDER}`, `{IF_...}`, `{END_IF}`, or `{FOR_EACH_...}` markers.
- No em dashes (—) in the rendered output.
- Image tags set only `width`, sized to the content (about 800 for full screenshots, 480–600 for terminal output or small details), never `height`.
