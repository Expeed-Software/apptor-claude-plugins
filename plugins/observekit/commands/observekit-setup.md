---
name: observekit-setup
description: First-time OpenTelemetry-to-ObserveKit integration for the current project. Detects the framework, writes idiomatic SDK config and dependencies, wires the API key safely per environment, and verifies that traces, metrics, and logs are flowing.
argument-hint: "[api-key] [service-name]"
---

# /observekit-setup

Load and execute the `observekit:setup` skill (defined at `${CLAUDE_PLUGIN_ROOT}/skills/setup/SKILL.md`).

If the user passed arguments on the slash-command line, parse them as:
- First positional argument → the ObserveKit API key the infra team gave them.
- Second positional argument → the service name to appear in ObserveKit (defaults to the repository folder name).

If either is missing, the skill asks for it interactively. Do not block on arguments — let the skill drive the conversation.

Follow the skill exactly. Do not invent a different workflow. Do not skip the verification step before offering custom spans. Do not write the API key value into any file the dev would commit.
