# Django + ObserveKit (OpenTelemetry)

## 1. What this framework needs

Django apps instrument cleanly with **OpenTelemetry's auto-instrumentation distribution**: `opentelemetry-distro[otlp]` plus the `opentelemetry-instrumentation-django` package. At process start you launch your normal entry command under the `opentelemetry-instrument` wrapper, which:

- Reads `OTEL_*` env vars and configures a global `TracerProvider` / `MeterProvider` / `LoggerProvider`.
- Walks Python entry points (registered by every `opentelemetry-instrumentation-*` package) and monkey-patches the target libraries before your code imports them.
- For Django specifically, it hooks `BaseHandler.get_response` so every incoming request becomes a server span, captures URL route, status code, and exception info, and propagates the trace context out to DB drivers (psycopg2/psycopg/mysqlclient) and outbound HTTP clients (`requests`, `httpx`, `urllib3`).

Why this works for Django: the framework-specific instrumentation knows how to map URL resolver output to the `http.route` attribute (so `/users/<id>/` shows up grouped, not as 50k unique URLs), and it understands Django's middleware order so the span wraps everything including auth and template rendering.

You do not need to write SDK init code. The launcher does it.

## 2. Dependency declaration

`requirements.txt`:

```
opentelemetry-distro[otlp]
opentelemetry-instrumentation-django
opentelemetry-instrumentation-logging
opentelemetry-instrumentation-requests
opentelemetry-instrumentation-httpx
opentelemetry-instrumentation-psycopg2
```

Or in `pyproject.toml` (PEP 621):

```toml
[project]
dependencies = [
  "opentelemetry-distro[otlp]",
  "opentelemetry-instrumentation-django",
  "opentelemetry-instrumentation-logging",
  "opentelemetry-instrumentation-requests",
  "opentelemetry-instrumentation-httpx",
  "opentelemetry-instrumentation-psycopg2",
]
```

Notes:

- `opentelemetry-distro[otlp]` pulls in `opentelemetry-api`, `opentelemetry-sdk`, the OTLP HTTP/protobuf exporter, and the distro launcher entry point. Do not pin these individually — let the distro decide.
- Use `opentelemetry-instrumentation-psycopg` (no `2`) if you're on psycopg 3.
- If you use Celery for background work, add `opentelemetry-instrumentation-celery`.
- If you use raw `redis` or `pymongo`, add the matching `opentelemetry-instrumentation-redis` / `-pymongo`.

## 3. SDK init / config block

Django needs **no in-code OTel init**. `DJANGO_SETTINGS_MODULE` stays as-is. `opentelemetry-instrument` reads everything from env vars:

```bash
# .env (or process environment)
OTEL_SERVICE_NAME=checkout-django
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
OTEL_LOG_LEVEL=info
```

Header alternatives:

- `OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}`
- `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20${OBSERVEKIT_API_KEY}` (note the URL-encoded space)

Endpoint facts that matter:

- HTTPS only: `https://observekit-api.expeed.com`
- Per-signal paths: `/v1/traces`, `/v1/metrics`, `/v1/logs`
- Body cap per OTLP request: **10 MB** — keep `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` at its default (512) unless you have a specific reason.

## 4. Launch wrapper

Wrap the Django entry command:

```bash
# dev
opentelemetry-instrument python manage.py runserver

# prod (gunicorn)
opentelemetry-instrument gunicorn myproject.wsgi:application \
  --workers 4 --bind 0.0.0.0:8000

# prod (uwsgi) — pass --enable-threads, the SDK uses a background exporter thread
opentelemetry-instrument uwsgi --module myproject.wsgi --enable-threads
```

Procfile / systemd / Dockerfile `CMD` all use the same pattern — prefix the existing command.

## 5. Local-dev secret file path

Django doesn't auto-load `.env` files. Either use `python-dotenv` (or `django-environ`) at the top of `manage.py` and `wsgi.py`, or load via your process manager.

`.env` (root of repo, **never committed**):

```
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
OTEL_SERVICE_NAME=checkout-django
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}
```

`.gitignore`:

```
.env
.env.*
!.env.example
```

Load step in `manage.py` (before `execute_from_command_line`):

```python
from dotenv import load_dotenv
load_dotenv()
```

Or, if you use `docker compose`, pass `env_file: .env` on the service — no in-code loader needed.

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

Decorator pattern for clean wrapping of service methods (idiomatic when paired with `@transaction.atomic`):

```python
import inspect
from functools import wraps
from django.db import transaction

def traced(span_name):
    def deco(fn):
        # Inspect declared parameters (not locals) so we only inject _span
        # when the wrapped function actually accepts it as a parameter.
        accepts_span = "_span" in inspect.signature(fn).parameters

        @wraps(fn)
        def inner(*args, **kwargs):
            with tracer.start_as_current_span(span_name) as span:
                if accepts_span:
                    return fn(*args, **kwargs, _span=span)
                return fn(*args, **kwargs)
        return inner
    return deco

@traced("order.checkout")
@transaction.atomic
def checkout(user, cart):
    ...
```

The Django middleware already creates the outer server span; your custom spans are children of it automatically because `start_as_current_span` reads from `contextvars`.

## 7. Log correlation snippet

**Strategy A — OTel log handler (recommended).** `opentelemetry-instrumentation-logging` injects trace IDs into the `LogRecord` so any formatter can render them.

`settings.py`:

```python
from opentelemetry.instrumentation.logging import LoggingInstrumentor
LoggingInstrumentor().instrument(set_logging_format=True)

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "otel": {
            "format": (
                "%(asctime)s %(levelname)s [%(name)s] "
                "[trace_id=%(otelTraceID)s span_id=%(otelSpanID)s "
                "resource.service.name=%(otelServiceName)s] "
                "%(message)s"
            ),
        },
    },
    "handlers": {
        "console": {"class": "logging.StreamHandler", "formatter": "otel"},
    },
    "root": {"handlers": ["console"], "level": "INFO"},
}
```

Setting `OTEL_PYTHON_LOG_CORRELATION=true` in env enables `set_logging_format=True` without the in-code call.

**Strategy B — structlog processor.** If you use structlog/loguru, write a processor that reads the active span:

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

Add `add_trace_context` near the start of your `structlog.configure(processors=[...])` chain.

## 8. Sampling and exclusion config keys

Sampling (env vars, read by the SDK at start):

- `OTEL_TRACES_SAMPLER=parentbased_traceidratio`
- `OTEL_TRACES_SAMPLER_ARG=0.25` — keep 25% of root traces; downstream services that received a trace context honor the parent decision.

URL exclusion (regex, not glob):

- `OTEL_PYTHON_EXCLUDED_URLS=^/healthz$,^/readyz$,^/metrics$,^/favicon\\.ico$`

Django-specific toggles:

- `OTEL_PYTHON_DJANGO_INSTRUMENT=true` — on by default; set to `false` to disable just the Django framework instrumentation while keeping others.
- `OTEL_PYTHON_DJANGO_EXCLUDED_URLS` — Django-only override of the global excluded URLs.

Batch / export tuning (rarely needed):

- `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` (default 512) — keep well below the **10 MB** body cap.
- `OTEL_BSP_SCHEDULE_DELAY` (default 5000ms).

## 9. Common pitfalls in this framework

- **Gunicorn / uWSGI pre-fork workers.** Each forked worker re-runs the auto-instrument bootstrap, so spans work per-worker. If you ever hand-roll SDK init in `wsgi.py`, you must do it inside a `post_fork` hook — initializing before the fork leaks file descriptors and silently drops spans from all but worker 0.
- **Celery.** Auto-instrument does not cross the broker boundary unless you install `opentelemetry-instrumentation-celery`. Without it, every Celery task starts a new orphan trace.
- **`async` views and ASGI.** Django 4+ ASGI works, but you need `gunicorn -k uvicorn.workers.UvicornWorker` (or `daphne`) and the same wrapper. The Django instrumentation handles both WSGI and ASGI paths.
- **Raw SQL via `connection.cursor()`.** `opentelemetry-instrumentation-django` covers ORM operations; for raw drivers, install `opentelemetry-instrumentation-psycopg2` / `-psycopg` / `-pymysql` explicitly.
- **Healthcheck noise.** Without `OTEL_PYTHON_EXCLUDED_URLS`, k8s liveness/readiness probes dominate trace volume. Exclude them at the agent, not by sampling at 0% — you still want errors to land.
- **Custom middleware ordering.** Place any middleware that needs to read the trace ID (request logging, error reporting) **below** Django's stock middleware so the OTel server span has already been opened.
- **`DEBUG=True` with thousands of spans.** Django caches every SQL query in `connection.queries` when `DEBUG=True`; combined with OTel span attributes this leaks memory. Never run with `DEBUG=True` under load.
