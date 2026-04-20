# expeed-review-protocol — MANDATORY review gate

WARNING: NON-NEGOTIABLE. This protocol is additive to any other workflow (including superpowers if present). It does not replace code review, tests, or plan discipline — it adds a terminal gate so nothing ships without end-to-end evidence.

## The gate
Before claiming "done", "complete", "ready", "approved", or before `git push` / PR creation: a tier-appropriate checklist at `.claude/reviews/<branch-name>.md` MUST exist and MUST have every required section filled with real evidence (not "TODO", not empty bullets, not "N/A" without justification).

## Tier decision — at PLAN START, not at done-claim
Decide tier the moment the plan is written. Record it in the checklist. Do not downgrade mid-flight.

- Tier 1: <5 files, single module, no UI change, no API change, no DB migration → L1 + smoke test.
- Tier 2: user-facing change OR cross-module OR new/changed API OR new event type → Tier 1 + cross-layer contract check + adversarial review.
- Tier 3: data migration, flag cutover, production deploy, auth/tenant/secrets change → Tier 2 + runbook + rollback test + staging dry-run.

When in doubt, go one tier higher.

## Required artifact
Path: `.claude/reviews/<current-git-branch>.md`. Bootstrap with `/review-init`. Close with `/review-complete`. Commit the checklist into the branch — it is the PR's evidence record.

## Smoke test definition (enforced)
"Booted the system, performed the user action, observed the user-visible result." Unit tests passing is NOT a smoke test. Compilation is NOT a smoke test. The checklist's Smoke Test section requires: exact boot command, exact user action, expected result, actual observed result (paste output or screenshot link).

## Escape hatch
Skipping a required step requires a written one-sentence justification in the checklist's "Escape hatches used" section. The justification is the audit trail. No silent skips. Environment variable `EXPEED_REVIEW_SKIP=1` bypasses the hooks for genuine emergencies and logs the bypass to stderr.

## Additive clause
This plugin does NOT replace brainstorming, TDD, plan-writing, or per-layer review disciplines already in use. It runs AFTER them as the end-to-end gate. If superpowers is installed, run its workflow first; this gate fires at done-claim.
