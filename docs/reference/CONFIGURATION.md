<title>Configuration</title>

# Configuration

Every field resolves through the same precedence: **CLI flag > environment
variable > settings file > default**. This is purely additive — with no
settings file configured (the common case), every field resolves exactly
as it did before the settings file existed. Config loading
(`service/src/config.ts`'s `loadServiceConfig`) runs at process startup,
before `server.listen()` — any misconfiguration here crashes the process
immediately rather than surfacing as a mysterious per-request failure
later (see [0005](../decisions/0005-bdd-suite-on-thomas.md)'s sibling
concern documented in
[Architecture](../concepts/architecture.md#startup-and-shutdown)).

## Fields

| Field | CLI flag | Env var | Settings file path | Default |
|---|---|---|---|---|
| BuildKit endpoint | `--buildkit-endpoint` | `BUILDKIT_ENDPOINT` | `buildkit.endpoint` | *(unset — readiness fails)* |
| HTTP port | `--port` | `PORT` | `service.port` | `8080` |
| Buildx builder name | `--buildx-builder-name` | `BUILDX_BUILDER_NAME` | *(none)* | `devcontainer-builder-remote` |
| SSH host key policy | `--ssh-host-key-policy` | `SSH_HOST_KEY_POLICY` | `sshHostKeyPolicy` | `tofu` |
| Git credentials file path | `--git-credentials-config-path` | `GIT_CREDENTIALS_CONFIG_PATH` | *(none — see below)* | *(unset — empty list)* |
| Registry mapping file path | `--registry-mapping-config-path` | `REGISTRY_MAPPING_CONFIG_PATH` | *(none — see below)* | *(unset — empty list)* |
| Default platforms | `--build-platforms` (comma-separated) | `BUILD_PLATFORMS` (comma-separated) | `build.platforms` | `[]` (no `--platform` passed) |
| Default no-cache | `--build-no-cache` | `BUILD_NO_CACHE` (`"true"`/`"false"`) | `build.noCache` | `false` |
| Default cache-from | `--build-cache-from` | `BUILD_CACHE_FROM` | `build.cacheFrom` | *(unset)* |
| Default cache-to | `--build-cache-to` | `BUILD_CACHE_TO` | `build.cacheTo` | *(unset)* |
| Default BuildKit mode | `--buildkit-mode` | `BUILDKIT_MODE` | `build.mode` | `auto` |
| Sentry/GlitchTip DSN | `--sentry-dsn` | `SENTRY_DSN` | `sentry.dsn` | *(unset — error tracking off)* |
| Service name | `--service-name` | `SERVICE_NAME` | `observability.serviceName` | `devcontainer-builder` |
| Deployment environment | `--environment` | `DEPLOYMENT_ENVIRONMENT` | `observability.environment` | `development` |
| Command-log retention (per kind) | `--command-log-retention` | `COMMAND_LOG_RETENTION` | `logs.retention` | `10` |
| Settings file path itself | `--settings` | `SERVICE_CONFIG_PATH` | — | *(unset)* |

Both new fields land on every structured log line (`service.name`/
`deployment.environment.name` — see
[Architecture](../concepts/architecture.md#observability)). There's no
field for the service's own *version* — it's always this build's own
`package.json` version, never something an operator would choose to
override. The Helm chart sets `SERVICE_NAME` unconditionally (from
`.Chart.Name`, matching the `app.kubernetes.io/name` label every other part
of the chart already uses) and `DEPLOYMENT_ENVIRONMENT` from its own
`environment` value — see [Helm reference](HELM.md).

`git clone`/`devcontainer build --push` output is captured to a file per
invocation rather than the pod's own stdout (see
[0010](../decisions/0010-command-output-capture.md)), fetchable via `GET
/logs/{id}` (see
[HTTP API (Redoc)](../api-reference.html){:target="_blank" rel="noopener"}) -
`commandLogRetention` caps how many of these are kept per kind (`git`/
`docker`) before the oldest are pruned.

OpenTelemetry tracing is deliberately **not** in this table — it's
bootstrapped from the standard `OTEL_EXPORTER_OTLP_ENDPOINT`/
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` env vars before this config even
loads (see [Architecture](../concepts/architecture.md#observability)), the
same env vars any OTel SDK reads — not an app-specific flag with its own
precedence chain. `DEPLOYMENT_ENVIRONMENT` is the one exception read in
*both* places independently: `tracing.ts` reads it directly (for the trace
resource's `deployment.environment.name`) since it runs before this
config ever loads, while `config.ts` reads the identical env var again
(for the log fields above) — the same value, read twice, rather than
plumbing OTel's bootstrap through this file's own precedence chain.

`gitCredentials`/`registryMapping` have no CLI flag or env var of their
own for the *entries themselves* (only a *path* to a file, for both the
dedicated-file and settings-file forms) — there's no practical way to
express a structured list as a single flag or env var value.

## The settings file

One JSON or YAML file (`SERVICE_CONFIG_PATH`/`--settings`), parsed by
extension (`.json`, `.yaml`, or `.yml` — anything else is a startup
error). Its shape deliberately mirrors the Helm chart's own
[`values.yaml`](HELM.md) keys and nesting, not a flat, invented shape —
an operator who already knows the chart's values recognizes this file
immediately:

```json
{
  "buildkit": { "endpoint": "tcp://buildkit.example:1234" },
  "build": {
    "platforms": ["linux/amd64", "linux/arm64"],
    "noCache": false,
    "cacheFrom": "type=registry,ref=ghcr.io/example/app:buildcache",
    "cacheTo": "type=registry,ref=ghcr.io/example/app:buildcache,mode=max",
    "mode": "auto"
  },
  "service": { "port": 8080 },
  "sshHostKeyPolicy": "pinned",
  "gitCredentials": {
    "entries": [
      { "host": "github.com", "kind": "https", "username": "svc-bot", "token": "ghp_example" },
      { "host": "gitlab.internal.example.com", "kind": "ssh", "privateKey": "-----BEGIN OPENSSH PRIVATE KEY-----\n...", "pinnedHostKey": "gitlab.internal.example.com ssh-ed25519 AAAA..." }
    ]
  },
  "registryMapping": {
    "rules": [
      { "hostMatch": "github.com", "pathPrefix": "org-a/", "registry": "ghcr.io/org-a" }
    ]
  },
  "observability": { "serviceName": "devcontainer-builder", "environment": "production" }
}
```

Every other key `values.yaml` has (`image`, `resources`,
`registryAuth`, ...) has no runtime-config meaning here and is silently
ignored if present — this file only ever feeds `loadServiceConfig`, it's
never re-templated back into the chart.

!!! warning "A malformed or non-object settings file crashes at startup"
    Invalid JSON/YAML, a file that parses to something other than an
    object, or a wrong-typed known field (`buildkit.endpoint` not a
    string, `build.platforms` not an array of strings, `build.noCache`
    not a boolean, `build.cacheFrom`/`build.cacheTo` not a string,
    `build.mode` not `"auto"`/`"never"`, `service.port` not a number,
    `gitCredentials`/`registryMapping` not an object, `.entries`/`.rules`
    not an array) all throw synchronously at startup — the same "fail
    loud, fail immediately" behavior as every other config source, not a
    silently ignored or partially-applied file.

## `gitCredentials.entries` / `registryMapping.rules`

Same array shape whether they arrive via the settings file
(`gitCredentials.entries`/`registryMapping.rules`) or a dedicated file
(`GIT_CREDENTIALS_CONFIG_PATH`/`REGISTRY_MAPPING_CONFIG_PATH` — a bare
JSON/YAML array, not wrapped in an object). A **dedicated-file path, if
set, wins entirely over the settings file's own entries for that same
list** — they don't merge.

### Git credential entry

| Field | Type | Notes |
|---|---|---|
| `host` | `string` | Required, non-empty. Matched exactly against the clone URL's host. |
| `kind` | `"https"` \| `"ssh"` | Required. |
| `username`, `token` | `string` | Required if `kind: "https"`. |
| `privateKey` | `string` | Required, non-empty, if `kind: "ssh"`. |
| `pinnedHostKey` | `string` | Optional for `kind: "ssh"` — required if `sshHostKeyPolicy: "pinned"`. |

### Registry mapping rule

| Field | Type | Notes |
|---|---|---|
| `hostMatch` | `string` | Optional. Exact match against the clone URL's host. |
| `pathPrefix` | `string` | Optional. Prefix match against the clone URL's path. |
| `registry` | `string` | Required, non-empty. |

Rules are checked in order; the first rule whose `hostMatch` (if given)
and `pathPrefix` (if given) both match wins. A rule with neither field
set is a universal fallback. See
[0003: Registry resolution via mapping rules](../decisions/0003-registry-resolution-via-mapping-rules.md).

!!! note "One bad entry is skipped and logged, not fatal"
    Inside an otherwise-valid array, one entry that fails its own shape
    check (missing `host`, wrong `kind`, etc.) is logged
    (`skipping invalid <git credentials|registry mapping> config entry
    at index <n>`) and dropped — the service still starts, using every
    *other* valid entry. This is different from the array/settings
    *file itself* being malformed (see the warning above), which is
    fatal. The array-vs-file distinction exists because a single typo'd
    entry shouldn't take down every other configured host, but a
    genuinely broken config file should never be silently treated as
    "no config."

## `SSH_HOST_KEY_POLICY`

`tofu` (default) or `pinned` — any other value is a startup error
(`SSH_HOST_KEY_POLICY must be "tofu" or "pinned", got "<value>"`). See
[Credential handling](../concepts/credential-handling.md#ssh-a-scratch-key-known_hosts-gated-by-host-key-policy)
for what each policy actually does at clone time.
