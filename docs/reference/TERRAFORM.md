<title>Terraform module</title>

# Terraform module

[`terraform/devcontainer-build`](https://github.com/alexanderilyin/devcontainer-builder/tree/main/terraform/devcontainer-build)
calls an already-running devcontainer-builder instance's
[`POST /build`](API.md#post-build) and exposes the pushed image
reference as an output — the module deploys nothing itself. It's a
pre-publish working copy of a future Coder Registry module; see
[0005](../decisions/0005-bdd-suite-on-thomas.md)'s neighboring status
note in the [index](../home/index.md) for what "pre-publish" means today.

```hcl
module "devcontainer_build" {
  source     = "./terraform/devcontainer-build"
  service_url = "http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080"
  repository  = "https://github.com/example/example-devcontainer.git"
}

output "built_image" {
  value = module.devcontainer_build.image
}
```

## Variables

| Variable | Type | Default | Notes |
|---|---|---|---|
| `service_url` | `string` | *(required)* | Base URL of a running instance, no trailing slash. |
| `repository` | `string` | *(required)* | Git URL of the repo containing the `.devcontainer.json`. |
| `branch` | `string` | `"main"` | |
| `git_username` | `string` (sensitive) | `""` | Leave empty for a public repository. |
| `git_token` | `string` (sensitive) | `""` | |
| `image_registry` | `string` | `""` | Leave empty to let the service resolve one from its own [mapping rules](CONFIGURATION.md#registry-mapping-rule) — the request fails if none matches. |
| `image_name` | `string` | `""` | Leave empty to let the service derive it from the repository path. |
| `image_tag` | `string` | `""` | Leave empty to let the service derive it from the built commit's sha. |
| `registry_username` | `string` (sensitive) | `""` | Requires `image_registry` — see the precondition below. |
| `registry_password` | `string` (sensitive) | `""` | |

## Outputs

| Output | Description |
|---|---|
| `image` | The built and pushed image reference, e.g. `ghcr.io/org/repo-devcontainer:sha-abc1234`. |

## A real Terraform quirk: `data "http"` always executes during `plan`

There's no way to defer a `data "http"` block — it makes the real
`POST /build` call (a real clone + build + push, not a cheap read)
every time Terraform runs `plan`, not just `apply`. This means
`build.tftest.hcl` can't assert against `data.http.build`'s real result
without either a live, reachable service or a `mock_provider "http"`
block — tests are currently limited to variable-validation failures
(the precondition below and the required-variable checks), not the real
HTTP round trip.

This exact limitation is the motivation for a companion **Terraform
provider** — [`terraform-provider-devcontainer-builder`](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder),
a `devcontainerbuilder_build` *resource* instead of a `data` source, so the
build only runs on `apply`, and only when there's an actual diff. See that
repo's [`README.md`](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder/blob/main/README.md).
Both are meant to coexist for now — this module isn't being replaced.

## The one real precondition

```hcl
lifecycle {
  precondition {
    condition     = var.registry_username == "" || var.image_registry != ""
    error_message = "image_registry must be set when registry_username is provided (registry_credentials needs to know which registry the credentials are for)."
  }
}
```

`registryCredentials` in the real `/build` request needs a `registry`
field — supplying `registry_username`/`registry_password` without
`image_registry` would build a credential the service can't associate
with any registry, so Terraform catches it at `plan` time instead of
letting the service reject it at request time.

## Conventions this module follows for its eventual Coder Registry publication

- Variable block field order: `description → type → default →
  validation → sensitive`.
- Every `output` has a `description`.
- Secrets (`git_username`, `git_token`, `registry_username`,
  `registry_password`) are `sensitive = true`.
- No hardcoded value that should be configurable.
