---
name: expeed-review-protocol
description: Use when closing work — when claiming done / complete / ready / shipping / about to push or open a PR — or when reviewing quality of a change before merge. Runs the Expeed three-tier review gate (L1 code review, smoke test, cross-layer contract check, adversarial review, runbook/rollback for Tier 3) and refuses to mark complete until the tier's required evidence is in `.claude/reviews/<branch>.md`.
---

# Expeed Review Protocol

## Why this exists

A recent 69-commit refactor passed per-batch L1 (code quality) reviews, per-batch L2 (spec compliance) reviews, per-batch Final (plan-deviation) reviews, per-plan contract-integration checks, and a full adversarial review. Every gate said APPROVED. The change shipped into a paper-ready state. Then one question — "how do I test this?" — surfaced a structural gap: the UI was persisting a field that no backend code read. The gap was invisible to every previous review because each reviewer worked from documents, specs, or single-layer code reads. Nobody booted the application. Nobody traced a value from a UI click through to an observable runtime effect.

The retrospective was clear about which gates carried signal. L1 found real bugs every batch. L2 tended to rubber-stamp when the author wrote both the spec and the code. Final passes were almost entirely performative. Per-plan contract checks caught within-layer issues but were blind to the UI ↔ backend seam. The two things that would have caught the gap — an actual smoke test and a hostile adversarial pass focused on cross-layer contracts — were either skipped or too narrowly scoped.

This protocol encodes those lessons. Every change, regardless of size, needs an L1 code review and a real smoke test (booted system, executed user action, observed result). Anything user-facing or cross-module also needs a cross-layer contract grep and a hostile adversarial review. Anything touching data migration, flags, or production needs a runbook and a rollback dry-run. The checklist at `.claude/reviews/<branch>.md` is the artifact, committed with the PR; the hooks refuse to let you declare done or push without it filled.

## Tier matrix

| Blast radius | Tier | Required gates |
|---|---|---|
| <5 files, single module, no UI/API/DB change, internal-only | 1 | L1 + smoke test + checklist |
| User-facing OR cross-module OR new/changed API OR new event type OR new public config | 2 | Tier 1 + cross-layer contract check + adversarial review |
| Data migration OR feature-flag cutover OR production deploy OR auth/tenant/secrets/crypto change | 3 | Tier 2 + runbook + rollback test + staging dry-run |

Decide tier when the plan is written. Record in the checklist's Tier field. Do not downgrade mid-flight. When uncertain, go one tier higher — the cost of an extra adversarial review is an hour; the cost of a missed integration gap in production is measured in customer-visible incidents.

## Per-step procedure

### Step 1 — L1 code review (all tiers)

Dispatch the `l1-reviewer` agent against the branch diff (or per-batch diff for large changes). L1's job is correctness, null safety, resource leaks, test quality, and style. Every finding must cite `path/to/file.ext:line`.

Prompt pattern (handled by the agent's system prompt, but useful to know):

> Review this diff for: (1) correctness bugs including off-by-one, null deref, wrong types, wrong operator; (2) resource leaks — unclosed streams, connections, subscriptions; (3) test quality — are the new tests asserting behavior or just calling methods; (4) style/consistency with neighbors. Output Critical / Important / Minor with file:line cites. No narrative — findings only.

Implementer resolves every Critical and Important, records resolution in the checklist. Minor findings may be deferred but must be listed with a reason.

### Step 2 — Smoke test (all tiers) — EVIDENCE REQUIRED

This is the step that would have caught the output-redesign gap. It has a strict definition:

> **Smoke test** = the operator booted the system, performed the exact user-facing action that exercises the change, and observed the user-visible result. Unit tests passing is NOT a smoke test. Compilation succeeding is NOT a smoke test. Reading code is NOT a smoke test.

Checklist evidence required:
- Exact boot command (e.g. `./gradlew :apptor-flow-api:run` plus any prerequisites).
- Exact user action (e.g. "opened designer, added ServiceTask node, set outputMapping `result → orderStatus`, saved, executed flow").
- Expected observable result.
- Actual observed result — pasted log line, API response body, UI screenshot link, or DB row dump. Raw evidence.
- Pass / fail box ticked.

If the change is not user-facing (e.g. a background service refactor), the smoke test is: trigger the service, observe the expected side effect (log line, DB state change, Kafka message), paste the evidence.

`/smoke-test` walks through this interactively and fills the section with real commands and output.

### Step 3 — Cross-layer contract check (Tier 2+)

Dispatch the `cross-layer-auditor` agent. Its grep discipline is:

1. For every field the frontend persists in this change: grep the backend for reads of that field name. Report fields with zero backend readers as orphans.
2. For every new API endpoint added: grep the frontend for the URL path or the generated client call. Report endpoints with zero frontend callers as orphans.
3. For every new event type / Kafka topic / WebSocket frame type: grep for the handler. Report unhandled emissions.
4. For every new DB column: grep the code for reads (SELECT/entity field access). Report write-only columns.
5. For every new config property: grep for the property key in code. Report config that is set but never read.

Orphans are not automatically bugs — some are intentional (fields persisted for audit-only, endpoints for future clients). Each orphan must be either fixed or annotated in the checklist with the intentional-orphan reason.

### Step 4 — Adversarial review (Tier 2+)

Dispatch the `adversarial-reviewer` agent. This has carried the highest signal of any review type in our history. The prompt is hostile by design and lives in the agent file; in short: assume every previous review missed things, try to break the change, look specifically for the integration gaps that per-layer reviewers couldn't see.

Implementer addresses every Blocking finding. Non-blocking findings go to the checklist with disposition (fixed / deferred with reason / won't fix with reason).

### Step 5 — Runbook + rollback (Tier 3 only)

Required content in the checklist:
- Runbook path (a markdown doc committed alongside the change, listing: deploy order, health checks, signals to watch, common failure modes).
- Dry-run evidence — the runbook was executed in staging, paste the relevant log lines or screenshots proving success.
- Rollback command — the exact command to undo this change.
- Rollback verification — the rollback was executed in staging, system returned to the pre-change state, paste the evidence.

An untested rollback is not a rollback; it is a wish.

## Checklist template

The canonical template lives at `templates/review-checklist.md` in this plugin. `/review-init` copies it to `.claude/reviews/<branch>.md` and pre-fills the tier, branch, and blast-radius fields.

## Failure-mode examples — what this catches, what it doesn't

### Catches

- **The output-redesign outputMappings gap.** UI wrote `outputMappings` to the process definition; no backend code read it. Tier 2 cross-layer contract check step 1 grep would have flagged zero backend readers on a newly-persisted field. Adversarial review prompt explicitly requires this check.
- **BPMN parser regression.** A refactor silently broke BPMN import. Smoke test step (import a real BPMN file into the designer) would have failed immediately. Tier 2.
- **Mid-flight feature-flag corruption.** A flag cutover left some tenants with the old code path reading new-schema DB rows. Tier 3 rollback dry-run would have shown the corruption on the staging replica.
- **Write-only DB column.** Migration added a column, entity persisted it, no query ever read it. Cross-layer contract step 4.

### Doesn't catch (known blind spots)

- **Performance regressions not visible in a single smoke run.** Load testing is out of scope.
- **Security vulnerabilities in unchanged code** — the gate is about THIS change, not the whole system. Use a security audit for that.
- **Third-party API contract drift** — if Stripe changes its webhook body and nothing in the diff triggers the change, the gate won't notice.
- **Race conditions that don't reproduce in single-operator smoke tests.**

For those, use dedicated tooling (load tests, security review, chaos testing). The review protocol is necessary, not sufficient.

## Entry points

- `/review-init` — create the checklist for the current branch.
- `/smoke-test` — fill the smoke-test section with real commands and observed output.
- `/review-complete` — verify all required sections populated for the tier, run any missing reviewer agents, mark ready to ship.

The `Stop` hook refuses to let you claim done without the checklist complete. The `PreToolUse(Bash)` hook refuses `git push` and `gh pr create` without it. Both honor `EXPEED_REVIEW_SKIP=1` for emergencies, logged to stderr.
