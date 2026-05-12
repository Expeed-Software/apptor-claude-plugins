# Verification Checklist

What to look at in ObserveKit after running setup, in order. Each step references the live help docs — cite those URLs in user-facing output. See [help-doc-index.md](./help-doc-index.md) for the full doc map.

## 1. Sources page

Confirm the source for this API key is visible.

- Open the **Sources** page in ObserveKit.
- The source associated with the API key you configured should be listed.
- The source's "last seen" timestamp should be recent (within the last few minutes).

If the source is missing entirely: the API key is wrong, or no data has ever been sent under it. Re-check the key in your secret store.

Docs: **https://observekit.expeed.com/help/sources/intro**

## 2. Services page

Within **~10 seconds of the first request to your app**, the service appears with the `OTEL_SERVICE_NAME` you configured.

- Navigate to the **Services** page.
- Find the row whose name matches `OTEL_SERVICE_NAME`.
- If the row exists and shows non-zero request count, the SDK is connected and reporting.

If the service is missing: the SDK is not exporting. Check the exporter logs for connection errors. The most common causes are an unset `OBSERVEKIT_API_KEY` or a misconfigured endpoint.

Docs: **https://observekit.expeed.com/help/services/intro**

## 3. Service Map

If your app calls another instrumented service, an edge appears on the Service Map.

- Open the **Service Map**.
- Locate your service. It should have edges to every downstream service it called.
- An edge appears only once both endpoints are instrumented and a trace has connected them.

If you expected an edge and don't see one: either the downstream service is not instrumented, or trace context propagation is broken (the `traceparent` header isn't being forwarded). The latter usually means an HTTP client wasn't wrapped by auto-instrumentation.

Docs: **https://observekit.expeed.com/help/service-map/intro**

## 4. Traces page

A row per request.

- Open the **Traces** page.
- Filter by your service name.
- You should see one row per incoming request, with duration, status, and root span name.

If rows appear but are missing fields (no duration, "unknown" status): the auto-instrumentation is partial. Check the framework reference to ensure the HTTP server instrumentation is wired correctly.

Docs: **https://observekit.expeed.com/help/traces/intro**

## 5. Trace detail

- Click any trace row. The detail view shows a **waterfall** of spans.
- The root span at the top represents the incoming request.
- Children below represent DB calls, outbound HTTP, queue operations, etc.
- Click any span to see its **Attributes** in the right panel — these are the semantic-convention keys (`http.route`, `db.statement`, etc.) plus anything you added.

If the waterfall has only the root span and no children: child instrumentations (DB driver, HTTP client) are not active. Re-check the framework reference for the list of auto-instrumented libraries.

## 6. Logs page (if log correlation is wired)

- Open the **Logs** page.
- Pick any trace ID from step 5 and filter by `trace_id=<id>`.
- You should see the application log lines that were emitted during that request.

If logs appear but `trace_id` is empty on every line: the log appender is wired but the MDC / span context bridge is missing. See the framework reference's logging section.

If no logs appear at all: log export is not enabled. Check `OTEL_LOGS_EXPORTER=otlp` (or the framework-specific equivalent).

## 7. Nothing appears at all

If after waiting **~30 seconds** none of the above appears, work the troubleshooting flow:

- Run the `troubleshoot` skill — it walks the stack-by-stack diagnosis.
- Or read the **Troubleshoot** section of the framework reference you used during setup (each framework reference has one).

Common root causes, in order of frequency:
1. `OBSERVEKIT_API_KEY` not actually injected into the running process (env var unset or typo).
2. Wrong endpoint (forgot `https://`, appended `/v1/traces` twice, used port 4317 in HTTP exporter).
3. Network egress blocked (corporate firewall, VPC without NAT, missing security-group egress rule).
4. SDK initialized too late — auto-instrumentation must be loaded before the framework's first HTTP server start.
