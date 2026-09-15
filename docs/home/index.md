<title>devcontainer-builder</title>

# devcontainer-builder

Builds a container image from a git repository's `.devcontainer.json`
using a remote [BuildKit](https://github.com/moby/buildkit) builder, and
pushes it to a registry — so a [Coder](https://github.com/coder/coder)
Workspace Template running on Kubernetes can boot a workspace straight
from a repo URL. You don't roll your own CI/CD pipeline to build and keep
track of every project's own image variant — point devcontainer-builder at
the repo and it handles the rest.

## The whole idea, in one request

Say you already have a repo with a `.devcontainer.json` at its root —
`example/example-devcontainer.git`, one of this project's own real BDD
fixtures, works as a stand-in. Point a running devcontainer-builder
instance at it:

### Request

```console
$ curl -s -X POST http://devcontainer-builder.internal:8080/build \
    -H 'Content-Type: application/json' \
    -d @payload.json
```

### Payload

```json
{
  "repository": "https://github.com/example/example-devcontainer.git",
  "image": {
    "registry": "ghcr.io/example"
  }
}
```

### Response

```json
{
  "image":"ghcr.io/example/example-devcontainer:sha-a1b2c3d"
}
```

That's the entire contract: a git `repository` (and whatever's needed
to clone/push it) in, a real, pushed image reference out. What happened
in between — a shallow clone, `docker buildx` pointed at a remote
BuildKit daemon (no local `dockerd`), `devcontainer build --push` — is
covered in [Architecture](../concepts/architecture.md); the exact shape of
this request and its error responses are in the
[HTTP API reference](../reference/API.md).

<div class="grid cards" markdown>

-   :material-application-braces:{ .lg .middle } **Application**

    ---

    How a request becomes a pushed image, credential handling, the HTTP
    API, and every configuration source.

    [:octicons-arrow-right-24: Read the docs](../concepts/architecture.md)

-   :simple-helm:{ .lg .middle } **Helm Chart**

    ---

    Deploy the service into a Kubernetes cluster — every value, including
    the optional bundled BuildKit dependency.

    [:octicons-arrow-right-24: Chart reference](../reference/HELM.md)

-   :simple-terraform:{ .lg .middle } **Terraform**

    ---

    The module a Workspace Template calls, and the provider giving it
    plan-time safety.

    [:octicons-arrow-right-24: Terraform reference](../reference/TERRAFORM.md)

-   :material-hammer-wrench:{ .lg .middle } **Project**

    ---

    Running it locally, running the real BDD suite, and what CI checks
    on every PR.

    [:octicons-arrow-right-24: Get set up](../project/installing.md)

-   :material-history:{ .lg .middle } **Decisions**

    ---

    Why BuildKit is remote-only, why credentials never touch argv, and
    the other architectural calls this project has made — and why.

    [:octicons-arrow-right-24: Read the decision log](../decisions/index.md)

</div>

## Why this exists

Coder Workspace Templates on Kubernetes need a container image at
pod-scheduling time. Templates are applied by coderd's own isolated
Terraform provisioner, which can't install tools once and reuse that
across workspace provisions — so building the devcontainer image has to
happen in a separate, long-running service, called from the template the
same way it already calls out to Kubernetes to provision a
`PersistentVolumeClaim` before the pod.

