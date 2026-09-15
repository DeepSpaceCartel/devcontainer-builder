# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

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

### Changed

- The HTTP service is rebuilt on [Fastify](https://fastify.dev) instead of
  a bare `node:http` listener — every documented request/response shape
  and status code is unchanged (verified against every case in
  `service/features/request_validation.feature`).
- `charts/devcontainer-builder/values.yaml`'s `image.repository` now
  defaults to the real, published
  `ghcr.io/deepspacecartel/devcontainer-builder` image.

### Fixed

- `service/package.json`'s `thomas` devDependency no longer points at a
  local sibling directory (`file:../../thomas`) that only resolved in one
  specific development environment — it's pinned to a real
  `github:DeepSpaceCartel/thomas` commit instead, which resolves in a
  fresh clone or CI with no sibling checkout needed.

[Unreleased]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/main...HEAD
