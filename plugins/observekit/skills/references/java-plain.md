# Plain Java (no framework) + ObserveKit (OpenTelemetry)

This reference covers integrating ObserveKit (OpenTelemetry-compatible backend) into a plain Java application — one that does not use Spring Boot, Micronaut, or Quarkus. Think: a CLI tool, a batch job, a small HTTP server built on `com.sun.net.httpserver`, a Jetty/Undertow embedded server, a Kafka consumer in a `main()` method, or any handwired service. For shared cross-language facts (endpoint URLs, auth headers, body caps, wire formats) see `./endpoints-and-auth.md`.

## 1. What this framework needs

The canonical OTel path for plain Java is the **OpenTelemetry Java agent (`opentelemetry-javaagent.jar`)**. It auto-instruments ~120 libraries out of the box — JDBC drivers, Apache HttpClient, OkHttp, Jetty/Tomcat/Undertow embedded, Netty, gRPC, Kafka, the JDK's `HttpClient`, JMS, MongoDB, Redis (Lettuce/Jedis), Logback/Log4j2 MDC injection — without any code changes. Because there's no framework doing build-time bytecode generation, there's no conflict with the agent. The agent is the simplest, highest-coverage option.

Two cases where you might **not** use the agent:

1. **You don't control the JVM launch.** E.g., your code is delivered as a library to a host you can't pass `-javaagent` to. In that case, fall back to the **programmatic SDK** — instantiate `OpenTelemetrySdk` yourself in `main()`. You lose auto-instrumentation; manual spans only.
2. **GraalVM native image.** The agent doesn't work in native image. Use the programmatic SDK plus the OTel native-image-friendly modules.

Default in this guide: the javaagent. The programmatic SDK section is provided for the cases above.

## 2. Dependency declaration

Pinned to `2.10.0` of the OpenTelemetry Java agent / instrumentation BOM as of writing. Use the latest minor patch at integration time.

### Option A — Javaagent (recommended)

The agent is **not a runtime code dependency** — it's a sidecar jar you attach to the JVM. You either:

- Download it once and commit to the repo (small / private codebases), or
- Pull at build time via Maven / Gradle into a known location.

**Maven (download at build time):**

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
    otelAgent("io.opentelemetry.javaagent:opentelemetry-javaagent:2.10.0")
}

tasks.register<Copy>("copyOtelAgent") {
    from(otelAgent)
    into(layout.buildDirectory.dir("agent"))
    rename { "opentelemetry-javaagent.jar" }
}

tasks.named("run") { dependsOn("copyOtelAgent") }
```

For **manual spans alongside the agent**, also pull in:

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

The annotation jar is API-only; the agent supplies the runtime implementation when present.

### Option B — Programmatic SDK (no agent)

When the agent isn't viable:

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
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-api</artifactId>
  </dependency>
  <dependency>
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-context</artifactId>
  </dependency>
  <dependency>
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-sdk</artifactId>
  </dependency>
  <dependency>
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-exporter-otlp</artifactId>
  </dependency>
  <!-- Autoconfigure reads env vars / system props — saves writing the bootstrap by hand -->
  <dependency>
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-sdk-extension-autoconfigure</artifactId>
  </dependency>
</dependencies>
```

```kotlin
dependencies {
    implementation(platform("io.opentelemetry:opentelemetry-bom:1.43.0"))
    implementation("io.opentelemetry:opentelemetry-api")
    implementation("io.opentelemetry:opentelemetry-context")
    implementation("io.opentelemetry:opentelemetry-sdk")
    implementation("io.opentelemetry:opentelemetry-exporter-otlp")
    implementation("io.opentelemetry:opentelemetry-sdk-extension-autoconfigure")
}
```

Pin via the BOM. As of writing the latest BOM is `1.43.0`; use the latest minor patch at integration time.

## 3. SDK init / config block (idiomatic, checked-in)

Plain Java has no `application.yml`. The agent reads JVM system properties (`-D...`) and environment variables. The **environment variable convention is the cleanest checked-in artifact** because it works identically in shell scripts, Dockerfiles, systemd unit files, k8s manifests, and CI pipelines.

### Env var form (preferred, checked in as `.env.example` / run script)

`.env.example` at the project root (this file IS checked in — it documents the variable surface, no real key):

```bash
# ObserveKit / OpenTelemetry — environment variables read by the OTel javaagent.
# Copy this to .env and fill in real values. .env is gitignored.

# Local-dev only. Real key from infra team. Never commit a real value.
OTEL_SERVICE_NAME=my-service
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
# NOTE: dotenv-java does NOT expand ${VAR} references inside .env values. For the API key,
# either set BOTH OBSERVEKIT_API_KEY (the raw key) AND OTEL_EXPORTER_OTLP_HEADERS with the
# key already substituted in (e.g. `OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=<paste-the-key-the-infra-team-gave-you>`),
# OR use shell-export so the shell expands $OBSERVEKIT_API_KEY before the JVM starts.
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=<paste-the-key-the-infra-team-gave-you>
# Alternative: OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <paste-the-key-the-infra-team-gave-you>

OTEL_EXPORTER_OTLP_TIMEOUT=10000
OTEL_EXPORTER_OTLP_COMPRESSION=gzip

OTEL_RESOURCE_ATTRIBUTES=service.name=my-service,service.namespace=default,deployment.environment=dev

# Sampling
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=1.0

# HTTP server: don't trace health endpoints
OTEL_INSTRUMENTATION_HTTP_SERVER_EXCLUDE_PATHS=/healthz,/readyz,/metrics

# The real key — set in .env or your shell, NEVER commit:
# OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
```

### System-property form (alternative — same keys, different syntax)

```bash
java -javaagent:./build/agent/opentelemetry-javaagent.jar \
     -Dotel.service.name=my-service \
     -Dotel.exporter.otlp.protocol=http/protobuf \
     -Dotel.exporter.otlp.endpoint=https://observekit-api.expeed.com \
     -Dotel.exporter.otlp.headers="X-API-Key=$OBSERVEKIT_API_KEY" \
     -Dotel.exporter.otlp.compression=gzip \
     -Dotel.traces.sampler=parentbased_traceidratio \
     -Dotel.traces.sampler.arg=1.0 \
     -Dotel.instrumentation.http.server.exclude-paths=/healthz,/readyz,/metrics \
     -jar build/libs/my-service.jar
```

PowerShell equivalent (Windows):

```powershell
java -javaagent:./build/agent/opentelemetry-javaagent.jar `
     -Dotel.service.name=my-service `
     -Dotel.exporter.otlp.protocol=http/protobuf `
     -Dotel.exporter.otlp.endpoint=https://observekit-api.expeed.com `
     "-Dotel.exporter.otlp.headers=X-API-Key=$env:OBSERVEKIT_API_KEY" `
     -Dotel.exporter.otlp.compression=gzip `
     -Dotel.traces.sampler=parentbased_traceidratio `
     -Dotel.traces.sampler.arg=1.0 `
     -Dotel.instrumentation.http.server.exclude-paths=/healthz,/readyz,/metrics `
     -jar build/libs/my-service.jar
```

Mapping rule: `OTEL_FOO_BAR_BAZ` (env) ↔ `-Dotel.foo.bar.baz` (system property). The agent and SDK accept either; env vars win over system properties if both are set.

### Programmatic SDK init (Option B only)

If you went with Option B (no agent), bootstrap in `main()`:

```java
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.autoconfigure.AutoConfiguredOpenTelemetrySdk;

public class Application {
    public static void main(String[] args) {
        // Reads OTEL_* env vars and -Dotel.* system properties.
        OpenTelemetrySdk sdk = AutoConfiguredOpenTelemetrySdk.initialize()
                .getOpenTelemetrySdk();

        Runtime.getRuntime().addShutdownHook(new Thread(() -> sdk.close()));

        // ... your application code ...
    }
}
```

`AutoConfiguredOpenTelemetrySdk` reads exactly the same `OTEL_*` env vars the javaagent does, so the `.env.example` above is the single source of truth across both paths.

## 4. Launch flag

### Vanilla `java -jar` with the agent

```bash
java -javaagent:./build/agent/opentelemetry-javaagent.jar \
     -jar build/libs/my-service.jar
```

All `OTEL_*` env vars are picked up from the surrounding shell. In Docker / k8s, set them on the container; in systemd, set them in `[Service] Environment=`.

### Wrapping via `JAVA_TOOL_OPTIONS`

For systems where you can't edit the `java` command (e.g., a script you don't own, or you just want the same instrumentation for every JVM invocation in this shell):

```bash
export JAVA_TOOL_OPTIONS="-javaagent:/opt/otel/agent.jar"
export OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_HEADERS="X-API-Key=$OBSERVEKIT_API_KEY"

./run-my-app.sh
```

PowerShell equivalent (Windows):

```powershell
$env:JAVA_TOOL_OPTIONS = "-javaagent:C:\opt\otel\agent.jar"
$env:OTEL_EXPORTER_OTLP_ENDPOINT = "https://observekit-api.expeed.com"
$env:OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
$env:OTEL_EXPORTER_OTLP_HEADERS = "X-API-Key=$env:OBSERVEKIT_API_KEY"

./run-my-app.ps1
```

`JAVA_TOOL_OPTIONS` is honored by every `java` invocation (including ones nested inside wrapper scripts), which is exactly what you want — and exactly what you don't want if you only intend to instrument one specific process. Pick `-javaagent` vs `JAVA_TOOL_OPTIONS` based on scope.

### Maven exec plugin

```bash
mvn exec:java -Dexec.mainClass=com.example.Application \
     -Dexec.args="-javaagent:target/agent/opentelemetry-javaagent.jar"
```

Or configure once in `pom.xml`:

```xml
<plugin>
  <groupId>org.codehaus.mojo</groupId>
  <artifactId>exec-maven-plugin</artifactId>
  <configuration>
    <executable>java</executable>
    <arguments>
      <argument>-javaagent:${project.build.directory}/agent/opentelemetry-javaagent.jar</argument>
      <argument>-jar</argument>
      <argument>${project.build.directory}/${project.build.finalName}.jar</argument>
    </arguments>
  </configuration>
</plugin>
```

### Gradle `JavaExec` task

```kotlin
tasks.named<JavaExec>("run") {
    mainClass.set("com.example.Application")
    classpath = sourceSets["main"].runtimeClasspath
    jvmArgs("-javaagent:${layout.buildDirectory.get()}/agent/opentelemetry-javaagent.jar")
    environment("OBSERVEKIT_API_KEY", System.getenv("OBSERVEKIT_API_KEY") ?: "")
}
```

### Docker

```dockerfile
FROM eclipse-temurin:21-jre
COPY build/agent/opentelemetry-javaagent.jar /opt/otel/agent.jar
COPY build/libs/my-service.jar /app/my-service.jar

ENV JAVA_TOOL_OPTIONS="-javaagent:/opt/otel/agent.jar"
ENV OTEL_SERVICE_NAME=my-service
ENV OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
# OBSERVEKIT_API_KEY injected at runtime — never baked in
ENV OTEL_EXPORTER_OTLP_HEADERS="X-API-Key=${OBSERVEKIT_API_KEY}"

ENTRYPOINT ["java", "-jar", "/app/my-service.jar"]
```

## 5. Local-dev secret file path

Plain Java has no convention for environment files, so we adopt one. Two common patterns:

### Option 1 — `.env` + a small dotenv library

Dependency:

```xml
<dependency>
  <groupId>io.github.cdimascio</groupId>
  <artifactId>dotenv-java</artifactId>
  <version>3.0.2</version>
</dependency>
```

```groovy
implementation "io.github.cdimascio:dotenv-java:3.0.2"
```

`.env` at project root (gitignored):

```bash
# DO NOT COMMIT
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
```

Load in `main()` *before* SDK init (the SDK reads `System.getenv`, so populate process env via system properties as a bridge, since Java doesn't expose a public API to mutate the env directly):

```java
import io.github.cdimascio.dotenv.Dotenv;

public class Application {
    public static void main(String[] args) {
        Dotenv.configure().ignoreIfMissing().load().entries().forEach(e -> {
            // Forward .env to system properties so OTel auto-config sees them.
            // System.setProperty(key, value) is safe and visible to OTel.
            if (System.getProperty(e.getKey()) == null && System.getenv(e.getKey()) == null) {
                System.setProperty(e.getKey(), e.getValue());
            }
        });

        // Now bootstrap OTel (or just rely on the agent which is already running).
        // ... your code ...
    }
}
```

This works because the OTel SDK and javaagent **both** consult `System.getProperty` after `System.getenv` — anything you set as a system property is picked up. The agent, however, reads env vars at *agent startup*, which is before `main()`. So if you're using the agent, **do not** rely on dotenv-in-main; use the shell-export approach below.

### Option 2 — Plain shell export (recommended when using the agent)

Edit a developer-only run script:

```bash
#!/usr/bin/env bash
# scripts/dev-run.sh  -- gitignored or committed without secrets

set -euo pipefail

# Source ~/.observekit.env (developer-local, not in repo)
if [[ -f "$HOME/.observekit.env" ]]; then
    set -a; source "$HOME/.observekit.env"; set +a
fi

exec java -javaagent:./build/agent/opentelemetry-javaagent.jar \
          -jar build/libs/my-service.jar
```

`~/.observekit.env` (each developer's home directory, never in any repo):

```bash
export OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
```

This is the cleanest approach for the agent case because env vars are visible from the moment the JVM starts.

### `.gitignore` additions

```gitignore
# OpenTelemetry / ObserveKit — local-only secrets
.env
.env.local
.env.*.local
*.env
# Never check in a real key file
**/observekit-key*
```

Always commit `.env.example` (the placeholder template from Section 3) — that documents the variable surface for new developers without leaking secrets.

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

`GlobalOpenTelemetry` is set by the agent or by `AutoConfiguredOpenTelemetrySdk.initialize()`. Either path makes this code work unchanged.

### B — `@WithSpan` annotation

```java
import io.opentelemetry.instrumentation.annotations.SpanAttribute;
import io.opentelemetry.instrumentation.annotations.WithSpan;

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

`@WithSpan` requires the **javaagent** to be running — there's no proxy/AOP layer in plain Java to wire it up otherwise. With Option B (programmatic SDK, no agent), you have to use the programmatic form.

## 7. Log correlation snippet

In plain Java, you usually have one of: Logback (via SLF4J), Log4j2 (via SLF4J or directly), or `java.util.logging` (JUL). The agent injects MDC keys for all three.

### Strategy A — OTel appender (logs shipped via OTLP `/v1/logs`)

#### Logback variant

```xml
<dependency>
  <groupId>io.opentelemetry.instrumentation</groupId>
  <artifactId>opentelemetry-logback-appender-1.0</artifactId>
  <version>2.10.0</version>
</dependency>
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

#### Log4j2 variant

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

With the agent loaded, both appenders auto-wire — you can omit the explicit `<OpenTelemetry>` / `<appender class="...OpenTelemetryAppender"/>` declaration if `otel.instrumentation.<logback-appender|log4j-appender>.experimental-log-attributes=true` is set.

### Strategy B — MDC pattern only

If you don't run a logging framework at all (just `System.out.println`), you get nothing — there's no MDC to populate. Switch to SLF4J + Logback or Log4j2; you can't ship correlated logs from `System.out.println`.

If you do have a logging framework but you ship logs out-of-band (Fluent Bit tailing a file, journald scraping stdout, etc.), keep the `%X{trace_id}` / `%X{span_id}` placeholders in your pattern. The agent populates MDC during span execution; your existing log shipper sees the fields without further wiring.

### Bare-bones `System.out.println` corner case

If the codebase truly has nothing but `System.out.println` (a hack script, an example), at minimum log the current trace ID by hand:

```java
import io.opentelemetry.api.trace.Span;

void handle() {
    String traceId = Span.current().getSpanContext().getTraceId();
    System.out.printf("[trace_id=%s] processing started%n", traceId);
}
```

This won't ship anywhere on its own, but at least the trace IDs in stdout match what ObserveKit recorded — a human grepping stdout can pivot to ObserveKit by ID.

## 8. Sampling and exclusion config keys

### Javaagent (env vars or `-D` flags)

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
OTEL_INSTRUMENTATION_HTTP_SERVER_EXCLUDE_PATHS=/healthz,/readyz,/metrics
```

Equivalents as system properties:

```bash
-Dotel.traces.sampler=parentbased_traceidratio
-Dotel.traces.sampler.arg=0.25
-Dotel.instrumentation.http.server.exclude-paths=/healthz,/readyz,/metrics
```

### Programmatic SDK (Option B)

The autoconfigure module reads exactly the same env vars / system properties. Set them before `AutoConfiguredOpenTelemetrySdk.initialize()` runs (i.e., in the shell or via `System.setProperty(...)` in `main()` before SDK init).

### Recommended profile

- **Dev:** `OTEL_TRACES_SAMPLER=always_on` (or `sampler.arg=1.0`).
- **Staging:** `parentbased_traceidratio` at `0.5`.
- **Prod:** `parentbased_traceidratio` at `0.1` for high-RPS services; `1.0` for low-RPS where every error matters.

Always exclude probe and metric-scrape paths. For an embedded Jetty/Undertow server, these are usually `/healthz`, `/readyz`, `/metrics`; for handwired services, audit your HTTP routes.

## 9. Common pitfalls in this framework

- **No logging framework means no log shipping.** If your codebase is `System.out.println`-only, the OTel agent has nothing to instrument on the log side. You'll still get traces and metrics, but **no logs** in ObserveKit's `/v1/logs` collector. Either wire up SLF4J + Logback or accept that logs are stdout-only and rely on a sidecar collector.

- **`main()` exits before the BatchSpanProcessor flushes.** Short-lived programs (CLIs, one-shot batch jobs) terminate the JVM before the OTel exporter's batch interval elapses. Result: the last few spans are dropped. Fix: lower `OTEL_BSP_SCHEDULE_DELAY=500` (default 5000ms) and explicitly call `OpenTelemetrySdk.close()` (or rely on the agent's shutdown hook). To switch from the default Batch Span Processor to the Simple Span Processor (which exports each span immediately — useful for dev/debugging only), use the SDK's programmatic API: `SdkTracerProvider.builder().addSpanProcessor(SimpleSpanProcessor.create(exporter)).build()`. Batch vs simple cannot be selected via env var alone — `OTEL_TRACES_EXPORTER` selects the *exporter* (e.g. `otlp`), not the processor. Set `OTEL_JAVAAGENT_DEBUG=true` once to verify shutdown is flushing.

- **Custom `ExecutorService` instances lose context across threads.** The agent instruments JDK's `Executors.newFixedThreadPool(...)`-style factories, but if you've handrolled a `ForkJoinPool` or a custom `ThreadFactory`, span context evaporates at the hand-off. Wrap your executor with `io.opentelemetry.context.Context.taskWrapping(executor)`.

- **Shaded fat-jars can hide OTel API from the agent.** If you've built an "uber-jar" with `maven-shade-plugin` or Gradle's `shadowJar` that relocates `io.opentelemetry.**` into your own namespace, the agent loads the original classes from its own classloader and your code uses the relocated copies — they never meet, and `GlobalOpenTelemetry.getTracer(...)` returns a no-op. Always **exclude** `io.opentelemetry.**` from any relocation pattern.

- **`OTEL_EXPORTER_OTLP_HEADERS` formatting on Windows PowerShell.** PowerShell expands `$` and quotes differently from Bash. Use single quotes around the entire value: `$env:OTEL_EXPORTER_OTLP_HEADERS = 'X-API-Key=<paste-the-key-the-infra-team-gave-you>'`. If the value contains a real `$`, escape it with a backtick (PowerShell's escape character) — not a backslash.

- **The agent's logging output goes to stderr by default and can flood CI logs.** A misconfigured agent on a CI machine emits a few hundred lines per second of "failed to export, retrying" while it can't reach the endpoint. Set `OTEL_LOG_LEVEL=warn` (default is `info`) to keep the noise down, and unset OTel env vars in CI environments where you don't want telemetry at all (or set `OTEL_SDK_DISABLED=true`).
