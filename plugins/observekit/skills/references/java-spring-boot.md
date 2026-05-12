# Spring Boot + ObserveKit (OpenTelemetry)

This reference covers integrating ObserveKit (OpenTelemetry-compatible backend) into a Spring Boot 2.7+ or 3.x application. For shared cross-language facts (endpoint URLs, auth headers, body caps, wire formats) see `./endpoints-and-auth.md`.

## 1. What this framework needs

Spring Boot has two canonical OpenTelemetry integration paths:

1. **The OpenTelemetry Java agent (`opentelemetry-javaagent.jar`)** — zero code changes, auto-instruments Spring MVC/WebFlux, RestTemplate, WebClient, JDBC, JPA, Kafka, JMS, Redis (Lettuce/Jedis), MongoDB, gRPC, Logback/Log4j2 MDC, and ~120 other libraries. This is the **default recommended path** for Spring Boot because it gets you everything for free and survives Spring Boot upgrades cleanly. Configuration is via JVM system properties or environment variables.

2. **The OpenTelemetry Spring Boot Starter (`io.opentelemetry.instrumentation:opentelemetry-spring-boot-starter`)** — pulls SDK config into `application.yml`, exposes OTel beans (`Tracer`, `Meter`, `OpenTelemetry`) for DI, but covers a **smaller set** of instrumentations than the agent (no JDBC, no Kafka, no Lettuce out of the box — you opt in per starter). Pick this when you cannot touch the JVM launch flags (e.g., a managed PaaS where you don't control `JAVA_TOOL_OPTIONS`), or when you specifically want OTel configured through Spring's property system and conditional beans.

**Default in this guide: the javaagent.** The starter section below is provided for the case where the agent is not viable. Mixing the two is supported (the agent backs off when it detects the SDK on the classpath) but rarely worth the complexity.

## 2. Dependency declaration

Pinned to `2.10.0` of the OpenTelemetry Java agent / instrumentation BOM as of writing — use the latest minor patch (`2.x.y`) at integration time. The agent jar moves quickly and bug fixes land monthly.

### Option A — Javaagent (recommended)

The agent is **not a code dependency** — it's a runtime jar. You either:

- Download it once and commit it to the repo (small teams, simple), or
- Pull it at build time via Maven `dependency:get` / Gradle resolution into `build/agent/`.

**Maven (build-time download via `maven-dependency-plugin`):**

```xml
<build>
  <plugins>
    <plugin>
      <groupId>org.apache.maven.plugins</groupId>
      <artifactId>maven-dependency-plugin</artifactId>
      <version>3.6.1</version>
      <executions>
        <execution>
          <id>fetch-otel-agent</id>
          <phase>generate-resources</phase>
          <goals><goal>copy</goal></goals>
          <configuration>
            <artifactItems>
              <artifactItem>
                <groupId>io.opentelemetry.javaagent</groupId>
                <artifactId>opentelemetry-javaagent</artifactId>
                <!-- Use the latest 2.x patch -->
                <version>2.10.0</version>
                <type>jar</type>
                <overWrite>true</overWrite>
                <outputDirectory>${project.build.directory}/agent</outputDirectory>
                <destFileName>opentelemetry-javaagent.jar</destFileName>
              </artifactItem>
            </artifactItems>
          </configuration>
        </execution>
      </executions>
    </plugin>
  </plugins>
</build>
```

**Gradle (Kotlin DSL):**

```kotlin
val otelAgent by configurations.creating

dependencies {
    // Use the latest 2.x patch — javaagent moves often
    otelAgent("io.opentelemetry.javaagent:opentelemetry-javaagent:2.10.0")
}

val copyOtelAgent = tasks.register<Copy>("copyOtelAgent") {
    from(otelAgent)
    into(layout.buildDirectory.dir("agent"))
    rename { "opentelemetry-javaagent.jar" }
}

tasks.named("bootRun") { dependsOn(copyOtelAgent) }
tasks.named("processResources") { dependsOn(copyOtelAgent) }
```

**Gradle (Groovy):**

```groovy
configurations { otelAgent }

dependencies {
    otelAgent "io.opentelemetry.javaagent:opentelemetry-javaagent:2.10.0"
}

task copyOtelAgent(type: Copy) {
    from configurations.otelAgent
    into "$buildDir/agent"
    rename { 'opentelemetry-javaagent.jar' }
}

bootRun.dependsOn copyOtelAgent
```

If you want to add a few **manual spans** in code alongside the agent, also pull in the annotation jar (matched to the agent version; the agent provides the implementation at runtime):

```xml
<dependency>
  <groupId>io.opentelemetry.instrumentation</groupId>
  <artifactId>opentelemetry-instrumentation-annotations</artifactId>
  <version>2.10.0</version>
</dependency>
```

```groovy
implementation "io.opentelemetry.instrumentation:opentelemetry-instrumentation-annotations:2.10.0"
```

### Option B — Spring Boot starter (no agent)

```xml
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>io.opentelemetry.instrumentation</groupId>
      <artifactId>opentelemetry-instrumentation-bom</artifactId>
      <version>2.10.0</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>

<dependencies>
  <dependency>
    <groupId>io.opentelemetry.instrumentation</groupId>
    <artifactId>opentelemetry-spring-boot-starter</artifactId>
  </dependency>
  <!-- OTLP exporter is wired by the starter, but pin it via the BOM. -->
  <dependency>
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-exporter-otlp</artifactId>
  </dependency>
  <!-- Optional: log appender bridging Logback -> OTel logs. -->
  <dependency>
    <groupId>io.opentelemetry.instrumentation</groupId>
    <artifactId>opentelemetry-logback-appender-1.0</artifactId>
  </dependency>
</dependencies>
```

```kotlin
dependencies {
    implementation(platform("io.opentelemetry.instrumentation:opentelemetry-instrumentation-bom:2.10.0"))
    implementation("io.opentelemetry.instrumentation:opentelemetry-spring-boot-starter")
    implementation("io.opentelemetry:opentelemetry-exporter-otlp")
    implementation("io.opentelemetry.instrumentation:opentelemetry-logback-appender-1.0")
}
```

Pin the **BOM** version — let it drive `opentelemetry-api`, `opentelemetry-context`, and `opentelemetry-sdk` so they stay in sync. As of writing the latest BOM is `2.10.0`; bump to the latest minor patch when integrating.

## 3. SDK init / config block (idiomatic, checked-in)

Spring Boot uses `application.yml` (or `application.properties`). The block below is **safe to check in** — it contains only placeholders, never the actual API key. The OpenTelemetry SDK and javaagent both honor the `otel.*` property tree out of the box.

`src/main/resources/application.yml`:

```yaml
spring:
  application:
    name: my-service                       # becomes the OTel service.name

otel:
  # Wire format: protobuf-over-HTTP is the default we use against ObserveKit.
  exporter:
    otlp:
      protocol: http/protobuf
      endpoint: https://observekit-api.expeed.com
      # Per-signal endpoints are optional; the SDK will derive /v1/traces, /v1/metrics, /v1/logs
      # from the base endpoint above when protocol=http/protobuf.
      headers:
        X-API-Key: ${OBSERVEKIT_API_KEY}
        # Alternative: Authorization: Bearer ${OBSERVEKIT_API_KEY}
      timeout: 10s
      compression: gzip
  resource:
    attributes:
      service.name: ${spring.application.name}
      service.namespace: ${OBSERVEKIT_NAMESPACE:default}
      deployment.environment: ${OBSERVEKIT_ENV:dev}
  traces:
    sampler:
      type: parentbased_traceidratio
      arg: 1.0                             # full sampling in dev; lower in prod (see Section 8)
  logs:
    exporter: otlp
  metrics:
    exporter: otlp
  instrumentation:
    http:
      server:
        exclude-paths: /healthz,/readyz,/actuator/health,/actuator/prometheus
```

Notes:

- `${OBSERVEKIT_API_KEY}` is Spring's standard property placeholder. It resolves from environment variables and JVM system properties by default — no extra configuration needed.
- If you prefer Bearer auth, swap `X-API-Key` for `Authorization: Bearer ${OBSERVEKIT_API_KEY}`. Both are accepted by ObserveKit (see `./endpoints-and-auth.md`).
- The `otel.exporter.otlp.endpoint` key is read identically by the javaagent and the SDK starter, so this block works for either Option A or Option B.
- Never set `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` against the public HTTPS endpoint — that endpoint speaks HTTP/protobuf. gRPC port 4317 is for direct local exposure only.
- The 10 MB body cap is enforced server-side. If you push very large batches, lower `otel.bsp.max.export.batch.size` (default 512) to stay well under it.

## 4. Launch flag

The `-javaagent` flag tells the JVM to instrument all classes at load time.

### Generic shape

```bash
java -javaagent:./build/agent/opentelemetry-javaagent.jar \
     -Dotel.service.name=my-service \
     -Dotel.exporter.otlp.endpoint=https://observekit-api.expeed.com \
     -Dotel.exporter.otlp.protocol=http/protobuf \
     -Dotel.exporter.otlp.headers="X-API-Key=$OBSERVEKIT_API_KEY" \
     -jar build/libs/my-service.jar
```

PowerShell equivalent (Windows):

```powershell
java -javaagent:./build/agent/opentelemetry-javaagent.jar `
     -Dotel.service.name=my-service `
     -Dotel.exporter.otlp.endpoint=https://observekit-api.expeed.com `
     -Dotel.exporter.otlp.protocol=http/protobuf `
     "-Dotel.exporter.otlp.headers=X-API-Key=$env:OBSERVEKIT_API_KEY" `
     -jar build/libs/my-service.jar
```

### Maven Spring Boot plugin

```xml
<plugin>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-maven-plugin</artifactId>
  <configuration>
    <jvmArguments>
      -javaagent:${project.build.directory}/agent/opentelemetry-javaagent.jar
    </jvmArguments>
  </configuration>
</plugin>
```

Then `mvn spring-boot:run` picks up the agent. The `headers` and `endpoint` come from `application.yml` (Section 3) so you only need the `-javaagent` flag here.

### Gradle `bootRun`

```kotlin
tasks.named<org.springframework.boot.gradle.tasks.run.BootRun>("bootRun") {
    jvmArgs = listOf(
        "-javaagent:${layout.buildDirectory.get()}/agent/opentelemetry-javaagent.jar"
    )
}
```

Groovy DSL:

```groovy
bootRun {
    jvmArgs = ["-javaagent:${buildDir}/agent/opentelemetry-javaagent.jar"]
}
```

### Production / container

In a Dockerfile, copy the agent into the image and use `JAVA_TOOL_OPTIONS` so you don't have to change the application's `ENTRYPOINT`:

```dockerfile
COPY build/agent/opentelemetry-javaagent.jar /opt/otel/agent.jar
ENV JAVA_TOOL_OPTIONS="-javaagent:/opt/otel/agent.jar"
ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
ENV OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
ENV OTEL_RESOURCE_ATTRIBUTES=service.name=my-service,deployment.environment=prod
# OBSERVEKIT_API_KEY is injected at runtime by the orchestrator (k8s Secret, ECS task role, etc.);
# the OTel SDK reads OTEL_EXPORTER_OTLP_HEADERS from the env at startup. Do NOT bake the headers
# into a Dockerfile `ENV` with `${VAR}` — Dockerfile ENV expansion happens at BUILD time, so
# `${OBSERVEKIT_API_KEY}` would resolve to whatever was in the build env (usually empty).
# Inject both `OBSERVEKIT_API_KEY` and the assembled `OTEL_EXPORTER_OTLP_HEADERS` from the
# orchestrator's runtime env block — see the k8s / docker-compose snippets below.
```

In a Kubernetes Deployment, inject both vars in the container's `env:` block (Pod env supports `$(VAR)` substitution between entries declared in the same block):

```yaml
env:
  - name: OBSERVEKIT_API_KEY
    valueFrom:
      secretKeyRef:
        name: observekit
        key: api-key
  - name: OTEL_EXPORTER_OTLP_HEADERS
    value: "X-API-Key=$(OBSERVEKIT_API_KEY)"
```

In `docker-compose.yml`:

```yaml
services:
  my-service:
    environment:
      OBSERVEKIT_API_KEY: ${OBSERVEKIT_API_KEY}    # from the shell / .env at compose-up time
      OTEL_EXPORTER_OTLP_HEADERS: "X-API-Key=${OBSERVEKIT_API_KEY}"
```

`JAVA_TOOL_OPTIONS` is honored by `java`, `java -jar`, Spring Boot's `spring-boot:run`, Gradle's `bootRun`, and even nested JVMs — so it propagates correctly through wrappers.

## 5. Local-dev secret file path

**Strategy:** the API key never lives in `application.yml`. It lives in `application-local.yml`, which is gitignored and activated by the `local` profile.

`src/main/resources/application-local.yml` (gitignored):

```yaml
# DO NOT COMMIT. Local-only secrets.
# spring.profiles.active=local is set via SPRING_PROFILES_ACTIVE env var or run config.
otel:
  exporter:
    otlp:
      headers:
        X-API-Key: <paste-the-key-the-infra-team-gave-you>
```

Activate it via one of:

- Environment variable: `SPRING_PROFILES_ACTIVE=local` before `mvn spring-boot:run` / `gradle bootRun`.
- IntelliJ run config → "Active profiles" → `local`.
- A `spring.profiles.active=local` line in `application.yml` itself — but only do this in a developer-only `application-default.yml`, never in checked-in `application.yml`.

Add to `.gitignore` (at repo root):

```gitignore
# OpenTelemetry / ObserveKit — local-only secrets
src/main/resources/application-local.yml
src/main/resources/application-local.properties
**/application-local.yml
**/application-local.properties
.env
.env.local
```

For developers who'd rather not deal with profiles, the alternative is to set the env var directly in their shell:

```bash
# ~/.zshrc or ~/.bashrc — developer-only
export OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
```

Spring's `${OBSERVEKIT_API_KEY}` placeholder in the committed `application.yml` will pick it up. No second file needed.

## 6. Custom span snippet

Two equivalent ways. Pick one per project and be consistent.

### A — Programmatic `Tracer` (works with both the agent and the starter)

```java
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;

@Service
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

The agent injects `GlobalOpenTelemetry` at startup; with the Spring Boot starter you can `@Autowired Tracer tracer` instead.

### B — `@WithSpan` annotation (cleaner; requires `opentelemetry-instrumentation-annotations`)

```java
import io.opentelemetry.instrumentation.annotations.SpanAttribute;
import io.opentelemetry.instrumentation.annotations.WithSpan;

@Service
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

`@WithSpan` is processed by the javaagent automatically. With the Spring Boot starter you also get annotation processing — no extra wiring needed. Exceptions thrown out of the method are recorded on the span and the status is set to ERROR.

## 7. Log correlation snippet

Two strategies, pick one:

### Strategy A — OTel appender (logs are shipped to ObserveKit's `/v1/logs`)

Dependency:

```xml
<dependency>
  <groupId>io.opentelemetry.instrumentation</groupId>
  <artifactId>opentelemetry-logback-appender-1.0</artifactId>
  <version>2.10.0</version>
</dependency>
```

`src/main/resources/logback-spring.xml`:

```xml
<configuration>
  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder>
      <!-- trace_id / span_id are auto-injected into MDC by the agent. -->
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

With the javaagent, the OTel appender is auto-installed — you can drop the explicit `<appender>` block above and the agent injects it. Setting `otel.instrumentation.logback-appender.experimental-log-attributes=true` is recommended.

### Strategy B — MDC pattern only (logs stay in stdout, correlation via trace_id)

If you ship logs through Fluent Bit / Vector / a sidecar instead of via OTLP, just keep the MDC keys in the pattern. The agent populates `trace_id` and `span_id` in MDC automatically — you don't need to write any glue:

```xml
<pattern>%d{HH:mm:ss.SSS} %-5level [trace_id=%X{trace_id} span_id=%X{span_id}] %logger{36} - %msg%n</pattern>
```

The downstream log collector parses these fields, and the trace IDs match the traces ObserveKit already has — correlation works either way.

## 8. Sampling and exclusion config keys

### Javaagent (JVM args or env vars)

```bash
-Dotel.traces.sampler=parentbased_traceidratio
-Dotel.traces.sampler.arg=0.25
-Dotel.instrumentation.http.server.exclude-paths=/healthz,/readyz,/actuator/health,/actuator/prometheus,/metrics
```

Or as env vars:

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
OTEL_INSTRUMENTATION_HTTP_SERVER_EXCLUDE_PATHS=/healthz,/readyz,/actuator/health,/actuator/prometheus,/metrics
```

### Spring Boot starter (`application.yml`)

```yaml
otel:
  traces:
    sampler:
      type: parentbased_traceidratio
      arg: 0.25
  instrumentation:
    http:
      server:
        exclude-paths: /healthz,/readyz,/actuator/health,/actuator/prometheus,/metrics
      client:
        # If your service polls a noisy upstream you don't care about, exclude it client-side:
        capture-headers:
          request: []
          response: []
```

### Recommended profile

- **Dev:** `sampler=always_on` (or `sampler.arg=1.0`) — see everything.
- **Staging:** `parentbased_traceidratio` at `0.5`.
- **Prod:** `parentbased_traceidratio` at `0.1` for high-RPS services, `1.0` for low-RPS services where every error matters.

Always exclude `/healthz`, `/readyz`, and `/actuator/*` — these run every few seconds from k8s probes and Prometheus, and they generate enormous trace volume for zero diagnostic value.

## 9. Common pitfalls in this framework

- **Spring Boot DevTools restarts can break the agent.** When DevTools triggers a hot restart, it spawns a new classloader inside the same JVM. The agent has already instrumented the *original* classloader, so the new beans bypass instrumentation. Symptoms: traces stop appearing after the first hot reload. Fix: disable DevTools restart for OTel-instrumented runs (`spring.devtools.restart.enabled=false`), or use full restarts during local debugging.

- **Reactive (`WebFlux`) context propagation needs `Context.taskWrapping` for thread hand-offs.** The agent handles Reactor and the standard schedulers correctly, but if you've written custom `Schedulers.fromExecutor(...)` with a raw `ExecutorService`, span context is lost when work hops threads. Wrap the executor with `io.opentelemetry.context.Context.taskWrapping(executor)`.

- **`@Async` methods need explicit context propagation when using a custom `TaskExecutor`.** The agent instruments the default `SimpleAsyncTaskExecutor` and `ThreadPoolTaskExecutor`, but a hand-rolled `Executor` bean will drop context. Either use the Spring-provided executors or wrap with `Context.taskWrapping(...)`.

- **Shaded jars (`spring-boot:repackage`) sometimes confuse the agent's class-discovery.** If you've custom-shaded an OTel API class into your fat jar (rare, but happens with Maven Shade configs that don't exclude `io.opentelemetry.*`), the agent sees two copies of the same class and silently disables instrumentation. Exclude `io.opentelemetry.**` from any Shade relocation.

- **`actuator/prometheus` doubles your metric pipeline.** If you have both Micrometer + Prometheus *and* OTel metrics enabled, every metric is exported twice (Prometheus scrape + OTLP push). Pick one. The clean Spring Boot 3 approach is to use Micrometer's OTel registry (`micrometer-registry-otlp`) and turn off the Prometheus endpoint, or vice versa.

- **`application-local.yml` precedence.** Spring loads `application.yml` first, then `application-<profile>.yml` overrides. If a developer has an *older* `application-local.yml` that sets `otel.exporter.otlp.endpoint` to a stale URL, it silently overrides the committed config. When ObserveKit endpoints change, post a notice and have devs delete their local override.
