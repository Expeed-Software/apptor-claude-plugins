# Flask + ObserveKit (OpenTelemetry)

## 1. What this framework needs

Flask is instrumented through **`opentelemetry-distro[otlp]`** plus **`opentelemetry-instrumentation-flask`** (which depends on `opentelemetry-instrumentation-wsgi` for the underlying WSGI request/response span). You launch your Flask process under the `opentelemetry-instrument` wrapper and the SDK is configured entirely from `OTEL_*` env vars.

Why this works:

- The distro's launcher registers `TracerProvider`, `MeterProvider`, and `LoggerProvider` before user code imports run.
- Every `opentelemetry-instrumentation-*` package exposes a Python entry point under the `opentelemetry_instrumentor` group. The launcher walks all installed entry points and calls each `Instrumentor().instrument()` once — before `flask` is imported in your code — so the framework hooks land in time.
- `opentelemetry-instrumentation-flask` wraps `Flask.full_dispatch_request` and patches the WSGI app, producing one server span per request, annotated with `http.route` (the URL rule, not the literal path).

You can opt into **in-code instrumentation** instead of the launcher — useful when you build the WSGI app in a factory and want explicit control. Both styles are shown below.

## 2. Dependency declaration

`requirements.txt`:

```
opentelemetry-distro[otlp]
opentelemetry-instrumentation-flask
opentelemetry-instrumentation-wsgi
opentelemetry-instrumentation-logging
opentelemetry-instrumentation-requests
opentelemetry-instrumentation-httpx
```

`pyproject.toml`:

```toml
[project]
dependencies = [
  "opentelemetry-distro[otlp]",
  "opentelemetry-instrumentation-flask",
  "opentelemetry-instrumentation-wsgi",
  "opentelemetry-instrumentation-logging",
  "opentelemetry-instrumentation-requests",
  "opentelemetry-instrumentation-httpx",
]
```

Notes:

- `opentelemetry-distro[otlp]` pulls api, sdk, OTLP HTTP/protobuf exporter, and the distro launcher.
- `opentelemetry-instrumentation-wsgi` is a transitive dep of the Flask instrumentation; list it explicitly so a future direct usage (e.g. attaching it to a non-Flask middleware stack) doesn't surprise you.
- For DB drivers, add `opentelemetry-instrumentation-sqlalchemy` (SQLAlchemy), `-psycopg2` / `-psycopg`, `-pymysql`, or `-redis`.
- For Celery workers add `opentelemetry-instrumentation-celery`.

## 3. SDK init / config block

**Env-driven (preferred).** No code changes:

```bash
OTEL_SERVICE_NAME=checkout-flask
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

Body cap on every OTLP HTTP request: **10 MB**. Keep `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` at the default 512 unless you're certain the resulting payload still fits.

**In-code init (when you want finer control).** Use this when your app factory needs to choose whether to instrument (e.g. tests skip it):

```python
# app.py
from flask import Flask
from opentelemetry.instrumentation.flask import FlaskInstrumentor

def create_app():
    app = Flask(__name__)
    # ... register blueprints, config, etc.
    FlaskInstrumentor().instrument_app(app)
    return app
```

When you use `FlaskInstrumentor().instrument_app(app)` you still launch under `opentelemetry-instrument` for the global TracerProvider — or, if you want to fully self-init, configure the provider explicitly with `TracerProvider(resource=Resource.create(...))` and add a `BatchSpanProcessor(OTLPSpanExporter(endpoint=..., headers=...))`. The env-var approach is shorter and less error-prone.

## 4. Launch wrapper

```bash
# dev (Flask's reloader is fine)
opentelemetry-instrument python -m flask --app app run --debug

# prod with a factory
opentelemetry-instrument gunicorn 'app:create_app()' \
  --workers 4 --bind 0.0.0.0:8000 --access-logfile -

# prod with a top-level app object
opentelemetry-instrument gunicorn app:app --workers 4 --bind 0.0.0.0:8000

# Procfile
web: opentelemetry-instrument gunicorn 'app:create_app()'
```

Use the same wrapper for `waitress`, `uwsgi`, or any other WSGI server.

## 5. Local-dev secret file path

Flask reads `.env` automatically if `python-dotenv` is installed (`pip install python-dotenv`). It also reads `.flaskenv` for non-secret defaults — keep secrets out of `.flaskenv`.

`.env` (root of repo, **never committed**):

```
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
OTEL_SERVICE_NAME=checkout-flask
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}
```

`.flaskenv` (committed, no secrets):

```
FLASK_APP=app:create_app
FLASK_DEBUG=1
```

`.gitignore`:

```
.env
.env.*
!.env.example
```

Loading:

- With `python-dotenv` installed, `flask run` (and `flask --app ... run`) loads `.env` and `.flaskenv` automatically before importing the app.
- Under gunicorn / uwsgi, Flask's auto-load does not run. Either source the file (`set -a; . ./.env; set +a`), use `gunicorn --env`, or call `load_dotenv()` at the top of your entrypoint.

## 6. Custom span snippet

```python
from opentelemetry import trace
tracer = trace.get_tracer(__name__)

def calculate_cart(cart):
    with tracer.start_as_current_span(
        "pricing.calculate",
        attributes={"cart.items": len(cart.lines), "cart.currency": cart.currency},
    ) as span:
        total = _apply_promotions(cart)
        span.set_attribute("cart.total", float(total))
        return total
```

Inside a Flask view the outer server span is already open, so `start_as_current_span` produces a child automatically:

```python
@app.post("/checkout")
def checkout():
    with tracer.start_as_current_span("checkout.validate") as span:
        validate(request.json)
        span.set_attribute("checkout.user_id", g.user.id)
    return calculate_and_charge(request.json)
```

For reusable instrumentation, prefer a decorator over scattering `with` blocks:

```python
from functools import wraps

def traced(span_name):
    def deco(fn):
        @wraps(fn)
        def inner(*args, **kwargs):
            with tracer.start_as_current_span(span_name):
                return fn(*args, **kwargs)
        return inner
    return deco

@traced("billing.charge_card")
def charge_card(order_id, amount): ...
```

## 7. Log correlation snippet

**Strategy A — OTel log handler.** `opentelemetry-instrumentation-logging` injects `otelTraceID`, `otelSpanID`, and `otelServiceName` into every `LogRecord`. With `set_logging_format=True` (or env `OTEL_PYTHON_LOG_CORRELATION=true`) it also installs a default format string.

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
2026-05-11T12:00:01 INFO [app.checkout] [trace_id=4bf92f3577b34da6a3ce929d0e0e4736 span_id=00f067aa0ba902b7 resource.service.name=checkout-flask] charge succeeded
```

**Strategy B — structlog / loguru processor.** Pull the trace context directly:

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

Wire it into `structlog.configure(processors=[..., add_trace_context, ...])` before the renderer.

## 8. Sampling and exclusion config keys

Sampling:

- `OTEL_TRACES_SAMPLER=parentbased_traceidratio`
- `OTEL_TRACES_SAMPLER_ARG=0.25`

URL exclusion (regex, not glob — patterns are joined with `|`):

- `OTEL_PYTHON_EXCLUDED_URLS=^/healthz$,^/readyz$,^/metrics$,^/favicon\\.ico$`

Flask-specific overrides:

- `OTEL_PYTHON_FLASK_EXCLUDED_URLS` — same syntax, overrides the global list for Flask only.

Batch / export tuning:

- `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` (default 512). Stay well under the **10 MB** OTLP body cap.
- `OTEL_BSP_SCHEDULE_DELAY` (default 5000ms).
- `OTEL_EXPORTER_OTLP_TIMEOUT` (default 10s).

## 9. Common pitfalls in this framework

- **Gunicorn pre-fork workers.** `opentelemetry-instrument` initializes the SDK in each forked worker, so it works correctly. If you replace the wrapper with hand-rolled `TracerProvider` setup in module scope, the provider is created before the fork and emits from a single worker only. Move custom init into `post_fork(server, worker)` in `gunicorn.conf.py` if you must hand-roll it.
- **Celery.** Auto-instrument does not cross the broker; install `opentelemetry-instrumentation-celery` so producer and consumer share a trace.
- **Flask `before_request` order.** Custom `before_request` hooks see the server span as the current span — read trace context from `trace.get_current_span()`, do not store spans on `flask.g`.
- **Streaming responses.** A long-lived streaming generator keeps the server span open until the generator exhausts; very slow consumers produce hour-long spans. Either time-bound the generator or emit a child span per chunk and close the parent eagerly.
- **`werkzeug` debug server with `--reload`.** The reloader runs your code in two processes: a parent watcher that re-execs on file changes, and a child that actually serves traffic. Werkzeug sets `WERKZEUG_RUN_MAIN=true` only in the child. Under `opentelemetry-instrument` the SDK reinitializes correctly, but **in-code** SDK init that runs at import time will run twice (once per process) and double-instrument. Guard it so init runs only in the child reloader process:

  ```python
  import os

  def init_otel():
      # Only initialize the SDK in the child reloader process to avoid
      # double-instrumentation in the parent watcher process. In production
      # (no reloader), WERKZEUG_RUN_MAIN is unset, so also handle that case.
      if os.environ.get("WERKZEUG_RUN_MAIN") == "true" or not os.environ.get("FLASK_DEBUG"):
          # ... your TracerProvider / instrumentor setup here ...
          pass
  ```

  The key bit is the positive check `== "true"`: the child is the process you want OTel running in; the parent is the file watcher and should stay un-instrumented.
- **SQLAlchemy without its instrumentation.** Flask-SQLAlchemy uses SQLAlchemy under the hood; without `opentelemetry-instrumentation-sqlalchemy` you get the WSGI span but no DB child spans, so latency attribution is wrong.
- **Healthcheck firehose.** k8s liveness probes hit `/healthz` every couple of seconds; without `OTEL_PYTHON_EXCLUDED_URLS` they dominate the trace volume and crowd out real traffic.
