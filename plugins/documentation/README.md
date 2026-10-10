# polaris-documentation

Documentation helpers for everyday engineering work.

## Install

```
/plugin marketplace add PLeonLopes/polaris-marketplace
/plugin install polaris-documentation@polaris
```

## Skills

| Skill | What it does |
|-------|--------------|
| [`pull-request-description`](skills/pull-request-description/SKILL.md) | Writes a pull request description from the branch diff and offers the `gh pr create` command |

### `pull-request-description`

On a feature branch with committed work, ask for it in your own words:

```
write the PR description
escreva a descrição do PR
```

The skill:

1. Reads the diff and commits between the branch and the default branch (read-only git).
2. Classifies the change: stacks touched, breaking changes, before/after, demo-worthy output.
3. Asks the output language (English or Brazilian Portuguese) and only what the diff cannot answer.
4. Fills [`templates/pr-description.md`](templates/pr-description.md): title, summary, metadata table, why, what changed, optional Mermaid diagram, before/after, demo, how to test, risks.
5. Saves `<branch-slug>_pr_description.md` (GitHub) or `.txt` (Bitbucket and other hosts, ready to paste) at the repository root, and proposes a Conventional Commit title.
6. On GitHub, offers `gh pr create --title ... --body-file ...` (or `gh pr edit` when the PR already exists), which runs only if you confirm. It never pushes.
7. Once the pull request is open, offers to delete the description file.

The generated file is a one-off working copy: never commit it, and delete it after opening the pull request. If you use the skill often, ignore it locally without touching the shared `.gitignore`:

```bash
echo '*_pr_description.*' >> "$(git rev-parse --git-dir)/info/exclude"
```

**Output conventions:** the title as the `#` heading, no em dashes, at most 8 change bullets, never pasted diff hunks, and demo images sized with `width` only (about 800 for full screenshots, 480–600 for terminal output).

**Not for:** reviewing, commenting on or merging existing pull requests, commit messages, or project documentation such as READMEs and ADRs.
