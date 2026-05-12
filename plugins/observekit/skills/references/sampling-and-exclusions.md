# Sampling and Exclusions

Cross-language conceptual reference for traffic-tier presets. For the exact framework-specific keys, see the per-framework references in this directory.

## Why `parentbased_traceidratio` (not plain `traceidratio`)

OTel offers two ratio-based samplers:

| Sampler                        | Behavior                                                                                                  |
|--------------------------------|-----------------------------------------------------------------------------------------------------------|
| `traceidratio`                 | Each service independently flips a coin per trace ID. Bad: a trace can be sampled at A and dropped at B. |
| `parentbased_traceidratio`     | Honors the incoming `sampled` flag from the parent span; only flips a coin when starting a fresh trace.   |

**Always use `parentbased_traceidratio`.** It preserves distributed trace continuity across service hops. A 10% sample rate then means "10% of trace roots are sampled, and every service in those traces participates fully," not "every service drops 90% of its spans independently and leaves traces full of holes."

Set via:

```
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1
```

### always_on cannot coexist with a stale sampler arg

Setting `OTEL_TRACES_SAMPLER=always_on` means "sample everything". If `OTEL_TRACES_SAMPLER_ARG` is left in the environment from a previous run, behavior is implementation-defined: some SDKs warn and ignore it, the Java agent treats an empty string value as ratio=0 and silently drops everything. The safe rule: REMOVE `OTEL_TRACES_SAMPLER_ARG` entirely when switching to always_on. Do not just set it to empty.

```
OTEL_TRACES_SAMPLER=always_on
# OTEL_TRACES_SAMPLER_ARG must be UNSET — do not write it, do not set it to empty
```

### Length cap on exclusion lists

The Java agent's `-Dotel.instrumentation.http.server.exclude-paths=...` is a single shell argument. Argv length limits (~32KB on Linux, ~8KB on Windows) silently truncate. Keep the exclusion list under ~50 paths. If you need more, switch to a code-level Sampler/filter in the application rather than the env-var path.

## The five traffic-tier presets

These are the canonical presets the plugin offers when configuring a service. Pick one based on the service's request volume, not its perceived importance — a low-traffic service can keep 100% of spans cheaply.

| Tier | Traffic profile        | `OTEL_TRACES_SAMPLER_ARG` | Default exclusions                                          | Log level threshold |
|------|------------------------|---------------------------|-------------------------------------------------------------|---------------------|
| a    | Low (<10 rps)          | `1.0` (100%)              | `/health`, `/healthz`, `/ready`, `/metrics`                 | INFO                |
| b    | Medium (10–100 rps)    | `0.25` (25%)              | `/health`, `/healthz`, `/ready`, `/metrics`, `/favicon.ico` | INFO                |
| c    | High (>100 rps)        | `0.05` (5%)               | `/health`, `/healthz`, `/ready`, `/metrics`, `/favicon.ico` | WARN                |
| d    | Specific endpoints only| `0.0` baseline + override | Everything except listed endpoints                          | INFO                |
| e    | Custom                 | dev choice                | dev choice                                                  | dev choice          |

Tier (d) is implemented per-instrumentation: set the sampler to drop everything by default, then re-include the specific routes you want via the instrumentation's "capture" allowlist. Each framework spells this differently — see its reference.

## HTTP path exclusion — per-instrumentation, not a standard env var

OpenTelemetry does **not** define a standard env var for "exclude these HTTP paths from instrumentation." It is configured per HTTP instrumentation. Pointer table:

| Stack                  | Where to set it (see framework reference)                       |
|------------------------|-----------------------------------------------------------------|
| Java Spring Boot       | `./java-spring-boot.md` section 8                               |
| Node Express           | `./node-express.md` section 8                                   |
| Node NestJS            | `./node-nestjs.md` section 8                                    |
| Python / Django / Flask| `./python.md` section 8                                         |
| Go (net/http, gin)     | `./go.md` section 8                                             |
| .NET / ASP.NET Core    | `./dotnet.md` section 8                                         |

In every case the configuration lives on the **HTTP server instrumentation**, not on the SDK or exporter. Exclude paths there, not by writing a custom sampler.

## Log level threshold — application logger, not OTel

OTel does not have a log level filter. The OTel log appender exports whatever the application logger emits.

Therefore: **set the level on the application logger**, not on the OTel SDK. If `logback.xml` is at `INFO`, only `INFO+` is exported to ObserveKit. If you switch it to `DEBUG`, all `DEBUG` lines ship — and you pay for them. See [volume-and-cost.md](./volume-and-cost.md).

## Per-instrumentation toggles

Disable noisy integrations entirely via:

```
OTEL_INSTRUMENTATION_<NAME>_ENABLED=false
```

The exact `<NAME>` value is auto-instrumentation–specific. Common candidates to disable:

- Redis `PING` health probes (often disabled wholesale because every connection ping creates a span).
- Internal liveness HTTP clients.
- ORM low-level cache calls.

Toggling an instrumentation off is binary: either you get all its spans or none. For finer control, leave it on and use sampling + exclusions.

## Resource attributes — for navigation, NOT volume

```
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=prod,team=payments
```

These attach to every span/metric/log. They are useful in the ObserveKit UI to filter and group ("show only `team=payments` in `deployment.environment=prod`").

**They do not reduce what is pushed.** Tagging a span with `deployment.environment=prod` doesn't drop anything. It just makes the already-pushed data easier to navigate.

If anyone says "tag it as low-priority to save cost," the answer is no — see the filtering-where table in [volume-and-cost.md](./volume-and-cost.md).

## Why no OpenTelemetry Collector

This plugin follows a **per-app push** model: each application sends OTLP directly to ObserveKit. There is intentionally no Collector in the picture.

Reasoning:
- A Collector adds a hop, an extra process to deploy, an extra config to maintain, and a single point of failure.
- ObserveKit's ingest endpoint is the Collector for our purposes — it accepts raw OTLP.
- Sampling and exclusions in the SDK reduce volume **before** it leaves the process, which is cheaper than reducing it in a Collector.
- The Collector becomes genuinely useful only at very large scale (50+ services with a shared sampling policy or a need for tail-based sampling). Teams at that scale can add one themselves; the plugin does not impose it on smaller deployments.

If a developer asks "should I add a Collector," default to **no**, and only revisit if they have one of: tail-based sampling needs, multi-backend fan-out, or strict egress controls that require a single network egress point.
