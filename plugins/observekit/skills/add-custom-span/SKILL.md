---
name: add-custom-span
description: This skill should be used when the user asks to "add a custom span", "instrument this function", "add manual span", "wrap this in a span", "trace this code", "add otel span around X", "create a custom span", "manually instrument", or runs the `/observekit-add-span` command. Wraps a specific function or code block in an OpenTelemetry custom span so it appears nested inside the auto-generated server span in ObserveKit traces, with semantic-convention attributes the dev can filter on.
---

# observekit: add-custom-span

Add a custom OpenTelemetry span around a specific function or code block. Use only after `/observekit-setup` has run and the developer has confirmed default spans are visible in ObserveKit. Custom spans on top of broken auto-instrumentation are impossible to debug.

## Hard precondition

Before doing anything else, check programmatically for `.claude/observekit-state.json` in the project root. Do NOT rely on developer self-report — the file must exist.

- If the file does NOT exist: STOP. Tell the developer: "I cannot find evidence that /observekit-setup has been completed and verified in this project. Run /observekit-setup first and confirm data is flowing in ObserveKit. Then come back."
- If the file exists but `verifiedAt` is missing or the `samplingTier` field is missing: STOP with: "The setup state file is incomplete. Re-run /observekit-setup and confirm verification."
- If the file exists and is valid: read `detectedStack`, `serviceName`, and `configFile` — these are the inputs you need for this skill. Custom spans on top of broken auto-instrumentation are impossible to debug; the state file is the gate.

No exceptions. Self-report does not bypass this check.

## Step 1 — Pick the target

Ask the developer which function or code block to wrap. Accept any of:

- A file path plus a function name (`src/services/checkout.ts:processOrder`).
- A file path alone — pick the most likely "business logic" function in that file (skip framework boilerplate, controllers, routers).
- A description ("the pricing calculation in the checkout flow") — Glob/Grep to find candidates and confirm with the developer.

### Deny-list — refuse these targets

If the developer points the skill at any of the following, push back instead of wrapping. A custom span here would be redundant or harmful:

- `main` / `Main` / entry-point functions (process bootstrap, not business logic).
- Class-level setup methods on classes annotated with `@Configuration`, `@SpringBootApplication`, `@Component` (Spring) or `@Module` (NestJS).
- HTTP controller methods that the auto-instrumentation already wraps — the auto server span already exists and a duplicate custom span just adds noise.
- Framework-internal lifecycle methods (`onInit`, `onApplicationStart`, servlet filters, middleware constructors).

When the requested target matches the deny-list, respond with: "`<that function>` is `<reason — boilerplate / already auto-instrumented / lifecycle>`. A custom span here would be redundant. Pick a business-logic function instead." Then re-ask.

**Detection precision.** The deny-list should match on the FUNCTION's effective annotations including meta-annotations and inherited annotations - not just the literal annotation string on the line above. For Kotlin, `@field:Component` and `@get:Configuration` count. For Spring, classes implementing `@Configuration` via `@Inherited` count.

Ask the developer only when at least ONE of these signals is present: (a) the target file lives under a `config/`, `infrastructure/`, `bootstrap/` directory; (b) the target function has any meta-annotation (`@field:Component`, `@get:Configuration`, etc.); (c) the target class has an `@Inherited` annotation in its ancestry; (d) the target is named `main`, `Application`, `init`, `bootstrap`, `configure`. Otherwise just proceed — most targets are unambiguously business logic.

Confirm the choice before editing.

## Step 2 — Pick the span name

Default to a name that follows semantic conventions:

- `<module>.<action>` — example: `pricing.calculate`, `inventory.fetch`, `payment.charge`.
- Verb-noun, lowercase, dot-separated.

Avoid camelCase, function names that include the file path, or anything that includes a request-specific value like a user ID.

If the function naturally implements a known semantic-convention pattern (database call, message publish, RPC), use the conventional namespace (`db.query`, `messaging.publish`, `rpc.client.call`). Read `${CLAUDE_PLUGIN_ROOT}/skills/references/semantic-conventions.md` for the full list.

## Step 3 — Pick attributes

A custom span without attributes is half the value. Suggest 2-4 attributes the dev should set, based on what the function does:

- For a pricing calculation: `cart.items`, `cart.currency`, `cart.total`.
- For a DB call: `db.system`, `db.statement` (sanitized — no user data), `db.rows_affected`.
- For an outbound HTTP: `http.url`, `http.method`, `http.status_code` (set after the call).
- For a queue publish: `messaging.system`, `messaging.destination.name`, `messaging.message.id`.

Use OpenTelemetry semantic-convention attribute names where one applies. They are universally recognized — both ObserveKit and any other OTel backend recognize them and render them with appropriate semantics.

Avoid:
- PII (email addresses, full names, payment details).
- High-cardinality values that explode the trace store (per-request UUIDs as attributes).
- Long strings (more than ~256 chars).

## Step 4 — Read the framework reference

Read `detectedStack` from `.claude/observekit-state.json` (written by setup). Read the matching framework reference under `${CLAUDE_PLUGIN_ROOT}/skills/references/` and find the section titled "Custom span snippet". Each reference has one.

If the framework is not listed, fall back to the language's official OpenTelemetry API documentation. The pattern is the same in every language:

1. Get a tracer for this module/service.
2. Start a span with the chosen name (`tracer.startActiveSpan` / `tracer.spanBuilder` / `Tracer.start_as_current_span`).
3. Set attributes.
4. Run the wrapped code inside the span scope.
5. End the span in a `finally` (so it ends even on exception).
6. Record exceptions via the span's exception API; set status to ERROR on failure.

## Step 5 — Write the change

Edit the target file. Wrap the existing function body — do NOT change its return value, parameters, or external behavior. The span is invisible to callers.

Add the API import only if it is not already present. Do NOT add the SDK — only the API. The SDK already runs (it was wired in `/observekit-setup`).

Idiomatic API imports:

| Language | Import |
|---|---|
| Java | `import io.opentelemetry.api.GlobalOpenTelemetry; import io.opentelemetry.api.trace.*; import io.opentelemetry.context.Scope;` |
| Node / TS | `const { trace, SpanStatusCode } = require('@opentelemetry/api');` |
| Python | `from opentelemetry import trace` |
| .NET / C# | `using System.Diagnostics;` (uses `ActivitySource`) |
| Go | `import "go.opentelemetry.io/otel"` |
| Ruby | `require 'opentelemetry/api'` |
| Rust | `use opentelemetry::trace::Tracer;` and `use opentelemetry::global;` |

## Step 6 — Verify

Tell the developer:

> Run the endpoint that calls this function once. Open ObserveKit, find the trace, click the auto-generated server span — you should see your `<span-name>` span nested inside it. Click the custom span; the Attributes panel on the right shows `<list the attributes you added>`.

Cite the help-doc URL for the trace detail view: `https://observekit.expeed.com/help/traces/intro`.

## Step 7 — Wait, then offer next

If the developer reports they cannot see the custom span:

- The wrapped function may not have been called. Confirm the endpoint actually exercises it.
- The auto-instrumented server span must be the active context when the custom span starts. If the wrapped function runs in a detached thread / Promise / coroutine, span context may have been lost. Read the language's "Context propagation" section in the framework reference.

Once verified, offer:
- "Want to wire structured logs to include this trace_id?" → `observekit:add-log-correlation`.
- "Want to instrument another function the same way?" → re-run this skill.

## Rules

- Read the framework reference before writing.
- Use semantic-convention attribute names where they apply.
- Wrap only one function per invocation. Do not bulk-instrument.
- Never include PII in attributes.
- Never change the wrapped function's signature or return value.
- End the span in a `finally` — span leaks happen when an exception bypasses `span.end()`.
- Record exceptions via the span's exception API; set status to ERROR on failure.
- One question at a time. Never batch questions to the developer — ask, wait for the answer, then ask the next.
- Refuse deny-list targets (main, framework lifecycle, auto-instrumented controllers, `@Configuration`/`@SpringBootApplication`/`@Component`/`@Module` setup methods). A custom span on those is noise.

## Reference files

| Reference | Path |
|---|---|
| Semantic conventions for span names and attributes | `${CLAUDE_PLUGIN_ROOT}/skills/references/semantic-conventions.md` |
| Framework-specific custom span snippet and context propagation | `${CLAUDE_PLUGIN_ROOT}/skills/references/<detectedStack>.md` |
| Setup state file (input) | `.claude/observekit-state.json` |
