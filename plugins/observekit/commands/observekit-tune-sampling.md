---
name: observekit-tune-sampling
description: Change the traffic-tier preset for an already-integrated app — adjusts sampling rate, endpoint exclusions, and log level. Useful when traffic grows from internal-only to public-facing, or when telemetry cost has to drop.
argument-hint: "[low|medium|high|endpoints-only|custom]"
---

# /observekit-tune-sampling

Load and execute the `observekit:tune-sampling` skill (defined at `${CLAUDE_PLUGIN_ROOT}/skills/tune-sampling/SKILL.md`).

If the user passed a tier on the slash-command line, accept it directly. Otherwise the skill presents the five options and asks the developer to pick.

The skill must modify the same idiomatic config file `/observekit-setup` already wrote — do not introduce a new mechanism. Do not push the developer toward an OTel Collector. Filtering is purely source-side in the SDK.
