<title>CI</title>

# CI

[`.github/workflows/ci.yaml`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/.github/workflows/ci.yaml)
runs independent jobs on every push to `main` and every pull
request (a newer push to a PR cancels its superseded run) — none of them run the real BDD suite (it needs a real cluster;
see [Running the tests](testing.md)'s prerequisites), so it isn't a CI
job today.

| Job | Runs |
|---|---|
| `service` | `npm install` + `npm run build` (`service/`) — the TypeScript compiles. |
| `service-image` | Builds the service image's `dev` target (`service/Dockerfile`) without pushing it — a Dockerfile break shows up on the PR, not at release time. |
| `vscode-extension` | `npm install`, build, `npm test`, `npm run package` (`vscode-extension/`). |
| `chart` | `helm lint`, then `helm template` (`charts/devcontainer-builder`) — the chart's own real rendering succeeds. |
| `terraform` | `terraform fmt -check -recursive`, `terraform init`, `terraform validate`, `terraform test` (`terraform/devcontainer-build/`) — including a real, mocked contract test against `devcontainerbuilder_build`, see the [module reference](../reference/TERRAFORM.md#why-this-wraps-the-provider-instead-of-data-http). |
| `template` | `terraform fmt -check`, `terraform init -backend=false`, `terraform validate` (`templates/coder-kubernetes/`). No plan: that needs a Coder deployment. |

Every workflow runs with a read-only `GITHUB_TOKEN` by default; jobs that
publish get more, scoped to that job. Third-party actions are pinned to
full commit SHAs (the version in a trailing comment), and
[Dependabot](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/.github/dependabot.yml)
updates them, and the npm dependencies of `service/`, `vscode-extension/`
and `tools/screenshots/`, weekly in grouped PRs.

## Docs

[`.github/workflows/docs.yaml`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/.github/workflows/docs.yaml)
runs `mkdocs build --strict` on every push/PR touching `docs/**` or
`mkdocs.yml`, and deploys via the Actions-based GitHub Pages flow
(`actions/upload-pages-artifact` + `actions/deploy-pages`, not a `gh-pages`
branch) on every push to `main`. Only the deploy job has Pages and OIDC
permissions, and runs are grouped per ref, so a PR's build never cancels a
`main` deploy.

## Release

[`.github/workflows/release.yaml`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/.github/workflows/release.yaml)
triggers on a `vX.Y.Z` tag and stamps the npm/CLI package, the Docker image,
and the Helm chart with the same version, strictly in that order: `npm
publish` of `@deepspacecartel/devcontainer-builder` first, then a multi-arch
(`linux/amd64`/`linux/arm64`) image build+push to
`ghcr.io/deepspacecartel/devcontainer-builder` (the `release` Dockerfile
target installs that exact just-published npm version rather than building
from this checkout's source — see [Developing](installing.md#the-container-image)),
then `helm package`+`helm push` to `oci://ghcr.io/deepspacecartel/charts`,
followed by a GitHub Release with generated notes. The VS Code extension is
packaged in the same run, attached to the release, and published to the VS
Code Marketplace and Open VSX.

The `version` job rejects a tag that isn't SemVer. A **pre-release** tag
(`v1.0.0-rc.1`) runs the same pipeline with three differences: npm
publishes under the `next` dist-tag, the `latest` image tag doesn't move,
and the Marketplace/Open VSX jobs are skipped (the Marketplace rejects
SemVer pre-release versions); the GitHub Release is marked pre-release. A
final release moves `latest` (image tag, npm dist-tag, GitHub's latest
release) only if it's the highest release tag, so a patch on an older line
can't drag it backwards; such a patch publishes to npm as `release-X.Y`.
Runs are serialized per tag and never cancelled midway.

`image` depends on `npm` succeeding, so `npm`'s
[Trusted Publisher](https://docs.npmjs.com/trusted-publishers) grant on
npmjs.com has to be the full `publish` action (not the stricter `stage`
option, which needs a separate manual, 2FA-gated approval step) — otherwise
a tag push would stall waiting on a human before any image could build.

## What isn't covered yet

- The real BDD suite, since it needs a live cluster.
