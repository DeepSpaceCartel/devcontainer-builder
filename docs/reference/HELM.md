<title>Helm chart</title>

# Helm chart

[`charts/devcontainer-builder`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/charts/devcontainer-builder)
deploys a single-replica `Deployment` + `ClusterIP` `Service` — no
autoscaling or `Ingress` by design; this is an in-cluster-only caller
service, not a public one. Every value below is the chart's own real
[`values.yaml`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/charts/devcontainer-builder/values.yaml).

```bash
helm lint charts/devcontainer-builder
helm template charts/devcontainer-builder -f my-values.yaml
```

## `image`

| Key | Default | Notes |
|---|---|---|
| `image.repository` | `ghcr.io/deepspacecartel/devcontainer-builder` | The real, published image — see `.github/workflows/release.yaml`. |
| `image.tag` | `"0.1.0"` | |
| `image.pullPolicy` | `IfNotPresent` | |

## `service`

| Key | Default | Notes |
|---|---|---|
| `service.port` | `8080` | Also becomes the container's `PORT` env var. |

## `environment`

| Key | Default | Notes |
|---|---|---|
| `environment` | `""` | Deployment environment name (e.g. `dev`/`staging`/`production`), passed through as the container's `DEPLOYMENT_ENVIRONMENT` env var — see [Configuration](CONFIGURATION.md#fields). Empty means unset, and the service falls back to its own `development` default. There's no equivalent chart value for the service's own *name* — the chart always sets `SERVICE_NAME` unconditionally from `.Chart.Name`, the same value the `app.kubernetes.io/name` label already uses everywhere else in this chart, so the two can never drift apart. |

## `buildkit`

| Key | Default | Notes |
|---|---|---|
| `buildkit.endpoint` | `""` | e.g. `tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234`. Unset means readiness never passes — see [`/health/ready`](../api-reference.html){:target="_blank" rel="noopener"}. Ignored when `buildkit.deploy.enabled` is `true`. |
| `buildkit.deploy.enabled` | `false` | Deploys a bundled BuildKit instance ([`andrcuns/buildkit-service`](https://github.com/andrcuns/charts/tree/main/charts/buildkit-service), the `buildkitBundled` dependency in `Chart.yaml`) alongside devcontainer-builder itself, and computes `buildkit.endpoint` automatically from it — zero pre-existing BuildKit infra needed for a first install. |

```yaml
buildkit:
  deploy:
    enabled: true
```

!!! warning "Don't pass `--create-namespace` when enabling this"
    BuildKit's default mode is genuinely privileged (inherent to how it
    does OCI builds) — enabling this makes the chart label its own release
    namespace `pod-security.kubernetes.io/enforce: privileged` (owning the
    `Namespace` resource itself, the same pattern
    [`charts/test-namespace`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/charts/test-namespace)
    uses per [ADR-0006](../decisions/0006-privileged-test-namespace-via-chart.md)),
    which conflicts with Helm's own unlabeled `--create-namespace` if both
    try to create the same namespace. `helm install ... -n <namespace>`
    alone (no `--create-namespace`) lets the chart create *and* label it on
    first install. "Privileged" is the most permissive PodSecurity tier —
    it only widens what the namespace *allows*, so devcontainer-builder's
    own ordinary (non-privileged) pod in the same namespace is unaffected.

## `build`

Server-wide defaults for platform selection and BuildKit build options,
used whenever a `/build` request doesn't specify its own `platforms` or
`buildOptions` — see [API](../api-reference.html){:target="_blank" rel="noopener"} for the per-request fields.

| Key | Default | Notes |
|---|---|---|
| `build.platforms` | `[]` | e.g. `["linux/amd64", "linux/arm64"]`. Empty means today's behavior: no `--platform` flag, builder's native platform. |
| `build.noCache` | `false` | Passed as `--no-cache` when `true`. |
| `build.cacheFrom` | `""` | Passed as `--cache-from <value>`, e.g. `type=registry,ref=ghcr.io/example/app:buildcache`. |
| `build.cacheTo` | `""` | Passed as `--cache-to <value>`, e.g. `type=registry,ref=ghcr.io/example/app:buildcache,mode=max`. Points BuildKit's own layer cache at the same registry the image is pushed to — persistent and shared across replicas, unlike a per-pod cache. |
| `build.mode` | `auto` | `auto` or `never` — passed as `--buildkit <value>`, controlling whether BuildKit is used at all. |

```yaml
build:
  platforms: ["linux/amd64", "linux/arm64"]
  cacheFrom: "type=registry,ref=ghcr.io/example/app:buildcache"
  cacheTo: "type=registry,ref=ghcr.io/example/app:buildcache,mode=max"
```

## `registryAuth`

Ambient registry push credentials — used whenever a `/build` request
doesn't supply its own `registryCredentials`.

| Key | Default | Notes |
|---|---|---|
| `registryAuth.existingSecret` | `""` | Name of an existing `kubernetes.io/dockerconfigjson`-shaped Secret. If set, `registries` below is ignored. |
| `registryAuth.registries` | `[]` | List of `{registry, username, password}` entries. The chart builds the real docker-config-JSON (`{"auths": {"<registry>": {"auth": "<base64 user:pass>"}}}`) and renders it into a chart-managed Secret if `existingSecret` is unset — nobody hand-builds or pre-base64-encodes JSON themselves. |

```yaml
registryAuth:
  registries:
    - registry: https://index.docker.io/v1/ # Docker Hub's real registry host
      username: svc-bot
      password: hunter2
```

Unconfigured (empty `registries`, no `existingSecret`) means an empty
`{"auths":{}}` — pushes rely entirely on whatever the target registry
allows anonymously, or on a per-request `registryCredentials` override.

## `gitCredentials`

Server-side default git credentials — see
[Configuration](CONFIGURATION.md#gitcredentialsentries-registrymappingrules)
for the entry shape and [Credential handling](../concepts/credential-handling.md)
for how they're used.

| Key | Default | Notes |
|---|---|---|
| `gitCredentials.enabled` | `true` | `false` omits `GIT_CREDENTIALS_CONFIG_PATH` and its volume entirely, rather than pointing at an empty list. |
| `gitCredentials.existingSecret` | `""` | Name of an existing Secret containing a `git-credentials.json` key (same array shape as `entries`). |
| `gitCredentials.entries` | `[]` | Inline entries, rendered into a chart-managed Secret if `existingSecret` is unset. |

## `sshHostKeyPolicy`

| Key | Default | Notes |
|---|---|---|
| `sshHostKeyPolicy` | `tofu` | `tofu` or `pinned` — see [Configuration](CONFIGURATION.md#ssh_host_key_policy). |

## `registryMapping`

Server-side repo → registry routing rules, used to resolve
`image.registry` when a request omits it.

| Key | Default | Notes |
|---|---|---|
| `registryMapping.enabled` | `true` | `false` omits `registryMapping` from the rendered settings file entirely. |
| `registryMapping.existingConfigMap` | `""` | Name of an existing ConfigMap containing a `registry-mapping.json` key, mounted separately with its own dedicated `REGISTRY_MAPPING_CONFIG_PATH` env var. If set, `rules` below is ignored. |
| `registryMapping.rules` | `[]` | Inline rules. Unlike `existingConfigMap`, these don't get a dedicated ConfigMap — they're folded straight into the chart-rendered settings file below. |

## The settings file

`SERVICE_CONFIG_PATH` and its ConfigMap are entirely automatic — there's
no `settingsFile.*` value to set. The chart renders `settings.json` from
values that already exist elsewhere in this page: `buildkit.endpoint`,
`build.*` (only the sub-fields that differ from their zero-value default),
`sshHostKeyPolicy`, and `registryMapping.rules` (only when
`registryMapping.existingConfigMap` is unset). `gitCredentials` is
deliberately never included — `GIT_CREDENTIALS_CONFIG_PATH` always takes
precedence over a settings-file copy of the same field (see
[Configuration](CONFIGURATION.md#the-settings-file) for `config.ts`'s
real precedence rules), so a copy here would be both inert and a needless
duplicate of sensitive material in a less-guarded ConfigMap.

## Escape hatches: `extraArgs`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`

| Key | Default | Notes |
|---|---|---|
| `extraArgs` | `[]` | Appended to the container's entrypoint args, e.g. `["--ssh-host-key-policy", "pinned"]`. |
| `extraEnv` | `[]` | Appended after the chart's own env entries — a plain `[{name: ..., value: ...}]` list. |
| `extraVolumes` / `extraVolumeMounts` | `[]` | Appended after the chart's own volumes/mounts — e.g. mounting a caller-provided ConfigMap holding a CA cert, paired with `extraEnv` pointing `GIT_SSL_CAINFO` at it. |

`extraEnv` is also how the service's remaining optional observability
integrations get configured — no dedicated chart values for these, since
they're just environment variables the service already reads directly
(unlike `SERVICE_NAME`/`DEPLOYMENT_ENVIRONMENT` above, which *are*
first-class chart values, since every deployment should set an
environment name, not just the ones opting into Sentry/OTel):

```yaml
extraEnv:
  - name: SENTRY_DSN # GlitchTip (Sentry-protocol-compatible) works too
    value: "https://<key>@errors.example.com/1"
  - name: OTEL_EXPORTER_OTLP_ENDPOINT # this cluster's Alloy OTLP/HTTP receiver
    value: "http://alloy.observability.svc.cluster.local:4318"
```

See [Architecture](../concepts/architecture.md#observability) for what
each actually does.

## `podSecurityContext`, `resources`, `scratchVolume`, `updateStrategy`, `replicaCount`

| Key | Default | Notes |
|---|---|---|
| `replicaCount` | `1` | |
| `updateStrategy` | `{}` | Empty means Kubernetes' own default (`RollingUpdate`). |
| `podSecurityContext.fsGroup` | `2000` | Must match the image's `builder` user's gid (`Dockerfile`'s `useradd --uid 2000 builder`) so group-readable mounted Secret/ConfigMap files are actually readable by the non-root process. |
| `resources.requests` | `cpu: 250m`, `memory: 256Mi` | |
| `resources.limits` | `cpu: "1"`, `memory: 1Gi` | |
| `scratchVolume.sizeLimit` | `5Gi` | An `emptyDir` mounted at `/tmp` — every per-request scratch clone/credential directory (see [Credential handling](../concepts/credential-handling.md)) lives here. |
