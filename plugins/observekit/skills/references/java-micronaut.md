# Micronaut + ObserveKit (OpenTelemetry)

This reference covers integrating ObserveKit (OpenTelemetry-compatible backend) into a Micronaut 4.x application. For shared cross-language facts (endpoint URLs, auth headers, body caps, wire formats) see `./endpoints-and-auth.md`.

## 1. What this framework needs

Micronaut's canonical OpenTelemetry path is its **first-party `micronaut-tracing-opentelemetry` modules**, not the javaagent. The reason is that Micronaut performs **compile-time dependency injection and proxy generation via AOT**, so the bytecode the JVM loads has very few of the indirections the OTel javaagent expects to instrument. The agent still works — and you can use it — but you give up Micronaut's strongest selling point (no reflection, no runtime weaving, fast cold start, GraalVM native compatibility) and you don't actually get much more coverage than the compile-time modules already provide.

In practice:

- **Default: the Micronaut OTel modules** (`micronaut-tracing-opentelemetry-http`, `micronaut-tracing-opentelemetry-annotation`, `micronaut-tracing-opentelemetry-exporter-otlp`). They auto-instrument the Micronaut HTTP server, declarative HTTP client, Kafka, gRPC, JMS, R2DBC, and the `@NewSpan`/`@ContinueSpan`/`@WithSpan` annotations. Configuration lives in `application.yml`. Works in JIT and GraalVM native image modes.
- **Exception: the javaagent** — pick this only when you need broad coverage of a non-Micronaut library that doesn't have a Micronaut module (e.g., a niche JDBC driver, a legacy library you can't replace). Mixing is supported; the agent backs off where the SDK is configured.

## 2. Dependency declaration

Pinned to Micronaut 4.7.x and OTel SDK `1.43.0` / instrumentation BOM `2.10.0` as of writing — use the latest minor patch at integration time.

**Maven:**

```xml
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>io.opentelemetry</groupId>
      <artifactId>opentelemetry-bom</artifactId>
      <version>1.43.0</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>

<dependencies>
  <dependency>
    <groupId>io.micronaut.tracing</groupId>
    <artifactId>micronaut-tracing-opentelemetry-http</artifactId>
    <scope>compile</scope>
  </dependency>
  <dependency>
    <groupId>io.micronaut.tracing</groupId>
    <artifactId>micronaut-tracing-opentelemetry-annotation</artifactId>
    <scope>compile</scope>
  </dependency>
  <dependency>
    <groupId>io.micronaut.tracing</groupId>
    <artifactId>micronaut-tracing-opentelemetry-exporter-otlp</artifactId>
    <scope>compile</scope>
  </dependency>
  <!-- Optional: logs over OTLP (Logback bridge) -->
  <dependency>
    <groupId>io.opentelemetry.instrumentation</groupId>
    <artifactId>opentelemetry-logback-appender-1.0</artifactId>
    <version>2.10.0</version>
  </dependency>
</dependencies>
```

**Gradle (Kotlin DSL):**

```kotlin
dependencies {
    implementation(platform("io.opentelemetry:opentelemetry-bom:1.43.0"))

    implementation("io.micronaut.tracing:micronaut-tracing-opentelemetry-http")
    implementation("io.micronaut.tracing:micronaut-tracing-opentelemetry-annotation")
    implementation("io.micronaut.tracing:micronaut-tracing-opentelemetry-exporter-otlp")

    // Optional log bridge
    implementation("io.opentelemetry.instrumentation:opentelemetry-logback-appender-1.0:2.10.0")
}
```

**Gradle (Groovy):**

```groovy
dependencies {
    implementation platform("io.opentelemetry:opentelemetry-bom:1.43.0")

    implementation "io.micronaut.tracing:micronaut-tracing-opentelemetry-http"
    implementation "io.micronaut.tracing:micronaut-tracing-opentelemetry-annotation"
    implementation "io.micronaut.tracing:micronaut-tracing-opentelemetry-exporter-otlp"

    implementation "io.opentelemetry.instrumentation:opentelemetry-logback-appender-1.0:2.10.0"
}
```

Versions of the three Micronaut OTel modules are managed by the Micronaut Tracing BOM (which `micronaut-bom` pulls transitively in 4.x). You normally don't pin them explicitly — Micronaut's BOM resolves them. If you need to override, declare a dependency on `io.micronaut.tracing:micronaut-tracing-bom` and import it.

## 3. SDK init / config block (idiomatic, checked-in)

Micronaut reads `application.yml` (or `.properties`). The `otel` tree below is honored by `micronaut-tracing-opentelemetry-*`. Like every other framework in this guide, **only the placeholder** appears here — never the real key.

`src/main/resources/application.yml`:

```yaml
micronaut:
  application:
    name: my-service

otel:
  service:
    name: ${micronaut.application.name}
  exporter:
    otlp:
      enabled: true
      protocol: http/protobuf
      endpoint: https://observekit-api.expeed.com
      headers:
        X-API-Key: ${OBSERVEKIT_API_KEY}
        # Alternative: Authorization: Bearer ${OBSERVEKIT_API_KEY}
      timeout: 10s
      compression: gzip
  traces:
    sampler:
      type: parentbased_traceidratio
      probability: 1.0       # full sampling in dev; lower in prod (see Section 8)
  resource:
    attributes:
      service.namespace: ${OBSERVEKIT_NAMESPACE:default}
      deployment.environment: ${OBSERVEKIT_ENV:dev}
  instrumentation:
    http:
      server:
        exclude-paths: /health,/readiness,/liveness,/metrics
  http:
    server:
      enabled: true
    client:
      enabled: true
```

Notes:

- `${OBSERVEKIT_API_KEY}` is Micronaut's environment-variable placeholder syntax. Same precedence rules as Spring (env vars, `-D` system properties, config files).
- The Micronaut OTLP exporter module derives per-signal paths (`/v1/traces`, `/v1/metrics`, `/v1/logs`) from the base `endpoint` when `protocol: http/protobuf`. Don't append `/v1/traces` to the endpoint yourself — that breaks metrics and logs.
- Avoid `protocol: grpc` against the public HTTPS URL; gRPC port 4317 is for local direct exposure only.
- If you need both HTTP/protobuf and gRPC paths simultaneously for an obscure reason, configure separate exporters via `otel.exporter.otlp.traces`, `.metrics`, `.logs` sub-trees. 99% of the time you don't need this.

## 4. Launch flag

The Micronaut OTel modules **do not require a `-javaagent`** — instrumentation is wired at compile time via annotation processors.

### Standard `java -jar` (built by `./gradlew assemble` or `mvn package`)

```bash
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you> \
java -jar build/libs/my-service-0.1-all.jar
```

PowerShell equivalent (Windows):

```powershell
$env:OBSERVEKIT_API_KEY = '<paste-the-key-the-infra-team-gave-you>'
java -jar build/libs/my-service-0.1-all.jar
```

That's it. No javaagent flag, no `JAVA_TOOL_OPTIONS`. The OTLP exporter module picks up the `otel.*` keys from `application.yml` and starts shipping spans on startup.

### `./gradlew run` (dev loop)

`build.gradle.kts`:

```kotlin
tasks.named<JavaExec>("run") {
    environment("OBSERVEKIT_API_KEY", System.getenv("OBSERVEKIT_API_KEY") ?: "")
    environment("MICRONAUT_ENVIRONMENTS", "local")
}
```

Or just `MICRONAUT_ENVIRONMENTS=local OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you> ./gradlew run`.

PowerShell equivalent (Windows): `$env:MICRONAUT_ENVIRONMENTS='local'; $env:OBSERVEKIT_API_KEY='<paste-the-key-the-infra-team-gave-you>'; ./gradlew run`

### Micronaut Maven plugin

```bash
mvn mn:run -Dmicronaut.environments=local
```

`OBSERVEKIT_API_KEY` must be exported in the shell first.

### When you DO want the javaagent on top of Micronaut

Download it via `maven-dependency-plugin` or a Gradle configuration (same pattern as the Spring Boot reference), then:

```bash
java -javaagent:./build/agent/opentelemetry-javaagent.jar \
     -Dotel.instrumentation.common.default-enabled=false \
     -Dotel.instrumentation.jdbc.enabled=true \
     -jar build/libs/my-service-0.1-all.jar
```

`-Dotel.instrumentation.common.default-enabled=false` turns off all built-in agent instrumentations and lets you re-enable only the ones you actually want (here, JDBC). This avoids double-instrumenting the Micronaut HTTP layer.

### GraalVM native image

Build with `./gradlew nativeCompile` or `mvn -Dpackaging=native-image package`. The Micronaut OTel modules are GraalVM-compatible *because* they're compile-time. The javaagent is **not** compatible with native image — that's another reason to prefer the modules.

## 5. Local-dev secret file path

**Strategy:** activate a `local` environment via `MICRONAUT_ENVIRONMENTS=local`. Micronaut then loads `application-local.yml` on top of `application.yml`.

`src/main/resources/application-local.yml` (gitignored):

```yaml
# DO NOT COMMIT. Local-only secrets.
# Activated by MICRONAUT_ENVIRONMENTS=local
otel:
  exporter:
    otlp:
      headers:
        X-API-Key: <paste-the-key-the-infra-team-gave-you>
```

Activate one of these ways:

- `MICRONAUT_ENVIRONMENTS=local ./gradlew run`
- `mvn mn:run -Dmicronaut.environments=local`
- IntelliJ run config → "Environment variables" → `MICRONAUT_ENVIRONMENTS=local`

Add to `.gitignore`:

```gitignore
# OpenTelemetry / ObserveKit — local-only secrets
src/main/resources/application-local.yml
src/main/resources/application-local.properties
**/application-local.yml
**/application-local.properties
.env
.env.local
```

Alternative (no second file): export the env var directly. Micronaut's `${OBSERVEKIT_API_KEY}` placeholder resolves from process env:

```bash
export OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
./gradlew run
```

This is the simplest path for solo devs.

## 6. Custom span snippet

Two equivalent ways. Pick one per project and be consistent.

### A — Programmatic `Tracer`

```java
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;

import jakarta.inject.Singleton;

@Singleton
public class CheckoutService {

    private static final Tracer TRACER =
            GlobalOpenTelemetry.getTracer("com.example.checkout", "1.0.0");

    public Receipt checkout(Cart cart) {
        Span span = TRACER.spanBuilder("checkout")
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

### B — `@NewSpan` annotation (Micronaut-native)

```java
import io.micronaut.tracing.annotation.NewSpan;
import io.micronaut.tracing.annotation.SpanTag;
import jakarta.inject.Singleton;

@Singleton
public class CheckoutService {

    @NewSpan("checkout")
    public Receipt checkout(
            @SpanTag("cart.items") int items,
            @SpanTag("cart.total") double total,
            Cart cart) {
        return doCheckout(cart);
    }
}
```

`@NewSpan` is processed by the `micronaut-tracing-opentelemetry-annotation` module at compile time. Exceptions are recorded on the span automatically. This works in GraalVM native image. The standard `@WithSpan` from `opentelemetry-instrumentation-annotations` is also supported — pick whichever your team is more familiar with.

## 7. Log correlation snippet

Two strategies, same as Spring Boot.

### Strategy A — OTel Logback appender (logs shipped via OTLP `/v1/logs`)

Dependency (see Section 2):

```groovy
implementation "io.opentelemetry.instrumentation:opentelemetry-logback-appender-1.0:2.10.0"
```

`src/main/resources/logback.xml`:

```xml
<configuration>
  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder>
      <pattern>%d{HH:mm:ss.SSS} [%thread] %-5level %logger{36} trace_id=%X{trace_id} span_id=%X{span_id} - %msg%n</pattern>
    </encoder>
  </appender>

  <appender name="OTEL" class="io.opentelemetry.instrumentation.logback.appender.v1_0.OpenTelemetryAppender">
    <captureExperimentalAttributes>true</captureExperimentalAttributes>
    <captureMdcAttributes>*</captureMdcAttributes>
  </appender>

  <root level="INFO">
    <appender-ref ref="CONSOLE"/>
    <appender-ref ref="OTEL"/>
  </root>
</configuration>
```

The Micronaut OTel module populates the `trace_id` / `span_id` MDC keys automatically while a span is current.

### Strategy A' — Log4j2 variant

If you've swapped Logback for Log4j2 via `micronaut-logging-log4j2`:

```xml
<dependency>
  <groupId>io.opentelemetry.instrumentation</groupId>
  <artifactId>opentelemetry-log4j-appender-2.17</artifactId>
  <version>2.10.0</version>
</dependency>
```

`log4j2.xml`:

```xml
<Configuration>
  <Appenders>
    <Console name="Console" target="SYSTEM_OUT">
      <PatternLayout pattern="%d{HH:mm:ss.SSS} %-5level [trace_id=%X{trace_id} span_id=%X{span_id}] %logger{36} - %msg%n"/>
    </Console>
    <OpenTelemetry name="OTEL">
      <captureContextDataAttributes>*</captureContextDataAttributes>
    </OpenTelemetry>
  </Appenders>
  <Loggers>
    <Root level="info">
      <AppenderRef ref="Console"/>
      <AppenderRef ref="OTEL"/>
    </Root>
  </Loggers>
</Configuration>
```

### Strategy B — MDC pattern only

Drop the OTel appender entirely; let your existing log shipper (Fluent Bit, Vector, Loki, etc.) pick up stdout. Just keep `%X{trace_id}` and `%X{span_id}` in the layout pattern. Trace IDs match the spans ObserveKit already has — correlation works without any OTLP log traffic.

## 8. Sampling and exclusion config keys

### `application.yml`

```yaml
otel:
  traces:
    sampler:
      type: parentbased_traceidratio
      probability: 0.25
  instrumentation:
    http:
      server:
        exclude-paths: /health,/readiness,/liveness,/metrics
```

### Env-var / system-property override (works everywhere)

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
OTEL_INSTRUMENTATION_HTTP_SERVER_EXCLUDE_PATHS=/health,/readiness,/liveness,/metrics
```

Same recommended profile as elsewhere: `always_on` in dev, `parentbased_traceidratio` at 0.1–0.5 in prod. Always exclude k8s probe endpoints and metric-scrape endpoints.

If you've added Micrometer for metrics, watch out — Micronaut's Micrometer integration can emit its own scrape endpoint at `/metrics`. Include it in `exclude-paths` so health checkers and scrapers don't generate trace noise.

## 9. Common pitfalls in this framework

- **Compile-time AOT can miss instrumentations for libraries added late in the build.** Micronaut's annotation processors run at `compileJava`. If you add a new dependency that ships its own Micronaut module (e.g., `micronaut-kafka`) and don't do a clean rebuild, the OTel hooks for it may not be generated. Fix: `./gradlew clean build` after any dependency change that adds Micronaut modules.

- **GraalVM native image needs explicit reflection config for any *manual* OTel API you call from native paths.** The Micronaut OTel modules ship native-image metadata, so the auto-instrumented HTTP/Kafka/etc. paths Just Work. But if you call `GlobalOpenTelemetry.getTracer(...)` from a code path that's only reachable via reflection (e.g., a `@Reflective` annotated class), you may need to add reflection hints. Use `@Reflective` and `@RegisterReflection` annotations on the involved classes.

- **The javaagent fights with Micronaut AOT.** If you add the javaagent *and* the Micronaut OTel modules, you'll see double spans for HTTP server requests — once from the agent's Servlet/Netty instrumentation, once from `micronaut-tracing-opentelemetry-http`. Pick one. Almost always: the Micronaut modules.

- **`@NewSpan` on a `private` method does nothing.** Micronaut AOP only proxies non-private, non-final methods on beans. A `@NewSpan` on a private helper compiles but produces no span. Symptoms: missing spans for some calls in a long chain. Fix: make the method package-private or public, and call it through the bean reference, not a `this.` self-call (self-calls bypass the proxy too).

- **`MICRONAUT_ENVIRONMENTS=local` vs. `--environments=local`.** Both work, but a stale `application.yml` line setting `micronaut.environments: [prod]` will override the env var. Audit any committed environment defaults — keep `application.yml` environment-agnostic.

- **Compression default differs from Spring.** The Micronaut OTLP exporter defaults to `none` for compression; the Spring starter defaults to `gzip`. Explicitly set `otel.exporter.otlp.compression: gzip` to stay below the 10 MB body cap when you have chatty traces.
