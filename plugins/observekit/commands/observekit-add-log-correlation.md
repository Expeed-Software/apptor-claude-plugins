---
name: observekit-add-log-correlation
description: Wire the application's logger so every log line includes the active trace_id. Lets ObserveKit's Logs page filter by trace_id and pivot between a span and its logs.
argument-hint: "[logger-library]"
---

# /observekit-add-log-correlation

Load and execute the `observekit:add-log-correlation` skill (defined at `${CLAUDE_PLUGIN_ROOT}/skills/add-log-correlation/SKILL.md`).

Detect the application's logging library before writing anything (Logback / Log4j2 / SLF4J for Java; Pino / Winston / Bunyan for Node; Python `logging` / structlog; Serilog / Microsoft.Extensions.Logging for .NET; Zap / Zerolog / slog for Go; Lograge / Rails.logger for Ruby; Monolog for PHP; `tracing` for Rust). Pick the matching reference under `${CLAUDE_PLUGIN_ROOT}/skills/references/`.

Refuse to add log correlation before `/observekit-setup` has completed. The OTel SDK must already be wired so the active `Span.current()` is populated when log statements run.
