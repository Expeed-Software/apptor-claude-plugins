---
name: setup
description: This skill should be used when the user asks to "set up observekit", "integrate opentelemetry", "add otel to my app", "wire observekit", "instrument with opentelemetry", "push telemetry to observekit", "send traces to observekit", "configure otlp exporter", "add observability", or runs the `/observekit-setup` command. Performs first-time OpenTelemetry-to-ObserveKit integration for any application — detects framework, writes idiomatic SDK config and dependencies, wires the API key safely per environment, and verifies that traces, metrics, and logs are flowing before offering custom spans.
---

# observekit: setup

Integrate OpenTelemetry with ObserveKit for the current project. Write production-quality config that any developer would be proud to ship. Never write a secret value into a file the developer would commit. Always verify with eyes-on confirmation before offering follow-ups.

## What this skill does in one sentence

Take an ObserveKit API key and a service name from the developer; detect the project's framework; write framework-idiomatic SDK config + dependency + launch flag; tell the developer where the API key should live for their target environment; verify data is flowing in ObserveKit; then offer to add a sample custom span.

## What this skill does NOT do

- Does not provision a source or an API key. The infra team owns that. If the developer does not have a key, tell them to ask infra.
- Does not configure an OTel Collector. The integration is per-app, direct push to ObserveKit. Same model on Kubernetes, Docker, EC2, bare-metal, on-prem, and the dev laptop.
- Does not put real secret values into any committed file. Ever.
- Does not add custom instrumentation code before the developer has confirmed auto-instrumentation works in the UI.

## Step 0 — Detect existing install

Before asking the developer for inputs, scan the project for evidence of a prior ObserveKit setup:

1. Check whether `.claude/observekit-state.json` exists.
2. If yes -> the project was already set up. Skip ahead: ask the developer whether to (a) regenerate / refresh the install, (b) only adjust the sampling tier (redirect to /observekit-tune-sampling), or (c) start over (destructive). Wait for the answer. Do NOT auto-pick.

   **Malformed state file.** If the state file exists but fails to parse as JSON (corrupted by a bad merge, truncated, etc.), treat it as missing and proceed to the config-detection branch in (3) below. Do not crash. Optionally inform the developer: "I found a state file but it is corrupted — falling back to detecting an existing install from your config files."
3. If no (or malformed per above), BUT a Glob across the project finds files referencing `OTEL_EXPORTER_OTLP_ENDPOINT`, `${OBSERVEKIT_API_KEY}`, or `observekit-api.expeed.com` (i.e., signs of a prior install whose state file was deleted/never committed) -> tell the developer: "I can see this project already has an OpenTelemetry-to-ObserveKit install but the state file is missing. I can regenerate the state file from the existing config without changing anything else. Confirm before proceeding."
   - If they confirm: read the existing config and extract the detected stack, the service name (from `OTEL_SERVICE_NAME` value), the config file path, and the current sampler. Then map the existing sampler config to one of the `samplingTier` enum values (`low|medium|high|endpoint-allowlist|custom`) using this table:

     | Existing config | samplingTier |
     |---|---|
     | `always_on` with no exclusions | `low` |
     | `parentbased_traceidratio` arg 0.25 with health-check exclusions | `medium` |
     | `parentbased_traceidratio` arg 0.10 with health-check exclusions and log level WARN | `high` |
     | `always_on` with extensive exclusion list (more than ~5 paths) | `endpoint-allowlist` |
     | Anything else | `custom` |

     Before writing the state file, run the verification plan from Step 6 (the regular setup's verification step). Only write `verifiedAt` once the developer confirms the service is visible in ObserveKit's Services page. If verification fails, treat this as a broken install and fall through to the full setup workflow (Step 1 onwards). Once verified, write a fresh `.claude/observekit-state.json` with the extracted values, the mapped `samplingTier`, and a fresh `verifiedAt` timestamp. Then STOP. Do not proceed to a full setup.
   - If they decline: continue to Step 1 (full setup).
4. If neither: proceed to Step 1 (full setup).

## Step 1 — Collect inputs

Ask the developer for, in order:

1. **The ObserveKit API key** their infra team gave them. Treat it as an opaque token issued by the infra team. Do not echo it back in subsequent messages; refer to it as "the key". Validate the shape with the regex `^ok_[A-Za-z0-9_-]+$`. If the value does not match, ask the developer to re-paste — it is probably truncated or wrapped in quotes.
2. **The service name** to display in ObserveKit. Default to the repository folder name. Confirm. The dev's input becomes the `OTEL_SERVICE_NAME` environment variable / `service.name` resource attribute. If the developer's service-name input ALSO matches `^ok_[A-Za-z0-9_-]+$`, abort with: "That looks like an API key, not a service name. Did you paste it in the wrong field? Re-enter the service name." Do not store it; do not proceed.

Only ask one question at a time. Do not batch.

If either is missing on the command line and the developer cannot provide it, stop and tell them to come back with both.

## Step 2 — Detect the framework

Read manifest files at the repository root in a single Glob pass:

- `pom.xml`, `build.gradle`, `build.gradle.kts` → Java
- `package.json` → Node.js
- `pyproject.toml`, `requirements.txt`, `Pipfile`, `setup.py` → Python
- `*.csproj`, `*.sln`, `Program.cs` → .NET
- `go.mod` → Go
- `Gemfile` → Ruby
- `composer.json` → PHP
- `Cargo.toml` → Rust

For Java, also detect the framework variant by scanning manifest contents:
- `spring-boot-starter` in `pom.xml` or `build.gradle` → Spring Boot
- `io.micronaut` → Micronaut
- `io.quarkus` → Quarkus
- Otherwise → plain Java

For Node, scan `package.json` dependencies:
- `@nestjs/core` → NestJS
- `fastify` → Fastify
- `express` (default) → Express

For Python:
- `django` → Django
- `flask` → Flask
- `fastapi` → FastAPI

Confirm the detected stack with the developer before writing anything: "I see this is a Spring Boot project. Confirm?"

**Polyglot tiebreak.** If two or more manifest files match, do NOT auto-pick. Enumerate EVERY detected stack (not just the first three). Build the option list dynamically — one option per detected manifest. Example for a Java + Node + Python + Go + Rust monorepo, list ALL FIVE:

> I see multiple stacks in this repo. Which service do you want to instrument?
> (a) Java/Spring (pom.xml)
> (b) Node (package.json)
> (c) Python (pyproject.toml)
> (d) Go (go.mod)
> (e) Rust (Cargo.toml)
>
> Treat each as a separate run; re-run this skill once per service you want to instrument.

Only proceed once the developer picks one.

## Step 3 — Read the matching reference

Before writing any code, read the framework-specific reference file under `${CLAUDE_PLUGIN_ROOT}/skills/references/`:

| Detected stack | Reference file |
|---|---|
| Java / Spring Boot | `java-spring-boot.md` |
| Java / Micronaut | `java-micronaut.md` |
| Java / Quarkus | `java-quarkus.md` |
| Java / plain | `java-plain.md` |
| Node / Express | `node-express.md` |
| Node / NestJS | `node-nestjs.md` |
| Node / Fastify | `node-fastify.md` |
| Python / Django | `python-django.md` |
| Python / Flask | `python-flask.md` |
| Python / FastAPI | `python-fastapi.md` |
| .NET / ASP.NET Core | `dotnet-aspnetcore.md` |
| Go / `net/http` | `go-net-http.md` |
| Ruby / Rails | `ruby-rails.md` |
| PHP / Laravel | `php-laravel.md` |
| Rust / Axum | `rust-axum.md` |

If the detected stack is not in the table, STOP. Tell the developer:

> I do not have a framework-specific reference for <detected stack>. Confirm the language and runtime, then I can fall back to OpenTelemetry standard env vars only (no dependency or launch-flag changes — you will need to wire the SDK yourself).

Only proceed on explicit confirmation. Do not silently fall back.

## Step 4 — Ask the developer where the key should live

Ask, with concrete options keyed off the project's deployment artifacts:

> Where should the ObserveKit API key be read from at runtime?
> (a) Kubernetes Secret (I see `k8s/`, `helm/`, or `deployment.yaml` in the repo).
> (b) HashiCorp Vault.
> (c) AWS Secrets Manager.
> (d) Azure Key Vault.
> (e) GCP Secret Manager.
> (f) GitHub Actions secret (for CI/CD only).
> (g) `dotnet user-secrets` (for .NET local dev).
> (h) A gitignored local file (for one-machine local dev only).

If the project has obvious deployment artifacts, default the suggestion to match (a) for Kubernetes manifests, (f) if a `.github/workflows/` directory exists, etc. Always allow the developer to override.

**Secret-target sanity check.** Before accepting the developer's choice, verify the corresponding deployment artifacts actually exist:

- **(a) Kubernetes Secret** — require at least one of `k8s/`, `helm/`, `kustomization.yaml`, or a `*.yaml` file containing `kind: Deployment` to be present in the repo. If none are found, warn: "I do not see Kubernetes manifests in this repo. Where will you paste the K8s snippet? If you do not actually deploy to K8s, pick a different target." Proceed only on explicit confirmation.
- **(f) GitHub Actions secret** — require `.github/workflows/` to exist. If it does not, warn similarly and only proceed on confirmation.
- **(h) Gitignored local file** — confirm explicitly that this is local-dev only. If the developer indicates this is for production use, refuse and ask them to pick a real secret store (a–e).

**Secret-target downgrade warning.** If the state file shows a previous secret target of K8s Secret / Vault / AWS Secrets Manager / Azure Key Vault / GCP Secret Manager, and the new choice is "gitignored local file" (option h), STOP and ask: "You previously had this wired to <previous secret store>. Switching to a local file would unwire the production secret store. Is this intentional?" Proceed only on explicit yes.

For full per-target details, read `${CLAUDE_PLUGIN_ROOT}/skills/references/secret-management.md`.

## Step 5 — Write the two tracks

### Pre-write: idempotent merge (MANDATORY before any file write)

**If the existing config file fails to parse** (broken YAML / malformed JSON / unmatched braces in a properties block):
- STOP. Do NOT attempt a merge or repair.
- Tell the developer: "I found `<configFile>` but it does not parse cleanly. I will not edit a broken file - the merge would compound the corruption. Fix the file (or back it up and remove it), then re-run /observekit-setup."
- Refuse to proceed until the dev confirms the file parses.

**How to detect "fails to parse" per file type** (use these definitions, not a vague "looks broken" check):

- **YAML files** (`application.yml`, `application.yaml`, etc.): use the project's YAML parser — the same one the framework would use at runtime. If the file's framework loader (`spring.config.import`, Micronaut `PropertySourceLoader`, etc.) would reject it, treat as failed-to-parse.
- **JSON files** (`appsettings.json`, `package.json`, etc.): `JSON.parse` (or the equivalent in the executing runtime). If it throws, treat as failed-to-parse.
- **TOML files** (`pyproject.toml`, `Cargo.toml`): the framework's TOML parser. If it throws, treat as failed-to-parse.
- **`pom.xml`**: must be well-formed XML AND have a valid `<project>` root element. Either condition failing counts as failed-to-parse.

Setup is idempotent. Re-running on a configured project replaces the existing block, never duplicates. Before writing any config:

1. **Read the existing target config file** (`application.yml`, `appsettings.json`, `settings.py`, `main.go`, `package.json`, `pom.xml`, etc.).
2. **Detect whether an `otel:` / OpenTelemetry / `OTEL_*` block already exists.**
   - If yes: MERGE — replace the existing block in place. Do NOT append a second copy. Show the developer the diff (before/after) and confirm before saving.
   - If no: insert a fresh block at the framework-idiomatic location.
3. **Dependency check.** Before adding any SDK dependency, read the manifest (`pom.xml`, `package.json`, `requirements.txt`, `*.csproj`, `go.mod`, `Gemfile`, `composer.json`, `Cargo.toml`) and check whether the relevant package is already present (e.g., `opentelemetry-javaagent`, `@opentelemetry/auto-instrumentations-node`, `opentelemetry-distro`, `OpenTelemetry.AutoInstrumentation`, etc.). If present, skip the add — do not duplicate.
4. **`.gitignore` check.** Before appending any line to `.gitignore`, read it and check whether the line is already present. If `.gitignore` does not exist at the repo root, CREATE it before writing any local-secret file. Never write a secret file without a `.gitignore` guarding it.

### Track 1: checked-in, framework-idiomatic config

Write the SDK configuration to the framework's idiomatic config file (NOT a `.env` unless the framework genuinely uses one). The config must reference the API key by name, never by value:

- Spring Boot: append to `application.yml` (use `${OBSERVEKIT_API_KEY}` placeholder syntax).
- Node: write `otel.config.js` or wire env-var reads in code.
- .NET: append to `appsettings.json` for endpoint and service name; the key field reads from `IConfiguration` (which transparently reads user-secrets, env vars, K8s secrets).
- Python: write the config in the framework's standard place (`settings.py` for Django, `app.config` for Flask, `Settings` class for FastAPI).
- Go: read env vars in `main.go` directly; no separate config file needed.
- Ruby: append to `config/application.rb` or an initializer.
- PHP: append to `.env.example` (the framework reads it via `getenv`).
- Rust: read env vars in `main.rs`.

Read the framework reference for the exact location, file format, and key names.

The set of values to write (using the framework's syntax for env-var substitution):

```
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}
OTEL_SERVICE_NAME=<the dev's service name>
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=${DEPLOYMENT_ENV},service.version=${SERVICE_VERSION}
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
OTEL_TRACES_SAMPLER=always_on
```

Default sampler is `always_on` for the initial setup — full visibility while the developer confirms data is flowing. The traffic-tier preset is offered in Step 8, after verification.

Note: do NOT write `OTEL_TRACES_SAMPLER_ARG` at all on always_on. If the key was present in a prior run's config, REMOVE it during the idempotent merge. Some SDKs (Java agent) treat empty string as ratio=0 and silently drop everything.

### Track 2: secret wiring instructions

Print the exact snippet for the secret target the developer chose in Step 4. Do not invent one — read it from the corresponding section in `secret-management.md`. For example, if the developer chose Kubernetes Secret:

```yaml
# In the Deployment env section:
env:
  - name: OBSERVEKIT_API_KEY
    valueFrom:
      secretKeyRef:
        name: app-secrets
        key: observekit-api-key

# To create the Secret:
# kubectl create secret generic app-secrets \
#   --from-literal=observekit-api-key=ok_xxx
```

If the developer chose option (h) — gitignored local file — the plugin writes the file directly (with the actual key value, since the file is not committed) and ensures it is in `.gitignore`. If `.gitignore` does not exist at the repo root, CREATE it first. Then read it; only append the secret-file entry if the line is not already there. Never write the secret file before `.gitignore` is in place.

### Add the SDK dependency

Add the OpenTelemetry SDK dependency / instrumentation package to the framework's manifest. Read the framework reference for the exact artifact coordinates. Examples:

- Spring Boot: nothing in `pom.xml` for the auto-instrumentation path; the `-javaagent` jar is wired into the launch flag.
- Node: add `@opentelemetry/auto-instrumentations-node` and `@opentelemetry/api` to `package.json`.
- Python: add `opentelemetry-distro[otlp]` to `requirements.txt`.

### Add the launch flag

Modify the project's run script (`start`, `dev`, `Procfile`, `Dockerfile`, or wherever the binary actually launches):

- Java: `-javaagent:opentelemetry-javaagent.jar` plus a download step.
- Node: `--require @opentelemetry/auto-instrumentations-node/register` as the prefix of the `node` invocation.
- Python: replace `python app.py` with `opentelemetry-instrument python app.py`.
- .NET: `dotnet add package OpenTelemetry.AutoInstrumentation` plus the profiler env vars.
- Go: no launch flag — Go has no auto-instrumentation; in-code OTel SDK init is the entry point.

### Windows shell parity

If the developer is on Windows + PowerShell, prefer the deployment-target snippet (K8s / Docker / etc.) over shell-export examples — `export FOO=bar` is not valid PowerShell. The plugin's framework references include Windows-equivalent commands (`$env:FOO = "bar"`) where they differ.

## Step 6 — Print a verification plan

Tell the developer:

> Setup written. To verify:
> 1. Start the app the way you normally do.
> 2. Issue one HTTP request that exercises an endpoint.
> 3. Open ObserveKit at https://observekit.expeed.com — go to the Services page.
> 4. You should see a service named `<service-name>` within ~10 seconds.
> 5. Open the trace and look for the auto-generated server span for your request.
>
> Tell me when you see the service appear (or if it does not).

For the full checklist of what to look for, point at `${CLAUDE_PLUGIN_ROOT}/skills/references/verification-checklist.md`.

## Step 7 — Wait for confirmation

Do not proceed to Step 8 until the developer confirms data is visible in ObserveKit. If the developer reports a failure, switch to the `troubleshoot` skill (`${CLAUDE_PLUGIN_ROOT}/skills/troubleshoot/SKILL.md`). Common failures: wrong endpoint, missing `OTEL_EXPORTER_OTLP_HEADERS`, secret not injected by deployment, app not actually restarted.

**Ambiguous responses.** If the developer's response is ambiguous (e.g., "I think I see something", "maybe", "there's a service but I'm not sure"), do NOT proceed. Ask the developer to explicitly confirm the service name they see on the ObserveKit Services page. Only an exact match against the service name from Step 1 proceeds.

### Write the state file

Once the developer has confirmed an exact-match service name on the Services page, write `.claude/observekit-state.json` at the repo root:

```json
{
  "version": 1,
  "detectedStack": "<e.g. java-spring-boot>",
  "serviceName": "<the dev's service name>",
  "configFile": "<e.g. application.yml>",
  "secretTarget": "<e.g. kubernetes-secret>",
  "samplingTier": "low",
  "verifiedAt": "<ISO 8601 timestamp>"
}
```

Before writing, verify `.claude/` is in `.gitignore` (the apptor convention already adds it, but check — if missing, add it). This file is the precondition state marker for downstream skills (`add-custom-span`, `add-log-correlation`, etc.). The initial `samplingTier` is `"low"` because the default sampler at this point is `always_on`; Step 8 updates it.

## Step 8 — Traffic-tier preset

Once auto-instrumentation is confirmed visible, ask:

> Expected traffic profile for this service?
> (a) Low — internal tools, less than 10 req/s. Keep 100% sampling.
> (b) Medium — typical web app, 10 to 500 req/s. 25% sampling, exclude /healthz /readyz /metrics.
> (c) High — public API, 500+ req/s. 10% sampling, same exclusions, raise log level to WARN.
> (d) Specific endpoints only — keep 100% sampling but exclude every route except the ones you list.
> (e) Custom — I will pick each value.

Apply the chosen preset by editing the same config file from Step 5. Use `OTEL_TRACES_SAMPLER=parentbased_traceidratio` (not plain `traceidratio`) so distributed traces stay whole across services. Read `${CLAUDE_PLUGIN_ROOT}/skills/references/sampling-and-exclusions.md` for the exact env-var names per framework — they differ.

After applying the tier, update `.claude/observekit-state.json` so `samplingTier` reflects the developer's choice (`"low"`, `"medium"`, `"high"`, `"endpoint-allowlist"`, or `"custom"`). Leave the other fields unchanged.

## Step 9 — Offer follow-ups

After tier is set, offer (one at a time, do not batch):

- Add a custom span around a function so the developer can see manual instrumentation alongside auto. → `observekit:add-custom-span` skill.
- Wire structured logs to include `trace_id` so the Logs page filters by trace. → `observekit:add-log-correlation` skill.
- Always-sample one specific endpoint regardless of the global sampler. → `observekit:force-sample-endpoint` skill.

Suggest the most likely one for the project's stack (e.g., for a Spring Boot service, log correlation tends to be the next ask).

## Rules

- Read the framework reference file before writing any code. Do not guess artifact coordinates, package names, or env-var names — they differ by framework.
- One question at a time. Never batch.
- Confirm framework detection before writing. Mistakes here cost the developer hours.
- Never write the actual API key value into any file the developer would commit. The only exception is the gitignored local-dev file when the developer explicitly chose option (h).
- Verify the local-dev file is in `.gitignore` before writing it.
- Do not introduce an OTel Collector. The integration is per-app.
- Do not add custom span code before the developer has confirmed auto-instrumentation works.
- Use `parentbased_traceidratio` as the sampler, never plain `traceidratio` — the parent-based variant preserves distributed traces across service hops.
- Cite the matching ObserveKit help URL whenever the developer might want to cross-check (full index at `${CLAUDE_PLUGIN_ROOT}/skills/references/help-doc-index.md`).
- Setup is idempotent. Re-running on a configured project replaces the existing block, never duplicates. This applies to config blocks, manifest dependencies, and `.gitignore` entries.
- Write `.claude/observekit-state.json` after the developer confirms verified data flow. Downstream skills read this file as the precondition signal — without it, they refuse to run.
- Validate the API key shape (`^ok_[A-Za-z0-9_-]+$`) at intake. Refuse if the service-name slot looks like a key — abort and re-ask.
- Refuse Step 4 option (h) — gitignored local file — for any context the developer indicates is production. Local-dev only.

## Reference files

| File | When to read |
|---|---|
| `${CLAUDE_PLUGIN_ROOT}/skills/references/<framework>.md` | Always, before writing any code, for the detected framework. The Step 0 state-file recovery path also reads existing config from these locations to reconstruct `.claude/observekit-state.json` without a full re-setup. |
| `${CLAUDE_PLUGIN_ROOT}/skills/references/endpoints-and-auth.md` | For the canonical endpoint table and auth-header rules. |
| `${CLAUDE_PLUGIN_ROOT}/skills/references/secret-management.md` | For the per-target secret-wiring snippets. |
| `${CLAUDE_PLUGIN_ROOT}/skills/references/sampling-and-exclusions.md` | For traffic-tier preset env-var values per framework. |
| `${CLAUDE_PLUGIN_ROOT}/skills/references/semantic-conventions.md` | If the developer asks about attribute names. |
| `${CLAUDE_PLUGIN_ROOT}/skills/references/verification-checklist.md` | For what to look for in the UI during Step 6. |
| `${CLAUDE_PLUGIN_ROOT}/skills/references/volume-and-cost.md` | If the developer asks "what does this cost" or "what is being pushed". |
| `${CLAUDE_PLUGIN_ROOT}/skills/references/help-doc-index.md` | For canonical ObserveKit help URLs to cite. |
