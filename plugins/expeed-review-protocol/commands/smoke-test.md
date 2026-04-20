---
name: smoke-test
description: Walk through a real smoke test for the current change — boot the system, perform the user action, capture the observed result. Fills the Smoke Test section of .claude/reviews/<branch>.md with evidence, not assertions.
---

# /smoke-test

You are guiding a real smoke test. Unit tests passing is not a smoke test. Compilation succeeding is not a smoke test. The operator must boot the system, perform the user action, and observe the result. Your job is to make that concrete and to capture the evidence.

## Step 1 — Open the checklist

Open `.claude/reviews/<current-branch>.md`. If it does not exist, tell the user to run `/review-init` first and stop.

## Step 2 — Establish the boot command

Check `.claude/expeed-review-protocol.local.md` for `smoke_test_boot_command` in the frontmatter. If present, propose it. If absent, infer from the repo:

- Java/Gradle → `./gradlew :<main-module>:run` or `./gradlew bootRun`.
- Angular frontend → `npm start` or `ng serve`.
- Node service → `npm run dev` or `npm start`.
- Docker-composed stack → `docker compose up -d` plus service command.

Ask the user to confirm or correct the boot command. Also ask for prerequisites (DB running? dependencies installed? env vars set?). Record them.

## Step 3 — Establish the user action

Ask the user, in order:

1. "What is the user-facing action that exercises this change? Describe it as a sequence of clicks / API calls / CLI commands."
2. "What should the user observe if this change is working? (specific UI element, specific API response field, specific log line, specific DB row)"

Be concrete. "The widget should appear" is too vague. "The 'Widgets' list should include a row with name='foo' and status='active'" is acceptable.

## Step 4 — Capture the evidence

Now the interactive part. Tell the user:

> Run the boot command. When the system is up, perform the user action. Then paste back: (a) the log lines or API response showing the action completed, (b) the evidence of the user-visible result (UI screenshot link / log excerpt / DB row dump / API response body). If it failed, paste the failure output and we will stop the smoke test here — the change is not ready.

Wait for their paste. If they say "it worked, I don't have output to paste", refuse — the evidence is the point. Guide them to grab it: browser devtools network tab, backend logs, `psql` query, `curl` response.

## Step 5 — Fill the section

Update the Smoke Test section of the checklist with:

- The exact boot command used (including prerequisites).
- The exact user action (as a numbered list of steps).
- The expected observable result (one sentence).
- The actual observed result (paste the evidence the operator provided — log excerpt, URL to a screenshot in the PR, DB row, API response).
- Tick the "Test passed" box if the evidence shows success; leave it unticked and add a note if the operator reports failure.

## Step 6 — Commit

Stage the checklist and commit:

```
chore(review): smoke test recorded for <branch-name>
```

## Step 7 — Tell the user

Print what is still required for the declared tier (cross-layer contract check and adversarial review for Tier 2+, runbook/rollback for Tier 3) and suggest `/review-complete` when those are done.

## Refusals

- Refuse to fill the section without pasted evidence. "Trust me, it worked" is the exact failure mode the plugin exists to prevent.
- Refuse if the smoke test failed — tell the operator to fix the change first, then re-run `/smoke-test`.
