# Semantic Conventions

Reference of standard OpenTelemetry attribute names. Use these on custom spans so that ObserveKit (and any OTel backend) renders them with the right UI semantics.

## Why semantic conventions matter

OTel publishes a list of well-known attribute names. ObserveKit's UI knows about these names — it parses `http.response.status_code` to colorize a row, groups by `db.system` on the database overview, builds the service map from `server.address`, and so on.

When your custom spans use these names, they look exactly like auto-instrumented spans. When they use ad-hoc names like `statusCode` or `db_type`, they show up as opaque key/value pairs and miss every piece of UI specialization.

The rule: **if there is a semantic-convention attribute for what you want to record, use it**. Invent your own attribute name only when none of the standard ones fit.

## HTTP

Set on spans that represent an HTTP request or response (client or server side).

| Attribute                  | Example                  | Notes                                                  |
|----------------------------|--------------------------|--------------------------------------------------------|
| `http.request.method`      | `GET`, `POST`            | Uppercase. Use `_OTHER` for non-standard methods.      |
| `http.response.status_code`| `200`, `404`, `500`      | Integer.                                               |
| `http.route`               | `/users/:id`             | The route pattern, **not** the concrete path.          |
| `url.path`                 | `/users/42`              | The actual path.                                       |
| `url.scheme`               | `https`                  |                                                        |
| `url.full`                 | `https://api/x?y=1`      | Use only when no PII / secrets in the URL.             |
| `server.address`           | `api.example.com`        | The host the client targeted.                          |
| `server.port`              | `443`                    | Integer.                                               |
| `user_agent.original`      | `curl/7.88.1`            | The raw `User-Agent` header.                           |

## Database

Set on spans that represent a database call.

| Attribute              | Example                              | Notes                                              |
|------------------------|--------------------------------------|----------------------------------------------------|
| `db.system`            | `postgresql`, `mysql`, `mongodb`     | The DB technology.                                 |
| `db.statement`         | `SELECT id FROM users WHERE ...`     | The query. Parameterized form preferred.           |
| `db.operation.name`    | `SELECT`, `INSERT`, `findOne`        | The operation. Often derivable from the statement. |
| `db.collection.name`   | `users`                              | Table / collection.                                |
| `db.namespace`         | `app_prod`                           | DB / schema name.                                  |

Do not put unparameterized values from `db.statement` if those values are PII. Either parameterize the statement or omit it.

## Messaging

Set on spans for queues, pub/sub, streams (Kafka, RabbitMQ, SQS, etc.).

| Attribute                      | Example                  | Notes                                            |
|--------------------------------|--------------------------|--------------------------------------------------|
| `messaging.system`             | `kafka`, `rabbitmq`, `sqs` |                                                  |
| `messaging.destination.name`   | `orders`                 | Topic / queue / exchange name.                   |
| `messaging.operation.type`     | `publish`, `receive`, `process` | Action being taken.                       |
| `messaging.message.id`         | `<uuid>`                 | If the broker exposes one.                       |

## RPC

Set on spans for gRPC, Thrift, or similar RPC calls.

| Attribute       | Example              | Notes                              |
|-----------------|----------------------|------------------------------------|
| `rpc.system`    | `grpc`               |                                    |
| `rpc.service`   | `UserService`        | The service name (no language `.`).|
| `rpc.method`    | `GetUser`            | The RPC method.                    |

## Exceptions

Set automatically by `recordException` (or the equivalent on your SDK). You normally do not set these by hand:

| Attribute             | Set by                | Notes                                |
|-----------------------|-----------------------|--------------------------------------|
| `exception.type`      | SDK                   | The exception class name.            |
| `exception.message`   | SDK                   | `Throwable.getMessage()` or similar. |
| `exception.stacktrace`| SDK                   | Multi-line stack trace.              |

You may **add** your own exception-related attributes (e.g., a domain-level error code) — just don't overwrite the standard ones.

## Anti-patterns

| Don't                                                           | Why                                                                    |
|-----------------------------------------------------------------|------------------------------------------------------------------------|
| Put PII in attributes (email, SSN, phone, full name)            | Attributes are indexed and queryable; PII leaks broaden the blast zone.|
| Put high-cardinality unique values (request IDs as a tag value) | High-cardinality blows up the metric/index storage. Use them as span IDs / log fields, not as metric labels. |
| Put long strings (full HTML body, large JSON blobs)             | The 10 MB body cap will hit, and span size affects ingest cost.        |
| Invent custom names that duplicate standard ones (`statusCode`) | Loses UI semantics. Use `http.response.status_code` instead.           |
| Use enum values that aren't the spec's (`POST_LOGIN`)           | Some UI features only match the spec's enum set.                       |

## The canonical, evolving list

Semantic conventions evolve. The list above is a useful starting point but not exhaustive. For the authoritative current spec, see:

**https://opentelemetry.io/docs/specs/semconv/**

When in doubt, search that site for the concept (e.g., "messaging", "feature flag", "GenAI") and use whatever the latest version names it.
