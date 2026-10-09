<!--
Title: a Conventional Commit, e.g. "feat(documentation): add pr-description skill".
Keep prose short — bullets and tables over paragraphs.
-->

<One sentence: what a reviewer gets from merging this.>

## Why

<The problem this solves. Link the related issue: "Closes #N".>

## What changed

**<Area>**

- <One line per change, referencing `path/to/file`>

## How to test

1. <Exact command or step>

## Checklist

- [ ] Every commit follows Conventional Commits, one topic per commit
- [ ] Changed plugins have a bumped `version` in `plugin.json`, and `metadata.version` in `marketplace.json` is bumped with them
- [ ] New or changed skills were tried in a Claude Code session (`/plugin marketplace add ./polaris-marketplace`)
- [ ] `uv run pre-commit run --all-files` passes locally
- [ ] No secrets, credentials or personal data in the diff
