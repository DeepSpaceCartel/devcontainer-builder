<title>Terraform provider</title>

# Terraform provider

[`terraform-provider-devcontainer-builder`](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder)
wraps the same [`POST /build`/`GET`/`DELETE /image`](../api-reference.html){:target="_blank" rel="noopener"}
endpoints as the [module](TERRAFORM.md) — as a real `devcontainerbuilder_build`
**resource** instead of a `data "http"` source, so a build only runs on
`terraform apply`, and only when there's an actual diff to reconcile
(`data "http"` has no way to defer its call — it executes on every single
`terraform plan`). Published on the Terraform Registry as
`deepspacecartel/devcontainer-builder`.

```hcl
terraform {
  required_providers {
    devcontainerbuilder = {
      source = "deepspacecartel/devcontainer-builder"
    }
  }
}

provider "devcontainerbuilder" {
  endpoint = "http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080"
}

resource "devcontainerbuilder_build" "example" {
  repository = "https://github.com/deepspacecartel/devcontainer-builder-examples.git"
  branch     = "node"

  image_spec = {
    registry = "ghcr.io/example"
  }
}

output "image" {
  value = devcontainerbuilder_build.example.image
}
```

## Provider configuration

| Attribute | Env var fallback | Notes |
|---|---|---|
| `endpoint` | `DEVCONTAINERBUILDER_ENDPOINT` | Base URL of a running devcontainer-builder instance, no trailing slash. No default — one of these two must be set. |
| `request_timeout` | `DEVCONTAINERBUILDER_REQUEST_TIMEOUT` | Go duration string (e.g. `"30m"`). Builds are unbounded clone+build+push calls, so this needs to be generous. Defaults to `30m`. |

## `devcontainerbuilder_build`

Every attribute forces replacement on change — the service has no
partial-update API, so any input change means a brand-new build.

| Attribute | Required | Notes |
|---|---|---|
| `repository` | yes | Git repository URL (`https://`, `ssh://`, or SCP-style). |
| `branch` | no | Defaults to `"main"`. |
| `image_spec.{registry,name,tag}` | no | Any field left unset is derived by the service. |
| `git_credentials.{username,token}` | no | HTTPS git credentials for a private repository — a nested-object **attribute**, not a legacy block; assign it as `{ username = ..., token = ... }` or `null`, never `dynamic "git_credentials" {}`. |
| `registry_credentials.{registry,username,password}` | no | Push credentials, reused for this resource's later `Read`/`Delete` registry calls too. |

Read-only, from the `/build` response: `id` (same value as `image`),
`image`, `resolved_registry`, `resolved_name`, `resolved_tag`.

**Read** calls `GET /image` for real drift detection — if the built image
was deleted from its registry out-of-band, the resource is removed from
state and the next plan recreates it. **Delete** calls `DELETE /image`,
best-effort (several registries, Docker Hub notably, don't support manifest
deletion at all — that's a normal outcome, not an error).

Full attribute reference with every description:
[the provider repo's generated docs](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder/blob/main/docs/resources/build.md).

## Module or provider?

Both are real, both are maintained, and **both are meant to coexist** — pick
per use case, not as a migration from one to the other:

- The [module](TERRAFORM.md) itself now wraps this same provider internally
  (see its own reference page) — reach for it when you want the module's
  stable variable/output interface without depending on the provider
  directly in your own `required_providers` block.
- Use the provider's `devcontainerbuilder_build` resource directly when you
  want its `Read`-based drift detection, or you're already comfortable
  managing providers directly (as
  [`templates/coder-kubernetes/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/templates/coder-kubernetes)
  does — see the [Coder Workspace Template guide](../guides/coder-workspace-template.md)).
