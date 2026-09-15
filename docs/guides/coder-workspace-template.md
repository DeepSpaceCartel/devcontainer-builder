<title>Coder Workspace Template</title>

# Guide: a Coder Workspace Template that builds from a git URL

Wire devcontainer-builder into a real
[Coder](https://github.com/coder/coder) Workspace Template so creating a
workspace looks like: type in a git repository URL, get a running pod built
from its `.devcontainer.json` — no separate `curl /build` step, no
hand-authored Dockerfile. The real, runnable template this guide walks
through lives at
[`templates/coder-kubernetes/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/templates/coder-kubernetes),
adapted from the official
[`coder/kubernetes`](https://registry.coder.com/templates/coder/kubernetes)
registry template — the only real change is what feeds the container's
`image`.

## What this template does — and, just as importantly, doesn't do

The template's `devcontainerbuilder_build` resource (from the
[Terraform provider](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder))
calls an **already-running** devcontainer-builder instance's `POST /build`
whenever a workspace is created, and wires the real, pushed image it
returns straight into `kubernetes_deployment_v1.main`'s container `image` —
that part is genuinely new versus the upstream template's fixed `image`
variable.

What it deliberately does **not** do: deploy devcontainer-builder itself,
or BuildKit. Both are **cluster-level platform infrastructure**, set up
once by whoever administers the cluster — not per-workspace-template state.
This isn't a corner cut for time; a `devcontainerbuilder_build` resource
inside the template would need a devcontainer-builder endpoint that already
exists and is reachable before the template's own `terraform apply` (run by
coderd's provisioner, on every workspace create) even starts — there's no
hook to stand up a brand-new Service and wait for it mid-apply. It's the
same "can't configure a provider from a value computed in the same apply"
problem that splitting infrastructure into separate Terraform states
generally exists to solve. And BuildKit's default mode is genuinely
privileged (see [ADR-0001](../decisions/0001-remote-buildkit-builder.md)) —
not something to grant a PodSecurity exemption for on every ephemeral
workspace-template apply.

## Prerequisites

- A Coder deployment, already running, with a Kubernetes cluster it can
  provision workspaces into.
- Cluster-admin access to that same cluster, to deploy the platform-level
  pieces below **once**.
- The [Terraform provider](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder)
  installed wherever `coder templates push` runs from (or already available
  from the public Terraform Registry, once published — see that repo's
  README for current status).

## 1. Deploy devcontainer-builder (and, optionally, BuildKit) as platform infrastructure

If you already run BuildKit somewhere reachable from this cluster, just
point `buildkit.endpoint` at it:

```bash
helm install devcontainer-builder oci://ghcr.io/deepspacecartel/charts/devcontainer-builder \
  --namespace devcontainer-builder --create-namespace \
  --set buildkit.endpoint="tcp://<your-buildkit-host>:<port>" \
  --set registryAuth.registries[0].registry=https://index.docker.io/v1/ \
  --set registryAuth.registries[0].username=<user> \
  --set registryAuth.registries[0].password=<token>
```

Starting from nothing? Skip sourcing a second chart — bundle BuildKit with
this one (see [Helm chart reference](../reference/HELM.md#buildkit) for the
real, non-optional PodSecurity prerequisite this doesn't remove):

```bash
helm install devcontainer-builder oci://ghcr.io/deepspacecartel/charts/devcontainer-builder \
  --namespace devcontainer-builder \
  --set buildkit.deploy.enabled=true \
  --set registryAuth.registries[0].registry=https://index.docker.io/v1/ \
  --set registryAuth.registries[0].username=<user> \
  --set registryAuth.registries[0].password=<token>
```

Note **no `--create-namespace`** in the second command — the chart creates
and labels its own release namespace when `buildkit.deploy.enabled` is
true; passing both conflicts. Confirm it's actually ready before moving on
(see [Quickstart](../home/quickstart.md)'s same check):

```bash
kubectl port-forward -n devcontainer-builder svc/devcontainer-builder 8080:8080 &
curl -s http://localhost:8080/health/ready
```

!!! danger "Never expose this Service outside the cluster"
    Same warning as the [Quickstart](../home/quickstart.md) — the API has
    no authentication of its own. `ClusterIP` only, reachable from wherever
    `coder templates push`/coderd's provisioner runs (inside the cluster),
    nothing else.

## 2. Push the template

```bash
git clone https://github.com/DeepSpaceCartel/devcontainer-builder.git
cd devcontainer-builder/templates/coder-kubernetes

coder templates push devcontainer-kubernetes \
  --var namespace=coder-workspaces \
  --var devcontainer_builder_endpoint=http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080
```

`namespace` and `devcontainer_builder_endpoint` are **template-level**
variables — set once here, not per-workspace. `image_pull_secret_name`,
`git_credentials_username`/`git_credentials_token` are optional template
variables too (see the template's own `variable` blocks for what each
does); leave them unset to start.

## 3. Create a workspace

In the Coder UI (or `coder create`), the workspace-level parameters are
now **Git repository** and **Branch** — instead of a fixed image. Point it
at any repo with a `.devcontainer.json` (or `.devcontainer/devcontainer.json`)
at its root:

```bash
coder create my-workspace --template devcontainer-kubernetes \
  --parameter repository=https://github.com/microsoft/vscode-remote-try-node.git
```

`coder create` calls the template's `terraform apply`, which runs
`devcontainerbuilder_build` (a real clone + build + push against the
platform infrastructure from step 1), then boots
`kubernetes_deployment_v1.main` from the image it returns.

## Real gotchas worth knowing before you hit them

- **A private registry needs `image_pull_secret_name`.** devcontainer-builder
  pushing an image is a separate concern from the *Kubernetes node* being
  able to *pull* it back — if `registryAuth`/the resolved registry is
  private, create a `kubernetes.io/dockerconfigjson` Secret in the
  template's `namespace` and pass its name as the
  `image_pull_secret_name` template variable, or every workspace's pod will
  sit in `ImagePullBackOff`.
- **`repository`/`branch` are immutable workspace parameters** (see the
  template's `data "coder_parameter"` blocks) — changing them on an
  existing workspace doesn't trigger a rebuild-in-place; it forces a new
  resource, same as any other immutable Coder parameter. That's deliberate,
  matching `devcontainerbuilder_build`'s own "every attribute forces
  replacement" design (see that provider's README) — there's no
  partial-update story on the service side to rebuild in place anyway.
- **Git/registry credentials default to devcontainer-builder's own ambient
  config**, not anything workspace- or template-specific — the simplest,
  most common case (public repo, one shared push registry) needs zero
  credential wiring in the template at all. The optional
  `git_credentials_username`/`git_credentials_token` template variables
  exist for a template-wide default that's still simpler than per-host
  server config; see
  [Credential handling](../concepts/credential-handling.md) for the full
  resolution order.
