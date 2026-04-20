# expeed-review-protocol

A Claude Code plugin that installs a mandatory three-tier review gate into any Expeed repository. It exists because internal-consistency reviews — L1 code quality, L2 spec compliance, plan-deviation final passes — can all mark a change APPROVED while a structural integration gap sits in plain sight. In one recent case a 69-commit refactor passed every per-layer review yet shipped with a UI field that no backend code ever read; the first person to boot the app found it in thirty seconds. This plugin makes "boot the app and trace the user journey" a terminal requirement, not an optional step.

## Install

```bash
claude plugin marketplace add https://github.com/expeedsoftware/apptor-claude-plugins
claude plugin install expeed-review-protocol
```

On Windows (Git Bash), after install verify the hooks are executable:
```bash
chmod +x "$(claude plugin path expeed-review-protocol)"/hooks/*.sh
```

## What it enforces

| Tier | Trigger | Required steps |
|------|---------|----------------|
| 1 | <5 files, single module, no UI/API/DB change | L1 code review + smoke test |
| 2 | User-facing OR cross-module OR API/event change | Tier 1 + cross-layer contract check + adversarial review |
| 3 | Data migration, flag cutover, prod deploy, auth/tenant/secrets | Tier 2 + runbook + rollback test + staging dry-run |

Tier is chosen at plan-start and recorded in the checklist. When in doubt, go one tier higher.

The gate is enforced by two hooks:
- `Stop` hook — on any session-stop where the assistant's last message asserted done/complete/ready/approved, verify the checklist exists and is filled. If not, exit code 2 and a clear error message.
- `PreToolUse(Bash)` hook — intercepts `git push` and `gh pr create`. Same verification, same block.

## What it does NOT do

- Does not replace `superpowers` (brainstorming, writing-plans, TDD). Runs AFTER those, not instead of.
- Does not replace human code review. Findings from humans still land in the checklist.
- Does not block Tier 1 changes from being marked done — a filled Tier 1 checklist (L1 + smoke test evidence) is sufficient.
- Does not gate exploratory work on `main` / `master` / `dev` branches. The gate fires on feature branches.
- Does not read or modify production secrets.

## Per-repo configuration

Drop a `.claude/expeed-review-protocol.local.md` into your repo to customize smoke-test commands and boot instructions. Frontmatter example:

```markdown
---
smoke_test_boot_command: "./gradlew :apptor-flow-api:run"
smoke_test_ui_url: "http://localhost:4200"
tier_3_staging_command: "./deploy-staging.sh"
adversarial_grep_roots: ["apptor-flow-api", "apptor-flow-editor/src"]
---

# Repo-specific notes
- Our smoke tests always need `docker compose up -d postgres` first.
- Tier 2+ changes touching `NodeHandler` require a flow-designer UI walk-through.
```

`/review-init` and `/smoke-test` read this file when present.

## Opt-out / escape hatch

Two documented mechanisms:

1. Per-step skip: fill the "Escape hatches used" section of the checklist with the skipped step and a one-sentence written justification. The checklist commits into the PR, so the audit trail is permanent.
2. Emergency bypass: `EXPEED_REVIEW_SKIP=1` in the environment. Hooks will allow the action but log the bypass to stderr. Intended for hotfix pushes during incidents.

Silent skips are not supported. If you want to skip a step, write down why.

## Troubleshooting

**Stop hook blocked me and I don't know what's missing.**
Run `/review-complete`. It names every missing section by tier and either fixes or prompts for evidence.

**I'm on `main` / `dev` and the hook is still complaining.**
It shouldn't — branches named `main`, `master`, `dev`, `develop`, or detached HEAD are skipped. If it still fires, check `git rev-parse --abbrev-ref HEAD` output and open an issue.

**The PreToolUse hook blocks a legitimate push.**
Either the checklist is missing required sections, or the branch was renamed after init. Re-run `/review-init` to refresh, or set `EXPEED_REVIEW_SKIP=1` for the single push and document why in the PR.

**Hooks aren't running at all.**
Verify `chmod +x` on the `hooks/*.sh` files. On Windows, confirm Git Bash is the shell resolving `bash` in `PATH`. Claude Code must be restarted after installing the plugin so the hook registration is picked up.

**How do I know which tier applies?**
`/review-init` proposes a tier based on `git diff --stat` and your description. You can override — the rationale is stored in the checklist.
