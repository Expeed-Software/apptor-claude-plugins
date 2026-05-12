---
name: observekit-add-span
description: Add a custom OpenTelemetry span around a specific function or code block so it shows up nested inside the auto-generated server span in ObserveKit traces.
argument-hint: "[file-path[:function-name]]"
---

# /observekit-add-span

Load and execute the `observekit:add-custom-span` skill (defined at `${CLAUDE_PLUGIN_ROOT}/skills/add-custom-span/SKILL.md`).

If the user passed a target on the slash-command line, parse it as:
- `<file-path>` → wrap the most likely "business logic" function in that file.
- `<file-path>:<function-name>` → wrap that specific function.

If no target is provided, the skill asks the developer which function or code block to instrument.

Refuse to add a custom span before auto-instrumentation has been verified in ObserveKit. If the dev has not yet run `/observekit-setup` or has not yet confirmed default spans are visible, tell them to do that first.
