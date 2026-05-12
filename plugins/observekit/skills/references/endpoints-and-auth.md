# Endpoints and Authentication

The canonical reference for ObserveKit's OTLP ingest surface. Language-neutral — for framework-specific exporter configuration, see the per-framework references in this directory.

## Production endpoint

```
https://observekit-api.expeed.com
```

This is the single ingest base URL for traces, metrics, and logs. There is no separate per-signal hostname.

## HTTP paths (OTLP/HTTP)

All paths accept `POST`. The body is OTLP — protobuf by default, JSON is accepted for debugging.

| Signal  | Path          |
|---------|---------------|
| Traces  | `/v1/traces`  |
| Metrics | `/v1/metrics` |
| Logs    | `/v1/logs`    |

When configuring an OTLP/HTTP exporter, set the endpoint to the **base URL** (`https://observekit-api.expeed.com`). The SDK appends `/v1/traces`, `/v1/metrics`, `/v1/logs` for you. Do not append the path twice.

## Ports

| Protocol      | Port | Notes                                                                 |
|---------------|------|-----------------------------------------------------------------------|
| OTLP/gRPC     | 4317 | Direct from apps is fully supported — not just for an agent relay.    |
| OTLP/HTTP     | 4318 | Used when running ObserveKit locally or with direct port exposure.    |
| HTTPS (prod)  | 443  | Production endpoint terminates TLS on 443 — no explicit port needed.  |

For the production URL above, you do not need to specify a port. Use ports 4317 / 4318 only when targeting a self-hosted or local ObserveKit instance.

## Authentication

Every request must carry the API key in one of two header forms:

```
X-API-Key: <key>
```

or

```
Authorization: Bearer <key>
```

Both are accepted and equivalent. Pick whichever your SDK / framework exposes most naturally.

The key value comes from a secret store — see [secret-management.md](./secret-management.md). It must never be committed to a repository.

## Body cap

The ingest endpoints cap request bodies at **10 MB**.

If you hit the cap (the server returns HTTP `413 Payload Too Large` or the SDK logs a `400` after a large flush), lower the OTel batch span processor's max export batch size:

```
OTEL_BSP_MAX_EXPORT_BATCH_SIZE=256
```

Default in most SDKs is 512. Halving it is the standard remedy. The same idea applies to the metric and log batch processors (`OTEL_BLRP_MAX_EXPORT_BATCH_SIZE` for logs).

## Rate limiting

Ingest endpoints are wrapped with a **per-IP rate limiter**.

**Symptoms when limited:**
- HTTP `429 Too Many Requests` from the exporter.
- SDK logs show retries with exponential backoff.
- Spans/metrics appear delayed but not lost (the SDK retries).

**How to back off:**
- Lower the export interval is not the answer — you'll just hit the limit on the next flush.
- Reduce volume: enable sampling (see [sampling-and-exclusions.md](./sampling-and-exclusions.md)).
- If you are behind a shared NAT and a single IP is multiple apps, contact ObserveKit support to discuss raising the limit for that source IP.

## Wire format

| Format            | Env var                                       | When to use                  |
|-------------------|-----------------------------------------------|------------------------------|
| protobuf (binary) | `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`   | Default. Always use in prod. |
| JSON (protojson)  | `OTEL_EXPORTER_OTLP_PROTOCOL=http/json`       | Manual debugging via curl.   |

protobuf is smaller and faster. JSON is human-readable and useful for hand-crafting requests with `curl`.

## Raw curl example (OTLP/JSON, manual debugging only)

A minimal trace POST that you can run from a terminal to verify connectivity and auth without any SDK:

```bash
curl -i -X POST https://observekit-api.expeed.com/v1/traces \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $OBSERVEKIT_API_KEY" \
  -d '{
    "resourceSpans": [{
      "resource": {
        "attributes": [
          {"key": "service.name", "value": {"stringValue": "curl-test"}}
        ]
      },
      "scopeSpans": [{
        "scope": {"name": "manual-curl"},
        "spans": [{
          "traceId": "00112233445566778899aabbccddeeff",
          "spanId":  "0011223344556677",
          "name": "manual-test-span",
          "kind": 1,
          "startTimeUnixNano": "1700000000000000000",
          "endTimeUnixNano":   "1700000001000000000"
        }]
      }]
    }]
  }'
```

A `200 OK` with an empty body means the span was accepted. The span will appear in ObserveKit under the service name `curl-test` within ~10 seconds.

If you get `401`, the API key is missing or wrong. If you get `429`, you're rate-limited. If you get `413`, your body is over 10 MB.

## Live documentation

The authoritative, current docs live at:

**https://observekit.expeed.com/help/ingestion/opentelemetry**

Cite this URL in any user-facing setup output. See [help-doc-index.md](./help-doc-index.md) for the full doc map.
