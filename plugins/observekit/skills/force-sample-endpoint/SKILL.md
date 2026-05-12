---
name: force-sample-endpoint
description: This skill should be used when the user asks to "always trace this endpoint", "force sample this route", "per-endpoint sampling", "always sample /checkout", "trace specific paths always", "100% sampling for one endpoint", "important endpoints should be sampled fully", or runs the `/observekit-force-sample-endpoint` command. Configures the SDK to always-sample one or more specific HTTP routes regardless of the global sampler. Default strategy is to invert — keep 100% sampling and exclude everything else; only falls back to a rule-based Sampler in code when per-attribute decisions (always sample errors, always sample tenant=acme) are required.
---

# observekit: force-sample-endpoint

Force OpenTelemetry to always trace specific HTTP routes, regardless of the global sampling rate. Two strategies — pick the right one for the developer's actual need.

## Hard precondition

Before doing anything else, check programmatically for `.claude/observekit-state.json` in the project root. Do NOT rely on developer self-report — the file must exist.

- If the file does NOT exist: STOP. Tell the developer: "I cannot find evidence that /observekit-setup has been completed and verified in this project. Run /observekit-setup first and confirm data is flowing in ObserveKit. Then come back."
- If the file exists but `verifiedAt` is missing or the `samplingTier` field is missing: STOP with: "The setup state file is incomplete. Re-run /observekit-setup and confirm verification."
- If the file exists and is valid: read `detectedStack`, `serviceName`, and `configFile` — these are the inputs you need.

No exceptions. Self-report does not bypass this check.

## The honest constraint

Head-based sampling (which is what the OTel env-var samplers do) decides whether to sample a trace **before the SDK knows what URL path the request will hit**. So there is no env-var-only way to say "always sample `/checkout`, sample others at 10%".

Two practical patterns get around this. Pick the right one based on what the developer actually needs.

## Pattern 1 — Invert (default, recommended)

If the goal is "always trace `/checkout`, do not bother tracing health checks and other noise", just keep 100% sampling at the SDK and aggressively exclude every uninteresting path.

Configuration:

```
OTEL_TRACES_SAMPLER=always_on
```

Plus HTTP instrumentation exclusions covering everything other than the target paths. Example for a Spring Boot app where `/checkout` and `/api/orders/*` are the routes that matter:

```
-Dotel.instrumentation.http.server.exclude-paths=/healthz,/readyz,/metrics,/favicon.ico,/static/*,/admin,/admin/*
```

The dev's important endpoints are traced 100%. The configured exclusions are dropped before they ever produce spans.

### When Pattern 1 fits

- The dev can enumerate the noisy paths.
- The dev cares about volume but not per-request decisions.
- The total request rate for the un-excluded paths is manageable (say, under 100 req/s).

### When Pattern 1 does NOT fit

- The dev wants to sample 10% of `/api/orders/*` but 100% of failed `/api/orders/*` (per-attribute decision based on outcome).
- The dev wants to sample all requests for premium tenants but only 10% for free-tier.
- Targeted endpoints alone produce hundreds of req/s and the dev cannot afford 100% of even those.

In these cases, switch to Pattern 2.

## Pattern 2 — Rule-based Sampler in code

Write a custom `Sampler` that:
- Always returns `RECORD_AND_SAMPLED` for spans matching specified rules (attribute equality, regex match on `http.route`, `http.status_code >= 500`).
- Delegates to a default `TraceIdRatioBased` sampler for everything else.

This requires code, not just config. The plugin writes the `Sampler` class and the registration glue.

Read `${CLAUDE_PLUGIN_ROOT}/skills/references/<framework>.md` for the framework's idiomatic way to register a custom `Sampler`:

- Java agent: do NOT try to wire this via `OTEL_TRACES_SAMPLER` — the env-var samplers (`always_on`, `parentbased_traceidratio`, `jaeger_remote`, etc.) are a fixed list and do not accept a custom class name. Instead, package a `SamplerProvider` SPI implementation and register it through the agent's `AutoConfigurationCustomizerProvider` mechanism (a `META-INF/services` entry plus a small extension JAR loaded via `-Dotel.javaagent.extensions=...`). The framework reference has the full boilerplate.
- Spring Boot Starter / programmatic: `SdkTracerProvider.builder().setSampler(customSampler)`.
- Node: `new NodeSDK({ sampler: new CustomSampler(...) })` at SDK init.
- Python: `tracerProvider.add_span_processor` is wrong — set the sampler on `TracerProvider` construction: `TracerProvider(sampler=CustomSampler(...))`.
- .NET: `AddSampler<CustomSampler>()` on the OpenTelemetry builder.
- Go: `sdktrace.WithSampler(customSampler)` on `NewTracerProvider`.

## Step 1 — Ask the developer what they actually want

Present:

> Two ways to always-sample specific endpoints. Which fits your need?
> (1) "I have a list of paths I want traced fully; everything else can be excluded." → invert strategy, config only.
> (2) "I want to sample based on request *outcome* — like always trace failures, or always trace specific tenants." → custom Sampler in code.

If the answer is (1), proceed with Pattern 1. If (2), proceed with Pattern 2.

## Step 2 — Pattern 1 implementation

Collect:
- The list of paths the developer wants traced fully.
- The list of paths the developer wants excluded — start with the standard noise (`/healthz`, `/readyz`, `/metrics`, `/favicon.ico`, `/static/*`) and ask if there are others.

### Hard cap: 50 paths max in the exclusion list

Many frameworks deliver the exclusion list as a single comma-separated `-D...` JVM flag, env var, or CLI argument. Argv length limits (and YAML/properties readability) silently truncate or corrupt very long values. If the developer's exclusion list exceeds 50 paths, STOP and tell them:

> Your exclusion list has more than 50 paths. Stuffing them into a comma-separated config string risks silent truncation by the OS argv limit. Switch to Pattern 2 (rule-based Sampler in code) — it expresses the same intent as code without an argv-length ceiling. Want to switch?

Do not silently proceed with a 200-path string.

Write:
- `OTEL_TRACES_SAMPLER=always_on` (overrides any prior sampler config).
- The framework-specific exclusion list. Read the framework reference for the exact key name.

Confirm the diff with the developer before saving.

## Step 3 — Pattern 2 implementation

Collect:
- The decision rule. Be specific: "always sample if `http.status_code >= 500`", "always sample if `app.tenant_id` attribute equals one of [list]".
- The default sampling rate for non-matching traces.

Write:
- A `RuleBasedSampler.<ext>` source file in a sensible package.
- The registration glue that wires it into the SDK (per-framework — read the reference).

The `Sampler` implementation:
- Examines the span's `attributes` map.
- Returns `SamplingResult` with decision `RECORD_AND_SAMPLED` if a rule matches.
- Otherwise delegates to `Sampler.traceIdRatioBased(ratio)`.

The framework reference has the boilerplate in idiomatic form.

## Step 4 — Verify

Tell the developer:

> Restart the app. Issue requests:
> - Pattern 1: hit each of your force-sampled paths and confirm they appear in ObserveKit. Hit one of the excluded paths and confirm it does NOT.
> - Pattern 2: trigger a request matching your rule (e.g., force a 500) and confirm it appears. Then issue many "normal" requests and check that only the configured fraction shows up.

## Rules

- Default to Pattern 1. Pattern 2 is only when Pattern 1 cannot express what the dev needs.
- For Pattern 1, do not write code — only config.
- For Pattern 1, cap the exclusion list at 50 paths. Above that, route to Pattern 2 — argv length limits silently truncate long `-D...` flags.
- For Pattern 2, write the smallest possible custom `Sampler`. Do not bring in unnecessary dependencies.
- Never invert without asking — Pattern 1 is destructive to traces of un-listed paths. Confirm explicitly.
- Do not introduce a Collector for tail-based sampling. Per-app philosophy.
- One question at a time. Never batch questions to the developer — ask, wait for the answer, then ask the next.

## Reference files

| Reference | Path |
|---|---|
| Sampling rationale and per-framework exclusion config keys | `${CLAUDE_PLUGIN_ROOT}/skills/references/sampling-and-exclusions.md` |
| Framework-specific `Sampler` registration and exclusion keys | `${CLAUDE_PLUGIN_ROOT}/skills/references/<detectedStack>.md` |
| Setup state file (input) | `.claude/observekit-state.json` |
