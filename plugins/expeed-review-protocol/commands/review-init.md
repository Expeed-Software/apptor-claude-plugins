---
name: review-init
description: Bootstrap .claude/reviews/<branch>.md from the checklist template. Propose a tier from git diff stats and user description. Commit the skeleton so it's visible in the PR.
---

# /review-init

You are initializing the Expeed review checklist for the current branch. Execute the following steps in order; do not skip.

## Step 1 — Gather context

Run:
- `git rev-parse --abbrev-ref HEAD` — the branch name (refuse to proceed if it is `main`, `master`, `dev`, or `develop`; tell the user the protocol only applies to feature branches).
- `git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD origin/master 2>/dev/null || git merge-base HEAD origin/dev` — the fork point.
- `git diff --stat <fork-point>...HEAD` — the blast-radius summary.
- `git diff --name-only <fork-point>...HEAD` — the list of changed files.

Also check if `.claude/expeed-review-protocol.local.md` exists in the repo. If yes, read its frontmatter — it may override default boot commands and adversarial grep roots.

## Step 2 — Propose a tier

Use these rules mechanically first, then ask the user to confirm:

- If the ONLY changed files match `*.md`, `*.txt`, or live under doc-only directories (`docs/`, `README*`), AND no file contains non-comment code changes → Tier 0.
- If any file under a `migrations/`, `liquibase/`, `db/changelog/` path → Tier 3.
- Else if any file touches auth, tenancy, secrets, crypto (search paths for `auth`, `tenant`, `secret`, `crypto`, `jwt`, `apikey`) → Tier 3.
- Else if any file under a `deployment/`, `k8s/`, `docker/`, `helm/` path AND flag/prod-related → Tier 3.
- Else if any frontend file changed AND any backend file changed → Tier 2.
- Else if any controller / route / API definition file changed → Tier 2.
- Else if the diff touches more than one module / service / package → Tier 2.
- Else if the diff touches ≥5 files → Tier 2.
- Else → Tier 1.

Show the proposed tier, the rule that triggered it, and the `git diff --stat` output. Ask the user to confirm or override. Record the final tier and the one-sentence rationale.

## Step 3 — Create the checklist

Copy the template from `${CLAUDE_PLUGIN_ROOT}/templates/review-checklist.md` to `.claude/reviews/<branch-name>.md`. Substitute:

- `<branch-name>` → actual branch.
- `[0 | 1 | 2 | 3]` → the confirmed tier.
- Tier rationale line → the user's confirmed rationale.
- Blast radius line → "N files changed, M modules touched, user-facing: yes/no" from the diff analysis.
- Started date → today's date.

Create the parent directory chain first (branches like `feature/output-redesign` require nested directories):

```bash
mkdir -p "$(dirname .claude/reviews/<branch-name>.md)"
```

This also creates `.claude/reviews/` if it does not exist.

## Step 4 — Commit the skeleton

Stage `.claude/reviews/<branch>.md` and commit with message:

```
chore(review): initialize Tier <N> review checklist for <branch-name>
```

Do NOT commit anything else. The checklist is the only file in this commit.

## Step 5 — Tell the user what comes next

Print:

> Review checklist initialized at `.claude/reviews/<branch>.md` (Tier <N>).
> Required remaining steps for Tier <N>:
> - <list based on tier>
> Next commands: `/smoke-test` to fill the smoke-test section, then `/review-complete` when ready to ship.

## Refusals

- Refuse on protected branches. Protocol is for feature branches only.
- Refuse if `.claude/reviews/<branch>.md` already exists — tell the user to open it and continue, or delete it explicitly if they want to start over.
