<title>HTTP API</title>

# HTTP API

No authentication of its own (the service is meant to sit behind
cluster-internal networking — see the Helm chart's
[`Service`](HELM.md#service)). Every response is `application/json` (except
`GET /metrics`, `text/plain`). Any other method/path returns
`404 {"error":"not found"}`.

Grouped into four tags, matching the [OpenAPI document](#openapi) below:
**Building devcontainers** (`POST /build`), **Images** (`GET`/`DELETE
/image`), **Health (Kubernetes probes)** (`/health/*`), and **Configuration
(read-only)** (`GET /config`).

## OpenAPI

The service is built on [Fastify](https://fastify.dev) with
[TypeBox](https://github.com/sinclairzx81/typebox) route schemas
([`src/schemas.ts`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/service/src/schemas.ts)) —
the same schemas that validate every request below also generate a real
OpenAPI 3.1 document, never hand-authored, so it can't drift from what the
service actually accepts, complete with realistic request examples (real
repo URLs, and — since a build against a private registry needs
credentials somewhere — one example showing `registryCredentials`
explicitly and one relying on the server's own ambient `registryAuth`):

- `GET /documentation/json` / `GET /documentation/yaml` — the generated
  OpenAPI document itself. Point [Restish](https://rest.sh) or any other
  OpenAPI-aware client at this URL to auto-configure against a running
  instance (`restish api configure devcontainer-builder
  http://<host>:8080/documentation/json`).
- `GET /documentation` — an interactive Swagger UI.

This same document is also bundled statically into this page (below) so you
can browse it without running the service at all.

Every documented `400` body below is a static string regardless of which
sub-field actually failed — this predates the OpenAPI document and is kept
that way deliberately (see `server.ts`) rather than switching to AJV's
own per-field validation-error format, since the exact string is already a
stable, tested part of this contract.

## `GET /health/startup`

Kubernetes `startupProbe`. Always `200 {"status":"started"}` once the
process is listening — checks nothing beyond that. A distinct route from
`GET /health/live` even though the check is identical today: this service
has no separate async startup phase (config loading is synchronous, before
the server ever starts listening), so there's nothing more to distinguish
yet. Kept separate so a `startupProbe` (a generous total budget, to
tolerate slow pod scheduling/image pulls) can be tuned independently of
`livenessProbe` (tight, once actually started) — see the
[Helm chart](HELM.md#podsecuritycontext-resources-scratchvolume-updatestrategy-replicacount).

## `GET /health/live`

Liveness probe. Always `200 {"status":"ok"}` once the process is
listening — checks nothing beyond that.

## `GET /health/ready`

Readiness probe.

| Status | Body | When |
|---|---|---|
| `200` | `{"status":"ready"}` | `BUILDKIT_ENDPOINT` is configured |
| `503` | `{"status":"not ready","reason":"BUILDKIT_ENDPOINT not configured"}` | it isn't |

## `GET /metrics`

Prometheus text-format metrics (`Content-Type: text/plain`), for a
`ServiceMonitor`/node-exporter-style scrape — not part of the OpenAPI
document (hidden via `schema.hide`, since it isn't a JSON API route).
Node.js process/runtime defaults (`prom-client`'s `collectDefaultMetrics`)
plus:

| Metric | Type | Labels | What it counts |
|---|---|---|---|
| `devcontainer_builder_builds_total` | counter | `status` (`success`\|`failure`\|`invalid_request`) | Every `POST /build` attempt. |
| `devcontainer_builder_build_duration_seconds` | histogram | `status` | Real build wall-clock time — bucketed toward minutes, not the sub-second defaults, since a build is a clone + image build + push. |
| `devcontainer_builder_image_checks_total` | counter | `result` (`exists`\|`absent`\|`error`) | Every `GET /image` call. |
| `devcontainer_builder_image_deletes_total` | counter | `result` (`deleted`\|`unsupported`\|`error`) | Every `DELETE /image` call. |

## `GET /config`

Read-only, non-sensitive view of the service's own loaded configuration
(`src/config.ts`'s `ServiceConfig`) — what devcontainer-builder was actually
started with, useful for confirming a Helm upgrade or settings-file change
actually took effect without shelling into the pod. **Never returns
credential material** — `gitCredentials` entries are reduced to
`{host, kind}` (no `token`/`privateKey`/`pinnedHostKey`);
`registryMappingRules` are returned in full since they were never sensitive
to begin with.

```json
{
  "buildkitConfigured": true,
  "buildxBuilderName": "devcontainer-builder-remote",
  "sshHostKeyPolicy": "tofu",
  "defaultPlatforms": [],
  "defaultBuildOptions": { "noCache": false, "mode": "auto" },
  "gitCredentials": [{ "host": "github.com", "kind": "https" }],
  "registryMappingRules": [{ "registry": "ghcr.io/deepspacecartel" }]
}
```

This is a presence check, not a live connectivity probe against
BuildKit — see [Architecture](../concepts/architecture.md#health-endpoints).

## `POST /build`

### Request body

| Field | Type | Required | Notes |
|---|---|---|---|
| `repository` | `string` | yes | Non-empty. `https://`, `ssh://`, or git's own SCP-style `[user@]host:path` shorthand. |
| `branch` | `string` | no | Defaults to `main`. Omitted or a non-empty string only. |
| `image.registry` | `string` | no | Non-empty if given. Wins over any server-side [mapping rule](CONFIGURATION.md#registry-mapping-rule). |
| `image.name` | `string` | no | Non-empty if given. Defaults to the repository path's last segment, `.git` stripped. |
| `image.tag` | `string` | no | Non-empty if given. Defaults to `sha-<short HEAD sha>`. |
| `gitCredentials.username` | `string` | no* | Required together with `token` if `gitCredentials` is present. |
| `gitCredentials.token` | `string` | no* | Always HTTPS-shaped — see [Credential handling](../concepts/credential-handling.md#git-credentials). |
| `registryCredentials.registry` | `string` | no* | Required together with `username`/`password` if `registryCredentials` is present. Non-empty. |
| `registryCredentials.username` | `string` | no* | Non-empty. |
| `registryCredentials.password` | `string` | no* | Non-empty. |
| `platforms` | `string[]` | no | Non-empty strings, e.g. `["linux/amd64", "linux/arm64"]`. Overrides [`build.platforms`](HELM.md#build) for this request; omitted or empty means today's behavior (no `--platform` flag). |
| `buildOptions.noCache` | `boolean` | no | Overrides [`build.noCache`](HELM.md#build) — passed as `--no-cache` when `true`. |
| `buildOptions.cacheFrom` | `string` | no | Non-empty if given. Overrides [`build.cacheFrom`](HELM.md#build). |
| `buildOptions.cacheTo` | `string` | no | Non-empty if given. Overrides [`build.cacheTo`](HELM.md#build). |
| `buildOptions.mode` | `"auto"` \| `"never"` | no | Overrides [`build.mode`](HELM.md#build). |

`image`/`gitCredentials`/`registryCredentials`/`buildOptions` may each be
omitted entirely; once present, their own required sub-fields apply
(marked `no*` above). Unknown top-level fields are tolerated, not
rejected.

=== "Minimal"

    ```json
    { "repository": "https://github.com/example/example-devcontainer.git" }
    ```

=== "Fully specified"

    ```json
    {
      "repository": "git@github.example.com:org/repo.git",
      "branch": "release",
      "image": { "registry": "ghcr.io/example", "name": "custom-name", "tag": "v1.2.3" },
      "gitCredentials": { "username": "svc-bot", "token": "ghp_example" },
      "registryCredentials": { "registry": "ghcr.io/example", "username": "svc-bot", "password": "hunter2" },
      "platforms": ["linux/amd64", "linux/arm64"],
      "buildOptions": {
        "noCache": false,
        "cacheFrom": "type=registry,ref=ghcr.io/example/app:buildcache",
        "cacheTo": "type=registry,ref=ghcr.io/example/app:buildcache,mode=max",
        "mode": "auto"
      }
    }
    ```

### Responses

| Status | Body | When |
|---|---|---|
| `200` | `{"image": "<registry>/<name>:<tag>", "registry": "<registry>", "name": "<name>", "tag": "<tag>"}` | The clone and build+push both succeeded. `registry`/`name`/`tag` are the same values decomposed, since re-parsing `image` generically is ambiguous (registry ports, default-registry conventions, tag-vs-digest forms). |
| `400` | `{"error": "invalid JSON body"}` | The request body isn't valid JSON at all. |
| `400` | `{"error": "missing or invalid fields: repository (required); branch, image.{registry,name,tag}, gitCredentials.{username,token}, registryCredentials.{registry,username,password}, platforms, buildOptions.{noCache,cacheFrom,cacheTo,mode} (all optional)"}` | The parsed body isn't a JSON object, or fails the shape check above. |
| `400` | `{"error": "unable to parse git repository URL: <repository>"}` | `repository` doesn't match any accepted URL form. |
| `400` | `{"error": "no registry resolved for repository <repository>: provide image.registry or configure a matching registry mapping rule"}` | No `image.registry` given and no [mapping rule](CONFIGURATION.md#registry-mapping-rule) matched. |
| `400` | `{"error": "SSH host key policy is \"pinned\" but no pinned key configured for host <host>"}` | The resolved SSH credential has no `pinnedHostKey` under `sshHostKeyPolicy: pinned`. |
| `500` | `{"error": "<command> <args...> exited with code <n>"}` | A real clone or build failure. |

!!! note "400 vs. 500"
    A `400` always means the *request itself* was unusable — nothing was
    ever attempted, or a required piece of configuration to even attempt
    it (a registry, a host key pin) was missing. A `500` always means a
    real external command was actually run and failed — the request was
    well-formed, but cloning or building it didn't work. See
    [`BuildRequestError`](../concepts/architecture.md#request-lifecycle-post-build)
    for the code-level distinction.

!!! warning "A 500's body is the real command and exit code, not the real error text"
    Subprocess stdout/stderr is inherited straight through to this
    service's own process output (`stdio: "inherit"`, never captured) —
    so a real `500` body looks like
    `{"error":"git clone --branch main --single-branch --depth 1 <url> <dir> exited with code 128"}`,
    not the actual `fatal: repository not found` (or a registry's real
    401 body) that caused it. That real text is only in this service's
    own pod logs. See
    [0002](../decisions/0002-credentials-never-touch-argv-or-urls.md)'s
    own consequence note on why this wasn't captured more granularly.

## `GET /image`

Checks whether a previously-built image still exists in its registry, by
talking to the registry's own HTTP API V2 directly (bearer-token
challenge/exchange, then a manifest lookup) — see
[0008](../decisions/0008-image-existence-and-deletion-endpoints.md).

### Query parameters

| Param | Required | Notes |
|---|---|---|
| `registry` | yes | Non-empty. |
| `name` | yes | Non-empty. |
| `tag` | yes | Non-empty. |

### Headers

| Header | Required | Notes |
|---|---|---|
| `X-Registry-Username` | no | Together with `X-Registry-Password`, explicit credentials for this call. Falls back to the service's ambient `DOCKER_CONFIG` auth for `registry` when omitted. |
| `X-Registry-Password` | no | See above. |

### Responses

| Status | Body | When |
|---|---|---|
| `200` | `{"image": "<registry>/<name>:<tag>", "exists": true}` | The registry has a manifest for this reference. |
| `200` | `{"image": "<registry>/<name>:<tag>", "exists": false}` | The registry returned 404 for this reference — a normal, successful answer, not an error. |
| `400` | `{"error": "missing or invalid query parameters: registry, name, tag (all required)"}` | Any of the three query params is missing or empty. |
| `502` | `{"error": "..."}` | The registry was unreachable, the auth challenge/exchange failed, or it returned something other than a clean 200/404. |

## `DELETE /image`

Best-effort deletion of a previously-built image's manifest. Not all
registries support this via the standard API (Docker Hub notably doesn't) —
see [0008](../decisions/0008-image-existence-and-deletion-endpoints.md) for
why that's treated as a normal outcome, not an error.

Same query parameters and headers as `GET /image` above.

### Responses

| Status | Body | When |
|---|---|---|
| `200` | `{"image": "<registry>/<name>:<tag>", "deleted": true}` | Deleted, or already absent — either way the post-condition "image is gone" holds. |
| `200` | `{"image": "<registry>/<name>:<tag>", "deleted": false, "reason": "registry does not support manifest deletion"}` | The registry returned 405/400/501 to the delete attempt. |
| `400` | `{"error": "missing or invalid query parameters: registry, name, tag (all required)"}` | Any of the three query params is missing or empty. |
| `502` | `{"error": "..."}` | The registry was unreachable or an auth/other failure occurred. |

## Bundled API docs

The exact same generated OpenAPI document [`GET /documentation/json`](#openapi)
serves from a running instance, rendered here statically
(`service/scripts/export-openapi.mjs`, run before `mkdocs build` — see
[Installing](../project/installing.md#this-documentation-site)) so it's
browsable without running the service at all:

<div id="redoc-container"></div>
<script src="https://cdn.jsdelivr.net/npm/redoc@2/bundles/redoc.standalone.js"></script>
<script>
  Redoc.init('../../openapi.json', {}, document.getElementById('redoc-container'));
</script>
