# Fastify + ObserveKit (OpenTelemetry)

## 1. What this framework needs

Fastify is a Node HTTP framework built on the `http` module with its own request/reply lifecycle and hook system. The canonical path is **auto-instrumentation via `@opentelemetry/auto-instrumentations-node`**, which bundles `@opentelemetry/instrumentation-fastify` and `@opentelemetry/instrumentation-http`.

Why it works: the meta-package registers a `require` hook. When Fastify is later required, `instrumentation-fastify` wraps the `onRequest`, `preHandler`, `handler`, and `onSend` hook stages, producing a child span per hook under the parent HTTP span. The `http` instrumentation captures the outer request span (route, status code, latency). No code changes inside route handlers are needed.

ObserveKit ingest:

- `https://observekit-api.expeed.com/v1/traces`
- `https://observekit-api.expeed.com/v1/metrics`
- `https://observekit-api.expeed.com/v1/logs`

Auth: `X-API-Key: <key>` (or `Authorization: Bearer <key>`). Body cap: 10 MB per request. Default protocol: `http/protobuf`.

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
- Fastify's request/reply hooks are covered by `@opentelemetry/instrumentation-fastify`, which ships inside `auto-instrumentations-node`. You do not need to add it explicitly.
- Same meta-package also brings `-http`, `-pg`, `-mysql2`, `-mongodb`, `-redis-4`, `-ioredis`, `-pino` (Fastify's default logger) — most Fastify-stack dependencies are covered.
- `@opentelemetry/api` belongs in `dependencies`, not `devDependencies`, because custom-span code imports from it at runtime.

## 3. SDK init / config

For Fastify, **no init code is needed**. Configuration is environment variables only.

`.env` (committed defaults):

```bash
OTEL_SERVICE_NAME=my-fastify-app
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production,service.version=1.0.0
```

Fastify's request/reply hooks (`onRequest`, `preParsing`, `preValidation`, `preHandler`, `preSerialization`, `onSend`, `onResponse`, `onError`) are auto-instrumented — each becomes a child span automatically once the framework is patched. You do not need to register any Fastify plugin to enable this.

## 4. Launch flag / start script

The `--require` flag wires auto-instrumentation into Node's startup:

```json
{
  "scripts": {
    "start": "node --require @opentelemetry/auto-instrumentations-node/register dist/server.js"
  }
}
```

If you run Fastify via its CLI (`fastify start`), apply the flag through `NODE_OPTIONS`. Use `cross-env` so the assignment works on both POSIX and Windows shells:

```json
{
  "scripts": {
    "start": "cross-env NODE_OPTIONS='--require @opentelemetry/auto-instrumentations-node/register' fastify start -l info dist/app.js"
  },
  "devDependencies": {
    "cross-env": "^7.0.3"
  }
}
```

cross-env makes the NODE_OPTIONS assignment work on both POSIX and Windows shells.

Dockerfile CMD:

```dockerfile
ENV OTEL_SERVICE_NAME=my-fastify-app
ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
ENV OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
# OTEL_EXPORTER_OTLP_HEADERS injected at deploy time, not baked in.
CMD ["node", "--require", "@opentelemetry/auto-instrumentations-node/register", "dist/server.js"]
```

## 5. Local-dev secret file

Keep the real key out of git.

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

`package.json` dev script that loads `.env.local` before the OTel register:

```json
{
  "scripts": {
    "dev": "node -r dotenv/config -r @opentelemetry/auto-instrumentations-node/register dist/server.js dotenv_config_path=.env.local"
  }
}
```

Order matters: `dotenv/config` populates `process.env` first, then `auto-instrumentations-node/register` constructs the SDK using those vars.

## 6. Custom span snippet

Auto-instrumentation already creates spans for each hook stage and the outer HTTP request. For business operations inside a handler:

```js
const { trace, SpanStatusCode } = require('@opentelemetry/api');

const tracer = trace.getTracer('checkout');

fastify.post('/checkout', async (request, reply) => {
  return tracer.startActiveSpan('checkout.process', async (span) => {
    try {
      span.setAttribute('cart.items', request.body.items.length);
      span.setAttribute('cart.total', request.body.total);

      const order = await processCheckout(request.body);
      span.setAttribute('order.id', order.id);
      span.setStatus({ code: SpanStatusCode.OK });
      return order;
    } catch (err) {
      span.recordException(err);
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      throw err;
    } finally {
      span.end();
    }
  });
});
```

The custom span is a child of the Fastify-handler span, which is itself a child of the HTTP request span — context propagation is automatic.

## 7. Log correlation

### Strategy A — OTel log appender (recommended)

Fastify uses **Pino** as its default logger. `@opentelemetry/instrumentation-pino` is bundled in `auto-instrumentations-node` and automatically injects `trace_id`, `span_id`, and `trace_flags` into every log record produced by `request.log` or `fastify.log`. No extra code:

```js
fastify.get('/users/:id', async (request, reply) => {
  request.log.info({ userId: request.params.id }, 'fetching user');
  // Log line emitted with trace_id and span_id injected automatically.
});
```

Enable OTLP log export with `OTEL_LOGS_EXPORTER=otlp` and the records flow to `/v1/logs`.

For Winston or Bunyan, the bundled `-winston` and `-bunyan` instrumentations do the same. Fastify with Pino is the most common combination and works out of the box.

### Strategy B — manual MDC pattern

If you customize the logger (e.g., a Fastify hook that produces non-Pino lines), pull IDs from the active span:

```js
const { trace } = require('@opentelemetry/api');

fastify.addHook('onResponse', (request, reply, done) => {
  const span = trace.getActiveSpan();
  const ids = span
    ? { trace_id: span.spanContext().traceId, span_id: span.spanContext().spanId }
    : {};
  console.log(JSON.stringify({ msg: 'response', status: reply.statusCode, ...ids }));
  done();
});
```

Strategy A is preferred — Strategy B is for legacy log formatters.

## 8. Sampling and exclusion

### Sampling — env vars

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
```

### Exclusion — code, not env

The Node auto-instrumentation does not support env-var-based path exclusion. You must build a custom `otel.config.js` with `NodeSDK` and `HttpInstrumentation.ignoreIncomingRequestHook`:

`otel.config.js`:

```js
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-proto');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');

const EXCLUDED = new Set(['/healthz', '/readyz', '/metrics']);

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter(),
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-http': {
        ignoreIncomingRequestHook: (req) => {
          const path = (req.url || '').split('?')[0];
          return EXCLUDED.has(path);
        },
      },
    }),
  ],
});

sdk.start();
```

Wire it in via `--require ./otel.config.js` instead of the `/register` shortcut:

```json
"scripts": {
  "start": "node --require ./otel.config.js dist/server.js"
}
```

Note: `ignoreIncomingRequestHook` lives on the HTTP instrumentation, not on the Fastify instrumentation. The Fastify-level hook spans for an excluded request are skipped automatically because no parent HTTP span is created.

This is a deviation from the JVM model, where exclusion is `OTEL_INSTRUMENTATION_HTTP_SERVER_EXCLUDED_URLS`. Plan accordingly.

## 9. Common pitfalls

- **ESM vs CommonJS.** Fastify supports both. With `"type": "module"`, `--require` no longer works — switch to `--import @opentelemetry/auto-instrumentations-node/register` (Node 18.19+ / 20.6+).
- **Bun and Deno.** Fastify boots on Bun but the OTel auto-instrumentation relies on Node's `require` hook and `AsyncLocalStorage` semantics that Bun only partially implements and Deno does not. Use Node for instrumented runs.
- **Cluster mode and pm2.** Every worker process must launch with the flag. In pm2: `node_args: "--require @opentelemetry/auto-instrumentations-node/register"`. A worker forked without it produces zero spans. Same for Fastify's own `cluster` example.
- **TypeScript.** The flag goes on the runtime `node` command that runs the compiled JS, not on `tsc`. If you run `ts-node` in dev, apply the flag there as well.
- **Loading order.** Anything that imports `fastify` or `http` **before** the OTel register runs will not be patched. Do not import application modules from a preload script.
- **`fastify-cli` and exec args.** When using `fastify start`, the CLI manages the Node invocation. Inject the flag via `NODE_OPTIONS` (see section 4) — passing `--require` after `fastify` will be treated as a Fastify arg, not a Node arg.
- **Double instrumentation.** Do not combine `--require @opentelemetry/auto-instrumentations-node/register` with a manual `NodeSDK` start inside your app — the second SDK silently overrides the first. Pick one entry point.
