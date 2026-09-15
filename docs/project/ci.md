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

## What isn't covered yet

- The real BDD suite, since it needs a live cluster.
- A `mkdocs build --strict` check for this documentation site — see the
  [`mkdocs` skill](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/.agents/skills/mkdocs)'s
  own guidance on wiring that in as a job scoped to `docs/**`/`mkdocs.yml`
  changes, paired with a separate deploy-on-merge job.
