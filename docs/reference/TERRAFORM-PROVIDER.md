<title>Terraform provider</title>

# Terraform provider

[`terraform-provider-devcontainer-builder`](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder)
wraps the same [`POST /build`/`GET`/`DELETE /image`](../api-reference.html){:target="_blank" rel="noopener"}
and [`GET /devcontainer`](../api-reference.html){:target="_blank" rel="noopener"}
endpoints as a `devcontainerbuilder_build` **resource** and a
`devcontainerbuilder_devcontainer` **data source**. A build only runs on
`terraform apply`, and only when there's an actual diff to reconcile (a
`data "http"` call, by contrast, executes on every `terraform plan`).
Published on the Terraform Registry as `deepspacecartel/devcontainer-builder`.
It is the Terraform surface 1.x keeps stable; the
[module](TERRAFORM.md) is deprecated.

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

Read-only, from the `/build` response:

| Attribute | Notes |
|---|---|
| `image` | The pushed image reference, e.g. `ghcr.io/org/repo:sha-abc1234`. |
| `id` | Same value as `image`; the service has no separate build ID. |
| `resolved_registry`, `resolved_name`, `resolved_tag` | What the service actually used. Pass them to `devcontainerbuilder_devcontainer` (below). |
| `commit` | Full SHA of the commit the image was built from. Check it out in the workspace to get the working copy that matches the image. Null for images built by a service older than v0.3.0. |

**Read** calls `GET /image` for real drift detection — if the built image
was deleted from its registry out-of-band, the resource is removed from
state and the next plan recreates it. **Delete** calls `DELETE /image`,
best-effort (several registries, Docker Hub notably, don't support manifest
deletion at all — that's a normal outcome, not an error).

Full attribute reference with every description:
[the provider repo's generated docs](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder/blob/main/docs/resources/build.md).

## `devcontainerbuilder_devcontainer` (data source)

Reads a built image's Dev Container metadata through
[`GET /devcontainer`](../api-reference.html){:target="_blank" rel="noopener"}
(see [ADR-0011](../decisions/0011-devcontainer-metadata-endpoint.md) and
[ADR-0012](../decisions/0012-dev-container-to-kubernetes-runtime-mapping.md)):
the Dev Containers CLI's merged configuration, lifecycle hooks rendered as
ready-to-run POSIX `sh` scripts, VS Code extensions and settings, and the
container settings translated into pod terms. It is what
[`templates/coder-kubernetes/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/templates/coder-kubernetes)
uses to configure the workspace pod.

```hcl
data "devcontainerbuilder_devcontainer" "example" {
  registry = devcontainerbuilder_build.example.resolved_registry
  name     = devcontainerbuilder_build.example.resolved_name
  tag      = devcontainerbuilder_build.example.resolved_tag
}
```

| Input | Required | Notes |
|---|---|---|
| `registry`, `name`, `tag` | yes | The image to read, normally a build's `resolved_*` attributes. |
| `platform` | no | `os/arch[/variant]` to read from a multi-platform image. The service defaults to `linux/amd64`. |
| `registry_credentials.{username,password}` | no | Credentials for this read. Unset: the service's own credentials for the registry. |

| Read-only attribute | Notes |
|---|---|
| `id` | `<registry>/<name>:<tag>`. |
| `digest` | Digest of the manifest the metadata was read from. |
| `remote_user`, `container_user` | Merged `remoteUser` / `containerUser`; null when unset. |
| `workspace_folder` | `devcontainer.json`'s `workspaceFolder`, raw. Needs an image built by v0.3.0+. |
| `lifecycle_scripts` | Map of hook name (`onCreateCommand` … `postAttachCommand`) to one `sh` script, only for hooks something sets. Use `lookup(…, hook, "")`. |
| `env_scripts` | `containerEnv` / `remoteEnv` as `export` scripts, to source in that order. |
| `extensions`, `settings_json` | VS Code extensions (de-duplicated) and merged settings (JSON string). |
| `forward_ports` | Numeric `forwardPorts` with `label`, `protocol`, `on_auto_forward`. |
| `mounts` | Volume and tmpfs mounts (`kind`, `source`, `target`, `read_only`); bind mounts are dropped with a warning. |
| `host_requirements` | `cpus`, `memory_bytes`, `storage_bytes`, `gpu_json`; null fields when unset. The template treats them as minimums ([ADR-0014](../decisions/0014-host-requirements-are-minimums.md)). |
| `runtime` | Pod settings: `remote_user_uid`/`gid`/`home`, `cap_add`, `privileged`, `init`, `seccomp_unconfined`, `shm_size_bytes`, `hostname`, `host_aliases`. |
| `variables` | Every `${…}` variable the image uses (`kind`, `name`, `default`, `used_in`). Scripts read them from shell variables set at runtime. |
| `configuration_json`, `metadata_json` | The full merged configuration and the raw label entries, as JSON strings. |
| `warnings` | What the service couldn't represent faithfully. |

Full reference:
[the provider repo's generated docs](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder/blob/main/docs/data-sources/devcontainer.md).

## The module is deprecated

The [`terraform/devcontainer-build` module](TERRAFORM.md) only wraps
`devcontainerbuilder_build`, and is deprecated in 1.0 (removal in 2.0). New
configurations should use the provider directly, as
[`templates/coder-kubernetes/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/templates/coder-kubernetes)
does (see [Operating the template](../guides/coder-workspace-template.md)).
Moving from the module means declaring the provider in your own
`required_providers` block and replacing the `module` block with a
`devcontainerbuilder_build` resource; `module.<name>.image` becomes
`devcontainerbuilder_build.<name>.image`.
