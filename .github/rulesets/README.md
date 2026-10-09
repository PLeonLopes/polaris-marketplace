# Branch rulesets

The protection of `main`, kept as code. GitHub does not read these files automatically — they are applied with the GitHub API and must be re-applied after editing.

| Ruleset | Rules | Bypass |
|---------|-------|--------|
| [`main-required-checks.json`](main-required-checks.json) | The four PR checks must pass; no force-push; `main` cannot be deleted | Nobody |
| [`main-pull-request-review.json`](main-pull-request-review.json) | Changes only through pull requests; 1 approval; conversations resolved; merge commits only | Repository admins, only when merging a pull request |

They are split on purpose: a bypass skips **every** rule of its ruleset. Keeping the checks in a ruleset without bypass means the admin bypass can skip the approval (needed when working alone, since GitHub does not let you approve your own PR) but never the checks, and never allows a direct push to `main`.

`integration_id: 15368` is the GitHub Actions app: only check runs reported by Actions satisfy the rule.

## Apply

```bash
REPO=PLeonLopes/polaris-marketplace

# First time: create
gh api -X POST "repos/$REPO/rulesets" --input .github/rulesets/main-required-checks.json
gh api -X POST "repos/$REPO/rulesets" --input .github/rulesets/main-pull-request-review.json

# After editing a file: update the existing ruleset by id
gh api "repos/$REPO/rulesets" --jq '.[] | "\(.id)  \(.name)"'
gh api -X PUT "repos/$REPO/rulesets/<id>" --input .github/rulesets/<file>.json
```

## Merging as the sole maintainer

With all checks green and no approval, merge with the admin bypass:

```bash
gh pr merge --merge --admin --delete-branch
```

In the web UI this is the **Merge without waiting for requirements to be met (bypass rules)** checkbox. Required checks still apply.

## Renaming a check

Check names are the `name:` of the jobs in `.github/workflows/pr.yml`. Renaming a job without updating `main-required-checks.json` (and re-applying it) leaves the rule waiting for a check that never reports, blocking every PR.
