<title>devcontainer-builder</title>

# devcontainer-builder

Builds a container image from a git repository's `.devcontainer.json`
using a remote [BuildKit](https://github.com/moby/buildkit) builder, and
pushes it to a registry — so a [Coder](https://github.com/coder/coder)
Workspace Template running on Kubernetes can boot a workspace straight
from a repo URL, without a dedicated CI pipeline to pre-build the image.

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

-   :material-sitemap:{ .lg .middle } **Concepts**

    ---

    How a request becomes a pushed image, how credentials are handled,
    and why the test suite is built the way it is.

    [:octicons-arrow-right-24: Read the concepts](../concepts/architecture.md)

-   :material-book-open-variant:{ .lg .middle } **Reference**

    ---

    The HTTP API, every configuration source and its precedence, and
    the Helm chart's and Terraform module's real inputs.

    [:octicons-arrow-right-24: Look things up](../reference/API.md)

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

## Layout

- [`service/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/service) —
  the HTTP service documented on this site.
- [`charts/devcontainer-builder/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/charts/devcontainer-builder) —
  the Helm chart that deploys it (see the [reference](../reference/HELM.md)).
- [`terraform/devcontainer-build/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/terraform/devcontainer-build) —
  the Terraform module a Workspace Template calls (see the
  [reference](../reference/TERRAFORM.md)).

!!! note "Status: early scaffold"
    Not yet wired into any real infrastructure or published as a Coder
    Registry module. The request/response contract, configuration
    sources, and Helm values documented here are all real and current —
    what's still open is end-to-end deployment (a live BuildKit endpoint,
    the chart consumed from real infrastructure, the module published).
