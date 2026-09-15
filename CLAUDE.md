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

- `service/` — the HTTP service. `src/server.ts` (HTTP listener + request
  validation), `src/build.ts` (clone → configure remote buildx builder →
  `devcontainer build --push`), `src/types.ts` (request/response shapes).
  `Dockerfile` builds the deployable image (Node + `docker-ce-cli` +
  `docker-buildx-plugin` + `@devcontainers/cli`, non-root).
- `charts/devcontainer-builder/` — Helm chart deploying the service
  (Deployment, ClusterIP Service, ServiceAccount, Secret for registry push
  creds with `existingSecret` support). No autoscaling/Ingress by design —
  single ClusterIP instance, in-cluster callers only.
- `terraform/devcontainer-build/` — the Terraform module a Coder Workspace
  Template consumes. Calls the already-running service over HTTP
  (`data "http"`, POST + JSON body) and outputs the built `image`. Does not
  deploy anything itself.
- The Terraform **provider** (`devcontainerbuilder_build` resource, wrapping
  the same service instead of `data "http"` so a build only runs on
  `apply`) is **not** part of this repo — it's split out into
  [DeepSpaceCartel/terraform-provider-devcontainer-builder](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder).
  Coexists with the module. See [ADR-0008](docs/decisions/0008-image-existence-and-deletion-endpoints.md)
  for the `GET`/`DELETE /image` endpoints it depends on. Unpublished —
  local-only via `dev_overrides`.

## Conventions

- The Terraform module is a pre-publish working copy of a future Coder
  Registry module. Follow that registry's variable/output conventions so
  porting it into `registry/<namespace>/modules/devcontainer-build/` later is
  mechanical: variable block field order `description → type → default →
  validation → sensitive`; every `output` has a `description`; secrets
  (`git_username`, `git_token`) are `sensitive = true`; no hardcoded values
  that should be configurable.
- `data "http"` always executes its request during `plan` (there's no way to
  defer it) — don't write `.tftest.hcl` assertions against
  `data.http.build`'s result unless a real service is reachable or a
  `mock_provider "http"` block is added. Keep tests limited to variable
  validation failures (see `build.tftest.hcl`) until that's addressed.
- Git credentials in `service/src/build.ts` go through a scratch `.netrc`
  (`withNetrcEnv`), never argv or an embedded URL — preserve that pattern for
  any future credential-handling changes so tokens don't leak into `ps` output
  or git's on-disk remote config.
- `.terraform*` and `node_modules/`/`dist/` are gitignored — don't commit
  provider lock files or build output (mirrors `/root/registry`'s
  convention for module directories).

## Status / next steps

Scaffold only — not yet wired into real infrastructure. See `README.md`
"Status" for what's still open (build validated end-to-end against a live
BuildKit endpoint, chart consumed from `rts-terraform`, module published to
the public Coder Registry, request/response contract locked down before
writing real `.tftest.hcl` coverage for the `http` call).
