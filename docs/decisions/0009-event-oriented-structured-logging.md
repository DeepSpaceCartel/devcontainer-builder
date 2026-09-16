<title>ADR-0009</title>

# ADR-0009: Event-oriented structured logging, and log/trace correlation via OpenTelemetry

Status: accepted
Date: 2026-09-15

## Context

Every log call in this service was either Fastify's own default
per-request access log (which logs the raw `req.url`, querystring
included — `/image?registry=...&name=...&tag=...`, high-cardinality and a
latent secret-leak surface for any future route whose query carries
something sensitive) or a bare `request.log.error(error)`/
`request.log.error(string)` with no event name and no domain fields.
`ADR-0002`'s credential-handling guarantees never let a registry/git
credential *reach* a log line, but nothing structural stopped a future
call site from logging headers wholesale. Distributed tracing
(`tracing.ts`) already existed, but its spans and this service's log
lines had no way to be correlated — a `trace.id` never appeared on a log
line even while a trace was active.

Separately, `0007`'s numeric-vs-string Pino level fix (`formatters.level`)
already made Loki's `detected_level` heuristic classify error/warn lines
correctly — this decision keeps that field named `level`, deliberately
not renaming it to `severity` even though that's the more OpenTelemetry-
Logs-flavored name, since the already-deployed "Logs Overview" Grafana
dashboard depends on the existing name and there's no functional reason
to risk that.

## Decision

Adopt OpenTelemetry semantic-convention field names for every common/
HTTP/error field, plus an explicit `event` name on every log call:

- **Common fields**, baked into every log line once at construction
  (`logger.ts`'s `base` option): `service.name`, `service.version`,
  `deployment.environment.name`. Sourced from the new `config.ts` fields
  `serviceName`/`environment` (`SERVICE_NAME`/`DEPLOYMENT_ENVIRONMENT`),
  and this build's own `package.json` version.
- **An `event` field on every log call**, dot-namespaced
  (`image.lookup.started`/`.completed`/`.failed`, `image.delete.*`,
  `build.*`, `http.request.completed`, `http.request.error`,
  `health.ready.failed`) — never a free-text sentence that happens to
  contain structured data.
- **HTTP fields**: `http.request.method`, `http.route` (always the
  *matched route template*, e.g. `/image` — never the raw querystring),
  `http.response.status_code`, `http.response.duration_ms`, emitted once
  per request via one `onResponse` hook (`server.ts`) that replaces
  Fastify's own default access log entirely (`disableRequestLogging`).
- **Domain fields** per event: `image.registry`/`image.name`/`image.tag`
  for the image routes, `repository`/`branch` for `/build` — the query/
  body values themselves, never folded into a generic `url`/`body` field.
- **Error fields**: `error.type`, `error.message`, `error.stacktrace` on
  every `.failed` event, alongside (not instead of) the existing Sentry
  capture and Prometheus counter increments for the same outcome.
- **`request.id` and `trace.id`/`span.id` stay distinct, never merged.**
  `reqId` is Fastify's own per-request identifier, present on every log
  line automatically via its request-scoped child logger. `trace.id`/
  `span.id` are OpenTelemetry's — present only while tracing is enabled
  (`OTEL_EXPORTER_OTLP_ENDPOINT` set), injected by the
  `@opentelemetry/instrumentation-pino` instrumentation
  `auto-instrumentations-node` already bundles, with its default
  snake_case key names (`trace_id`/`span_id`) overridden in `tracing.ts`
  to the dotted style (`trace.id`/`span.id`) every other field here uses.
  No custom Pino `mixin` was needed — the correlation mechanism already
  existed, just under the wrong key names.
- **Loki labels are untouched by this decision, deliberately.** The
  `rts-terraform` platform repo's Alloy config already relabels only
  Kubernetes metadata (`namespace`, `app`, `pod`, `container`, `job`) onto
  Loki labels — no field this ADR adds (`event`, `trace.id`, `image.*`,
  ...) should ever become a Loki *label*; they stay structured log fields/
  metadata. This is a constraint on any future change here, not new work:
  don't add a matching Alloy `stage.labels` block for any of these.
- **`SERVICE_NAME` is Helm-chart-derived, not operator-typed.** The chart
  sets it unconditionally from `.Chart.Name` — the exact value
  `app.kubernetes.io/name` already uses — so `service.name` on every log
  line can never drift from the `app` label Alloy already promotes for
  the same pod. `DEPLOYMENT_ENVIRONMENT` has no such automatic source (a
  chart can't know what environment it's being installed into) — it's a
  first-class `values.yaml` field (`environment`), wired from the calling
  Terraform's own `var.environment` in the separate `rts-terraform` repo.

## Consequences

- **Easier**: a log line for a failed `/image` lookup or `/build` now
  answers "what happened, to what, and why" without cross-referencing the
  request body/query separately — `event`, the domain fields, and
  `error.*` are all on the one line. Correlating a Loki log line to a
  Tempo trace is a `trace.id` copy-paste once both are enabled.
- **Harder**: every new route/failure branch going forward needs to
  actually pick an `event` name and domain fields, rather than a quick
  `request.log.error(err)` — deliberate friction, the same trade `ADR-0002`
  already made for credential handling (verbosity in exchange for a real,
  checkable interface instead of an implicit convention).
- **A real, accepted duplication**: `DEPLOYMENT_ENVIRONMENT` is read
  independently in two places (`tracing.ts`, before `config.ts` ever
  loads; `config.ts` itself, for `logger.ts`'s base fields) rather than
  plumbed through one shared code path — the same shape `SENTRY_DSN`/OTel
  bootstrap already had before this decision.
