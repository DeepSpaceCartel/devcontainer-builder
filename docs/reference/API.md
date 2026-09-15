<title>HTTP API</title>

# HTTP API

Five routes, no authentication of its own (the service is meant to sit
behind cluster-internal networking — see the Helm chart's
[`Service`](HELM.md#service)). Every response is `application/json`.
Any other method/path returns `404 {"error":"not found"}`.

## `GET /health/live`

Liveness probe. Always `200 {"status":"ok"}` once the process is
listening — checks nothing beyond that.

## `GET /health/ready`

Readiness probe.

| Status | Body | When |
|---|---|---|
| `200` | `{"status":"ready"}` | `BUILDKIT_ENDPOINT` is configured |
| `503` | `{"status":"not ready","reason":"BUILDKIT_ENDPOINT not configured"}` | it isn't |

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
