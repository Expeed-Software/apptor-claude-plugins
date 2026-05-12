---
name: observekit-force-sample-endpoint
description: Always-sample one or more specific HTTP routes in the app, regardless of the global sampler. Default strategy is invert — keep 100% sampling and exclude everything but the listed paths. Falls back to a rule-based custom Sampler in code only when per-attribute decisions are required.
argument-hint: "[path] [path] ..."
---

# /observekit-force-sample-endpoint

Load and execute the `observekit:force-sample-endpoint` skill (defined at `${CLAUDE_PLUGIN_ROOT}/skills/force-sample-endpoint/SKILL.md`).

If the user passed one or more paths on the slash-command line, those are the target paths. Otherwise the skill asks for them interactively.

Default to Pattern 1 (invert: `OTEL_TRACES_SAMPLER=always_on` plus exclusion list covering every other route the dev does not care about). Switch to Pattern 2 (rule-based Sampler in code) only if the dev says they need per-attribute decisions, like "always sample errors" or "always sample tenant=acme".
