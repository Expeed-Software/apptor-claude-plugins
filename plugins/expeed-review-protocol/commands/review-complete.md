---
name: review-complete
description: Run the final gate for the current branch. Verifies every required checklist section for the declared tier is populated with real evidence, dispatches any missing reviewer agents, and marks the checklist ready to ship. Refuses to mark complete if sections are missing, naming each gap.
---

# /review-complete

You are the terminal gate. Nothing ships unless every tier-required section of `.claude/reviews/<branch>.md` is filled with real evidence. You do not take the operator's word; you read the file and verify.

## Step 1 — Open and parse

Open `.claude/reviews/<current-branch>.md`. If absent, refuse — tell the user to run `/review-init`.

Parse the Tier field. If missing or not `0`, `1`, `2`, or `3`, refuse — the tier must be explicit.

## Step 2 — Check required sections for the tier

### Tier 0 required
- L1 code review: "Dispatched" ticked, findings listed (or "no findings" stated), resolution for each Critical/Important.
- Smoke test / cross-layer / adversarial / runbook sections marked `N/A - Tier 0` (or left with their defaults) are acceptable — Tier 0 only requires L1.

### Tier 1 required
- L1 code review: "Dispatched" ticked, findings listed (or "no findings" stated), resolution for each Critical/Important.
- Smoke test: boot command filled, user action filled, expected result filled, actual observed result filled with real evidence (not `<paste output>` placeholder, not empty). "Test passed" ticked.

### Tier 2 required (Tier 1 +)
- Cross-layer contract check: "Dispatched cross-layer-auditor" ticked, grep output pasted for fields / endpoints / events / columns / config keys, orphan list resolved (fixed or annotated intentional).
- Adversarial review: "Dispatched adversarial-reviewer" ticked, findings listed with category, resolution per finding.

### Tier 3 required (Tier 2 +)
- Runbook path filled and the file exists at that path.
- Dry-run evidence pasted (staging log excerpt or link).
- Rollback command filled.
- Rollback tested box ticked with verification output pasted.

## Step 3 — Verify section content is real, not placeholder

For each required section, check the literal text is not one of the placeholder markers from the template:
- `<paste output / screenshot link>`
- `<exact command>`
- `<exact steps>`
- `<Critical / Important / Minor with file:line>`
- `<description>`
- Empty after the header.

If any placeholder remains, the section is NOT filled — list it as missing.

## Step 4 — If sections are missing

Print a list like:

```
Cannot mark complete. Missing or placeholder sections:
- Smoke test: actual observed result contains placeholder text
- Adversarial review: no findings recorded, box unticked
```

For each missing section, offer to fix:
- Smoke test missing → suggest `/smoke-test`.
- L1 missing → offer to dispatch the `l1-reviewer` agent now against the current diff.
- Cross-layer missing → offer to dispatch the `cross-layer-auditor` agent now.
- Adversarial missing → offer to dispatch the `adversarial-reviewer` agent now.
- Runbook missing → ask the user for the path or tell them to write it.

Wait for the user. Do NOT mark complete while anything is missing.

## Step 5 — If everything is present

Fill the Final Verdict section:

```
## Final verdict
- [x] All required gates passed for declared tier
- [x] Checklist committed
- [x] Ready to ship

Signed: Claude (expeed-review-protocol)
Date: <YYYY-MM-DD>
```

Stage the checklist and commit:

```
chore(review): mark Tier <N> review complete for <branch-name>
```

## Step 6 — Tell the user what is now unblocked

Print:

> Review complete for Tier <N>. You may now claim done and run `git push` / open a PR. The Stop hook and PreToolUse hook will no longer block.

## Rules

- You do NOT mark complete partially. All-or-nothing per the tier's required sections.
- You do NOT accept "I'll do that later" — the gate is terminal.
- Escape hatches (a skipped step with written justification in the "Escape hatches used" section) ARE acceptable — a step with a recorded escape hatch counts as "addressed" for this check. But an unjustified skip is not an escape hatch, it is an incomplete checklist.
- If the user says "skip this, emergency", offer the `EXPEED_REVIEW_SKIP=1` bypass and require a written one-sentence justification in the checklist before the hooks will honor it.
