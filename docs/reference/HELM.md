<title>Helm chart</title>

# Helm chart

[`charts/devcontainer-builder`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/charts/devcontainer-builder)
deploys a single-replica `Deployment` + `ClusterIP` `Service` — no
autoscaling or `Ingress` by design; this is an in-cluster-only caller
service, not a public one. Every value below is the chart's own real
[`values.yaml`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/charts/devcontainer-builder/values.yaml),
validated by its
[`values.schema.json`](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/charts/devcontainer-builder/values.schema.json):
an unknown key, a wrong type, or a value outside an enum (`build.mode`,
`sshHostKeyPolicy`, ...) fails `helm install`/`helm template` up front.

```bash
helm lint charts/devcontainer-builder
helm template charts/devcontainer-builder -f my-values.yaml
```


!!! note "Upgrading with `--reuse-values`"
    `helm upgrade --reuse-values` keeps only the previous release's values. The
    chart fills in values added by newer versions from its own defaults, so
    that works. Helm 3.14's `--reset-then-reuse-values` is the more explicit
    way to do it.

## `image`

| Key | Default | Notes |
|---|---|---|
| `image.repository` | `ghcr.io/deepspacecartel/devcontainer-builder` | The real, published image — see `.github/workflows/release.yaml`. |
| `image.tag` | `""` | Empty means the chart's own `appVersion`, so every chart release deploys its matching image. Set it only to deliberately pin a different image. |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | e.g. `[{name: my-pull-secret}]`, for a private copy of the image. |

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

| `buildkit.manageNamespace` | `false` | Renders the release `Namespace` itself, labeled `pod-security.kubernetes.io/enforce: privileged` — the behavior of chart versions up to 0.5.0. Only takes effect with `buildkit.deploy.enabled`. See [the namespace](#the-namespace-for-bundled-buildkit) below. |

### `buildkitBundled`

Values passed straight through to the bundled
[`buildkit-service`](https://github.com/andrcuns/charts/tree/main/charts/buildkit-service)
chart (any of its own values work here). The chart relies on these:

| Key | Default | Notes |
|---|---|---|
| `buildkitBundled.fullnameOverride` | `buildkit` | Pins the BuildKit Service's name, which the computed `buildkit.endpoint` (`tcp://<fullnameOverride>.<namespace>.svc.cluster.local:<port>`) is built from. |
| `buildkitBundled.service.type` | `ClusterIP` | |
| `buildkitBundled.service.port` | `1234` | Also the port in the computed endpoint. |

### The namespace for bundled BuildKit

BuildKit's default mode is genuinely privileged (inherent to how it does
OCI builds), and the bundled chart installs into the release namespace — so
that namespace must allow privileged pods. Create and label it once, before
installing:

```bash
kubectl create namespace devcontainer-builder
kubectl label namespace devcontainer-builder pod-security.kubernetes.io/enforce=privileged
helm install devcontainer-builder oci://ghcr.io/deepspacecartel/charts/devcontainer-builder \
  --namespace devcontainer-builder \
  --set buildkit.deploy.enabled=true
```

"Privileged" is the most permissive Pod Security level — it only widens
what the namespace *allows*, so devcontainer-builder's own pod (non-root,
read-only root filesystem, see [below](#security-and-scheduling)) is
unaffected. The chart doesn't create the namespace: a chart-owned
`Namespace` can't be installed into a namespace that already exists, and
conflicts with `--create-namespace`.

!!! warning "Upgrading an install from chart 0.5.0 or earlier with `buildkit.deploy.enabled`"
    Those versions rendered the release `Namespace` themselves. Helm
    deletes a resource that disappears from a release on upgrade, which
    here would be the namespace and the release with it — so the chart
    keeps rendering the `Namespace` for an install whose live namespace is
    owned by the same release (detected with `lookup`), now annotated
    `helm.sh/resource-policy: keep`. A plain `helm upgrade` is safe, and a
    later `helm uninstall` leaves the namespace in place. If you upgrade
    with something that can't `lookup` (`helm template | kubectl apply`,
    Argo CD, client-side `--dry-run` renders), set
    `buildkit.manageNamespace=true` instead, or first run
    `kubectl annotate namespace <ns> helm.sh/resource-policy=keep`.

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
| `build.fallbackImage` | `mcr.microsoft.com/devcontainers/base:ubuntu` | The image a repository without any `devcontainer.json` is built from, as if it had `{"image": "<fallbackImage>"}` ([ADR-0013](../decisions/0013-fallback-config-for-repos-without-one.md)). Empty: such builds fail, as with the Dev Containers CLI. |
| `build.cloneTimeoutSeconds` | `null` | Seconds before a clone is killed. `null` keeps the service's default, 600. |
| `build.timeoutSeconds` | `null` | Seconds before a Dev Container build is killed. `null` keeps the service's default, 3600. |
| `build.maxConcurrent` | `null` | Builds running at once; past it, `POST /build` answers 429 with `Retry-After`. `0` means no limit; `null` keeps the service's default, 4. |
| `git.allowInsecureProtocols` | `false` | Allow `git://` and `http://` repository URLs. They're unencrypted and can reach in-cluster hosts; for test git servers only. |

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

## `insecureRegistries`

| Key | Default | Notes |
|---|---|---|
| `insecureRegistries` | `[]` | Registry hosts the service's own registry calls reach over plain HTTP — see [Configuration](CONFIGURATION.md#insecure_registries). Rendered into the settings file only when non-empty. |

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
`sshHostKeyPolicy`, `insecureRegistries` (only when non-empty), and `registryMapping.rules` (only when
`registryMapping.existingConfigMap` is unset). `gitCredentials` is
deliberately never included — `GIT_CREDENTIALS_CONFIG_PATH` always takes
precedence over a settings-file copy of the same field (see
[Configuration](CONFIGURATION.md#the-settings-file) for `config.ts`'s
real precedence rules), so a copy here would be both inert and a needless
duplicate of sensitive material in a less-guarded ConfigMap.

## Escape hatches: `extraArgs`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`

| Key | Default | Notes |
|---|---|---|
| `extraArgs` | `[]` | Appended to the container's entrypoint (`devcontainer-builder`, i.e. `node dist/index.js`) as args, e.g. `["--ssh-host-key-policy", "pinned"]`. |
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

## `replicaCount`, `updateStrategy`, `terminationGracePeriodSeconds`

| Key | Default | Notes |
|---|---|---|
| `replicaCount` | `1` | `0` or `1` — the schema rejects more. Captured build output (`GET /logs/{id}`) lives on the pod's own `/tmp` `emptyDir`, so a second replica would answer `404` for log ids the other one returned. |
| `updateStrategy` | `{}` | Empty means Kubernetes' own default (`RollingUpdate`). |
| `terminationGracePeriodSeconds` | `300` | On `SIGTERM` the service stops accepting requests and lets in-flight ones finish; a `/build` request lasts as long as its build, so this is how long an in-flight build gets during a rollout or node drain. |

## Security and scheduling

The image runs as uid/gid `2000` (`USER 2000:2000`, numeric so
`runAsNonRoot` can verify it), with [`tini`](https://github.com/krallin/tini)
as PID 1 to reap the clone/`ssh`/`buildx` subprocesses. The defaults below
fit the Pod Security *restricted* level.

| Key | Default | Notes |
|---|---|---|
| `podSecurityContext` | `runAsNonRoot: true`, `runAsUser: 2000`, `runAsGroup: 2000`, `fsGroup: 2000`, `seccompProfile: {type: RuntimeDefault}` | Rendered as the pod's `securityContext`. The ids must match the image's user, so group-readable mounted Secret/ConfigMap files (mode `0440`) and the `emptyDir`s are readable/writable by it. |
| `securityContext` | `runAsNonRoot: true`, `runAsUser: 2000`, `runAsGroup: 2000`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities: {drop: [ALL]}`, `seccompProfile: {type: RuntimeDefault}` | Rendered as the container's `securityContext`. The root filesystem can be read-only because everything the service writes goes to the two `emptyDir`s below. |
| `serviceAccount.automountServiceAccountToken` | `false` | The service never calls the Kubernetes API, so the pod gets no token. |
| `podAnnotations` | `{}` | Merged with the chart's own `checksum/*` annotations. |
| `nodeSelector` / `tolerations` / `affinity` | `{}` / `[]` / `{}` | Standard pod scheduling fields. |

## `resources`, `scratchVolume`, `dockerConfigVolume`

| Key | Default | Notes |
|---|---|---|
| `resources.requests` | `cpu: 250m`, `memory: 256Mi` | |
| `resources.limits` | `cpu: "1"`, `memory: 1Gi` | |
| `scratchVolume.sizeLimit` | `5Gi` | An `emptyDir` mounted at `/tmp` — every per-request scratch clone/credential directory (see [Credential handling](../concepts/credential-handling.md)), the captured output behind `GET /logs/{id}`, and the Dev Containers CLI's own cache live here. |
| `dockerConfigVolume.sizeLimit` | `64Mi` | An `emptyDir` mounted at `DOCKER_CONFIG` (`/home/builder/.docker`) for `buildx`'s builder state; the registry-auth `config.json` is mounted into it. |
