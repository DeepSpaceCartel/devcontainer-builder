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
| `terraform` | `terraform fmt -check -recursive`, `terraform init`, `terraform validate`, `terraform test` (`terraform/devcontainer-build/`) — see the [module reference](../reference/TERRAFORM.md#a-real-terraform-quirk-data-http-always-executes-during-plan) for why `terraform test` is currently limited to offline checks. |

## Docs

[`.github/workflows/docs.yaml`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/.github/workflows/docs.yaml)
runs `mkdocs build --strict` on every push/PR touching `docs/**` or
`mkdocs.yml`, and deploys via the Actions-based GitHub Pages flow
(`actions/upload-pages-artifact` + `actions/deploy-pages`, not a `gh-pages`
branch) on every push to `main`.

## Release

[`.github/workflows/release.yaml`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/.github/workflows/release.yaml)
triggers on a `vX.Y.Z` tag and stamps the Docker image, the Helm chart, and
the npm/CLI package with the same version in one run: multi-arch
(`linux/amd64`/`linux/arm64`) image build+push to
`ghcr.io/deepspacecartel/devcontainer-builder`, `helm package`+`helm push`
to `oci://ghcr.io/deepspacecartel/charts`, and `npm publish` of
`@deepspacecartel/devcontainer-builder`, followed by a GitHub Release with
generated notes.

## What isn't covered yet

- The real BDD suite, since it needs a live cluster.
