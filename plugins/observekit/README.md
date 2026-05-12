# observekit — Claude Code Plugin

Integrate [OpenTelemetry](https://opentelemetry.io) with [ObserveKit](https://observekit.expeed.com) (Expeed's on-prem observability platform) into any application. The plugin detects the framework, writes idiomatic SDK configuration, wires the ObserveKit API key safely per environment, and verifies that traces, metrics, and logs are flowing.

The plugin does **not** provision sources or API keys — that is owned by the infra team. The plugin takes a key the infra team gives the developer and integrates it into the app.

## Commands

| Command | What it does |
|---|---|
| `/observekit-setup` | First-time integration. Detects framework, writes config + dependencies + launch flags, verifies data is flowing. |
| `/observekit-add-span` | Add a custom span around a specific function or code block. |
| `/observekit-add-log-correlation` | Wire the app's logger to include `trace_id` so logs filter cleanly in ObserveKit. |
| `/observekit-tune-sampling` | Change the traffic-tier preset (sampling rate, exclusions, log level) post-setup. |
| `/observekit-force-sample-endpoint` | Always-sample one or more specific routes (overrides the global sampler). |
| `/observekit-troubleshoot` | Debug "nothing is showing in ObserveKit" — checks env vars, endpoint reachability, app export logs, common pitfalls. |

## Skills

Every command is backed by a skill of the same purpose. Skills also trigger by description, so the developer can ask for help in natural language (for example, "set up OpenTelemetry for ObserveKit", "add a custom span to my checkout function", "logs do not show up in ObserveKit") and the right skill activates without typing the slash command.

| Skill | Triggers on |
|---|---|
| `observekit:setup` | "set up observekit", "integrate opentelemetry", "add otel to my app", "wire observekit" |
| `observekit:add-custom-span` | "add a custom span", "instrument this function", "manual span", "trace this code" |
| `observekit:add-log-correlation` | "correlate logs with traces", "trace_id in logs", "log correlation" |
| `observekit:tune-sampling` | "change sampling rate", "reduce telemetry volume", "tune observekit", "filter telemetry" |
| `observekit:force-sample-endpoint` | "always trace this endpoint", "force sample", "per-endpoint sampling" |
| `observekit:troubleshoot` | "nothing in observekit", "otel not exporting", "ECONNREFUSED 4317", "spans not visible" |

## Install

```bash
claude plugin marketplace add https://github.com/expeedsoftware/apptor-claude-plugins
claude plugin install observekit
```

## Quick start

1. The infra team gives you an ObserveKit **API key** for a source named after your service.
2. In your project, run `/observekit-setup` in Claude Code.
3. Answer two questions: the API key, and the service name to show in ObserveKit.
4. The plugin detects your framework, writes the right config + dependency + launch flag, and ensures the API key is wired from the right secret store (Kubernetes Secret / Vault / AWS Secrets Manager / Azure Key Vault / GCP Secret Manager / GitHub Actions secret / `dotnet user-secrets` / a gitignored local file for dev).
5. Run your app. The plugin tells you which ObserveKit URL to open and what to look for.
6. Once auto-instrumentation is visible, the plugin offers to add a sample custom span so manual instrumentation shows up alongside.

## What the plugin writes

Two tracks, every time:

- **Checked-in, framework-idiomatic config.** Endpoint, service name, exporter protocol, and sampler — all reference `${OBSERVEKIT_API_KEY}` by name. Never the value. Safe to commit.
- **Per-environment secret wiring.** Plugin prints the exact snippet for your deployment target (K8s Deployment env block with `valueFrom.secretKeyRef`, GitHub Actions repo secrets entry, Vault path, etc.). For local dev only, the plugin writes a gitignored local file (`application-local.yml`, `.env.local`, etc.) and adds it to `.gitignore`.

## What the plugin does NOT do

- **Does not provision sources or API keys** — infra team owns that.
- **Does not run an OTel Collector.** The integration is per-app, direct push to ObserveKit. Same model on Kubernetes, Docker, EC2, bare-metal, on-prem, dev laptop. The plugin is deliberately not adding a Collector layer.
- **Does not filter at the destination.** Filtering happens in the SDK at source — sampling, exclusions, log level, instrumentation toggles. Filtering after data reaches ObserveKit saves nothing; bytes already on the wire, in the DB, in query cost.
- **Does not modify business logic.** Custom spans are added only when the developer asks for them, and only around the function the developer points at.

## Supported frameworks

Java (Spring Boot, Micronaut, Quarkus, plain JDK), Node.js (Express, NestJS, Fastify), Python (Django, Flask, FastAPI), .NET (ASP.NET Core), Go (`net/http`), Ruby (Rails), PHP (Laravel), Rust (Axum). For any framework not listed, the plugin falls back to the OpenTelemetry standard environment variables, which work universally.

## Help docs

The plugin cites canonical ObserveKit help URLs throughout. Cross-check anything against the live docs:

- OpenTelemetry ingestion: https://observekit.expeed.com/help/ingestion/opentelemetry
- Sources: https://observekit.expeed.com/help/sources/intro
- Services: https://observekit.expeed.com/help/services/intro
- Service Map: https://observekit.expeed.com/help/service-map/intro
- Traces: https://observekit.expeed.com/help/traces/intro

## License

Proprietary. Maintained by Expeed Software.
