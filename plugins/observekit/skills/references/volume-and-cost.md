# Volume and Cost

Conceptual reference for "what does my service actually push, and what does it cost?"

## Default volume

OpenTelemetry auto-instrumentation is **noisy on purpose**. Without sampling or exclusions, a typical service pushes:

- **One span per HTTP request** the service handles (server side).
- **One span per outbound HTTP call** the service makes (client side).
- **One span per DB query** through any instrumented driver.
- **One span per message** sent or received through an instrumented broker.
- **Runtime metrics every 60 seconds** — CPU, memory, GC, thread counts, event-loop lag, etc.
- **Application logs**, if the log appender is wired — every line at or above the configured log level.

A service handling 100 rps with one DB call per request and one outbound HTTP per request will push **~300 spans/sec** by default. Multiply by 86,400 sec/day. That's ~26M spans/day from one service before anyone has done anything special.

This is fine for low-traffic services. For higher traffic, you need to reduce volume at the source. There are exactly four useful levers, plus one anti-pattern (filtering in the UI) that does not save anything that matters.

## Cost lever 1: sampling

The only knob that meaningfully reduces span volume.

Sampling drops complete traces — so a 10% sample (`OTEL_TRACES_SAMPLER_ARG=0.1`) pushes 10% of traces in full, and the other 90% are never exported at all. Metrics and logs are unaffected.

Pointer: [sampling-and-exclusions.md](./sampling-and-exclusions.md).

## Cost lever 2: exclusions

Drop noisy endpoints at the instrumentation layer — typically health checks, readiness probes, the metrics scrape endpoint, and `/favicon.ico`. These produce thousands of useless spans per day per service.

Exclusions are per-instrumentation config; see the framework reference for the exact key. Pointer: [sampling-and-exclusions.md](./sampling-and-exclusions.md).

## Cost lever 3: log level

Logs shipped through OTel cost the same as any other log line — `DEBUG` is not cheaper than `INFO`. A chatty `DEBUG` logger can easily ship more bytes than the entire trace pipeline.

**Most teams keep `INFO+` in prod.** Drop to `DEBUG` only in non-production environments, or temporarily under a feature flag for one service for a fixed window when debugging.

Set the level on the application's logger (Logback, log4j, Serilog, Python `logging`, Pino, Winston, etc.). OTel will export whatever the logger emits.

## Cost lever 4: per-instrumentation toggles

Disable integrations the team does not care about:

```
OTEL_INSTRUMENTATION_<NAME>_ENABLED=false
```

Examples worth disabling when noisy:
- Redis `PING` health probes from a connection pool that pings every second.
- An internal liveness HTTP client that hits 10 endpoints every 5 seconds.
- A caching layer that creates a span per cache lookup.

A single chatty integration can dominate total volume. Disable wholesale or, if you still want some signal, leave it on and sample harder.

## Why source-side filtering is the only filtering that matters

| Where you filter            | Saves egress | Saves ObserveKit CPU | Saves DB storage | Saves query cost |
|-----------------------------|:------------:|:--------------------:|:----------------:|:----------------:|
| In the SDK (sampling, excl.)| **yes**      | **yes**              | **yes**          | **yes**          |
| In ObserveKit ingest        | no           | no                   | **yes**          | **yes**          |
| In the UI / query           | no           | no                   | no               | no (cosmetic)    |

The point of this table: by the time data has left your process, **you have already paid the egress and ingest cost**. Filtering in the UI hides rows but saves nothing — the data is still indexed, still stored, still counts.

When a developer asks **"why can't I just filter `/health` in the UI?"**, this table is the answer. The data is already paid for. The only filtering that saves money is in the SDK.

## Why no Collector

A per-app push model is appropriate at the scale this plugin targets. Each app exports directly to ObserveKit. There is no Collector in the middle.

A Collector becomes genuinely useful at very large scale — roughly:

- **50+ services** all needing a uniform sampling policy that must be changed in one place, or
- **tail-based sampling** (sample by error status, by latency, by attribute) — which requires buffering whole traces before deciding, which an SDK cannot do, or
- **multi-backend fan-out** (sending to ObserveKit + a second backend simultaneously).

At that scale the team can add a Collector themselves. The plugin does not install one and does not recommend one, because for the 1-to-dozens-of-services case it is over-engineering: an extra hop, an extra process to maintain, an extra single point of failure, and zero benefit over direct push.
