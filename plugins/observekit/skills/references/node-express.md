# Express + ObserveKit (OpenTelemetry)

## 1. What this framework needs

Express is a CommonJS HTTP framework built on Node's `http` module. The canonical path is **auto-instrumentation via `@opentelemetry/auto-instrumentations-node`**, which bundles `@opentelemetry/instrumentation-http` and `@opentelemetry/instrumentation-express` (plus dozens of others).

Why it works: the meta-package registers a `require` hook the moment Node loads it. Any subsequent `require('express')`, `require('http')`, `require('pg')`, etc. is intercepted and patched. As long as the package is loaded **before** your application code, every Express route handler, middleware, and outbound HTTP call gets a span automatically — no code changes inside your routes.

You ship traces/metrics/logs to ObserveKit using the standard OTLP exporter. ObserveKit speaks `http/protobuf` on:

- `https://observekit-api.expeed.com/v1/traces`
- `https://observekit-api.expeed.com/v1/metrics`
- `https://observekit-api.expeed.com/v1/logs`

Auth: `X-API-Key: <key>` (or `Authorization: Bearer <key>`). Body cap: 10 MB per request.

## 2. Dependency declaration

`package.json`:

```json
{
  "dependencies": {
    "@opentelemetry/api": "^1.9.0",
    "@opentelemetry/auto-instrumentations-node": "^0.52.0"
  }
}
```

Notes:
- `@opentelemetry/api` belongs in `dependencies` (not `devDependencies`) because your custom-span snippets import from it at runtime.
- `@opentelemetry/auto-instrumentations-node` is a meta-package — it pulls in every official Node instrumentation including `instrumentation-http`, `instrumentation-express`, `instrumentation-pg`, `instrumentation-mysql2`, `instrumentation-redis`, `instrumentation-pino`, `instrumentation-winston`, etc. You do not need to add them individually.
- No SDK package is required for the env-var path — the `/register` entrypoint constructs a NodeSDK for you.

## 3. SDK init / config

For Express, **no init code is needed**. Configuration is purely environment variables — set them before the Node process starts. Use `dotenv` for local development.

`.env` (committed defaults — no secrets):

```bash
OTEL_SERVICE_NAME=my-express-app
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production,service.version=1.0.0
```

`${OBSERVEKIT_API_KEY}` resolves at process start — keep the real key in `.env.local` (see section 5) or your secret manager.

## 4. Launch flag / start script

The `--require` flag wires auto-instrumentation into Node's startup. The meta-package's `/register` subpath does all the wiring (creates a `NodeSDK`, registers exporters from env vars, starts it):

```json
{
  "scripts": {
    "start": "node --require @opentelemetry/auto-instrumentations-node/register dist/server.js"
  }
}
```

For Dockerfile:

```dockerfile
ENV OTEL_SERVICE_NAME=my-express-app
ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
ENV OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
# OTEL_EXPORTER_OTLP_HEADERS injected at deploy time, not baked in.
CMD ["node", "--require", "@opentelemetry/auto-instrumentations-node/register", "dist/server.js"]
```

The flag is purely a Node CLI argument — it does not require any change to your `app.js`/`server.js`. Your Express app boots normally; instrumentation is patched in before your `require('express')` call resolves.

## 5. Local-dev secret file

Keep the real key out of git. Use `.env.local`, loaded with `dotenv`:

`.env.local` (NEVER commit):

```bash
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=<paste-the-key-the-infra-team-gave-you>
```

`.gitignore`:

```
.env.local
.env.*.local
```

`package.json` dev script that loads `.env.local` **before** registering OTel (so the API key is in `process.env` when the exporter constructs):

```json
{
  "scripts": {
    "dev": "node -r dotenv/config -r @opentelemetry/auto-instrumentations-node/register dist/server.js dotenv_config_path=.env.local"
  }
}
```

Order matters: `-r dotenv/config` first populates `process.env`, then `-r @opentelemetry/auto-instrumentations-node/register` constructs the SDK using those vars.

## 6. Custom span snippet

Auto-instrumentation gives you every HTTP request as a span for free. When you need a custom span for a business operation (e.g., "checkout"), use the API directly:

```js
const { trace, SpanStatusCode } = require('@opentelemetry/api');

const tracer = trace.getTracer('checkout');

app.post('/checkout', async (req, res) => {
  await tracer.startActiveSpan('checkout.process', async (span) => {
    try {
      span.setAttribute('cart.items', req.body.items.length);
      span.setAttribute('cart.total', req.body.total);

      const order = await processCheckout(req.body);
      span.setAttribute('order.id', order.id);

      res.json(order);
      span.setStatus({ code: SpanStatusCode.OK });
    } catch (err) {
      span.recordException(err);
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      res.status(500).json({ error: err.message });
    } finally {
      span.end();
    }
  });
});
```

The custom span becomes a child of the auto-instrumented HTTP span — no manual context propagation needed.

## 7. Log correlation

Two strategies.

### Strategy A — OTel log appender (recommended)

`@opentelemetry/instrumentation-pino` (and `-winston`, `-bunyan`) are bundled in `auto-instrumentations-node`. They automatically inject `trace_id`, `span_id`, and `trace_flags` into every log record produced by your logger, **and** ship those records as OTLP logs to `/v1/logs`.

With Pino, no extra code — just use Pino normally:

```js
const pino = require('pino');
const logger = pino();

app.get('/users/:id', (req, res) => {
  logger.info({ userId: req.params.id }, 'fetching user');
  // Log line emitted with trace_id and span_id added automatically.
});
```

Enable log export with: `OTEL_LOGS_EXPORTER=otlp`.

### Strategy B — manual MDC pattern

If you want trace IDs in your existing stdout log format (e.g., for human reading without OTLP log export), pull them from the active span:

```js
const { trace } = require('@opentelemetry/api');

function withTraceId(obj) {
  const span = trace.getActiveSpan();
  if (span) {
    const ctx = span.spanContext();
    return { ...obj, trace_id: ctx.traceId, span_id: ctx.spanId };
  }
  return obj;
}

app.get('/orders/:id', (req, res) => {
  console.log(JSON.stringify(withTraceId({ msg: 'fetching order', orderId: req.params.id })));
  res.json({ ok: true });
});
```

Strategy A is preferred — Strategy B is for legacy log pipelines.

## 8. Sampling and exclusion

### Sampling — env-var driven

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
```

This keeps 25% of root traces and respects upstream sampling decisions. Use `always_on` in dev, `parentbased_traceidratio` with 0.05–0.25 in prod.

### Exclusion — code, not env

Unlike the JVM agent, the Node auto-instrumentation **does not support env-var-based path exclusion**. You must drop into code with a custom `otel.config.js` that builds a `NodeSDK` manually and supplies `ignoreIncomingRequestHook` to the HTTP instrumentation:

`otel.config.js`:

```js
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-proto');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { HttpInstrumentation } = require('@opentelemetry/instrumentation-http');

const EXCLUDED = new Set(['/healthz', '/readyz', '/metrics']);

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter(),
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-http': {
        ignoreIncomingRequestHook: (req) => {
          const url = req.url || '';
          const path = url.split('?')[0];
          return EXCLUDED.has(path);
        },
      },
    }),
  ],
});

sdk.start();
```

Wire it in via `--require ./otel.config.js` instead of the bundled `/register` shortcut:

```json
"scripts": {
  "start": "node --require ./otel.config.js dist/server.js"
}
```

This is a real deviation from the JVM model, where exclusion is `OTEL_INSTRUMENTATION_HTTP_SERVER_EXCLUDED_URLS`. Plan accordingly.

## 9. Common pitfalls

- **ESM vs CommonJS.** `--require` works only with CommonJS. For ESM (`"type": "module"` in `package.json`), use `--import @opentelemetry/auto-instrumentations-node/register` — requires Node 18.19+ or Node 20.6+. On older Node you must transpile back to CJS or pin to a `NODE_OPTIONS` loader hook.
- **Bun and Deno.** Auto-instrumentation depends on Node's `require` hook and AsyncLocalStorage internals. Bun has partial compatibility; Deno does not. If the runtime is not Node, this approach does not apply — use the manual SDK or a different exporter strategy.
- **Cluster mode and pm2.** Every worker process must be launched with the flag. In pm2's ecosystem file: `node_args: "--require @opentelemetry/auto-instrumentations-node/register"`. A worker forked without it produces zero spans.
- **TypeScript.** The `--require` flag goes on the **runtime** node command (the one that runs the compiled JS), not on `tsc`. If you run `ts-node` in dev, put it there: `ts-node --require @opentelemetry/auto-instrumentations-node/register src/server.ts`.
- **Loading order.** Anything that imports `express`, `http`, `pg`, etc. **before** the instrumentation register runs will not be patched. Do not import application code from a preload script.
- **Double instrumentation.** Do not combine `--require @opentelemetry/auto-instrumentations-node/register` with a manual `NodeSDK` in your app — the second SDK silently overrides the first and you lose half your spans. Pick one entry point.
