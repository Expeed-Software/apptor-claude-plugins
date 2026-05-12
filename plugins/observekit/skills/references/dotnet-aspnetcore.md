# ASP.NET Core + ObserveKit (OpenTelemetry)

## 1. What this framework needs

ASP.NET Core (6+) has two viable instrumentation paths:

1. **Auto-instrumentation via `OpenTelemetry.AutoInstrumentation`** — a profiler-based agent (the CLR ICorProfiler API) that hooks IL at JIT time. No code change required. Configured entirely via environment variables and the `CORECLR_ENABLE_PROFILING` env var.
2. **Code-based via OpenTelemetry NuGet packages** — wired into the generic-host `WebApplicationBuilder` in `Program.cs`. This is the idiomatic path for ASP.NET Core 6+ minimal-hosting model and is the **recommended** approach: it composes cleanly with `IConfiguration`, `IHostBuilder`, and the built-in `ILogger<T>`.

This document covers both, but defaults to the code-based path. The `Activity` / `ActivitySource` types in `System.Diagnostics` are the .NET-native span API; OpenTelemetry simply observes them.

Ship target — ObserveKit speaks `http/protobuf` on:

- `https://observekit-api.expeed.com/v1/traces`
- `https://observekit-api.expeed.com/v1/metrics`
- `https://observekit-api.expeed.com/v1/logs`

Auth header: `X-API-Key: <key>` (or `Authorization: Bearer <key>`). Body cap: 10 MB.

## 2. Dependency declaration (NuGet)

Code-based path — `MyApp.csproj`:

```xml
<ItemGroup>
  <PackageReference Include="OpenTelemetry" Version="1.9.0" />
  <PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.9.0" />
  <PackageReference Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" Version="1.9.0" />
  <PackageReference Include="OpenTelemetry.Instrumentation.AspNetCore" Version="1.9.0" />
  <PackageReference Include="OpenTelemetry.Instrumentation.Http" Version="1.9.0" />
</ItemGroup>
```

Or via CLI:

```bash
dotnet add package OpenTelemetry
dotnet add package OpenTelemetry.Extensions.Hosting
dotnet add package OpenTelemetry.Exporter.OpenTelemetryProtocol
dotnet add package OpenTelemetry.Instrumentation.AspNetCore
dotnet add package OpenTelemetry.Instrumentation.Http
```

Auto-instrumentation path — no NuGet, just the standalone installer:

```powershell
# PowerShell on Windows
Invoke-WebRequest -Uri https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/latest/download/otel-dotnet-auto-install.ps1 -OutFile otel.ps1
./otel.ps1
```

## 3. SDK init / config block

`Program.cs` (minimal hosting, .NET 6+):

```csharp
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetry.Metrics;
using OpenTelemetry.Logs;

var builder = WebApplication.CreateBuilder(args);

var resourceBuilder = ResourceBuilder.CreateDefault()
    .AddService(
        serviceName: builder.Configuration["OTEL_SERVICE_NAME"] ?? "my-aspnet-app",
        serviceVersion: "1.0.0")
    .AddAttributes(new Dictionary<string, object>
    {
        ["deployment.environment"] = builder.Environment.EnvironmentName.ToLowerInvariant(),
    });

builder.Services.AddOpenTelemetry()
    .ConfigureResource(r => r.AddService(
        serviceName: builder.Configuration["OTEL_SERVICE_NAME"] ?? "my-aspnet-app"))
    .WithTracing(t => t
        .AddSource("MyApp")                          // register the ActivitySource name(s) you use
        .AddAspNetCoreInstrumentation(o =>
        {
            o.Filter = ctx => !ctx.Request.Path.StartsWithSegments("/healthz")
                           && !ctx.Request.Path.StartsWithSegments("/readyz");
            o.RecordException = true;
        })
        .AddHttpClientInstrumentation()
        .AddOtlpExporter())
    .WithMetrics(m => m
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddRuntimeInstrumentation()
        .AddOtlpExporter())
    .WithLogging(l => l
        .AddOtlpExporter());

var app = builder.Build();
app.MapGet("/", () => "ok");
app.Run();
```

`appsettings.json` (non-secret defaults):

```json
{
  "OTEL_SERVICE_NAME": "my-aspnet-app",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "https://observekit-api.expeed.com"
}
```

The `AddOtlpExporter()` call with no arguments reads `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`, and `OTEL_EXPORTER_OTLP_HEADERS` from environment automatically — same env-var contract as every other OTel SDK.

## 4. Launch wrapper or in-code wiring

Code-based path: no launcher. `dotnet run` (dev) or `dotnet MyApp.dll` (prod). The builder pattern in `Program.cs` is the wiring.

Auto-instrumentation path: set the profiler env vars **before** the process starts. On Linux:

```bash
export CORECLR_ENABLE_PROFILING=1
export CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318}
export CORECLR_PROFILER_PATH=/opt/otel-dotnet-auto/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so
export DOTNET_ADDITIONAL_DEPS=/opt/otel-dotnet-auto/AdditionalDeps
export DOTNET_SHARED_STORE=/opt/otel-dotnet-auto/store
export DOTNET_STARTUP_HOOKS=/opt/otel-dotnet-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll
export OTEL_DOTNET_AUTO_HOME=/opt/otel-dotnet-auto
export OTEL_SERVICE_NAME=my-aspnet-app
export OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
export OTEL_EXPORTER_OTLP_HEADERS="X-API-Key=${OBSERVEKIT_API_KEY}"
dotnet MyApp.dll
```

PowerShell equivalent (Windows — note the profiler env vars differ for Windows .NET; the OTel header line is what's translated here):

```powershell
$env:OTEL_SERVICE_NAME = "my-aspnet-app"
$env:OTEL_EXPORTER_OTLP_ENDPOINT = "https://observekit-api.expeed.com"
$env:OTEL_EXPORTER_OTLP_HEADERS = "X-API-Key=$env:OBSERVEKIT_API_KEY"
dotnet MyApp.dll
```

Windows also uses different profiler env-var names (`CORECLR_*` is cross-platform, but the GUID and `.dll` paths differ). See the OpenTelemetry .NET auto-instrumentation docs for the Windows native paths.

Or use the bundled `instrument.sh` wrapper that the installer drops next to your binary.

Dockerfile snippet for auto-instrumentation:

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:8.0
COPY --from=otel/autoinstrumentation-dotnet:latest /autoinstrumentation /opt/otel-dotnet-auto
ENV CORECLR_ENABLE_PROFILING=1 \
    CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318} \
    CORECLR_PROFILER_PATH=/opt/otel-dotnet-auto/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so \
    DOTNET_STARTUP_HOOKS=/opt/otel-dotnet-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll \
    OTEL_DOTNET_AUTO_HOME=/opt/otel-dotnet-auto \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
ENTRYPOINT ["dotnet", "MyApp.dll"]
```

## 5. Local-dev secret file path

Use the built-in **User Secrets** store — it lives outside the repo, scoped per-project:

```bash
cd MyApp
dotnet user-secrets init
dotnet user-secrets set "OBSERVEKIT_API_KEY" "<paste-the-key-the-infra-team-gave-you>"
dotnet user-secrets set "OTEL_EXPORTER_OTLP_HEADERS" "X-API-Key=<paste-the-key-the-infra-team-gave-you>"
```

On Windows the store is at `%APPDATA%\Microsoft\UserSecrets\<UserSecretsId>\secrets.json`; on Linux/macOS `~/.microsoft/usersecrets/<UserSecretsId>/secrets.json`. The `<UserSecretsId>` GUID is injected into `MyApp.csproj` by `user-secrets init`. The `IConfiguration` builder picks them up automatically in `Development` environment — they appear at `builder.Configuration["OBSERVEKIT_API_KEY"]` just like any other config key.

`.gitignore` (the secrets file lives outside the repo, but be defensive):

```
**/secrets.json
.env
.env.local
appsettings.Development.local.json
```

If you prefer an env-var file, put it in `.env.local` and load with `DotNetEnv` — but user-secrets is the .NET-native answer.

## 6. Custom span snippet (with semantic-convention attributes)

`Activity` / `ActivitySource` is .NET's native tracing API. OpenTelemetry's SDK observes any `ActivitySource` whose name you registered with `.AddSource(...)` in the builder.

```csharp
using System.Diagnostics;
using OpenTelemetry.Trace;

public class PricingService
{
    // The name "MyApp" MUST match a call to .AddSource("MyApp") in Program.cs.
    private static readonly ActivitySource Activity = new("MyApp", "1.0.0");

    public async Task<decimal> CalculateAsync(Cart cart, CancellationToken ct)
    {
        using var activity = Activity.StartActivity("pricing.calculate", ActivityKind.Internal);

        activity?.SetTag("cart.items", cart.Items.Count);
        activity?.SetTag("cart.currency", cart.Currency);
        activity?.SetTag("user.id", cart.UserId);

        try
        {
            var total = await ComputeTotalAsync(cart, ct);
            activity?.SetTag("cart.total", (double)total);
            activity?.SetStatus(ActivityStatusCode.Ok);
            return total;
        }
        catch (Exception ex)
        {
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.AddException(ex);                 // OTel-aware exception event
            throw;
        }
    }
}
```

The activity automatically becomes a child of the in-flight ASP.NET Core request activity — no explicit parent passing needed.

## 7. Log correlation snippet

### Strategy A — OTel-native via `Microsoft.Extensions.Logging`

`builder.Services.AddOpenTelemetry().WithLogging(...)` registers an `ILoggerProvider` that observes every log written through the standard `ILogger<T>`. Each `LogRecord` automatically carries the active `TraceId`, `SpanId`, and `TraceFlags`. Logs are exported via OTLP to `/v1/logs`. No code change at log sites:

```csharp
public class CheckoutController(ILogger<CheckoutController> logger) : ControllerBase
{
    [HttpPost]
    public IActionResult Post([FromBody] CheckoutRequest req)
    {
        logger.LogInformation("Processing checkout for user {UserId} with {ItemCount} items",
            req.UserId, req.Items.Count);
        // The log record is shipped with trace_id and span_id from Activity.Current automatically.
        return Ok();
    }
}
```

This is the recommended path for ASP.NET Core 6+.

### Strategy B — format injection (Serilog)

If you have an existing Serilog pipeline, use the `Serilog.Sinks.OpenTelemetry` sink and `Serilog.Enrichers.OpenTelemetry`:

```xml
<PackageReference Include="Serilog.AspNetCore" Version="8.0.1" />
<PackageReference Include="Serilog.Sinks.OpenTelemetry" Version="4.0.0" />
<PackageReference Include="Serilog.Enrichers.Span" Version="3.1.0" />
```

```csharp
builder.Host.UseSerilog((ctx, lc) => lc
    .Enrich.WithSpan()                        // adds TraceId, SpanId, ParentId
    .WriteTo.Console(outputTemplate:
        "[{Timestamp:HH:mm:ss} {Level:u3} trace_id={TraceId} span_id={SpanId}] {Message:lj}{NewLine}{Exception}")
    .WriteTo.OpenTelemetry(o =>
    {
        o.Endpoint = "https://observekit-api.expeed.com/v1/logs";
        o.Protocol = OtlpProtocol.HttpProtobuf;
        o.Headers = new Dictionary<string, string>
        {
            ["X-API-Key"] = Environment.GetEnvironmentVariable("OBSERVEKIT_API_KEY")!,
        };
    }));
```

Use Strategy A unless a Serilog pipeline already exists.

## 8. Sampling and exclusion config keys

### Sampling — env-var driven

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
```

The .NET SDK reads these on `AddOpenTelemetry().WithTracing()` startup. In code, override with `.SetSampler(new TraceIdRatioBasedSampler(0.25))` inside the `WithTracing(...)` builder if you need programmatic control.

### Exclusion — code-based

ASP.NET Core instrumentation accepts a `Filter` predicate:

```csharp
.AddAspNetCoreInstrumentation(o =>
{
    var excluded = new[] { "/healthz", "/readyz", "/metrics" };
    o.Filter = ctx => !excluded.Any(p => ctx.Request.Path.StartsWithSegments(p));
})
```

For outbound `HttpClient`:

```csharp
.AddHttpClientInstrumentation(o =>
{
    o.FilterHttpRequestMessage = req =>
        !req.RequestUri!.AbsolutePath.StartsWith("/internal/health");
})
```

Auto-instrumentation respects these env vars:

```bash
OTEL_DOTNET_AUTO_TRACES_ENABLED_INSTRUMENTATIONS=AspNet,HttpClient,SqlClient
OTEL_DOTNET_AUTO_TRACES_DISABLED_INSTRUMENTATIONS=GraphQL
```

There is no env-var equivalent to "exclude these URL paths" — exclusion is always code-side via the `Filter` callback.

## 9. Common pitfalls

- **`ActivitySource` name must be registered.** `new ActivitySource("Foo")` produces nothing unless `.AddSource("Foo")` was called on the tracer provider. The activity returned by `StartActivity` will be `null` and your `.SetTag` calls become no-ops. This is the single most common silent-failure mode in .NET OTel.
- **`new Activity(...)` is not the same as `ActivitySource.StartActivity`.** Direct `Activity` construction bypasses the listener machinery — those activities are invisible to OTel. Always go through an `ActivitySource`.
- **Profiler env vars must be set before the process spawns.** Setting `CORECLR_ENABLE_PROFILING=1` from inside `Program.cs` is too late — the CLR has already finished profiler attach. For container images this means `ENV` directives, not runtime config.
- **Minimum target framework.** OpenTelemetry 1.9+ requires `net6.0` or later. `netcoreapp3.1` and `net5.0` are unsupported on current versions — pin to OpenTelemetry 1.6.x if you cannot upgrade.
- **`WithLogging` is OTel 1.9+.** Older versions used `builder.Logging.AddOpenTelemetry(...)`. Mixing the two APIs duplicates log records — pick one.
- **IIS in-process hosting.** The profiler-based auto-instrumentation conflicts with Application Insights' profiler if both are enabled. Disable AI's profiler or use code-based OTel.
- **Background services and `IHostedService`.** `Activity.Current` is `null` on the background thread unless you start a fresh activity in the worker loop. Auto-instrumentation cannot infer a parent for non-HTTP entry points — wrap each loop iteration in `Activity.StartActivity("worker.iteration")`.
- **Sampling decision is cached on the root.** Switching `OTEL_TRACES_SAMPLER_ARG` at runtime via `IOptionsMonitor` does not retroactively re-sample in-flight traces. Restart the process to change sampling.
