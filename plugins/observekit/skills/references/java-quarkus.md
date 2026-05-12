# Quarkus + ObserveKit (OpenTelemetry)

This reference covers integrating ObserveKit (OpenTelemetry-compatible backend) into a Quarkus 3.x application. For shared cross-language facts (endpoint URLs, auth headers, body caps, wire formats) see `./endpoints-and-auth.md`.

## 1. What this framework needs

Quarkus's canonical OpenTelemetry path is the **first-party `quarkus-opentelemetry` extension**, not the javaagent. Quarkus does build-time bytecode generation (it calls this "compile-time boot") to support fast cold starts, Quarkus Dev Mode, and GraalVM native image. The OTel extension hooks into that build-time pipeline and generates instrumentation glue for JAX-RS endpoints, the Vert.x event loop, RESTEasy Reactive, the gRPC client and server, the reactive SQL clients, Kafka, JMS, the Redis client, and Hibernate ORM at compile time.

The javaagent is **not recommended for Quarkus** because:

- It can't be used in GraalVM native image — Quarkus's marquee deployment mode — at all.
- It doubles up with the extension's instrumentations in JVM mode.
- It loses Quarkus Dev Mode's live reload (the agent's class transformations conflict with hot-reload class redefinition).

In practice: **always use `quarkus-opentelemetry`**, and reach for the javaagent only in the rare case where you specifically need an OTel instrumentation Quarkus doesn't bundle and you're running JVM-only.

## 2. Dependency declaration

Pinned to Quarkus `3.15.x` (LTS line as of writing). The Quarkus BOM pins the OTel SDK and the extension together — you don't pin OTel versions explicitly. Use the latest minor patch at integration time.

**Maven:**

```xml
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>io.quarkus.platform</groupId>
      <artifactId>quarkus-bom</artifactId>
      <version>3.15.1</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>

<dependencies>
  <dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-opentelemetry</artifactId>
  </dependency>
  <!-- Optional: explicit OTLP exporter; bundled by default but pin via BOM -->
  <dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-opentelemetry-exporter-otlp</artifactId>
  </dependency>
</dependencies>
```

**Gradle (Kotlin DSL):**

```kotlin
plugins {
    id("io.quarkus")
}

dependencies {
    implementation(enforcedPlatform("io.quarkus.platform:quarkus-bom:3.15.1"))
    implementation("io.quarkus:quarkus-opentelemetry")
    implementation("io.quarkus:quarkus-opentelemetry-exporter-otlp")
}
```

**Gradle (Groovy):**

```groovy
dependencies {
    implementation enforcedPlatform("io.quarkus.platform:quarkus-bom:3.15.1")
    implementation "io.quarkus:quarkus-opentelemetry"
    implementation "io.quarkus:quarkus-opentelemetry-exporter-otlp"
}
```

The `quarkus-opentelemetry` extension transitively brings `opentelemetry-api`, `opentelemetry-context`, the SDK, and the instrumentation annotations. You can still depend explicitly on `io.opentelemetry.instrumentation:opentelemetry-instrumentation-annotations` if you want the `@WithSpan` annotation (the Quarkus extension also accepts it natively).

## 3. SDK init / config block (idiomatic, checked-in)

Quarkus uses `application.properties` (YAML is supported via `quarkus-config-yaml`, but properties is the idiomatic Quarkus default). Below is the checked-in config — placeholder only, no real key.

`src/main/resources/application.properties`:

```properties
quarkus.application.name=my-service

# --- OpenTelemetry / ObserveKit ---
quarkus.otel.enabled=true
quarkus.otel.exporter.otlp.protocol=http/protobuf
quarkus.otel.exporter.otlp.endpoint=https://observekit-api.expeed.com
# Per-signal endpoints are derived from the base when protocol=http/protobuf.
# The exporter appends /v1/traces, /v1/metrics, /v1/logs automatically.

# Headers: comma-separated key=value list. Quarkus expands ${VAR} placeholders.
quarkus.otel.exporter.otlp.headers=X-API-Key=${OBSERVEKIT_API_KEY}
# Alternative: quarkus.otel.exporter.otlp.headers=Authorization=Bearer ${OBSERVEKIT_API_KEY}

quarkus.otel.exporter.otlp.timeout=10s
quarkus.otel.exporter.otlp.compression=gzip

# Resource attributes — service.name comes from quarkus.application.name automatically.
quarkus.otel.resource.attributes=\
  service.namespace=${OBSERVEKIT_NAMESPACE:default},\
  deployment.environment=${OBSERVEKIT_ENV:dev}

# Sampling
quarkus.otel.traces.sampler=parentbased_traceidratio
quarkus.otel.traces.sampler.arg=1.0

# HTTP server: don't trace health/readiness/metrics endpoints
quarkus.otel.instrument.rest=true
quarkus.otel.instrument.reactive-messaging=true
quarkus.otel.instrument.grpc=true
# Quarkus has a dedicated drop filter for noisy paths:
quarkus.otel.span.exporter.otlp.batch.max-export-batch-size=512
```

To exclude health/metrics paths, Quarkus's mechanism is slightly different from Spring/Micronaut. The cleanest cross-version approach is using the standard OTel env var (Section 8) **or** a `Sampler` bean filter. Both are shown below in their respective sections.

Notes:

- `${OBSERVEKIT_API_KEY}` is Quarkus's standard `MicroProfile Config` placeholder. It resolves from env vars, system properties, `application.properties`, and `.env` (Section 5).
- Don't append `/v1/traces` to `quarkus.otel.exporter.otlp.endpoint` — the OTLP exporter derives per-signal paths from the base.
- `protocol=http/protobuf` is mandatory against the public HTTPS endpoint. The gRPC port 4317 is for local direct exposure only.
- `quarkus.otel.exporter.otlp.compression=gzip` keeps you safely under the 10 MB body cap on chatty services.

## 4. Launch flag

The Quarkus OTel extension **does not require a `-javaagent`**.

### Quarkus Dev Mode (live reload)

```bash
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you> ./mvnw quarkus:dev
# or
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you> ./gradlew quarkusDev
```

PowerShell equivalent (Windows):

```powershell
$env:OBSERVEKIT_API_KEY = '<paste-the-key-the-infra-team-gave-you>'
./mvnw quarkus:dev
# or
./gradlew quarkusDev
```

Tracing starts on the first hot reload. Live class redefinition works fine because the extension wires up its hooks via Quarkus's build steps, not bytecode rewriting at load time.

### JVM mode (production-style `java -jar`)

After `./mvnw package`:

```bash
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you> \
java -jar target/quarkus-app/quarkus-run.jar
```

PowerShell equivalent (Windows):

```powershell
$env:OBSERVEKIT_API_KEY = '<paste-the-key-the-infra-team-gave-you>'
java -jar target/quarkus-app/quarkus-run.jar
```

No `-javaagent`, no `JAVA_TOOL_OPTIONS`.

### Native image

```bash
./mvnw package -Dnative
# then
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you> \
./target/my-service-1.0.0-runner
```

PowerShell equivalent (Windows):

```powershell
./mvnw package -Dnative
$env:OBSERVEKIT_API_KEY = '<paste-the-key-the-infra-team-gave-you>'
./target/my-service-1.0.0-runner.exe
```

The Quarkus OTel extension is fully GraalVM-compatible — that's the entire point of using it over the agent. Native binaries spin up in tens of milliseconds and start exporting traces on the first request.

### Container image

```dockerfile
FROM registry.access.redhat.com/ubi8/openjdk-21:1.20
COPY --chown=185 target/quarkus-app/lib/ /deployments/lib/
COPY --chown=185 target/quarkus-app/*.jar /deployments/
COPY --chown=185 target/quarkus-app/app/ /deployments/app/
COPY --chown=185 target/quarkus-app/quarkus/ /deployments/quarkus/

ENV QUARKUS_OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
ENV QUARKUS_OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
# OBSERVEKIT_API_KEY injected at runtime by k8s/ECS/Nomad — never baked in
# QUARKUS_OTEL_EXPORTER_OTLP_HEADERS expands ${OBSERVEKIT_API_KEY} at startup
ENV QUARKUS_OTEL_EXPORTER_OTLP_HEADERS="X-API-Key=${OBSERVEKIT_API_KEY}"
```

The Quarkus convention for env-var-style config keys is `UPPER_SNAKE_CASE` of the property name — e.g., `quarkus.otel.exporter.otlp.endpoint` becomes `QUARKUS_OTEL_EXPORTER_OTLP_ENDPOINT`.

Quarkus's MicroProfile Config re-expands `${VAR}` references at application startup, so the `QUARKUS_OTEL_EXPORTER_OTLP_HEADERS="X-API-Key=${OBSERVEKIT_API_KEY}"` line above works in Quarkus even though plain Dockerfile `ENV` substitution would not (Dockerfile `ENV` resolves `${VAR}` at *build* time, not container start). For other frameworks see `java-spring-boot.md` for the corrected pattern.

### When you want the javaagent anyway (JVM-only)

Download via Maven `dependency:get` into `target/agent/opentelemetry-javaagent.jar`, then:

```bash
java -javaagent:target/agent/opentelemetry-javaagent.jar \
     -Dotel.instrumentation.common.default-enabled=false \
     -Dotel.instrumentation.jdbc.enabled=true \
     -jar target/quarkus-app/quarkus-run.jar
```

`default-enabled=false` is critical — without it, the agent doubles up with the extension on every HTTP request. Use this only for narrow gap-filling.

## 5. Local-dev secret file path

Quarkus supports `.env` natively (loaded before `application.properties`), and also supports `application-local.properties` via the `quarkus.profile` mechanism. Both are valid; `.env` is the more common Quarkus idiom.

### Option 1 — `.env` (recommended)

`.env` at the project root (gitignored):

```bash
# DO NOT COMMIT
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
```

That's it. Quarkus picks it up automatically when running `./mvnw quarkus:dev` or `./gradlew quarkusDev`. No code or annotation needed. In production, the `.env` file is ignored — env vars come from the orchestrator.

### Option 2 — Profile-specific properties

`src/main/resources/application-local.properties` (gitignored):

```properties
# DO NOT COMMIT. Local-only secrets.
# Activated by quarkus.profile=local
%local.quarkus.otel.exporter.otlp.headers=X-API-Key=<paste-the-key-the-infra-team-gave-you>
```

Activate via `-Dquarkus.profile=local` or `QUARKUS_PROFILE=local`. Or use Quarkus's per-profile inline syntax in the main file — but that defeats the "secrets in their own file" property and is not recommended.

### `.gitignore`

```gitignore
# OpenTelemetry / ObserveKit — local-only secrets
.env
.env.local
.env.*.local
src/main/resources/application-local.properties
**/application-local.properties
```

## 6. Custom span snippet

Two equivalent ways.

### A — Programmatic `Tracer` (injected via CDI)

```java
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

@ApplicationScoped
public class CheckoutService {

    @Inject
    Tracer tracer;   // injected by quarkus-opentelemetry; named after the class

    public Receipt checkout(Cart cart) {
        Span span = tracer.spanBuilder("checkout")
                .setAttribute(AttributeKey.longKey("cart.items"), (long) cart.items().size())
                .setAttribute(AttributeKey.doubleKey("cart.total"), cart.total())
                .startSpan();
        try (Scope scope = span.makeCurrent()) {
            return doCheckout(cart);
        } catch (Throwable t) {
            span.recordException(t);
            span.setStatus(StatusCode.ERROR, t.getMessage());
            throw t;
        } finally {
            span.end();
        }
    }
}
```

### B — `@WithSpan` annotation

```java
import io.opentelemetry.instrumentation.annotations.SpanAttribute;
import io.opentelemetry.instrumentation.annotations.WithSpan;
import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class CheckoutService {

    @WithSpan("checkout")
    public Receipt checkout(
            @SpanAttribute("cart.items") int items,
            @SpanAttribute("cart.total") double total,
            Cart cart) {
        return doCheckout(cart);
    }
}
```

The Quarkus OTel extension processes `@WithSpan` at build time. Works in JVM mode and native image. Exceptions thrown out of the method are recorded on the span automatically.

## 7. Log correlation snippet

Quarkus uses the JBoss LogManager via `quarkus-jboss-logmanager` (which underlies `java.util.logging`, SLF4J, and any other logging API you might pull in). The Quarkus OTel extension automatically populates **`traceId`** and **`spanId`** as Log MDC keys.

### Strategy A — Log shipping over OTLP

The Quarkus OTel extension ships **log records** over OTLP by default starting in 3.7+. Enable / verify with:

```properties
quarkus.otel.logs.enabled=true
quarkus.otel.logs.exporter=otlp
```

Logs at WARN and above are exported by default. Adjust with:

```properties
quarkus.otel.logs.level=INFO
```

You don't need a separate appender or bridge dependency — it's built in.

### Strategy B — MDC pattern (logs stay in stdout)

If you've turned off OTLP log export (`quarkus.otel.logs.enabled=false`), keep the IDs in the console pattern so your log shipper / log file viewer can correlate:

```properties
quarkus.log.console.format=%d{HH:mm:ss.SSS} %-5p [%c{2.}] [traceId=%X{traceId} spanId=%X{spanId}] (%t) %s%e%n
```

Note Quarkus uses **camelCase** MDC keys (`traceId`, `spanId`) by default in its JBoss LogManager bridge, *not* the snake_case `trace_id`/`span_id` you see in some other OTel docs. If you've configured Quarkus to use Logback or Log4j2 instead of JBoss LogManager (rare), the keys revert to snake_case — verify by inspecting a log line at runtime.

### Strategy C — Log4j2 variant (if you've swapped logging frameworks)

Rare in Quarkus, but if you've added `quarkus-logging-log4j2` (community extension) or similar:

```xml
<dependency>
  <groupId>io.opentelemetry.instrumentation</groupId>
  <artifactId>opentelemetry-log4j-appender-2.17</artifactId>
  <version>2.10.0</version>
</dependency>
```

Then configure the OTel appender in `log4j2.xml` as in the Micronaut reference.

## 8. Sampling and exclusion config keys

### `application.properties`

```properties
quarkus.otel.traces.sampler=parentbased_traceidratio
quarkus.otel.traces.sampler.arg=0.25
```

For path exclusions, Quarkus doesn't expose a single `exclude-paths` key matching Spring/Micronaut. Use either of:

1. **OTel standard env var:**

   ```properties
   quarkus.otel.instrument.rest=true
   # The OTel agent-style env var is honored:
   # OTEL_INSTRUMENTATION_HTTP_SERVER_EXCLUDE_PATHS=/q/health,/q/health/ready,/q/health/live,/q/metrics
   ```

   Or as a property:

   ```properties
   quarkus.otel.instrumentation.http.server.exclude-paths=/q/health,/q/health/ready,/q/health/live,/q/metrics
   ```

2. **Custom drop sampler** as a CDI bean if you need conditional logic beyond path matching:

   ```java
   @ApplicationScoped
   public class DropHealthChecksSampler implements Sampler {
       private static final Set<String> EXCLUDED =
           Set.of("/q/health", "/q/health/ready", "/q/health/live", "/q/metrics");

       @Override
       public SamplingResult shouldSample(Context ctx, String traceId, String name,
                                          SpanKind kind, Attributes attrs, List<LinkData> links) {
           Object path = attrs.get(AttributeKey.stringKey("url.path"));
           if (path != null && EXCLUDED.contains(path.toString())) {
               return SamplingResult.create(SamplingDecision.DROP);
           }
           return SamplingResult.recordAndSample();
       }

       @Override public String getDescription() { return "DropHealthChecksSampler"; }
   }
   ```

   Then wire it via `quarkus.otel.traces.sampler=<your-bean-fqcn>` or by `@Produces Sampler`.

### Recommended profile

- **Dev:** `sampler.arg=1.0`.
- **Staging:** `sampler.arg=0.5`.
- **Prod:** `sampler.arg=0.1` for high-RPS services; `1.0` for low-RPS services where every error matters.

Always exclude the Quarkus default `/q/health/*` and `/q/metrics` paths. They run from k8s probes and Prometheus and generate enormous trace noise.

## 9. Common pitfalls in this framework

- **Dev Mode vs production-mode native compilation diverge in subtle ways.** A trace export that works in `quarkus:dev` may silently fail in native image if you've called OTel APIs from a path the native-image analyzer didn't reach. Mitigation: run an end-to-end smoke test in native mode (`./mvnw package -Dnative -DskipTests=false`) before declaring done. The Quarkus OTel extension ships native-image hints for its own API surface; only *your* code can hit this issue.

- **`@WithSpan` on a private method is a no-op.** Like all CDI interceptors in Quarkus, `@WithSpan` only fires through the proxy. Private methods, final methods, and `this.foo()` self-calls bypass it. Symptoms: missing spans for some internal calls. Fix: make the method non-private and call it through the bean reference (or inject the bean into itself with `@Inject Self self`).

- **`quarkus-vertx`'s event loop demands non-blocking trace work.** If your custom span code includes blocking I/O (e.g., a synchronous JDBC call on a Vert.x event-loop thread), Quarkus will log "BlockedThreadChecker" warnings *and* possibly drop spans because the exporter never gets a chance to flush. Use `@Blocking` to move the work to a worker thread.

- **The OTLP exporter retries are aggressive; native image cold starts can drop the first batch.** The exporter caches and retries by default, but if your native binary exits within a few seconds (e.g., a Quarkus CLI command, a one-shot job), the in-flight batch is lost. Call `OpenTelemetrySdk.shutdown()` (or accept Quarkus's default shutdown flush) before exit. For one-shot jobs, set `quarkus.otel.bsp.export.timeout=5s` and `quarkus.otel.bsp.schedule.delay=500ms` to flush more eagerly.

- **`quarkus.profile` cascades.** Quarkus loads `application.properties`, then `application-<profile>.properties`, then `.env`, in that order. If you have a stale `application-local.properties` with an old endpoint, it silently overrides the committed config. Audit local property files when endpoints rotate.

- **`quarkus.otel.exporter.otlp.headers` is a comma-separated string, not a list.** Multiple headers join with commas: `X-API-Key=foo,X-Tenant=bar`. If a header value itself contains a comma, you have to escape it (use single-value Bearer tokens in practice and you'll never hit this). The OTel SDK's `OTEL_EXPORTER_OTLP_HEADERS` env var follows the same convention.
