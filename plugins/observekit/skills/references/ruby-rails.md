# Ruby on Rails + ObserveKit (OpenTelemetry)

## 1. What this framework needs

Rails is a Rack-based MVC framework, and OpenTelemetry's Ruby project provides a fully auto-instrumented path via the `opentelemetry-instrumentation-all` meta-gem. It bundles ~40 instrumentation gems — Rack, Action Pack, Action View, Active Record, Active Job, Net::HTTP, Faraday, PG, MySQL2, Redis, Sidekiq, and more.

The meta-gem hooks Ruby's `Module#prepend` mechanism at load time to wrap framework methods. As long as `OpenTelemetry::SDK.configure` runs in a Rails initializer (after Bundler.require, before request serving), every Rails controller action and outbound HTTP call gets a span automatically.

Ship target — ObserveKit speaks `http/protobuf` on:

- `https://observekit-api.expeed.com/v1/traces`
- `https://observekit-api.expeed.com/v1/metrics`
- `https://observekit-api.expeed.com/v1/logs`

Auth header: `X-API-Key: <key>` (or `Authorization: Bearer <key>`). Body cap: 10 MB.

## 2. Dependency declaration (Gemfile)

```ruby
# Gemfile
gem 'opentelemetry-sdk', '~> 1.5'
gem 'opentelemetry-exporter-otlp', '~> 0.29'
gem 'opentelemetry-instrumentation-all', '~> 0.62'

group :development do
  gem 'dotenv-rails'
end
```

Then:

```bash
bundle install
```

For a slimmer image, replace `opentelemetry-instrumentation-all` with the specific gems you use:

```ruby
gem 'opentelemetry-instrumentation-rack'
gem 'opentelemetry-instrumentation-rails'
gem 'opentelemetry-instrumentation-active_record'
gem 'opentelemetry-instrumentation-net_http'
gem 'opentelemetry-instrumentation-pg'
gem 'opentelemetry-instrumentation-sidekiq'   # required separately even with -all in some Sidekiq setups
```

## 3. SDK init / config block

`config/initializers/opentelemetry.rb`:

```ruby
require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'
require 'opentelemetry/instrumentation/all'

OpenTelemetry::SDK.configure do |c|
  c.service_name    = ENV.fetch('OTEL_SERVICE_NAME', 'my-rails-app')
  c.service_version = ENV.fetch('OTEL_SERVICE_VERSION', '1.0.0')

  c.resource = OpenTelemetry::SDK::Resources::Resource.create(
    'deployment.environment' => Rails.env,
    'service.namespace'      => 'web',
  )

  # use_all() activates every loaded instrumentation gem with default config.
  # Override per-instrumentation here:
  c.use_all(
    'OpenTelemetry::Instrumentation::Rack' => {
      untraced_endpoints: ['/healthz', '/readyz', '/up'],
    },
    'OpenTelemetry::Instrumentation::ActiveRecord' => {
      db_statement: :include,   # :omit | :obfuscate | :include
    },
  )
end

# Expose a tracer for application code.
APP_TRACER = OpenTelemetry.tracer_provider.tracer('my-rails-app', '1.0.0')
```

`.env` (non-secret defaults — committed):

```bash
OTEL_SERVICE_NAME=my-rails-app
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
```

The OTLP exporter reads `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`, and `OTEL_EXPORTER_OTLP_HEADERS` from environment. No code-side endpoint configuration needed.

## 4. Launch wrapper or in-code wiring

No launcher. Rails loads the initializer during boot. `bundle exec rails server`, `bundle exec puma`, and any deployer (`rails s`, Passenger, Unicorn) work unmodified.

For Sidekiq (separate process), the initializer still loads because Sidekiq boots the Rails environment — but confirm with `Sidekiq.configure_server` blocks that the OTel SDK fork-handles correctly (see Pitfalls).

Dockerfile:

```dockerfile
FROM ruby:3.3-slim
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install --without development test
COPY . .
ENV RAILS_ENV=production \
    OTEL_SERVICE_NAME=my-rails-app \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    OTEL_EXPORTER_OTLP_ENDPOINT=https://observekit-api.expeed.com
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
```

`OTEL_EXPORTER_OTLP_HEADERS` is injected by the deploy system, never baked into the image.

## 5. Local-dev secret file path

Rails ships two complementary mechanisms:

### Encrypted credentials (preferred for prod)

```bash
EDITOR=vim bin/rails credentials:edit --environment production
```

Stored at `config/credentials/production.yml.enc` (encrypted, committed) with the master key at `config/credentials/production.key` (NOT committed, distributed via secret manager). Reference from the initializer:

```ruby
api_key = Rails.application.credentials.dig(:observekit, :api_key)
ENV['OTEL_EXPORTER_OTLP_HEADERS'] ||= "X-API-Key=#{api_key}" if api_key
```

### `.env` for dev (via `dotenv-rails`)

`.env.local` (NEVER commit):

```bash
OBSERVEKIT_API_KEY=<paste-the-key-the-infra-team-gave-you>
OTEL_EXPORTER_OTLP_HEADERS=X-API-Key=<paste-the-key-the-infra-team-gave-you>
```

`dotenv-rails` loads `.env.local` automatically in development; nothing else to wire.

`.gitignore` (Rails templates usually include these — verify):

```
/.env
/.env.*
!/.env.example
/config/credentials/*.key
/config/master.key
```

## 6. Custom span snippet (with semantic-convention attributes)

```ruby
class CheckoutsController < ApplicationController
  def create
    APP_TRACER.in_span('pricing.calculate', attributes: {
      'cart.items'    => params[:items].length,
      'cart.currency' => params[:currency],
      'user.id'       => current_user.id,
    }) do |span|
      total = PricingService.compute(params)
      span.set_attribute('cart.total', total.to_f)
      span.set_attribute('order.id', SecureRandom.uuid)

      render json: { total: total }
    rescue StandardError => e
      span.record_exception(e)
      span.status = OpenTelemetry::Trace::Status.error(e.message)
      raise
    end
  end
end
```

The span is automatically a child of the Rack/Rails request span — no manual context plumbing needed.

For module-level work outside a controller, fetch the tracer lazily:

```ruby
class PricingService
  TRACER = OpenTelemetry.tracer_provider.tracer('my-rails-app/pricing')

  def self.compute(params)
    TRACER.in_span('pricing.compute') do |span|
      # ...
    end
  end
end
```

## 7. Log correlation snippet

### Strategy A — OTel-native log records (recommended where available)

`opentelemetry-sdk` 1.5+ ships an experimental `OpenTelemetry::Logs::Logger` API. Bridge `Rails.logger` to it:

```ruby
# config/initializers/opentelemetry.rb (append after SDK.configure)
require 'opentelemetry/logs/sdk'

logger_provider = OpenTelemetry.logger_provider
logger_provider.add_log_record_processor(
  OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor.new(
    OpenTelemetry::Exporter::OTLP::Logs::LogsExporter.new
  )
)

# Optional: bridge Rails.logger to also emit OTLP log records
otel_logger = logger_provider.logger(name: 'rails')
Rails.application.config.after_initialize do
  Rails.logger.formatter = proc do |severity, ts, progname, msg|
    span_ctx = OpenTelemetry::Trace.current_span.context
    otel_logger.emit(severity_text: severity, body: msg.to_s, attributes: {
      'trace_id' => span_ctx.hex_trace_id,
      'span_id'  => span_ctx.hex_span_id,
    })
    "[#{ts}] #{severity} #{msg}\n"
  end
end
```

### Strategy B — format injection via Lograge

This is the dominant Rails logging pattern in production. Add trace IDs to every request line:

```ruby
# Gemfile
gem 'lograge'

# config/environments/production.rb
config.lograge.enabled = true
config.lograge.formatter = Lograge::Formatters::Json.new
config.lograge.custom_options = lambda do |event|
  span_ctx = OpenTelemetry::Trace.current_span.context
  {
    trace_id: span_ctx.valid? ? span_ctx.hex_trace_id : nil,
    span_id:  span_ctx.valid? ? span_ctx.hex_span_id  : nil,
    user_id:  event.payload[:user_id],
  }
end
```

Output:

```json
{"method":"POST","path":"/checkouts","status":200,"duration":42.3,"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7"}
```

Use Strategy B for any existing Rails service — the OTel Logs API on Ruby is newer and less battle-tested than the Logger-bridge story on .NET / Java.

## 8. Sampling and exclusion config keys

### Sampling

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
```

The Ruby SDK reads these on `SDK.configure`. Override in code if needed:

```ruby
c.sampler = OpenTelemetry::SDK::Trace::Samplers.parent_based(
  root: OpenTelemetry::SDK::Trace::Samplers.trace_id_ratio_based(0.25),
)
```

### Exclusion — Rack instrumentation config

```ruby
c.use_all(
  'OpenTelemetry::Instrumentation::Rack' => {
    untraced_endpoints: ['/healthz', '/readyz', '/up', '/metrics'],
    # Optional regex match instead of exact:
    untraced_requests:  ->(env) { env['PATH_INFO'].start_with?('/internal/') },
  },
)
```

Endpoints listed in `untraced_endpoints` produce zero spans and zero metrics for the request.

For specific instrumentations:

```ruby
'OpenTelemetry::Instrumentation::ActiveRecord' => { enabled: true, db_statement: :obfuscate },
'OpenTelemetry::Instrumentation::Net::HTTP'    => { enabled: false },
```

## 9. Common pitfalls

- **Initializer load order with Zeitwerk autoloading.** Rails 6.1+ uses Zeitwerk; `OpenTelemetry::SDK.configure` should run after Bundler.require but before any application code defines tracers. The default initializer location (`config/initializers/opentelemetry.rb`) is correct, but a tracer captured at class-load time (e.g., `TRACER = OpenTelemetry.tracer_provider.tracer(...)` at file top) may resolve before the SDK is fully configured if the file is eager-loaded too early. Defer with `Rails.application.config.after_initialize` or lazy `def self.tracer` if you see no-op tracers.
- **`opentelemetry-instrumentation-all` is large.** ~200+ files loaded into every process — adds 100–300 ms to boot, noticeable in `rails console`. For slim images use individual gems.
- **Sidekiq requires explicit instrumentation gem.** Even with `-all`, Sidekiq workers sometimes need `gem 'opentelemetry-instrumentation-sidekiq'` declared explicitly and `use 'OpenTelemetry::Instrumentation::Sidekiq'` in `SDK.configure`. Verify with `OpenTelemetry::Instrumentation.registry.installed` in a Sidekiq process.
- **Forked process handling (Puma / Unicorn / Passenger).** The OTel SDK launches background threads (batch span processor). After fork, those threads do not survive. Rails calls `Process.fork`-style hooks; the SDK installs a `Process.after_fork`-style handler, but for Puma `preload_app!` mode you must call `OpenTelemetry::SDK::Trace.instance_variable_get(:@tracer_provider).reset!` or simply do not preload. See the gem docs for the current preferred pattern.
- **`current_span.context` returns an invalid context when no span is active.** Check `.valid?` before using `hex_trace_id` — otherwise you'll log `"00000000000000000000000000000000"` for trace ID.
- **`use_all` is convenient but opaque.** When debugging "no spans for X", check `OpenTelemetry::Instrumentation.registry.installed` to confirm the instrumentation actually attached. Some gems silently no-op if the target library isn't loaded yet at `use` time.
- **OTLP exporter retries on 5xx.** Long network stalls (e.g., DNS failure) can block the batch processor up to ~30s. Set `OTEL_EXPORTER_OTLP_TIMEOUT=10000` (ms) to cap.
- **Rails reloader in development.** Code reloading clears module constants — if you captured `TRACER` at file top, it gets reset on each reload. Use `Rails.application.config.cache_classes = true` in dev only when investigating tracer-lifetime issues.
