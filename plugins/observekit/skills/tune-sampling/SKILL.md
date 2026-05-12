---
name: tune-sampling
description: This skill should be used when the user asks to "tune sampling", "change sampling rate", "reduce telemetry volume", "filter telemetry", "lower observekit cost", "drop noisy traces", "switch traffic tier", "change otel sampler", or runs the `/observekit-tune-sampling` command. Changes the traffic-tier preset (sampling rate, endpoint exclusions, log level) for an already-integrated app. Edits the same idiomatic config file `/observekit-setup` wrote. No OTel Collector.
---

# observekit: tune-sampling

Adjust the traffic-tier preset for an app that has already been integrated with ObserveKit. Edit the same config file `/observekit-setup` already wrote. Do not introduce a new mechanism.

## Hard precondition

Before doing anything else, check programmatically for `.claude/observekit-state.json` in the project root. Do NOT rely on developer self-report — the file must exist.

- If the file does NOT exist: STOP. Tell the developer: "I cannot find evidence that /observekit-setup has been completed and verified in this project. Run /observekit-setup first and confirm data is flowing in ObserveKit. Then come back."
- If the file exists but `verifiedAt` is missing or the `samplingTier` field is missing: STOP with: "The setup state file is incomplete. Re-run /observekit-setup and confirm verification."
- If the file exists and is valid: read `detectedStack`, `serviceName`, `configFile`, and the current `samplingTier`.

Then verify the config file at the path in `configFile` still exists on disk and still contains the OTel block. If state says one thing but the actual file is missing or empty, STOP and tell the developer: "Setup state says config lives at `<path>` but the file is missing or empty. Re-run /observekit-setup before tuning."

No exceptions. Self-report does not bypass this check.

## Step 1 — Read the existing config

Open the file at `configFile` from the state file. Note the current sampler, current exclusions, current log level. Show them to the developer before changing anything.

## Step 2 — Pick the new tier

Present:

> Pick a traffic-tier preset:
> (a) Low — internal tools, less than 10 req/s. 100% sampling, no exclusions, log level INFO.
> (b) Medium — typical web app, 10 to 500 req/s. 25% sampling, exclude /healthz /readyz /metrics, log level INFO.
> (c) High — public API, 500+ req/s. 10% sampling, same exclusions, log level WARN.
> (d) Specific endpoints only — 100% sampling, exclude every route except the ones you list. (Use `/observekit-force-sample-endpoint` for this.)
> (e) Custom — I will pick each value.

If the developer picks (d), invoke `${CLAUDE_PLUGIN_ROOT}/skills/force-sample-endpoint/SKILL.md` instead.

## Step 3 — Compute the new config

| Tier | `OTEL_TRACES_SAMPLER` | `OTEL_TRACES_SAMPLER_ARG` | HTTP exclusions | Log level |
|---|---|---|---|---|
| (a) Low | `always_on` | (unused) | none | INFO |
| (b) Medium | `parentbased_traceidratio` | `0.25` | `/healthz,/readyz,/metrics` | INFO |
| (c) High | `parentbased_traceidratio` | `0.10` | `/healthz,/readyz,/metrics` | WARN |
| (e) Custom | ask | ask | ask | ask |

Always use `parentbased_traceidratio`, never plain `traceidratio`. Parent-based preserves distributed trace continuity across service hops — if the upstream caller decided to sample, this service also samples even if its own ratio would have rejected. Read `${CLAUDE_PLUGIN_ROOT}/skills/references/sampling-and-exclusions.md` for the full rationale and per-framework exclusion config keys.

## Step 4 — Write the change

Edit the same config file `/observekit-setup` wrote. Do not introduce a new file. Do not add a Collector. Do not add code — only config edits.

Per-framework HTTP exclusion knobs (these are not standardized OTel env vars; each instrumentation has its own):

| Framework | Exclusion config |
|---|---|
| Java agent | `-Dotel.instrumentation.http.server.exclude-paths=/healthz,/readyz,/metrics` |
| Spring Boot Starter | `otel.instrumentation.http.server.exclude-paths` property |
| Node (HttpInstrumentation) | `ignoreIncomingRequestHook` in the registration code |
| Python (`opentelemetry-instrument`) | `OTEL_PYTHON_EXCLUDED_URLS=/healthz,/readyz,/metrics` |
| .NET ASP.NET Core | `AddAspNetCoreInstrumentation(o => o.Filter = ctx => !excluded(ctx))` |
| Go (otelhttp) | wrap handler conditionally — exclusions in code |
| Ruby (Rails) | `OpenTelemetry::Instrumentation::Rack` middleware filter |
| PHP (Laravel) | exclude middleware-level paths |
| Rust (axum) | filter middleware in `tower` layer |

Read the project's framework reference for the precise edit.

For the log level, edit the app's logger config (Logback / Log4j / Pino / Python `logging.getLogger().setLevel(...)` / Serilog `MinimumLevel` / etc.).

After the config file edit is saved, update `.claude/observekit-state.json` to set `samplingTier` to the new tier the developer picked (`low` / `medium` / `high` / `custom`). Preserve every other field in the state file. This keeps downstream skills in sync with the actual runtime configuration.

## Step 5 — Restart and verify

Tell the developer:

> Restart the app. Send a burst of traffic — perhaps 100 requests. Then in ObserveKit go to the Traces page and check that the trace count matches the expected rate. For Medium tier (25%), expect ~25 traces from 100 requests. For High (10%), expect ~10.

Note: sampling is per-trace, so a single end-to-end distributed trace still produces one trace row in the UI; the 25% applies to whether the trace gets created at all.

## Step 6 — Document the change

If the project has a deployment runbook or operational doc, suggest updating it to record the current tier. The plugin can append a one-line entry but only if the developer points to the file — never create a new doc.

## Rules

- Edit the existing config file (path comes from `.claude/observekit-state.json` → `configFile`). Do not introduce a new file.
- Use `parentbased_traceidratio` for any sampler other than 100% / 0%.
- HTTP exclusions are per-instrumentation config, not standard OTel env vars — read the framework reference.
- Log level threshold is on the app's logger, not on OTel. (OTel logs export everything the logger emits.)
- Never introduce a Collector. Sampling is in-process.
- Show the before/after diff to the developer before saving.
- After saving, update `samplingTier` in `.claude/observekit-state.json` to match.
- One question at a time. Never batch questions to the developer — ask, wait for the answer, then ask the next.

## Reference files

| Reference | Path |
|---|---|
| Sampling rationale and per-framework exclusion config keys | `${CLAUDE_PLUGIN_ROOT}/skills/references/sampling-and-exclusions.md` |
| Framework-specific config edits | `${CLAUDE_PLUGIN_ROOT}/skills/references/<detectedStack>.md` |
| Setup state file (input and output) | `.claude/observekit-state.json` |
| Force-sample-endpoint skill (tier d redirect) | `${CLAUDE_PLUGIN_ROOT}/skills/force-sample-endpoint/SKILL.md` |
