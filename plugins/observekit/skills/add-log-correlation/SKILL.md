---
name: add-log-correlation
description: This skill should be used when the user asks to "correlate logs with traces", "add trace_id to logs", "log correlation", "wire logs to traces", "include trace_id in log output", "OTel log appender", "log MDC trace_id", or runs the `/observekit-add-log-correlation` command. Wires the application's logger so every log line includes the active trace_id (and optionally span_id). Lets ObserveKit's Logs page filter by trace_id and pivot from a span to its log lines.
---

# observekit: add-log-correlation

Wire the application's logger so every log line carries the active `trace_id`. After this, ObserveKit's Logs page can filter by `trace_id` to show every log line emitted during a specific request, even across services.

## Hard precondition

Before doing anything else, check programmatically for `.claude/observekit-state.json` in the project root. Do NOT rely on developer self-report — the file must exist.

- If the file does NOT exist: STOP. Tell the developer: "I cannot find evidence that /observekit-setup has been completed and verified in this project. Run /observekit-setup first and confirm data is flowing in ObserveKit. Then come back."
- If the file exists but `verifiedAt` is missing or the `samplingTier` field is missing: STOP with: "The setup state file is incomplete. Re-run /observekit-setup and confirm verification."
- If the file exists and is valid: read `detectedStack`, `serviceName`, and `configFile` — these are the inputs you need. After confirmation, use `detectedStack` to pick the matching framework reference. `trace_id` is meaningless without the SDK loaded; the state file is the gate that proves it is.

No exceptions. Self-report does not bypass this check.

## Step 1 — Detect the logging library

Scan the project to identify which logger is in use. Order of preference:

| Stack | Likely loggers (in order to check) |
|---|---|
| Java | Logback (most common), Log4j2, `java.util.logging` |
| Node | Pino, Winston, Bunyan, `console.*` |
| Python | `logging` (stdlib), structlog, loguru |
| .NET | `Microsoft.Extensions.Logging`, Serilog, NLog |
| Go | `slog` (Go 1.21+), Zap, Zerolog, Logrus |
| Ruby | `Rails.logger`, Lograge, Semantic Logger |
| PHP | Monolog (Laravel default), error_log |
| Rust | `tracing`, `log` |

Read configuration files first (`logback-spring.xml`, `log4j2.xml`, `pino.config.js`, `appsettings.json` Serilog section, `config/environments/*.rb`). Confirm with the developer if multiple loggers are present.

## Step 2 — Pick the wiring strategy

Two strategies, in priority order:

### Strategy A: OTel log appender / handler (preferred)

OpenTelemetry ships an appender for every major language that:
- Bridges log statements through the OTel SDK as `LogRecord`s.
- Automatically attaches the active `trace_id` / `span_id` to every record.
- Also ships those records as OTLP log signals to ObserveKit (the Logs page in the UI shows them with the same `trace_id` as the originating span).

Use this where it exists:

| Stack | Appender / handler |
|---|---|
| Java + Logback | `io.opentelemetry.instrumentation:opentelemetry-logback-appender-1.0` |
| Java + Log4j2 | `io.opentelemetry.instrumentation:opentelemetry-log4j-appender-2.17` |
| Node | `@opentelemetry/instrumentation-pino`, `-winston`, `-bunyan` (auto-instrumentations-node includes these) |
| Python | `LoggingInstrumentor` (`opentelemetry-instrumentation-logging`) |
| .NET | `OpenTelemetry.Logs` extension on `ILoggerProvider` |
| Go | `otelslog` for Go 1.21+ `slog`, or manual span-aware logger wrappers |
| Ruby | `OpenTelemetry::Instrumentation::Logger` |
| PHP | Monolog OTel handler from `open-telemetry/opentelemetry-logger-monolog` |
| Rust | `tracing-opentelemetry` |

### Strategy B: Just inject trace_id into the log pattern (fallback)

If Strategy A is unavailable or the dev does not want a new log shipper, just add `trace_id` to the existing logger's output format. Application logs continue going wherever they already go (stdout, a file, an agent); ObserveKit-side trace filtering still works because the agent or developer can parse `trace_id` from the structured log.

Example (Logback pattern):

```xml
<pattern>%d{ISO8601} [%X{trace_id}/%X{span_id}] %-5level %logger - %msg%n</pattern>
```

OpenTelemetry's MDC instrumentation populates `%X{trace_id}` and `%X{span_id}` automatically when the SDK is loaded.

Recommend Strategy A unless the developer pushes back. Strategy A gives end-to-end correlation in the ObserveKit Logs page; Strategy B only correlates if the logs reach ObserveKit through another path.

## Step 3 — Read the framework reference

For exact dependency coordinates, config file edits, and pattern strings, read the framework reference under `${CLAUDE_PLUGIN_ROOT}/skills/references/`. Each reference has a section titled "Log correlation snippet" with both strategies' code.

## Step 4 — Write the change

Make the smallest possible edit:

- Add the appender / handler dependency to the manifest.
- Register it once during application startup (or via the framework's auto-config mechanism, which usually picks it up by classpath alone).
- For Strategy B: just edit the log pattern string.

Do NOT replace the developer's existing logger. The OTel appender is additive — it bridges through, the original sink keeps working.

## Step 5 — Verify

Tell the developer:

> Restart the app. Hit one endpoint. Then in ObserveKit go to the Traces page, open the trace, copy the trace ID from the URL or detail panel. Then go to the Logs page and paste the trace ID into the filter — you should see every log line emitted during that request, including any from downstream services that share the same trace.

Help-doc URL: `https://observekit.expeed.com/help/logs/intro`.

## Rules

- Detect the logging library before writing. Do not assume.
- Strategy A is preferred; only fall back to B if A is unavailable or the dev says no.
- Never replace the existing logger — only bridge or extend its pattern.
- Do not change log levels. The developer's level threshold stays.
- `trace_id` is meaningless without the SDK loaded. The `.claude/observekit-state.json` gate proves it is.
- One question at a time. Never batch questions to the developer — ask, wait for the answer, then ask the next.

## Reference files

| Reference | Path |
|---|---|
| Framework-specific log correlation snippet (both strategies) | `${CLAUDE_PLUGIN_ROOT}/skills/references/<detectedStack>.md` |
| Setup state file (input) | `.claude/observekit-state.json` |
