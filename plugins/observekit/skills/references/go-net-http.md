# Go (net/http) + ObserveKit (OpenTelemetry)

## 1. What this framework needs

**There is no auto-instrumentation for Go.** Go compiles to a static binary, lacks runtime metaprogramming, and has no JVM-style agent or .NET-style profiler hook. Every span in a Go service is wired manually — either by the framework's middleware (Gin, Echo, Chi, etc.) or by wrapping `http.Handler` with `otelhttp.NewHandler`.

This is not a deficiency of the OpenTelemetry Go SDK; it is a property of the language. Plan for explicit wiring at every entry point: HTTP handlers, gRPC servers, database calls, and outbound `http.Client` usage. The good news is the wiring is small and lives in one file (`main.go`), and the SDK is excellent.

Ship target — ObserveKit speaks `http/protobuf` on:

- `https://observekit-api.expeed.com/v1/traces`
- `https://observekit-api.expeed.com/v1/metrics`
- `https://observekit-api.expeed.com/v1/logs`

Auth header: `X-API-Key: <key>` (or `Authorization: Bearer <key>`). Body cap: 10 MB.

## 2. Dependency declaration (go.mod)

```bash
go get go.opentelemetry.io/otel@latest
go get go.opentelemetry.io/otel/sdk@latest
go get go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp@latest
go get go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp@latest
go get go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp@latest
go get go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp@latest
go get go.opentelemetry.io/contrib/bridges/otelslog@latest
```

Resulting `go.mod` excerpt:

```go
require (
    go.opentelemetry.io/otel v1.29.0
    go.opentelemetry.io/otel/sdk v1.29.0
    go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp v1.29.0
    go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp v1.29.0
    go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp v0.5.0
    go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.54.0
    go.opentelemetry.io/contrib/bridges/otelslog v0.5.0
)
```

The contrib versions (`v0.5x.x`) are intentionally lower than the core SDK — that's the published pattern.

## 3. SDK init / config block

`internal/telemetry/telemetry.go` — canonical init, returns a shutdown func the caller must defer:

```go
package telemetry

import (
    "context"
    "fmt"
    "os"
    "strconv"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// Init wires up the OTel SDK and returns a shutdown function.
// Caller pattern:
//
//   shutdown, err := telemetry.Init(ctx)
//   if err != nil { log.Fatal(err) }
//   defer shutdown(context.Background())
func Init(ctx context.Context) (func(context.Context) error, error) {
    serviceName := envOr("OTEL_SERVICE_NAME", "my-go-service")
    env := envOr("DEPLOYMENT_ENV", "development")

    res, err := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceName(serviceName),
            semconv.ServiceVersion("1.0.0"),
            semconv.DeploymentEnvironment(env),
        ),
        resource.WithProcessRuntimeName(),
        resource.WithProcessRuntimeVersion(),
        resource.WithHost(),
    )
    if err != nil {
        return nil, fmt.Errorf("resource: %w", err)
    }

    // Endpoint and headers come from OTEL_EXPORTER_OTLP_* env vars by default.
    // We pass nothing here — the SDK reads them.
    exporter, err := otlptracehttp.New(ctx)
    if err != nil {
        return nil, fmt.Errorf("trace exporter: %w", err)
    }

    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter,
            sdktrace.WithMaxQueueSize(2048),
            sdktrace.WithMaxExportBatchSize(512),
            sdktrace.WithBatchTimeout(5*time.Second)),
        sdktrace.WithResource(res),
        sdktrace.WithSampler(sampler()),
    )

    otel.SetTracerProvider(tp)
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{},
        propagation.Baggage{},
    ))

    return tp.Shutdown, nil
}

func sampler() sdktrace.Sampler {
    ratio := 1.0
    if s := os.Getenv("OTEL_TRACES_SAMPLER_ARG"); s != "" {
        if v, err := strconv.ParseFloat(s, 64); err == nil {
            ratio = v
        }
    }
    return sdktrace.ParentBased(sdktrace.TraceIDRatioBased(ratio))
}

func envOr(key, fallback string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return fallback
}

// Attribute helpers exported for handlers.
var (
    AttrCartItems = attribute.Key("cart.items")
    AttrCartTotal = attribute.Key("cart.total")
)
```

`main.go`:

```go
package main

import (
    "context"
    "log"
    "net/http"
    "os"
    "os/signal"
    "syscall"
    "time"

    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

    "myapp/internal/telemetry"
)

func main() {
    ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
    defer stop()

    shutdown, err := telemetry.Init(ctx)
    if err != nil {
        log.Fatalf("telemetry init: %v", err)
    }
    defer func() {
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()
        _ = shutdown(ctx)
    }()

    mux := http.NewServeMux()
    mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
    })
    mux.Handle("/checkout", http.HandlerFunc(checkoutHandler))

    // Wrap once at the top — every route below gets a server span automatically.
    // Exclude /healthz by skipping the wrapper for that path (see section 8).
    handler := excludePaths(otelhttp.NewHandler(mux, "http.server"), "/healthz", "/readyz")

    srv := &http.Server{Addr: ":8080", Handler: handler}
    go func() {
        if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
            log.Fatal(err)
        }
    }()
    <-ctx.Done()
    _ = srv.Shutdown(context.Background())
}
```

## 4. Launch wrapper or in-code wiring

No launcher. Go binaries embed the SDK. Run with environment variables set:

```bash
export OTEL_SERVICE_NAME=my-go-service
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
export OTEL_EXPORTER_OTLP_HEADERS="X-API-Key=${OBSERVEKIT_API_KEY}"
export OTEL_TRACES_SAMPLER=parentbased_traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.25
./myapp
```

PowerShell equivalent (Windows):

```powershell
$env:OTEL_SERVICE_NAME = "my-go-service"
$env:OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
$env:OTEL_EXPORTER_OTLP_ENDPOINT = "https://observekit-api.expeed.com"
$env:OTEL_EXPORTER_OTLP_HEADERS = "X-API-Key=$env:OBSERVEKIT_API_KEY"
$env:OTEL_TRACES_SAMPLER = "parentbased_traceidratio"
$env:OTEL_TRACES_SAMPLER_ARG = "0.25"
./myapp.exe
```

Dockerfile:

```dockerfile
FROM gcr.io/distroless/static-debian12
COPY myapp /myapp
ENV OTEL_SERVICE_NAME=my-go-service \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
ENTRYPOINT ["/myapp"]
```

The in-code wiring in `telemetry.Init` is the entire "launcher" — there is no flag and no preload mechanism.

## 5. Local-dev secret file path

Two acceptable patterns. Pick one — do not mix.

### `.env` loaded by `godotenv`

```bash
go get github.com/joho/godotenv
```

`cmd/myapp/main.go` (very top of `main`):

```go
if env := os.Getenv("ENV"); env == "" || env == "development" {
    _ = godotenv.Load(".env.local", ".env")
}
```

`.env.local` (NEVER commit):

```bash
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=<paste-the-key-the-infra-team-gave-you>
```

### Shell-exported

For developers who prefer no extra dependency, document a `direnv` `.envrc` or a `make dev` target that exports vars before invoking `go run`.

`.gitignore`:

```
.env
.env.local
.env.*.local
.envrc.local
```

## 6. Custom span snippet (with semantic-convention attributes)

```go
package pricing

import (
    "context"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/trace"
)

var tracer trace.Tracer = otel.Tracer("myapp/pricing")

type Cart struct {
    UserID   string
    Currency string
    Items    []Item
}

func Calculate(ctx context.Context, cart Cart) (total float64, err error) {
    ctx, span := tracer.Start(ctx, "pricing.calculate",
        trace.WithAttributes(
            attribute.Int("cart.items", len(cart.Items)),
            attribute.String("cart.currency", cart.Currency),
            attribute.String("user.id", cart.UserID),
        ),
    )
    defer func() {
        if err != nil {
            span.RecordError(err)
            span.SetStatus(codes.Error, err.Error())
        }
        span.End()
    }()

    total, err = computeTotal(ctx, cart)
    if err != nil {
        return 0, err
    }
    span.SetAttributes(attribute.Float64("cart.total", total))
    return total, nil
}
```

**Always pass `ctx` through every call** — Go has no implicit thread-local. A function that takes `context.Background()` instead of the inbound `ctx` orphans the span and breaks the trace tree.

## 7. Log correlation snippet

### Strategy A — OTel-native via `slog` bridge (Go 1.21+, recommended)

```go
import (
    "log/slog"
    "go.opentelemetry.io/contrib/bridges/otelslog"
)

// In telemetry.Init, after the LoggerProvider is built:
logger := otelslog.NewLogger("myapp", otelslog.WithLoggerProvider(lp))
slog.SetDefault(logger)
```

Then anywhere in the codebase:

```go
slog.InfoContext(ctx, "processing checkout",
    slog.String("user.id", userID),
    slog.Int("cart.items", len(items)))
```

The bridge reads `trace_id` / `span_id` from `ctx` automatically and emits an OTLP log record with them attached. Records ship to `/v1/logs`.

### Strategy B — format injection for stdout JSON logs

If you keep logs on stdout (Loki / Vector / file shipping) and only want OTLP for traces, pull IDs out of the active span and add them as JSON fields:

```go
import "go.opentelemetry.io/otel/trace"

func loggerFromCtx(ctx context.Context) *slog.Logger {
    sc := trace.SpanContextFromContext(ctx)
    if !sc.IsValid() {
        return slog.Default()
    }
    return slog.Default().With(
        slog.String("trace_id", sc.TraceID().String()),
        slog.String("span_id", sc.SpanID().String()),
    )
}

func handler(w http.ResponseWriter, r *http.Request) {
    log := loggerFromCtx(r.Context())
    log.Info("checkout received", "user.id", r.Header.Get("X-User-Id"))
}
```

Use Strategy A unless a Loki/Elastic pipeline already exists.

## 8. Sampling and exclusion config keys

### Sampling

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
```

Heads-up: **the Go SDK does not automatically read these.** The init code above wires them manually via `sampler()`. If you do not write that code, the env vars are ignored. This is the single biggest gotcha for engineers moving from Java/Node to Go — the SDK is explicit, not magic. See Pitfalls.

### Exclusion — wrap conditionally

`otelhttp.NewHandler` instruments every request. For health checks, skip the wrapper at the mux level:

```go
func excludePaths(instrumented http.Handler, paths ...string) http.Handler {
    skip := make(map[string]struct{}, len(paths))
    for _, p := range paths {
        skip[p] = struct{}{}
    }
    raw := instrumented
    bare := http.DefaultServeMux  // or capture the underlying mux

    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if _, ok := skip[r.URL.Path]; ok {
            // Serve the raw mux directly — no span created.
            bare.ServeHTTP(w, r)
            return
        }
        raw.ServeHTTP(w, r)
    })
}
```

Or use `otelhttp.WithFilter` if you want a span suppressed inside the wrapper:

```go
handler := otelhttp.NewHandler(mux, "http.server",
    otelhttp.WithFilter(func(r *http.Request) bool {
        return r.URL.Path != "/healthz" && r.URL.Path != "/readyz"
    }),
)
```

`WithFilter` returning `false` skips span creation for that request.

## 9. Common pitfalls

- **`context.TODO()` / `context.Background()` orphans spans.** The active span lives only on the `context.Context` chain. Any function call that drops the inbound `ctx` and substitutes a fresh one creates an orphan trace. Always thread `ctx` through.
- **Goroutines need explicit propagation.** `go doWork()` does not carry the parent's span. Pass the context explicitly: `go doWork(ctx)`. For fire-and-forget work that outlives the request, use `context.WithoutCancel(ctx)` (Go 1.21+) so the span context survives request cancellation but the cancellation signal does not propagate.
- **`defer span.End()` always.** Forgetting `End()` causes the span to never flush — it disappears silently at process exit. The `defer` immediately after `Start` is the safe idiom.
- **`OTEL_TRACES_SAMPLER` is not auto-read.** The Go SDK constructor takes a `Sampler` argument. If you write `sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp))` and rely on env vars, you get `ParentBased(AlwaysOn)` — not what the env var says. Wire the sampler from env explicitly (the snippet in section 3 does this).
- **`otelhttp` server-side route name is `"unknown"` by default.** It uses the operation name passed to `NewHandler`. For per-route names use `otelhttp.WithSpanNameFormatter` or rely on Gin/Chi instrumentation that knows route templates.
- **`otlptracehttp.New` returns a `TraceExporter`, not a `TracerProvider`.** You still need `NewTracerProvider` + `WithBatcher` to plug it in. Many copy-paste blogs skip this and you get zero spans.
- **Shutdown order.** Call `tp.Shutdown(ctx)` before `os.Exit` and before `log.Fatal` — the batch span processor needs ~1–5 seconds to flush. A process killed without shutdown loses the last batch.
- **`semconv` version drift.** Pin one version (`v1.26.0` in the snippet) across all your files — mixing `v1.21.0` and `v1.26.0` constants compiles but emits inconsistent attribute keys. The backend will see both `http.method` and `http.request.method` and not be able to correlate.
- **The contrib module versions lag the core SDK.** `otelhttp` ships as `v0.54.x` while `otel` is at `v1.29.x`. Both numbers are correct — do not "fix" one to match the other.
