<title>CI</title>

# CI

[`.github/workflows/ci.yaml`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/.github/workflows/ci.yaml)
runs three independent jobs on every push to `main` and every pull
request — none of them run the real BDD suite (it needs a real cluster;
see [Running the tests](testing.md)'s prerequisites), so it isn't a CI
job today.

| Job | Runs |
|---|---|
| `service` | `npm install` + `npm run build` (`service/`) — the TypeScript compiles. |
| `chart` | `helm lint`, then `helm template` (`charts/devcontainer-builder`) — the chart's own real rendering succeeds. |
| `terraform` | `terraform fmt -check -recursive`, `terraform init`, `terraform validate`, `terraform test` (`terraform/devcontainer-build/`) — including a real, mocked contract test against `devcontainerbuilder_build`, see the [module reference](../reference/TERRAFORM.md#why-this-wraps-the-provider-instead-of-data-http). |

## Docs

[`.github/workflows/docs.yaml`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/.github/workflows/docs.yaml)
runs `mkdocs build --strict` on every push/PR touching `docs/**` or
`mkdocs.yml`, and deploys via the Actions-based GitHub Pages flow
(`actions/upload-pages-artifact` + `actions/deploy-pages`, not a `gh-pages`
branch) on every push to `main`.

## Release

[`.github/workflows/release.yaml`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/.github/workflows/release.yaml)
triggers on a `vX.Y.Z` tag and stamps the npm/CLI package, the Docker image,
and the Helm chart with the same version, strictly in that order: `npm
publish` of `@deepspacecartel/devcontainer-builder` first, then a multi-arch
(`linux/amd64`/`linux/arm64`) image build+push to
`ghcr.io/deepspacecartel/devcontainer-builder` (the `release` Dockerfile
target installs that exact just-published npm version rather than building
from this checkout's source — see [Installing](installing.md#the-container-image)),
then `helm package`+`helm push` to `oci://ghcr.io/deepspacecartel/charts`,
followed by a GitHub Release with generated notes.

`image` depends on `npm` succeeding, so `npm`'s
[Trusted Publisher](https://docs.npmjs.com/trusted-publishers) grant on
npmjs.com has to be the full `publish` action (not the stricter `stage`
option, which needs a separate manual, 2FA-gated approval step) — otherwise
a tag push would stall waiting on a human before any image could build.

## What isn't covered yet

- The real BDD suite, since it needs a live cluster.
