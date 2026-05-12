# NestJS + ObserveKit (OpenTelemetry)

## 1. What this framework needs

NestJS runs on top of Express (default) or Fastify, both of which are Node CommonJS HTTP frameworks. The canonical path is **auto-instrumentation via `@opentelemetry/auto-instrumentations-node`**, which bundles `@opentelemetry/instrumentation-nestjs-core` alongside the HTTP, Express, Fastify, and database instrumentations.

Why it works: the meta-package registers a `require` hook the moment Node loads it. When Nest later calls `require('@nestjs/core')`, `instrumentation-nestjs-core` patches the `RouterExecutionContext` and creates a span per controller method, with the HTTP span as parent. Provider lifecycle and pipe/guard/interceptor execution is also captured. No decorators required for HTTP traces.

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
- `@nestjs/core` is patched by `@opentelemetry/instrumentation-nestjs-core`, which ships inside `auto-instrumentations-node`. You do not need to add it explicitly.
- The same meta-package also brings `@opentelemetry/instrumentation-http`, `-express`, `-fastify`, `-pg`, `-mysql2`, `-mongodb`, `-redis-4`, `-ioredis`, `-pino`, `-winston`, and the GraphQL instrumentation — most NestJS dependencies are covered by default.
- For a custom NodeSDK init (section 8), you also add `@opentelemetry/sdk-node` and `@opentelemetry/exporter-trace-otlp-proto` — but only if you need exclusion or other in-code config.

## 3. SDK init / config

For most NestJS apps, **no init code is needed** — env vars do everything. Set them before `nest start` or `node dist/main.js`.

`.env` (committed defaults):

```bash
OTEL_SERVICE_NAME=my-nest-app
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production,service.version=1.0.0
```

If you need a custom `NodeSDK` init (e.g., for path exclusion — see section 8), create `otel.config.js` at the project root using `@opentelemetry/sdk-node` + `OTLPTraceExporter`. Load it with `--require ./otel.config.js` **before** Nest's main entry — never inside `main.ts` after `NestFactory.create()`, because by then `@nestjs/core` has already been required and patching is too late.

## 4. Launch flag / start script

The `--require` flag wires auto-instrumentation in. Apply it to the production `start` script and the `start:prod` Nest convention:

```json
{
  "scripts": {
    "start": "nest start",
    "start:prod": "node --require @opentelemetry/auto-instrumentations-node/register dist/main.js",
    "start:dev": "nest start --watch"
  }
}
```

Nest's `nest-cli.json` has no `scripts` field — its schema is `compilerOptions`, `entryFile`, `monorepo`, `projects`, etc. Dev scripts live in `package.json`. Inject the OTel preload via `NODE_OPTIONS` so `nest start --watch` picks it up:

```json
{
  "scripts": {
    "dev": "cross-env NODE_OPTIONS='--require @opentelemetry/auto-instrumentations-node/register' nest start --watch"
  }
}
```

Dockerfile CMD:

```dockerfile
ENV OTEL_SERVICE_NAME=my-nest-app
ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
ENV OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
# OTEL_EXPORTER_OTLP_HEADERS injected at deploy time, not baked in.
CMD ["node", "--require", "@opentelemetry/auto-instrumentations-node/register", "dist/main.js"]
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

NestJS commonly uses `@nestjs/config`, but that loads env vars **after** the app bootstraps — too late for the OTel SDK which constructs at `--require` time. Load `.env.local` with `dotenv` at the process level instead:

```json
{
  "scripts": {
    "dev": "node -r dotenv/config -r @opentelemetry/auto-instrumentations-node/register dist/main.js dotenv_config_path=.env.local"
  }
}
```

Order matters: `dotenv/config` populates `process.env` first, then the OTel register reads it.

## 6. Custom span snippet

Auto-instrumentation already creates a span per controller method. For business spans inside a service, use the API directly:

```ts
import { Injectable } from '@nestjs/common';
import { trace, SpanStatusCode } from '@opentelemetry/api';

const tracer = trace.getTracer('checkout');

@Injectable()
export class CheckoutService {
  async process(cart: { items: Item[]; total: number }) {
    return tracer.startActiveSpan('checkout.process', async (span) => {
      try {
        span.setAttribute('cart.items', cart.items.length);
        span.setAttribute('cart.total', cart.total);

        const order = await this.persist(cart);
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
  }
}
```

### Idiomatic alternative — `@Span()` decorator (third-party)

The `nestjs-otel` community package exposes a `@Span()` decorator that wraps the method body:

```ts
import { Span } from 'nestjs-otel';

@Injectable()
export class CheckoutService {
  @Span('checkout.process')
  async process(cart) { /* ... */ }
}
```

This is third-party (`nestjs-otel`), not maintained by the OpenTelemetry project. It is more idiomatic-looking but adds a dependency outside the official `@opentelemetry/*` packages. Prefer the API-direct form unless your team already standardized on `nestjs-otel`.

## 7. Log correlation

### Strategy A — OTel log appender (recommended)

`@opentelemetry/instrumentation-pino` and `-winston` are bundled in `auto-instrumentations-node` and automatically inject `trace_id`, `span_id`, and `trace_flags` into every log record. For NestJS the most common setup is **`nestjs-pino`** (which wraps Pino as a Nest logger):

```ts
import { Logger, Module } from '@nestjs/common';
import { LoggerModule } from 'nestjs-pino';

@Module({
  imports: [LoggerModule.forRoot()],
})
export class AppModule {}
```

With `OTEL_LOGS_EXPORTER=otlp`, Pino's records flow to `/v1/logs` with trace correlation included. The default Nest `Logger` from `@nestjs/common` will route through Pino once `nestjs-pino` is wired in.

### Strategy B — manual MDC pattern

For the default Nest logger or any custom logger formatter, pull IDs from the active span:

```ts
import { Logger as NestLogger } from '@nestjs/common';
import { trace } from '@opentelemetry/api';

export class TracedLogger extends NestLogger {
  log(message: string, context?: string) {
    const span = trace.getActiveSpan();
    const ids = span
      ? { trace_id: span.spanContext().traceId, span_id: span.spanContext().spanId }
      : {};
    super.log(JSON.stringify({ msg: message, ...ids }), context);
  }
}
```

Strategy A is preferred — Strategy B is for cases where you cannot change the logger.

## 8. Sampling and exclusion

### Sampling — env vars

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
```

### Exclusion — code, not env

Like Express, the Node auto-instrumentation does not support env-var path exclusion. You must build a custom `otel.config.js` with `NodeSDK` and `HttpInstrumentation`:

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

Wire it in via `--require ./otel.config.js` — **before** Nest's main module is required, never after:

```json
"scripts": {
  "start:prod": "node --require ./otel.config.js dist/main.js"
}
```

This is a deviation from the JVM model, where exclusion is `OTEL_INSTRUMENTATION_HTTP_SERVER_EXCLUDED_URLS`. Plan accordingly.

## 9. Common pitfalls

- **ESM vs CommonJS.** NestJS defaults to CommonJS, so `--require` works. If your project sets `"type": "module"` and compiles to ESM, switch to `--import @opentelemetry/auto-instrumentations-node/register` (Node 18.19+ / 20.6+).
- **Bun and Deno.** Nest does not officially support either. Even where it boots, OTel auto-instrumentation relies on Node-specific `require` hooks and `AsyncLocalStorage` semantics that Bun only partially implements and Deno does not.
- **Cluster mode and pm2.** Every worker must boot with the flag — pm2 `node_args: "--require @opentelemetry/auto-instrumentations-node/register"`. A worker forked without it emits zero spans.
- **TypeScript.** The flag goes on the **runtime** `node` command that runs the compiled JS in `dist/`, not on `tsc` or `nest build`. If you debug with `ts-node`, put it there too.
- **`main.ts` is too late.** Do not initialize a `NodeSDK` from inside `main.ts` after `NestFactory.create(AppModule)`. By then `@nestjs/core` has been required and the instrumentation cannot patch it retroactively. The SDK must start in a preload script (`--require`).
- **Double instrumentation.** Do not combine `--require @opentelemetry/auto-instrumentations-node/register` with a manual `NodeSDK` inside the app — the second `start()` overrides the first silently. Pick one entry point: either `/register` (env-var path) or `./otel.config.js` (in-code path).
- **`nestjs-otel` vs raw API.** The community `nestjs-otel` package adds a `@Span()` decorator and a metrics provider, but it does **not** replace `auto-instrumentations-node`. If you use both, ensure you do not register conflicting HTTP instrumentations.
