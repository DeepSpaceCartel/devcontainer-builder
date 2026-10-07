# devcontainer-build

> **Deprecated** in devcontainer-builder 1.0 and removed in 2.0. Use the
> [Terraform provider](https://registry.terraform.io/providers/deepspacecartel/devcontainer-builder)'s
> `devcontainerbuilder_build` resource directly - this module only wraps it,
> and the provider is the one Terraform surface 1.x promises to keep stable:
>
> ```tf
> terraform {
>   required_providers {
>     devcontainerbuilder = {
>       source  = "deepspacecartel/devcontainer-builder"
>     }
>   }
> }
>
> provider "devcontainerbuilder" {
>   endpoint = "http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080"
> }
>
> resource "devcontainerbuilder_build" "this" {
>   repository = "https://github.com/example/example-devcontainer.git"
>   branch     = "main"
> }
>
> # devcontainerbuilder_build.this.image => "ghcr.io/example/example-devcontainer:sha-abc1234"
> ```

Calls a running [devcontainer-builder](../../service) service to build a
container image from a repository's `.devcontainer.json` (using a remote
BuildKit builder) and exposes the resulting image reference as an output.

Intended to be used by a Coder Workspace Template the same way it uses a
`kubernetes_persistent_volume_claim_v1` resource - provisioned before the
workspace pod, whose result (here, an image reference instead of a PVC name)
feeds into the pod spec.

This module does not deploy the service itself - see the
[Helm chart](../../charts/devcontainer-builder) for that.

## Usage

```tf
module "devcontainer_build" {
  source = "./terraform/devcontainer-build"

  service_url    = "http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080"
  repository     = "https://github.com/example/example-devcontainer.git"
  branch         = "main"
  image_registry = "ghcr.io/example"
  image_name     = "example-devcontainer"
  image_tag      = "sha-abc1234"
}

# module.devcontainer_build.image => "ghcr.io/example/example-devcontainer:sha-abc1234"
```

For a private repository, also set `git_username` and `git_token`.

> It was meant to move into the Coder Registry as a module; the complete
> Coder template (`templates/coder-kubernetes/`) goes there instead.
