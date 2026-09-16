<title>Quickstart</title>

# Quickstart: zero pre-existing infra, build a public repo, push to GHCR

Deploy devcontainer-builder with Helm — bundling BuildKit too, so there's
nothing else to stand up first — then make one real `/build` request
against a public git repository, pushing the result to GHCR. Every command
below is real — nothing here is pseudocode.

## Prerequisites

- A Kubernetes cluster and `helm` (v3) pointed at it.
- A registry to push to, and credentials for it — a build always needs
  somewhere to push, and (unless the registry allows anonymous pushes,
  which essentially none do) real credentials for it. This walkthrough
  uses [GHCR](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
  and a [PAT scoped to `write:packages`](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
  — a Docker Hub access token works the same way, just a different
  `registry`/host.

No git credentials are needed for this walkthrough — a public
repository clones anonymously; see
[Credential handling](../concepts/credential-handling.md#no-credential-configured-clone-verbatim).

!!! danger "Never expose this Service outside the cluster"
    The API has no authentication of its own — see the
    [HTTP API reference](../api-reference.html){:target="_blank" rel="noopener"}. It's designed to sit behind
    ordinary cluster-internal networking only (the chart's `Service` is
    `ClusterIP`, no `Ingress` — see [Helm chart](../reference/HELM.md)).
    Anyone who can reach `POST /build` can make this service clone
    arbitrary repositories and push arbitrary images using whatever
    credentials it's configured with — don't put an `Ingress`/`LoadBalancer`
    in front of it, and restrict which pods can reach it with a
    `NetworkPolicy` if your cluster is multi-tenant.

## 1. Write a values file

```bash
GHCR_USERNAME=<your-github-username>
```

The chart's [`registryAuth.registries`](../reference/HELM.md#registryauth)
value is a plain list of `{registry, username, password}` entries — the
chart builds the real docker-config-JSON itself, so there's no manual
base64-encoding or hand-built JSON here. `buildkit.deploy.enabled: true`
bundles a real BuildKit instance alongside the service — no separate
BuildKit of your own to source or configure first (see the
[Helm chart reference](../reference/HELM.md#buildkit) for the one real
prerequisite this doesn't remove, and when to point `buildkit.endpoint` at
an existing instance instead):

```yaml title="quickstart-values.yaml"
buildkit:
  deploy:
    enabled: true

registryAuth:
  registries:
    - registry: ghcr.io
      username: <your-github-username> # same value as $GHCR_USERNAME above
      password: <your-write:packages-scoped GitHub PAT>
```

With `registryAuth` configured this way, every `/build` request pushes
using these ambient credentials unless it supplies its own
[`registryCredentials`](../api-reference.html){:target="_blank" rel="noopener"}.

## 2. Install the chart

```bash
helm install devcontainer-builder oci://ghcr.io/deepspacecartel/charts/devcontainer-builder \
  -f quickstart-values.yaml
```

!!! warning "No `--create-namespace`"
    `buildkit.deploy.enabled: true` makes the chart create *and label*
    its own release namespace — see the
    [Helm chart reference](../reference/HELM.md#buildkit) for why passing
    both conflicts.

Confirm it's actually ready — not just that the Pod is `Running`, but
that BuildKit was picked up (see
[`/health/ready`](../api-reference.html){:target="_blank" rel="noopener"}):

```bash
kubectl port-forward svc/devcontainer-builder 8080:8080 &
curl -s http://localhost:8080/health/ready
# {"status":"ready"}
```

## 3. Build a public repo and push it to GHCR

Any public repo with a `.devcontainer/devcontainer.json` (or a root
`.devcontainer.json`) works —
[devcontainer-builder-examples](https://github.com/DeepSpaceCartel/devcontainer-builder-examples)
is a stable, real one, with a real example for exactly this:

```json title="payload.json"
{
  "repository": "https://github.com/deepspacecartel/devcontainer-builder-examples.git",
  "branch": "node",
  "image": { "registry": "ghcr.io/deepspacecartel" }
}
```

```bash
curl -s -X POST http://localhost:8080/build \
  -H 'Content-Type: application/json' \
  -d @payload.json
```

```json
{"image":"ghcr.io/deepspacecartel/devcontainer-builder-examples:sha-a1b2c3d"}
```

`image.name` defaulted to the repo's own last path segment
(`devcontainer-builder-examples`), and `image.tag` defaulted to
`sha-<short HEAD sha>` — see the
[`POST /build` reference](../api-reference.html){:target="_blank" rel="noopener"} for every
field and its default. Pull it back to confirm the push really
happened:

```bash
docker pull ghcr.io/deepspacecartel/devcontainer-builder-examples:sha-a1b2c3d
```

## Skipping `image.registry` on every request

Passing `image.registry` on every single request is fine for a
one-off, but a deployment that always pushes to the same registry can
configure a
[registry mapping rule](../reference/CONFIGURATION.md#registry-mapping-rule)
instead, so callers can omit `image` entirely:

```yaml
registryMapping:
  rules:
    - registry: "ghcr.io/deepspacecartel" # no hostMatch/pathPrefix = universal fallback
```

See [ADR-0003](../decisions/0003-registry-resolution-via-mapping-rules.md)
for why this resolves server-side instead of being required on every
request.

## Using this from an actual Coder Workspace Template

Everything above talks to devcontainer-builder directly, over its raw HTTP
API. For the real end-to-end shape — a Coder user types in a git repo URL
when creating a workspace, and a template turns that into a running pod,
no separate CI/CD pipeline of your own to build and track every project's
own image variant — see the
[Coder Workspace Template guide](../guides/coder-workspace-template.md).

## If something goes wrong

A `500` response only ever contains the failing command and its exit
code, never the real underlying error text (that's in the pod's own
logs) — see the
[warning in the API reference](../api-reference.html){:target="_blank" rel="noopener"} before
assuming a `500` is a devcontainer-builder bug rather than, say, a
typo'd `registryAuth.registries` entry in step 1.
