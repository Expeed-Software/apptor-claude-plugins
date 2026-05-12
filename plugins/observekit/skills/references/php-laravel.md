# Laravel (PHP) + ObserveKit (OpenTelemetry)

## 1. What this framework needs

PHP's OpenTelemetry support requires the **C extension `ext-opentelemetry`** installed via PECL. This is non-negotiable: the pure-PHP SDK works for manual spans, but auto-instrumentation of Laravel, Symfony HttpClient, PDO, Guzzle, etc. relies on the extension's `OpenTelemetry\Instrumentation\hook()` mechanism to patch class methods at runtime. Without the extension, every span must be written by hand.

Once the extension is installed, the **`open-telemetry/opentelemetry-auto-laravel`** Composer package handles bootstrapping: it registers hooks for `Illuminate\Foundation\Http\Kernel::handle`, `Illuminate\Routing\Router::runRoute`, the queue worker, console kernel, and Eloquent — all the surfaces a Laravel app actually uses.

Laravel reads `.env` automatically via `vlucas/phpdotenv` (a default Laravel dependency), so OTEL_* environment variables flow into the SDK without any explicit loader.

Ship target — ObserveKit speaks `http/protobuf` on:

- `https://observekit-api.expeed.com/v1/traces`
- `https://observekit-api.expeed.com/v1/metrics`
- `https://observekit-api.expeed.com/v1/logs`

Auth header: `X-API-Key: <key>` (or `Authorization: Bearer <key>`). Body cap: 10 MB.

## 2. Dependency declaration (composer.json)

First install the C extension on the runtime image:

```bash
# Alpine / Debian
pecl install opentelemetry
docker-php-ext-enable opentelemetry

# Verify
php -m | grep opentelemetry
```

Then add the Composer packages:

```bash
composer require \
  open-telemetry/sdk \
  open-telemetry/exporter-otlp \
  open-telemetry/opentelemetry-auto-laravel \
  open-telemetry/transport-grpc:^1.0     # only if using gRPC; skip for http/protobuf
```

`composer.json` excerpt:

```json
{
  "require": {
    "php": "^8.2",
    "ext-opentelemetry": "*",
    "open-telemetry/sdk": "^1.2",
    "open-telemetry/exporter-otlp": "^1.2",
    "open-telemetry/opentelemetry-auto-laravel": "^1.0",
    "monolog/monolog": "^3.0"
  },
  "minimum-stability": "stable",
  "prefer-stable": true
}
```

As of 2026 the auto-instrumentation packages publish stable `1.x` releases; if you pin to an older version that's only `dev`, set `"minimum-stability": "dev"` and `"prefer-stable": true`.

## 3. SDK init / config block

**There is no init code for auto-instrumentation.** The C extension reads its configuration entirely from environment variables. The `auto-laravel` package self-registers via Composer's autoloader.

`.env` (Laravel-default, NOT committed for the secret — see section 5):

```bash
OTEL_PHP_AUTOLOAD_ENABLED=true
OTEL_SERVICE_NAME=my-laravel-app
OTEL_SERVICE_VERSION=1.0.0
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production,service.namespace=web

OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}

OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp

OTEL_PROPAGATORS=tracecontext,baggage
```

`OTEL_PHP_AUTOLOAD_ENABLED=true` is the toggle that activates `auto-laravel` — without it, the package is dormant.

For **manual SDK** (when the extension is absent or you want explicit control), put this in `bootstrap/app.php` immediately after `$app = ...`:

```php
use OpenTelemetry\API\Globals;
use OpenTelemetry\SDK\Common\Attribute\Attributes;
use OpenTelemetry\SDK\Resource\ResourceInfo;
use OpenTelemetry\SDK\Resource\ResourceInfoFactory;
use OpenTelemetry\SDK\Trace\SpanProcessor\BatchSpanProcessor;
use OpenTelemetry\SDK\Trace\TracerProvider;
use OpenTelemetry\Contrib\Otlp\SpanExporter;
use OpenTelemetry\SDK\Common\Export\Http\PsrTransportFactory;

$transport = (new PsrTransportFactory())->create(
    'https://observekit-api.expeed.com/v1/traces',
    'application/x-protobuf',
    ['X-API-Key' => env('OBSERVEKIT_API_KEY')],
);

$tracerProvider = TracerProvider::builder()
    ->addSpanProcessor(BatchSpanProcessor::builder(new SpanExporter($transport))->build())
    ->setResource(ResourceInfoFactory::defaultResource()->merge(
        ResourceInfo::create(Attributes::create([
            'service.name'           => env('OTEL_SERVICE_NAME', 'my-laravel-app'),
            'deployment.environment' => app()->environment(),
        ]))
    ))
    ->build();

Globals::registerInitializer(function ($builder) use ($tracerProvider) {
    return $builder->withTracerProvider($tracerProvider);
});

// Flush on shutdown.
register_shutdown_function([$tracerProvider, 'shutdown']);
```

## 4. Launch wrapper or in-code wiring

No launcher. Both PHP-FPM and `php artisan serve` honor `.env` automatically.

Dockerfile:

```dockerfile
FROM php:8.3-fpm-alpine

RUN apk add --no-cache $PHPIZE_DEPS linux-headers \
 && pecl install opentelemetry \
 && docker-php-ext-enable opentelemetry \
 && apk del $PHPIZE_DEPS

WORKDIR /var/www
COPY composer.json composer.lock ./
RUN composer install --no-dev --optimize-autoloader
COPY . .

ENV OTEL_PHP_AUTOLOAD_ENABLED=true \
    OTEL_SERVICE_NAME=my-laravel-app \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com

CMD ["php-fpm"]
```

For Laravel Octane (long-running workers), see Pitfalls — span lifecycle differs from request-per-process FPM.

## 5. Local-dev secret file path

Laravel's default `.env` file. It is gitignored by every Laravel skeleton (`/.env` is in the default `.gitignore`).

`.env` (in repo as `.env.example` only, with placeholder values):

```bash
APP_NAME=Laravel
APP_ENV=local
APP_DEBUG=true

OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
OTEL_PHP_AUTOLOAD_ENABLED=true
OTEL_SERVICE_NAME=my-laravel-app
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=${OBSERVEKIT_API_KEY}
```

Confirm `.gitignore`:

```
/.env
/.env.backup
/.env.*.local
!/.env.example
```

Developer onboarding:

```bash
cp .env.example .env
# Edit .env, replace OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you> with the real key
php artisan key:generate
```

For production, inject `OBSERVEKIT_API_KEY` via your secret manager — never bake the real key into the image or the committed `.env.example`.

## 6. Custom span snippet (with semantic-convention attributes)

```php
<?php

namespace App\Services;

use OpenTelemetry\API\Globals;
use OpenTelemetry\API\Trace\StatusCode;
use OpenTelemetry\API\Trace\SpanKind;

class PricingService
{
    public function calculate(array $cart): float
    {
        $tracer = Globals::tracerProvider()->getTracer('my-laravel-app/pricing', '1.0.0');

        $span = $tracer->spanBuilder('pricing.calculate')
            ->setSpanKind(SpanKind::KIND_INTERNAL)
            ->setAttribute('cart.items', count($cart['items']))
            ->setAttribute('cart.currency', $cart['currency'])
            ->setAttribute('user.id', $cart['user_id'])
            ->startSpan();

        $scope = $span->activate();

        try {
            $total = $this->computeTotal($cart);
            $span->setAttribute('cart.total', $total);
            $span->setStatus(StatusCode::STATUS_OK);
            return $total;
        } catch (\Throwable $e) {
            $span->recordException($e);
            $span->setStatus(StatusCode::STATUS_ERROR, $e->getMessage());
            throw $e;
        } finally {
            $scope->detach();
            $span->end();
        }
    }
}
```

The `$scope->detach()` + `$span->end()` pair in `finally` is mandatory — PHP has no `using` / `defer`. Forgetting `detach()` leaks the active-span context into the next request on a long-lived worker (Octane, Swoole).

## 7. Log correlation snippet

### Strategy A — OTel-native via Monolog handler

Laravel uses Monolog under the hood. The `open-telemetry/opentelemetry-logger-monolog` package ships a handler that emits OTLP log records with trace context attached:

```bash
composer require open-telemetry/opentelemetry-logger-monolog
```

`config/logging.php`:

```php
'channels' => [
    'stack' => [
        'driver'   => 'stack',
        'channels' => ['daily', 'otel'],
    ],

    'otel' => [
        'driver' => 'monolog',
        'handler' => \OpenTelemetry\Contrib\Logs\Monolog\Handler::class,
        'handler_with' => [
            'loggerProvider' => \OpenTelemetry\API\Globals::loggerProvider(),
            'level'          => \Monolog\Level::Info,
        ],
    ],
],
```

`Log::info('processing checkout', ['user_id' => $userId])` then ships as an OTLP log record with `trace_id` / `span_id` pulled from the active span automatically.

### Strategy B — format injection (existing Monolog stack)

If you want to keep your existing JSON-to-stdout logger and only enrich it with trace IDs, add a Monolog processor:

`app/Logging/OtelTraceProcessor.php`:

```php
<?php

namespace App\Logging;

use Monolog\LogRecord;
use Monolog\Processor\ProcessorInterface;
use OpenTelemetry\API\Trace\Span;

class OtelTraceProcessor implements ProcessorInterface
{
    public function __invoke(LogRecord $record): LogRecord
    {
        $ctx = Span::getCurrent()->getContext();
        if ($ctx->isValid()) {
            $record->extra['trace_id'] = $ctx->getTraceId();
            $record->extra['span_id']  = $ctx->getSpanId();
        }
        return $record;
    }
}
```

`config/logging.php`:

```php
'daily' => [
    'driver'     => 'daily',
    'path'       => storage_path('logs/laravel.log'),
    'processors' => [\App\Logging\OtelTraceProcessor::class],
],
```

Use Strategy A when the OTLP logs pipeline is the primary store; Strategy B when stdout/file logs remain canonical.

## 8. Sampling and exclusion config keys

### Sampling

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
```

The PHP SDK reads these on autoload.

### Exclusion — early-return middleware (recommended)

There is no env-var-driven URL exclusion for the PHP auto-instrumentation. The cleanest approach is an **early-return middleware that responds to the health-check path before the OTel-instrumented Kernel code runs at all** — so the auto-instrumentation never sees the request and no span is created in the first place.

`app/Http/Middleware/HealthCheck.php`:

```php
<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Http\Response;

class HealthCheck
{
    private const EXCLUDED = ['healthz', 'readyz', 'up'];

    public function handle(Request $request, Closure $next)
    {
        if (in_array($request->path(), self::EXCLUDED, true)) {
            // Short-circuit before any downstream (instrumented) middleware sees the request.
            return new Response('ok', 200);
        }
        return $next($request);
    }
}
```

Register this **first** in the middleware stack — `bootstrap/app.php` (Laravel 11+) or the top of `$middleware` in `app/Http/Kernel.php` (Laravel 10) — so it runs before the router and before the auto-instrumentation's hooks fire.

Note: ending an in-flight auto span mid-request (e.g. by calling `Span::getCurrent()->end()`) does **not** suppress the span — it just produces a truncated span that still exports. The early-return pattern above is the correct way to make a request invisible to OTel.

If your deploy must keep the OTel middleware ahead of everything else (for example, in a global PSR-15 pipeline you don't control), the alternative is to suppress span recording at the context level: detach the active scope and activate a non-recording span so any nested spans become no-ops — e.g. `Context::storage()->scope()->detach()` followed by `Span::wrap(SpanContext::getInvalid())->activate()`. This is intrusive and easy to leak (you must restore the previous scope in a `finally`), so prefer the early-return middleware unless you have no other option.

For finer control over which instrumentations run at all, set `OTEL_PHP_DISABLED_INSTRUMENTATIONS=psr15,psr18` to disable specific hook sets entirely.

Per-instrumentation toggles via env:

```bash
OTEL_PHP_DISABLED_INSTRUMENTATIONS=guzzle,curl
```

## 9. Common pitfalls

- **The C extension MUST match the PHP version.** `pecl install opentelemetry` against PHP 8.2 produces `opentelemetry.so` that won't load on PHP 8.3. Re-install when you bump PHP. Verify with `php -m | grep opentelemetry`.
- **`OTEL_PHP_AUTOLOAD_ENABLED` is required.** Without it, `auto-laravel` registers nothing and you get zero spans despite the package being installed. This is the single most common silent-failure mode in PHP OTel.
- **PHP-FPM forks per worker.** Each FPM worker initializes the SDK independently — this is fine, but it means the BatchSpanProcessor's queue is per-worker. A short-lived request that doesn't trigger a batch flush before worker recycle loses its spans. The SDK installs a shutdown hook; ensure `OTEL_BSP_SCHEDULE_DELAY` is short enough (default 5000ms) relative to your worker max-requests setting.
- **Laravel Octane (Swoole / RoadRunner) keeps the process alive across requests.** Spans no longer end at request boundary automatically — the auto-instrumentation handles this for the HTTP entry point, but **any manually-activated `$scope` that isn't `detach()`ed leaks into the next request**, polluting subsequent traces with stale parent context. Always pair `activate()` with `detach()` in `finally`.
- **`composer install` order.** The OTel SDK packages must be in `require` (not `require-dev`) because the extension's autoload hook fires for production traffic.
- **Disabled in CLI by default for some setups.** `php artisan` commands inherit the extension, but if you customized `php-cli.ini` to omit `opentelemetry.so`, console traces silently vanish.
- **`Span::getCurrent()` returns a no-op `Span` when no span is active.** Calls succeed without errors but produce nothing — check `getContext()->isValid()` if in doubt.
- **gRPC vs HTTP exporter.** The `transport-grpc` package adds ~10 MB of generated stubs. For http/protobuf, do not install it. Pick one transport per service.
- **`vlucas/phpdotenv` does not re-load on each request.** Changing `.env` requires restarting PHP-FPM. This affects tracer-config changes in dev.
- **`minimum-stability` traps.** Older versions of the auto-instrumentation packages were tagged `dev-main`. As of 2026 stable `1.x` releases exist — pin to those; do not leave `"minimum-stability": "dev"` once you migrate.
