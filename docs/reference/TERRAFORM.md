<title>Terraform module</title>

# Terraform module

[`terraform/devcontainer-build`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/terraform/devcontainer-build)
calls an already-running devcontainer-builder instance and exposes the
pushed image reference as an output — the module deploys nothing itself.
Internally it wraps the [Terraform provider](TERRAFORM-PROVIDER.md)'s
`devcontainerbuilder_build` resource (owning its own `provider
"devcontainerbuilder"` configuration, sourced from `service_url`) rather
than calling [`POST /build`](API.md#post-build) directly via `data "http"`
— the same variable/output interface either way, but a real build now only
runs on `terraform apply`, and only for an actual diff, not on every single
`terraform plan` (see [the provider reference](TERRAFORM-PROVIDER.md) for
why that matters).

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

## Why this wraps the provider instead of `data "http"`

An earlier version of this module called `POST /build` directly via
`data "http"` — a real quirk of that approach was the actual motivation for
building the [Terraform provider](TERRAFORM-PROVIDER.md) in the first
place: a `data "http"` block can't be deferred, so it made the real
clone+build+push call on every single `terraform plan`, not just `apply`.
Now that the provider exists, this module wraps its
`devcontainerbuilder_build` resource internally instead — real builds only
happen on `apply`, for an actual diff, and `build.tftest.hcl` can assert
against a real (mocked, via Terraform's `mock_provider`) result without
needing a live, reachable service at all. See that test file for the real
contract test this enables.

Both the module and the provider are meant to coexist — see
[Module or provider?](TERRAFORM-PROVIDER.md#module-or-provider) for when to
reach for which.

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
