# Axum (Rust) + ObserveKit (OpenTelemetry)

## 1. What this framework needs

Rust has no auto-instrumentation — like Go, instrumentation is always manual. The idiomatic pattern is **`tracing` + `tracing-opentelemetry`**: write code against the `tracing` crate (Rust's de facto structured-tracing API, with the `#[tracing::instrument]` proc macro), and use `tracing-opentelemetry` as a bridge layer that converts `tracing` spans into OTel spans and ships them via the OTLP exporter.

This composes cleanly with Axum because:
- Axum is built on `tower`, and `tower_http::trace::TraceLayer` emits `tracing` events for every request.
- The `tracing` crate is already used by `tokio`, `hyper`, `reqwest`, `sqlx`, etc. — turning on the OTel bridge instantly captures spans from the whole stack.

Ship target — ObserveKit speaks `http/protobuf` on:

- `https://observekit-api.expeed.com/v1/traces`
- `https://observekit-api.expeed.com/v1/metrics`
- `https://observekit-api.expeed.com/v1/logs`

Auth header: `X-API-Key: <key>` (or `Authorization: Bearer <key>`). Body cap: 10 MB.

## 2. Dependency declaration (Cargo.toml)

```toml
[package]
name = "myapp"
version = "0.1.0"
edition = "2021"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["macros", "rt-multi-thread", "signal"] }
tower = "0.5"
tower-http = { version = "0.6", features = ["trace"] }

tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json", "fmt"] }
tracing-opentelemetry = "0.27"

opentelemetry = "0.26"
opentelemetry_sdk = { version = "0.26", features = ["rt-tokio"] }
opentelemetry-otlp = { version = "0.26", features = ["http-proto", "reqwest-client"] }
opentelemetry-semantic-conventions = "0.26"

dotenvy = "0.15"
anyhow = "1"
```

Version coupling matters: `opentelemetry`, `opentelemetry_sdk`, `opentelemetry-otlp`, and `tracing-opentelemetry` must agree on a major.minor — mixing `opentelemetry 0.25` with `tracing-opentelemetry 0.27` will not compile. Bump them together.

## 3. SDK init / config block

`src/telemetry.rs`:

```rust
use anyhow::Result;
use opentelemetry::{global, trace::TracerProvider as _, KeyValue};
use opentelemetry_otlp::{Protocol, WithExportConfig};
use opentelemetry_sdk::{
    propagation::TraceContextPropagator,
    trace::{self, RandomIdGenerator, Sampler, SdkTracerProvider},
    Resource,
};
use opentelemetry_semantic_conventions::resource::{
    DEPLOYMENT_ENVIRONMENT, SERVICE_NAME, SERVICE_VERSION,
};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

pub fn init() -> Result<SdkTracerProvider> {
    let service_name = std::env::var("OTEL_SERVICE_NAME").unwrap_or_else(|_| "my-axum-app".into());
    let env = std::env::var("DEPLOYMENT_ENV").unwrap_or_else(|_| "development".into());

    let exporter = opentelemetry_otlp::SpanExporter::builder()
        .with_http()
        .with_protocol(Protocol::HttpBinary)
        // Endpoint, headers, and timeout are read from OTEL_EXPORTER_OTLP_* env vars.
        // Override here only if you need to.
        .build()?;

    let resource = Resource::builder()
        .with_attributes(vec![
            KeyValue::new(SERVICE_NAME, service_name.clone()),
            KeyValue::new(SERVICE_VERSION, env!("CARGO_PKG_VERSION")),
            KeyValue::new(DEPLOYMENT_ENVIRONMENT, env),
        ])
        .build();

    let ratio = std::env::var("OTEL_TRACES_SAMPLER_ARG")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(1.0);

    let provider = SdkTracerProvider::builder()
        .with_batch_exporter(exporter)
        .with_resource(resource)
        .with_sampler(Sampler::ParentBased(Box::new(Sampler::TraceIdRatioBased(ratio))))
        .with_id_generator(RandomIdGenerator::default())
        .build();

    global::set_tracer_provider(provider.clone());
    global::set_text_map_propagator(TraceContextPropagator::new());

    // Wire `tracing` to OTel.
    let tracer = provider.tracer("my-axum-app");
    let otel_layer = tracing_opentelemetry::layer().with_tracer(tracer);

    tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .with(tracing_subscriber::fmt::layer().json())
        .with(otel_layer)
        .init();

    Ok(provider)
}
```

`src/main.rs`:

```rust
use axum::{routing::get, routing::post, Router};
use std::net::SocketAddr;
use tower_http::trace::TraceLayer;

mod telemetry;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _ = dotenvy::dotenv();
    let provider = telemetry::init()?;

    let app = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/checkout", post(handlers::checkout))
        .layer(TraceLayer::new_for_http());

    let addr: SocketAddr = "0.0.0.0:8080".parse()?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(%addr, "starting server");

    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            tokio::signal::ctrl_c().await.ok();
        })
        .await?;

    // Flush before exit.
    provider.shutdown()?;
    Ok(())
}
```

## 4. Launch wrapper or in-code wiring

No launcher. `cargo run` (dev) or the compiled binary (prod). The `telemetry::init()` call in `main` is the entire wiring.

Dockerfile:

```dockerfile
FROM rust:1.82 AS build
WORKDIR /src
COPY . .
RUN cargo build --release

FROM gcr.io/distroless/cc-debian12
COPY --from=build /src/target/release/myapp /myapp
ENV OTEL_SERVICE_NAME=my-axum-app \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
ENTRYPOINT ["/myapp"]
```

## 5. Local-dev secret file path

`dotenvy` (the maintained fork of `dotenv`) loads `.env` files. Call `dotenvy::dotenv()` at the very top of `main` — before `telemetry::init()` — so the OTLP exporter sees the API key in `std::env`.

`.env.local` (NEVER commit):

```bash
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=<paste-the-key-the-infra-team-gave-you>
OTEL_SERVICE_NAME=my-axum-app
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
RUST_LOG=info,my_axum_app=debug,tower_http=debug
```

In `main`:

```rust
// Load .env.local in preference; fall back to .env.
let _ = dotenvy::from_filename(".env.local").or_else(|_| dotenvy::dotenv());
```

`.gitignore`:

```
.env
.env.local
.env.*.local
/target
```

## 6. Custom span snippet (with semantic-convention attributes)

Two equivalent idioms.

### `#[tracing::instrument]` — preferred for whole functions

```rust
use tracing::instrument;

#[instrument(
    name = "pricing.calculate",
    skip(self, cart),
    fields(
        cart.items = cart.items.len(),
        cart.currency = %cart.currency,
        user.id = %cart.user_id,
        cart.total = tracing::field::Empty,
    )
)]
pub async fn calculate(&self, cart: &Cart) -> Result<f64, PricingError> {
    let total = self.compute_total(cart).await?;
    tracing::Span::current().record("cart.total", total);
    Ok(total)
}
```

`tracing::field::Empty` reserves the field at span creation time so it can be filled in later — without this declaration, `record()` is a no-op.

### Manual span — for in-line scopes

```rust
use tracing::info_span;

pub async fn checkout(cart: Cart) -> Result<Order, Error> {
    let span = info_span!(
        "pricing.calculate",
        cart.items   = cart.items.len(),
        cart.currency = %cart.currency,
        user.id      = %cart.user_id,
    );
    let _enter = span.enter();

    let total = compute_total(&cart).await?;
    span.record("cart.total", total);
    Ok(Order { total })
}
```

Both produce the same OTel span via the `tracing-opentelemetry` bridge layer.

## 7. Log correlation snippet

### Strategy A — OTel-native via `tracing-subscriber`

This is what the init code in section 3 already does. Every `tracing::info!`, `tracing::warn!`, `tracing::error!` is recorded as a `tracing` event inside the current span; `tracing-opentelemetry` attaches the trace context automatically. With `OTEL_LOGS_EXPORTER=otlp` and the OTLP logs exporter wired (omitted from section 3 for brevity but follows the same pattern as traces), events ship to `/v1/logs` correlated to their parent span.

In code:

```rust
#[instrument(skip(req))]
async fn checkout(req: CheckoutRequest) -> Result<Json<Order>, Error> {
    tracing::info!(user.id = %req.user_id, items = req.items.len(), "processing checkout");
    // Event is recorded as a span-attached log with trace_id and span_id populated by the bridge.
    Ok(Json(process(req).await?))
}
```

### Why there is no Strategy B here

Other framework references in this set offer a "format-injection" fallback for teams that keep logs on stdout and want trace IDs stitched in as JSON fields. On Rust this fallback is unnecessary: Strategy A above already routes every `tracing::info!`/`warn!`/`error!` event through the OTel bridge with `trace_id` and `span_id` attached, and the same `tracing_subscriber::fmt::layer().json()` layer in section 3 also emits those events to stdout — with the active span's IDs included — in one pass. If you only want stdout JSON (no OTLP logs export), drop the `OTEL_LOGS_EXPORTER` env var and keep the `fmt::layer().json()` layer; you still get trace-correlated stdout logs because the `tracing` span carries the IDs through the same subscriber pipeline. Strategy A is sufficient — there is no second strategy to recommend.

## 8. Sampling and exclusion config keys

### Sampling — env-var, but wired manually

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
```

The Rust SDK does **not** auto-read these — the init code in section 3 parses `OTEL_TRACES_SAMPLER_ARG` manually. If you skip that wiring you get `Sampler::AlwaysOn` regardless of the env var. This mirrors Go's behavior; it is a deliberate trade-off in low-level SDKs.

### Exclusion — Axum middleware or per-route layering

`TraceLayer::new_for_http()` instruments every request. To skip `/healthz`, apply the layer only to the routes that need it:

```rust
let observed = Router::new()
    .route("/checkout", post(handlers::checkout))
    .route("/orders/:id", get(handlers::get_order))
    .layer(TraceLayer::new_for_http());

let unobserved = Router::new()
    .route("/healthz", get(|| async { "ok" }))
    .route("/readyz",  get(|| async { "ok" }));

let app = unobserved.merge(observed);
```

Or filter inside a custom layer that wraps `TraceLayer` and short-circuits for excluded paths.

For the OTLP HTTP exporter timeout / queue:

```bash
OTEL_EXPORTER_OTLP_TIMEOUT=10000
OTEL_BSP_MAX_QUEUE_SIZE=2048
OTEL_BSP_MAX_EXPORT_BATCH_SIZE=512
OTEL_BSP_SCHEDULE_DELAY=5000
```

## 9. Common pitfalls

- **Runtime initialization order.** `global::set_tracer_provider` must be called **before** any task spawns work that creates spans. In practice this means `telemetry::init()` is the second line in `#[tokio::main] async fn main` (after `dotenvy::dotenv()`), and you do not spawn workers from `main` until init returns.
- **`#[tracing::instrument]` on async fns requires `?Sized` impl Future.** This works out of the box on stable Rust — but applying `#[instrument]` to `fn` returning an `impl Future` you constructed by hand can fail with cryptic lifetime errors. Fix by making the function `async fn` directly, or skip the macro.
- **`tracing` spans and OTel spans are not the same thing.** Without the `tracing-opentelemetry` layer wired into the subscriber, `info_span!` produces a `tracing` span that never reaches OTel. Confirm with `opentelemetry::global::tracer("...").start("test")` showing up but `info_span!` not showing up — that's a missing bridge layer.
- **`#[instrument]` requires fields declared at macro time.** `Span::current().record("foo", 42)` only works if `foo = Empty` is in the `fields(...)` list. Recording an undeclared field is a silent no-op.
- **Version drift across `opentelemetry*` crates.** All four (`opentelemetry`, `opentelemetry_sdk`, `opentelemetry-otlp`, `tracing-opentelemetry`) must agree. Cargo will accept mismatched versions and either fail to compile with `expected TracerProvider, found TracerProvider` (different types from different crate versions) or silently produce no spans.
- **`SdkTracerProvider::shutdown()` is sync.** Call it from `main` after the server returns — not from inside a task. Skipping shutdown loses the last batch (~5s of spans).
- **`reqwest-client` feature requires native TLS.** On distroless images or musl builds you may need `rustls-tls` feature instead: `opentelemetry-otlp = { ..., features = ["http-proto", "reqwest-rustls"] }`.
- **Tokio current-thread runtime starves the batch exporter.** The batch span processor needs a runtime to drive its background flush task. Use `tokio = { features = ["rt-multi-thread"] }` and `#[tokio::main(flavor = "multi_thread")]`. The runtime is picked up from the `rt-tokio` feature on `opentelemetry_sdk` (declared in Cargo.toml); in opentelemetry_sdk 0.26+ the `runtime` argument was removed from `with_batch_exporter`, so do not pass it — the feature flag is what wires Tokio in.
- **Cross-task context propagation.** `span.enter()` ties the span to the current async task only. Spawning a new task with `tokio::spawn(async { ... })` loses context unless you do `tokio::spawn(future.instrument(span))` from `tracing::Instrument`.
