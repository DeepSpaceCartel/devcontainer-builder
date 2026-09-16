# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-16

### Added

- `templates/coder-kubernetes/` — a real, runnable Coder Workspace Template
  (adapted from the official `coder/kubernetes` registry template) where a
  workspace-level git-repository parameter drives a real
  `devcontainerbuilder_build` before the workspace's pod ever starts, instead
  of a fixed image. See the new
  [Coder Workspace Template guide](docs/guides/coder-workspace-template.md).
- CLI/npm package: `service/` is now published to npm as
  `@deepspacecartel/devcontainer-builder`, runnable directly via
  `npx @deepspacecartel/devcontainer-builder`.
- Live, generated OpenAPI document (`GET /documentation/json`, Swagger UI at
  `GET /documentation`) — generated from the same TypeBox route schemas that
  validate every request, so it can't drift from what the service actually
  accepts. Restish and other OpenAPI-aware clients can auto-configure
  against a running instance.
- Optional bundled BuildKit dependency for the Helm chart
  (`buildkit.deploy.enabled`, off by default) — a single
  `helm install --set buildkit.deploy.enabled=true` now works with zero
  pre-existing BuildKit infra.
- `.github/workflows/release.yaml` — a `vX.Y.Z` tag now builds and
  publishes the Docker image (multi-arch, GHCR), the Helm chart (OCI, GHCR),
  and the npm package together, then cuts a GitHub Release.
- `.github/workflows/docs.yaml` — this documentation site now builds
  (`mkdocs build --strict`) and deploys (GitHub Pages, via the
  Actions-based flow) automatically.
- `GET /health/startup` — a Kubernetes `startupProbe`, wired into the Helm
  chart with a generous `failureThreshold` so slow pod scheduling/image
  pulls never trip `livenessProbe`/`readinessProbe`.
- `GET /metrics` — Prometheus text-format metrics (`prom-client`), Node.js
  process defaults plus real build/image-check/image-delete counters and a
  build-duration histogram.
- `GET /config` — read-only, non-sensitive view of the service's own
  loaded configuration (credential material always redacted).
- Optional Sentry/GlitchTip error tracking (`SENTRY_DSN`) and optional
  OpenTelemetry tracing (`OTEL_EXPORTER_OTLP_ENDPOINT`), both entirely off
  unless configured.
- The generated OpenAPI document now has real per-route tags (`Dev
  Containers`/`Images`/`Health`/`Configuration`/`Logs`) instead of the
  default catch-all group, and realistic request examples (real repo URLs,
  one showing `registryCredentials` explicitly) — upgraded to OpenAPI 3.1
  so TypeBox's own `examples` keyword survives `@fastify/swagger`'s
  transform (silently dropped under its default 3.0.x).
- `terraform/devcontainer-build` now wraps
  `terraform-provider-devcontainer-builder`'s `devcontainerbuilder_build`
  resource internally instead of `data "http"` — the module's
  variable/output interface is unchanged, but a real build now only runs
  on `terraform apply`, for an actual diff, not on every single `terraform
  plan`. `build.tftest.hcl` gains a real, mocked contract test
  (`mock_provider`) this now makes possible.
- Event-oriented structured logging: every log line now carries an
  explicit `event` name plus OpenTelemetry-semantic field names
  (`http.route`, `error.type`, `image.registry`, ...) instead of a
  free-text message, `service.name`/`service.version`/
  `deployment.environment.name` on every line (new `SERVICE_NAME`/
  `DEPLOYMENT_ENVIRONMENT` config fields, the latter also a first-class
  Helm chart value), and `trace.id`/`span.id` correlation with
  OpenTelemetry traces when tracing is enabled. See
  [ADR-0009](docs/decisions/0009-event-oriented-structured-logging.md).
- `git clone`/`devcontainer build --push` output is now captured to a file
  per invocation instead of being written straight to the pod's own
  stdout, fetchable/deletable via new `GET`/`DELETE /logs/{id}` routes
  (`POST /build` returns the relevant id as `gitCloneLogId`/
  `imageBuildLogId` on success, `logId` on failure). Retained per kind
  (`git`/`docker`), capped by the new `commandLogRetention` config field
  (default 10). See
  [ADR-0010](docs/decisions/0010-command-output-capture.md).

### Changed

- The HTTP service is rebuilt on [Fastify](https://fastify.dev) instead of
  a bare `node:http` listener — every documented request/response shape
  and status code is unchanged (verified against every case in
  `service/features/request_validation.feature`).
- `charts/devcontainer-builder/values.yaml`'s `image.repository` now
  defaults to the real, published
  `ghcr.io/deepspacecartel/devcontainer-builder` image.
- Docs restructured into dedicated Application / Helm Chart / Terraform
  nav sections (previously a doc-type split of Concepts/Reference that
  didn't map to the three deployable pieces); the Quickstart now leads
  with the chart's bundled BuildKit dependency instead of requiring a
  pre-existing BuildKit daemon, and makes registry credentials explicit
  from its first example.
- The HTTP API reference is now two fully static, generated pages
  (`docs/api-reference.html` via Redoc, `docs/api-swagger-ui/` — the exact
  static bundle `GET /documentation` serves live) instead of a hand-written
  `docs/reference/API.md`.

### Fixed

- `service/package.json`'s `thomas` devDependency no longer points at a
  local sibling directory (`file:../../thomas`) that only resolved in one
  specific development environment — it's pinned to a real
  `github:DeepSpaceCartel/thomas` commit instead, which resolves in a
  fresh clone or CI with no sibling checkout needed.
- The docs site's Redoc-based API viewer used to be a `<script>` tag
  embedded inline in a markdown page — it silently broke under this
  theme's `navigation.instant` (client-side page transitions don't re-run
  an injected `<script>` tag, only a real full page load does). Replaced
  by the two fully static generated pages above, which don't depend on a
  script running after navigation at all.

[Unreleased]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/v0.1.0...HEAD
[1.0.0]: https://github.com/DeepSpaceCartel/devcontainer-builder/releases/tag/v0.1.0
