---
name: troubleshoot
description: This skill should be used when the user reports "nothing in observekit", "otel not exporting", "spans not visible", "service not appearing", "ECONNREFUSED", "401 unauthorized from observekit", "OTLP export failed", "no traces in ui", "metrics not showing", or runs the `/observekit-troubleshoot` command. Diagnoses why OpenTelemetry-to-ObserveKit data is missing — checks env vars, endpoint reachability, app export logs, common pitfalls (wrong endpoint, missing service name, 10 MB body cap, rate limit, secret not injected, source vs service-name confusion).
---

# observekit: troubleshoot

Diagnose why OpenTelemetry data is not appearing in ObserveKit. Work systematically. Read the app's actual export log output — do not guess.

## Step 0 — Gather the symptom

Before diagnosing, ask the developer what they actually see:

- Is the service missing entirely from ObserveKit's Services page?
- Is the service there but no traces appear?
- Are traces there but a specific span / attribute / log line is missing?
- Did the app log an explicit OTel export error?
- Did the dev change anything recently (env, deployment, code)?

If the developer cannot describe a concrete symptom, ask: "What would you expect to see that you do not? If everything looks fine, you probably do not need this skill." Do not run the full diagnostic if there is no observed problem.

## Diagnostic order

Work through these in order. Stop at the first problem you find; fix it; ask the dev to retry; only continue if it does not solve the issue.

### 1. Is the OTel SDK actually loaded?

Confirm the app's launch script includes the right flag / entry:

| Stack | Required at launch |
|---|---|
| Java | `-javaagent:opentelemetry-javaagent.jar` (or Spring Boot Starter on the classpath) |
| Node | `--require @opentelemetry/auto-instrumentations-node/register` |
| Python | `opentelemetry-instrument python app.py` |
| .NET | `OpenTelemetry.AutoInstrumentation` profiler env vars or `AddOpenTelemetry()` in `Program.cs` |
| Go | OTel SDK init code in `main` |

Check the launch script. If missing, this is the root cause — the SDK is not loading. Fix by re-running `/observekit-setup` for the project.

Symptom: app produces zero OTel-related log lines at startup.

### 2. Are the four required env vars set?

The OTel SDK reads its config from environment. The four that matter:

| Variable | Required value |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `https://observekit-api.expeed.com` |
| `OTEL_EXPORTER_OTLP_HEADERS` | `X-API-Key=<the key>` (the key is an opaque token — do not assume any specific prefix or format) |
| `OTEL_SERVICE_NAME` | Something descriptive |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` (or `grpc` if using port 4317) |

Ask the developer to run, depending on shell:

```
# Linux / macOS
printenv | grep OTEL

# PowerShell
Get-ChildItem env: | Where-Object Name -like 'OTEL*'

# Inside a running container
docker exec <container> env | grep OTEL
```

Check the output:
- All four present? If not — the secret is not injected (Kubernetes Secret not mounted, GitHub Actions secret not exposed, `.env.local` not loaded by the framework). Re-check the secret wiring from `/observekit-setup`.
- `OTEL_SERVICE_NAME` empty? OTel falls back to `unknown_service`. The Services page will show that as the name; the dev's expected service name will not appear at all.

### 3. Look at the app's export log

The OTel SDK logs export failures. Tail the app's stdout/stderr and grep for keywords:

```
grep -iE "otel|opentelemetry|export|otlp" <app-log>
```

Common error patterns and meanings:

| Log signature | Meaning | Fix |
|---|---|---|
| `ECONNREFUSED`, `Connection refused`, `Failed to connect to localhost` | App is exporting to localhost — the dev set wrong endpoint, or kept dev `http://localhost:8080`. | Set `OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com`. |
| `401 Unauthorized` or `HTTP 401` | API key wrong or missing from header. | Verify the header. The **header key** matters — both forms below are valid. Compare the value against what is in your secret store; treat the key as an opaque token (do not assume a specific prefix). Correct forms: `OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=<key>` OR `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <key>`. Wrong form: `OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=Bearer <key>` (the literal word `Bearer` ends up as part of the X-API-Key value and gets rejected). |
| `400 Bad Request` with body around 10 MB | Hit the body cap. | Reduce batch size: `OTEL_BSP_MAX_EXPORT_BATCH_SIZE=256` (default is 512). |
| `429 Too Many Requests` | Rate limited on `/v1/*`. | Increase batch interval or reduce export volume via sampling. |
| `Unknown OTLP exporter target` or `unsupported protocol` | `OTEL_EXPORTER_OTLP_PROTOCOL` mismatch (e.g., set to `grpc` but pushing to HTTP port). | Set protocol to match the endpoint: `http/protobuf` for the public HTTPS URL. |
| `Hostname verification failed` / `SSL` errors | Endpoint URL has wrong host. | Verify the host is exactly `observekit-api.expeed.com` — no typos. |
| No OTel log output at all | SDK is not loaded (see step 1). | Re-check launch flag. |

### 4. Is the app actually emitting requests?

Spans require activity. Tell the developer to issue a request that exercises an instrumented code path:

```
curl -v <app-url>/<some-endpoint>
```

Then watch the app log for either:
- A "exporting N spans" log line (good).
- No new OTel output (the request is not being traced — likely auto-instrumentation does not cover this path, or the path is excluded by config).

### 5. Service vs source mismatch

In ObserveKit:
- **Source** = the API key boundary (RBAC, ingest scope). Provisioned by infra.
- **Service** = `service.name` resource attribute set by the SDK from `OTEL_SERVICE_NAME`.

A common confusion: the dev expects to find their data filtered by source name, but the Services page filters by `service.name`. If they look in the wrong source's view, or the wrong service's view, they will see nothing.

Verify:
1. Source switcher (top of UI) shows the source the API key belongs to. Ask infra if unsure which source name maps to which key.
2. Services page lists `<OTEL_SERVICE_NAME>`. If it shows `unknown_service` instead, the env var was not set.

If `.claude/observekit-state.json` exists in the project, read it — the `serviceName` field tells you what to look for on the Services page. If the value in the UI does not match that, that is your mismatch.

### 6. Has enough time elapsed?

SDKs batch exports. Default batch interval is roughly 5 seconds. If the dev issued one request and immediately checked ObserveKit, data may not have shipped yet. Wait 30 seconds.

Also: ObserveKit's Services page may take a few seconds to render the new service the first time it sees data.

### 7. Did the secret get injected?

For deployments using a Kubernetes Secret, AWS Secrets Manager, etc., the secret needs to actually flow into the process. Inside the pod / container:

```
echo "$OTEL_EXPORTER_OTLP_HEADERS"
```

If the value is empty or has unsubstituted `${OBSERVEKIT_API_KEY}`, the secret is not wired. Re-check the Deployment env block or the secret reference.

### 8. Sampler vs sampler-arg collision

If `OTEL_TRACES_SAMPLER=always_on` is set but `OTEL_TRACES_SAMPLER_ARG` is also set (from a prior run), some SDKs warn-and-ignore, some apply the arg silently. Inspect both:

- PowerShell: `Get-ChildItem env: | Where-Object Name -like 'OTEL_TRACES*'`
- Linux/macOS: `env | grep OTEL_TRACES`

**Fix:** remove `OTEL_TRACES_SAMPLER_ARG` from the env entirely when `OTEL_TRACES_SAMPLER=always_on`. Setting it to empty is NOT safe - the Java agent treats empty as ratio=0 and silently drops all spans.

### 9. Is the protocol correct for the port?

If the dev is pushing to `4317`, that is the gRPC port — `OTEL_EXPORTER_OTLP_PROTOCOL` must be `grpc`. If pushing to `4318` or the public HTTPS URL, the protocol must be `http/protobuf`. Mixing these is a silent failure (handshake never completes).

## How to drive the conversation

- Ask for one thing at a time, in the diagnostic order above.
- Read actual output. Do not accept "I think I set that" — ask the developer to paste the relevant log lines or env output.
- Cite the help-doc URL for any fix: `https://observekit.expeed.com/help/ingestion/opentelemetry`.

## When to escalate

If after working through all nine steps data is still not flowing:

- Ask infra to verify the API key is active and tied to the expected source.
- Ask infra to check ObserveKit server-side logs for ingest errors keyed by this key.

## Reference files

| File | When to consult |
|---|---|
| `${CLAUDE_PLUGIN_ROOT}/skills/references/endpoints-and-auth.md` | Canonical endpoint URLs, accepted auth header forms, and curl smoke-test recipes |
| `${CLAUDE_PLUGIN_ROOT}/skills/references/secret-management.md` | How the API key flows from secret store to process env across local-dev, Docker, k8s, CI |
| `${CLAUDE_PLUGIN_ROOT}/skills/references/verification-checklist.md` | What to look at in the ObserveKit UI after a fix, in order — Sources, Services, Service Map, Traces |
| `${CLAUDE_PLUGIN_ROOT}/skills/references/sampling-and-exclusions.md` | Sampler env vars, `always_on` vs `parentbased_traceidratio_arg` interaction, exclusion-list length cap |

## Rules

- Read the app's log. Do not guess error causes.
- Verify env vars are present in the actual running process — not just the dev's intention.
- **One fix at a time.** After each fix, ask the dev to retry before moving on.
- Cite `https://observekit.expeed.com/help/ingestion/opentelemetry` for canonical docs.
