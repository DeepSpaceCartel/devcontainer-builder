# CLAUDE.md

devcontainer-builder: builds a container image from a git repo's
`.devcontainer.json` via a remote BuildKit builder, so a Coder Workspace
Template on Kubernetes can boot straight from a repo URL. See `README.md` for
the why; this file is command/convention reference for working in the repo.

## Commands

```bash
# service/ (Node.js/TypeScript HTTP service)
cd service && npm install                 # Install deps
cd service && npm run build                # Compile TypeScript -> dist/
cd service && npm run start                # Run the compiled server (needs BUILDKIT_ENDPOINT)
cd service && docker build -t devcontainer-builder .   # Build the service image

# charts/devcontainer-builder/ (Helm chart)
helm lint charts/devcontainer-builder
helm template charts/devcontainer-builder -f values-file.yaml   # Render manifests

# terraform/devcontainer-build/ (Terraform module)
cd terraform/devcontainer-build && terraform init
cd terraform/devcontainer-build && terraform fmt -check -diff
cd terraform/devcontainer-build && terraform validate
cd terraform/devcontainer-build && terraform test    # Offline; see note in build.tftest.hcl

```

The Terraform provider (`devcontainerbuilder_build` resource) lives in its
own repo, [DeepSpaceCartel/terraform-provider-devcontainer-builder](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder) —
not in this one. See that repo's `README.md` for its build/dev commands.

Node/npm are not guaranteed to be present in every environment this repo is
worked in — if `npm`/`node` aren't on PATH, say so rather than assuming the
TypeScript compiles; ask the user to verify or run it themselves.

## Structure

- `service/` — the HTTP service, built on [Fastify](https://fastify.dev).
  `src/server.ts` (`buildApp()` — routes + [TypeBox](https://github.com/sinclairzx81/typebox)
  schemas from `src/schemas.ts`, which double as real request validation
  and the generated OpenAPI document at `GET /documentation/json` — never
  hand-authored, bundled statically into the docs site (see
  [Installing](docs/project/installing.md#this-documentation-site))),
  `src/index.ts` (the real entrypoint — `tracing.ts` first, then crash
  handlers, then `buildApp().listen()`), `src/build.ts` (clone → configure
  remote buildx builder → `devcontainer build --push`, both wrapped in an
  OpenTelemetry span with output captured via `src/command-log.ts` instead
  of inherited stdio, see [ADR-0010](docs/decisions/0010-command-output-capture.md)),
  `src/logger.ts` (the shared structured-logging Pino instance, see
  [ADR-0009](docs/decisions/0009-event-oriented-structured-logging.md)),
  `src/tracing.ts` (opt-in OpenTelemetry bootstrap), `src/metrics.ts`
  (Prometheus metrics for `GET /metrics`), `src/types.ts` (request/response
  shapes). `bin/devcontainer-builder.js` is the published npm package's CLI
  entry (`npx @deepspacecartel/devcontainer-builder`) — same compiled
  `dist/index.js` the Docker image runs, no separate CLI parsing of its
  own (every setting is already a CLI flag/env var/settings-file field via
  `src/config.ts`, see [Configuration](docs/reference/CONFIGURATION.md)).
  `Dockerfile` builds the deployable image (Node + `docker-ce-cli` +
  `docker-buildx-plugin` + `@devcontainers/cli`, non-root).
- `charts/devcontainer-builder/` — Helm chart deploying the service
  (Deployment, ClusterIP Service, ServiceAccount, Secret for registry push
  creds with `existingSecret` support). No autoscaling/Ingress by design —
  single ClusterIP instance, in-cluster callers only.
- `terraform/devcontainer-build/` — the Terraform module a Coder Workspace
  Template consumes. Wraps the Terraform provider's
  `devcontainerbuilder_build` resource internally (owns its own `provider
  "devcontainerbuilder"` config, sourced from `var.service_url`) and
  outputs the built `image`. Does not deploy anything itself.
- `templates/coder-kubernetes/` — a real Coder Workspace Template (adapted
  from the official `coder/kubernetes` registry template), wiring a
  workspace-level git-repository parameter through the Terraform
  **provider**'s `devcontainerbuilder_build` resource into
  `kubernetes_deployment_v1.main`'s container image. Deploys neither
  devcontainer-builder nor BuildKit itself — both are cluster-level
  platform infrastructure this template only calls. See
  [docs/guides/coder-workspace-template.md](docs/guides/coder-workspace-template.md).
- The Terraform **provider** (`devcontainerbuilder_build` resource, wrapping
  the same service) is **not** part of this repo — it's split out into
  [DeepSpaceCartel/terraform-provider-devcontainer-builder](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder),
  published on the Terraform Registry as `deepspacecartel/devcontainer-builder`.
  Coexists with the module (which wraps it internally, see above). See
  [ADR-0008](docs/decisions/0008-image-existence-and-deletion-endpoints.md)
  for the `GET`/`DELETE /image` endpoints it depends on.

## Conventions

- The Terraform module is a pre-publish working copy of a future Coder
  Registry module. Follow that registry's variable/output conventions so
  porting it into `registry/<namespace>/modules/devcontainer-build/` later is
  mechanical: variable block field order `description → type → default →
  validation → sensitive`; every `output` has a `description`; secrets
  (`git_username`, `git_token`) are `sensitive = true`; no hardcoded values
  that should be configurable.
- `build.tftest.hcl` mocks the provider (`mock_provider "devcontainerbuilder"`)
  for real contract assertions against `devcontainerbuilder_build.this` -
  no live service needed. Only variable-validation-failure cases stay as
  plain `plan`-mode `expect_failures` runs.
- Git credentials in `service/src/build.ts` go through a scratch `.netrc`
  (`withNetrcEnv`), never argv or an embedded URL — preserve that pattern for
  any future credential-handling changes so tokens don't leak into `ps` output
  or git's on-disk remote config.
- `.terraform*` and `node_modules/`/`dist/` are gitignored — don't commit
  provider lock files or build output (mirrors `/root/registry`'s
  convention for module directories).

