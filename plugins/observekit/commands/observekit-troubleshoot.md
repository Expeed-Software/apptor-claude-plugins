---
name: observekit-troubleshoot
description: Diagnose "nothing is showing in ObserveKit" or "the OTel exporter is failing". Inspects environment variables, endpoint reachability, app export logs, and the most common pitfalls (wrong endpoint, missing service name, 10 MB body cap, rate limit, gitignored secret file not loaded, source vs service-name confusion).
---

# /observekit-troubleshoot

Load and execute the `observekit:troubleshoot` skill (defined at `${CLAUDE_PLUGIN_ROOT}/skills/troubleshoot/SKILL.md`).

Work systematically through the checklist in the skill. Read the app's actual export log output (do not guess). Check exact environment variable names — the OTel spec is case-sensitive. Cite the matching ObserveKit help URL whenever a fix is recommended so the developer can verify against canonical docs.
