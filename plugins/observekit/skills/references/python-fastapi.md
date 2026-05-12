# FastAPI + ObserveKit (OpenTelemetry)

## 1. What this framework needs

FastAPI is instrumented with **`opentelemetry-distro[otlp]`** plus **`opentelemetry-instrumentation-fastapi`** (which builds on `opentelemetry-instrumentation-asgi` for the underlying ASGI request/response span). Launch the app under `opentelemetry-instrument` and the SDK is configured entirely from `OTEL_*` env vars.

Why this works:

- The distro launcher initializes `TracerProvider` / `MeterProvider` / `LoggerProvider` before user imports run.
- Each `opentelemetry-instrumentation-*` package declares an `opentelemetry_instrumentor` entry point. The launcher walks all installed entry points and calls each `Instrumentor().instrument()` once, before `fastapi` is imported in user code.
- `opentelemetry-instrumentation-fastapi` wraps Starlette's ASGI middleware stack so every request becomes a server span, properly annotated with `http.route` (the route template, not the literal path).
- The span context is attached to Python's `contextvars`, which `asyncio` propagates across `await` boundaries — so any `async def` view inherits the right parent without extra work.

In-code instrumentation via `FastAPIInstrumentor.instrument_app(app)` is also supported when you want to enable/disable per environment.

## 2. Dependency declaration

`requirements.txt`:

```
opentelemetry-distro[otlp]
opentelemetry-instrumentation-fastapi
opentelemetry-instrumentation-asgi
opentelemetry-instrumentation-logging
opentelemetry-instrumentation-requests
opentelemetry-instrumentation-httpx
```

`pyproject.toml`:

```toml
[project]
dependencies = [
  "opentelemetry-distro[otlp]",
  "opentelemetry-instrumentation-fastapi",
  "opentelemetry-instrumentation-asgi",
  "opentelemetry-instrumentation-logging",
  "opentelemetry-instrumentation-requests",
  "opentelemetry-instrumentation-httpx",
]
```

Notes:

- `opentelemetry-distro[otlp]` pulls api, sdk, OTLP HTTP/protobuf exporter, and the distro launcher.
- `opentelemetry-instrumentation-asgi` is a transitive of the FastAPI instrumentation; list it explicitly so a future Starlette-only path stays covered.
- For async DB drivers: `opentelemetry-instrumentation-asyncpg`, `opentelemetry-instrumentation-aiopg`, `opentelemetry-instrumentation-sqlalchemy` (works for async engines too), `opentelemetry-instrumentation-redis`, `opentelemetry-instrumentation-aio-pika`.
- For outbound HTTP, `httpx` (the recommended async client) is covered by `opentelemetry-instrumentation-httpx`; `aiohttp` clients use `opentelemetry-instrumentation-aiohttp-client`.

## 3. SDK init / config block

**Env-driven (preferred).** No code changes — uvicorn just inherits the environment:

```bash
OTEL_SERVICE_NAME=checkout-fastapi
OTEL_RESOURCE_ATTRIBUTES=service.namespace=shop,deployment.environment=production
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://observekit-api.expeed.com/v1/traces
OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=https://observekit-api.expeed.com/v1/metrics
OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=https://observekit-api.expeed.com/v1/logs
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
OTEL_PYTHON_LOG_CORRELATION=true
```

Auth header alternatives:

- `OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}`
- `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20${OBSERVEKIT_API_KEY}`

OTLP HTTP body cap: **10 MB**. Keep `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` at 512 unless you've measured.

**In-code init (alternative).** Use this when you want a programmatic switch (e.g. tests/dev bypass instrumentation):

```python
# main.py
from fastapi import FastAPI
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

app = FastAPI()

# ... routes, dependencies ...

FastAPIInstrumentor.instrument_app(app)
```

You still launch under `opentelemetry-instrument` so the global TracerProvider is wired up; the `instrument_app` call is just an alternative to letting the auto-instrumentation discover the app via the ASGI hook.

## 4. Launch wrapper

```bash
# dev
opentelemetry-instrument python -m uvicorn main:app --reload --host 0.0.0.0 --port 8000

# prod (gunicorn with uvicorn workers — recommended)
opentelemetry-instrument gunicorn 'main:app' \
  -k uvicorn.workers.UvicornWorker \
  --workers 4 --bind 0.0.0.0:8000

# prod (single-process uvicorn behind a load balancer)
opentelemetry-instrument python -m uvicorn main:app --host 0.0.0.0 --port 8000 --workers 4
```

For Hypercorn: `opentelemetry-instrument hypercorn main:app`.

## 5. Local-dev secret file path

FastAPI doesn't bundle a `.env` loader; the idiomatic option is `pydantic-settings` (or `python-dotenv` if you'd rather just populate `os.environ`).

`.env` (root of repo, **never committed**):

```
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
OTEL_SERVICE_NAME=checkout-fastapi
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}
```

`.gitignore`:

```
.env
.env.*
!.env.example
```

Load step — either:

(a) pydantic-settings reads `.env` into a typed `Settings` object; your code accesses `settings.observekit_api_key`, but the OTel SDK reads `OTEL_*` directly from `os.environ` — so you must ALSO export the variables, either via the shell, dotenv-cli, or by setting them in `os.environ` at startup. pydantic-settings does **not** write loaded values back into `os.environ` on its own.

(b) `python-dotenv` at the top of `main.py`:

```python
from dotenv import load_dotenv
load_dotenv()
```

(c) docker compose `env_file: .env` — preferred for containerized dev because the env exists before the Python interpreter starts, so `opentelemetry-instrument` sees it.

Note: `OTEL_*` vars must be in the **process environment before** `opentelemetry-instrument` runs. Options (b) and (a) only work for vars your app reads at runtime — for OTel init, use (c) or `set -a; . ./.env; set +a` in the shell.

## 6. Custom span snippet

The context manager is async-safe because `start_as_current_span` stores the span in a `contextvars.ContextVar`, and asyncio propagates contextvars across `await`.

```python
from opentelemetry import trace
tracer = trace.get_tracer(__name__)

async def calculate_cart(cart):
    with tracer.start_as_current_span(
        "pricing.calculate",
        attributes={"cart.items": len(cart.lines), "cart.currency": cart.currency},
    ) as span:
        total = await _apply_promotions(cart)   # awaits inside the span: fine
        span.set_attribute("cart.total", float(total))
        return total
```

In a FastAPI route, the outer server span is already active, so this is automatically a child:

```python
@app.post("/checkout")
async def checkout(payload: CheckoutIn):
    with tracer.start_as_current_span("checkout.validate") as span:
        await validate(payload)
        span.set_attribute("checkout.user_id", payload.user_id)
    return await charge(payload)
```

Decorator that works for both sync and async handlers:

```python
import asyncio
from functools import wraps

def traced(span_name):
    def deco(fn):
        if asyncio.iscoroutinefunction(fn):
            @wraps(fn)
            async def aio(*args, **kwargs):
                with tracer.start_as_current_span(span_name):
                    return await fn(*args, **kwargs)
            return aio
        @wraps(fn)
        def sync(*args, **kwargs):
            with tracer.start_as_current_span(span_name):
                return fn(*args, **kwargs)
        return sync
    return deco
```

## 7. Log correlation snippet

**Strategy A — OTel log handler.** `opentelemetry-instrumentation-logging` injects `otelTraceID`, `otelSpanID`, and `otelServiceName` into every `LogRecord`. Combined with `set_logging_format=True` (or env `OTEL_PYTHON_LOG_CORRELATION=true`) you get a ready-made format string.

```python
import logging
from opentelemetry.instrumentation.logging import LoggingInstrumentor

LoggingInstrumentor().instrument(set_logging_format=True)

logging.basicConfig(
    level=logging.INFO,
    format=(
        "%(asctime)s %(levelname)s [%(name)s] "
        "[trace_id=%(otelTraceID)s span_id=%(otelSpanID)s "
        "resource.service.name=%(otelServiceName)s] %(message)s"
    ),
)
```

Resulting line:

```
2026-05-11T12:00:01 INFO [app.checkout] [trace_id=4bf92f3577b34da6a3ce929d0e0e4736 span_id=00f067aa0ba902b7 resource.service.name=checkout-fastapi] charge succeeded
```

For uvicorn's own logs, point its loggers at the same format:

```python
import logging
for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
    logging.getLogger(name).handlers.clear()
    logging.getLogger(name).propagate = True
```

**Strategy B — structlog / loguru processor.** Read the active span context directly:

```python
from opentelemetry import trace

def add_trace_context(logger, method_name, event_dict):
    span = trace.get_current_span()
    ctx = span.get_span_context()
    if ctx.is_valid:
        event_dict["trace_id"] = f"{ctx.trace_id:032x}"
        event_dict["span_id"] = f"{ctx.span_id:016x}"
    return event_dict
```

Wire it into `structlog.configure(processors=[..., add_trace_context, ...])` before the renderer. Because contextvars propagate across `await`, the trace ID is correct even inside async views.

## 8. Sampling and exclusion config keys

Sampling:

- `OTEL_TRACES_SAMPLER=parentbased_traceidratio`
- `OTEL_TRACES_SAMPLER_ARG=0.25`

URL exclusion (regex, not glob; patterns are comma-separated and joined with `|`):

- `OTEL_PYTHON_EXCLUDED_URLS=^/healthz$,^/readyz$,^/metrics$,^/favicon\\.ico$`

FastAPI-specific overrides:

- `OTEL_PYTHON_FASTAPI_EXCLUDED_URLS` — same syntax, FastAPI-only override of the global list.

Batch / export tuning:

- `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` (default 512). Stay well under the **10 MB** OTLP body cap.
- `OTEL_BSP_SCHEDULE_DELAY` (default 5000ms).
- `OTEL_EXPORTER_OTLP_TIMEOUT` (default 10s).

## 9. Common pitfalls in this framework

- **Gunicorn / uvicorn pre-fork workers.** `opentelemetry-instrument` reinitializes the SDK per worker. Hand-rolled `TracerProvider()` at module import runs once before fork and silently exports from worker 0 only. If you must hand-roll, do it in uvicorn's `lifespan` startup or gunicorn's `post_fork` hook.
- **Celery / dramatiq / arq.** None of these are auto-instrumented by the FastAPI package. Install the matching `opentelemetry-instrumentation-celery` (or write a manual wrapper for arq) so background tasks join the originating trace.
- **`async` context preservation.** Spans live in `contextvars`. Do not store a span in a module global or a class attribute and `set_attribute` on it from another task — you'll mutate a span outside its scope and confuse the exporter. Always use `with tracer.start_as_current_span(...)`.
- **FastAPI `Depends`.** Each dependency call resolved by `Depends()` produces its own child span when wrapped in `start_as_current_span` (or when the dependency is itself instrumented). This is intentional but can be surprising in waterfall views — disable selectively by removing inner spans on noisy deps.
- **`BackgroundTasks`.** Tasks added via `BackgroundTasks` run **after** the response is sent. The server span is already closed by then, so spans created inside a background task are parent-less unless you capture the context when scheduling and reattach it inside the task. Use the matching `attach` / `detach` pair so the context is properly released:

  ```python
  from opentelemetry import context, trace

  tracer = trace.get_tracer(__name__)

  @app.post("/checkout")
  async def checkout(payload: CheckoutIn, background_tasks: BackgroundTasks):
      ctx = context.get_current()        # capture at schedule time
      background_tasks.add_task(_finalize, payload, ctx)
      return {"status": "queued"}

  def _finalize(payload, ctx):
      token = context.attach(ctx)        # reattach inside the task
      try:
          with tracer.start_as_current_span("checkout.finalize"):
              ...
      finally:
          context.detach(token)          # always detach to release the context
  ```
- **Raw `asyncpg` / `aiohttp` calls.** Not covered by `opentelemetry-instrumentation-fastapi`. Install the matching instrumentation or you'll see request spans with no DB / outbound HTTP children, making latency attribution misleading.
- **Healthcheck firehose.** k8s probes and load balancer health pings dominate trace volume without `OTEL_PYTHON_EXCLUDED_URLS` / `OTEL_PYTHON_FASTAPI_EXCLUDED_URLS`.
- **`uvicorn --reload` in dev.** The reloader spawns a child; under `opentelemetry-instrument` this works correctly, but any in-code SDK init at import time runs twice. Guard with the same pattern you'd use for werkzeug or rely on env-driven init only.
