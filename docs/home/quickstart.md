<title>Quickstart</title>

# Quickstart: build a public repo, push to Docker Hub

Deploy devcontainer-builder with Helm, then make one real `/build`
request against a public git repository, pushing the result to Docker
Hub. Every command below is real — nothing here is pseudocode.

## Prerequisites

- A Kubernetes cluster and `helm` (v3) pointed at it.
- A **BuildKit** daemon already running and reachable from that
  cluster (`tcp://<host>:<port>`) — devcontainer-builder never runs
  `dockerd` itself, see [ADR-0001](../decisions/0001-remote-buildkit-builder.md).
- A **Docker Hub** account and an
  [access token](https://docs.docker.com/security/for-developers/access-tokens/)
  (a password works too, but a scoped token is safer to put in a
  Secret).

No git credentials are needed for this walkthrough — a public
repository clones anonymously; see
[Credential handling](../concepts/credential-handling.md#no-credential-configured-clone-verbatim).

## 1. Write a values file

```bash
DOCKERHUB_USERNAME=<your-dockerhub-username>
```

The chart's [`registryAuth.registries`](../reference/HELM.md#registryauth)
value is a plain list of `{registry, username, password}` entries — the
chart builds the real docker-config-JSON itself, so there's no manual
base64-encoding or hand-built JSON here:

```yaml title="quickstart-values.yaml"
image:
  repository: ghcr.io/example/devcontainer-builder # the service's own image
  tag: "0.1.0"

buildkit:
  endpoint: "tcp://<your-buildkit-host>:<port>"

registryAuth:
  registries:
    - registry: https://index.docker.io/v1/ # Docker Hub's real registry host
      username: <your-dockerhub-username> # same value as $DOCKERHUB_USERNAME above
      password: <your-access-token>
```

`image.repository`/`tag` here are the **devcontainer-builder service's
own** image (see the [Helm chart reference](../reference/HELM.md#image))
— not the image it's going to build. With `registryAuth` configured
this way, every `/build` request pushes using these ambient
credentials unless it supplies its own
[`registryCredentials`](../reference/API.md#post-build).

## 2. Install the chart

```bash
helm install devcontainer-builder charts/devcontainer-builder \
  -f quickstart-values.yaml
```

Confirm it's actually ready — not just that the Pod is `Running`, but
that `BUILDKIT_ENDPOINT` was picked up (see
[`/health/ready`](../reference/API.md#get-healthready)):

```bash
kubectl port-forward svc/devcontainer-builder 8080:8080 &
curl -s http://localhost:8080/health/ready
# {"status":"ready"}
```

## 3. Build a public repo and push it to Docker Hub

Any public repo with a `.devcontainer/devcontainer.json` (or a root
`.devcontainer.json`) works — Microsoft's own
[`vscode-remote-try-node`](https://github.com/microsoft/vscode-remote-try-node)
is a stable, real example:

```bash
curl -s -X POST http://localhost:8080/build \
  -H 'Content-Type: application/json' \
  -d '{
    "repository": "https://github.com/microsoft/vscode-remote-try-node.git",
    "image": { "registry": "docker.io/'"$DOCKERHUB_USERNAME"'" }
  }'
```

```json
{"image":"docker.io/<your-dockerhub-username>/vscode-remote-try-node:sha-a1b2c3d"}
```

`image.name` defaulted to the repo's own last path segment
(`vscode-remote-try-node`), and `image.tag` defaulted to
`sha-<short HEAD sha>` — see the
[`POST /build` reference](../reference/API.md#post-build) for every
field and its default. Pull it back to confirm the push really
happened:

```bash
docker pull docker.io/$DOCKERHUB_USERNAME/vscode-remote-try-node:sha-a1b2c3d
```

## Skipping `image.registry` on every request

Passing `image.registry` on every single request is fine for a
one-off, but a deployment that always pushes to the same Docker Hub
account can configure a
[registry mapping rule](../reference/CONFIGURATION.md#registry-mapping-rule)
instead, so callers can omit `image` entirely:

```yaml
registryMapping:
  rules:
    - registry: "docker.io/<your-dockerhub-username>" # no hostMatch/pathPrefix = universal fallback
```

See [ADR-0003](../decisions/0003-registry-resolution-via-mapping-rules.md)
for why this resolves server-side instead of being required on every
request.

## If something goes wrong

A `500` response only ever contains the failing command and its exit
code, never the real underlying error text (that's in the pod's own
logs) — see the
[warning in the API reference](../reference/API.md#post-build) before
assuming a `500` is a devcontainer-builder bug rather than, say, a
typo'd `registryAuth.registries` entry in step 1.
