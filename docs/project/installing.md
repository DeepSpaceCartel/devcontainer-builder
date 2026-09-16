<title>Installing</title>

# Installing

## Prerequisites

Opening this repo in the provided
[`.devcontainer/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/.devcontainer)
(VS Code Dev Containers, or any Dev Container-compatible tool) gets you
everything below for free — its `postCreateCommand.sh` installs Helm,
Terraform, the GitHub CLI, `kubectl`, the Docker CLI + `buildx` plugin,
and the `@devcontainers/cli`, on top of the base
`mcr.microsoft.com/devcontainers/typescript-node:1-20-bookworm` image
(Node 20 already included). Versions are deliberately unpinned there,
matching CI's own unpinned `setup-helm`/`setup-terraform` actions.

Outside a Dev Container, you need real, working installs of: Node 20,
Docker CLI with the `buildx` plugin, `@devcontainers/cli`, and `git` —
the same set `service/Dockerfile` installs into the deployable image
itself.

## The service

```bash
cd service
npm install
npm run build      # tsc -> dist/
npm run start       # node dist/index.js - needs BUILDKIT_ENDPOINT
```

`npm run start` runs the real, compiled entrypoint — it needs a real
`BUILDKIT_ENDPOINT` pointed at a reachable BuildKit daemon before
`/health/ready` reports ready, and a real git host to clone from before
`/build` can do anything. See [Configuration](../reference/CONFIGURATION.md)
for every other source it reads at startup.

### As a standalone CLI

The same server is published to npm and runnable directly, without cloning
this repo:

```bash
npx @deepspacecartel/devcontainer-builder --buildkit-endpoint tcp://buildkit.example:1234
```

Still needs `docker` (with the `buildx` plugin), `@devcontainers/cli`, and
`git` on `PATH` locally — the CLI doesn't bundle or replace any of them,
same prerequisites the Docker image bakes in below. Every flag/env
var/settings-file field is identical either way — see
[Configuration](../reference/CONFIGURATION.md).

### The container image

`service/Dockerfile` has two build targets, sharing one runtime base (`git`,
the Docker CLI + `buildx` plugin — no `dockerd`, see
[0001](../decisions/0001-remote-buildkit-builder.md) — `@devcontainers/cli`,
a non-root `builder` user):

```bash
# dev: builds from this checkout's source (tsc -> dist/), no network
# dependency beyond npm's own lockfile install. This is also what a bare
# `docker build service/` produces, with no --target at all - use it for
# local iteration and testing against a local cluster.
docker build --target dev -t devcontainer-builder service/

# release: installs a specific version of the published npm package
# instead of building from source, so the image is provably the same
# artifact as what's live on npm. Needs that version to already be
# published - this is what .github/workflows/release.yaml builds.
docker build --target release --build-arg PACKAGE_VERSION=0.1.0 \
  -t devcontainer-builder service/
```

## The Helm chart

```bash
helm lint charts/devcontainer-builder
helm template charts/devcontainer-builder -f my-values.yaml
```

See the [Helm chart reference](../reference/HELM.md) for every value.

## The Terraform module

```bash
cd terraform/devcontainer-build
terraform init
terraform fmt -check -diff
terraform validate
terraform test    # real contract tests, mocked - no live service needed
```

See the [Terraform module reference](../reference/TERRAFORM.md).

!!! note "Node/npm availability isn't guaranteed in every environment"
    If `npm`/`node` aren't on `PATH`, don't assume the TypeScript
    compiles — verify it or ask, rather than reporting success on faith.

## This documentation site

```bash
# The two HTTP API nav entries (mkdocs.yml) need three real, generated
# paths to exist first - all gitignored, not source, all regenerated from
# the service's own schemas:
cd service && npm install && npm run build
OPENAPI_OUTPUT_PATH=../docs/openapi.json node scripts/export-openapi.mjs
npx redocly build-docs ../docs/openapi.json -o ../docs/api-reference.html
SWAGGER_UI_OUTPUT_DIR=../docs/api-swagger-ui node scripts/export-swagger-ui.mjs
cd ..

python3 -m venv .venv-docs && . .venv-docs/bin/activate
pip install -r docs/requirements.txt
mkdocs serve            # live preview at http://127.0.0.1:8000
mkdocs build --strict   # what CI should run on every docs/** change
```

`docs/api-reference.html` (Redoc) and `docs/api-swagger-ui/` (the exact
static bundle `GET /documentation` serves live, pointed at the sibling
`openapi.json` instead of a live route) are both real standalone pages,
each its own top-level nav entry ("HTTP API (Redoc)"/"HTTP API (Swagger
UI)", `mkdocs.yml`) — not a hand-written Markdown page wrapping a widget
embedded inline in an mkdocs-material page. An earlier version tried the
latter (Redoc only, as a section on a hand-written `docs/reference/API.md`)
and it silently broke under `navigation.instant` (this theme's SPA-style
client-side page transitions don't re-run a `<script>` tag injected via a
normal client-side DOM patch, only a real full page load does).

`--strict` is what actually catches a broken internal link or a heading
renamed without updating what links into it — run it after any edit
that touches a link or a heading, not just once at the end.

!!! note "`docs/claude/` is deliberately excluded from this site's nav"
    `docs/claude/plans/` and `docs/claude/notes/` are internal
    planning/investigation records, not part of the published site —
    `mkdocs build` reports them as "exists but not in nav" (an `INFO`,
    not a failure); that's intentional, not an oversight. See the
    [Decision log](../decisions/index.md) for how those differ from a
    real ADR.
