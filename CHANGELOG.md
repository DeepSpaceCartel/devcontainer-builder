# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Chart: `values.schema.json`.** Unknown keys, wrong types, and values outside an enum
  (`build.mode`: `auto`|`never`, `sshHostKeyPolicy`: `tofu`|`pinned`) fail `helm install` up front.
  `replicaCount` is capped at 1: captured build output (`GET /logs/{id}`) lives on the pod's own
  `emptyDir`.
- **Chart: scheduling and pod values** `imagePullSecrets`, `podAnnotations`, `nodeSelector`,
  `tolerations`, `affinity`, `terminationGracePeriodSeconds` (default 300, so an in-flight build can
  finish during a rollout), `serviceAccount.automountServiceAccountToken`, `securityContext`,
  `dockerConfigVolume.sizeLimit`, and the `app.kubernetes.io/version` label.
- **Image: OCI labels** (`org.opencontainers.image.source`, `description`, `licenses`, `version`).
- The VS Code extension is also published to **Open VSX** as `deepspacecartel.devcontainer-builder`,
  for VSCodium, Cursor, code-server and other editors that don't use Microsoft's Marketplace.
- **Private repositories with the user's own account.** The template's new `external_auth_id`
  variable (e.g. `github`, a Coder external auth provider) makes creating a workspace ask the user
  to link that account. The workspace's clone uses it, and so does the image build: the user's
  token is sent with the build request, so devcontainer-builder needs no `gitCredentials` of its
  own. A refreshed token doesn't trigger a rebuild. **Coder: Clone Repository in Workspace…** opens
  the link page and waits for it, instead of failing on create.
- Docs: [Security model](docs/concepts/security.md), [Troubleshooting](docs/guides/troubleshooting.md)
  and [Uninstall](docs/guides/uninstall.md) pages, and the Terraform provider's
  `devcontainerbuilder_devcontainer` data source and `commit` attribute in its reference.

### Changed

- **Breaking:** **Template: `hostRequirements` are minimums**, as in the Dev Container spec, instead of overriding
- **Image: Node 24 LTS** (was Node 20, end-of-life since April 2026), base image pinned by digest.
  The npm package's `engines` is now `node >=22`.
- **Image: `@devcontainers/cli` pinned to 0.89.0** (`DEVCONTAINERS_CLI_VERSION` build arg), the
  version the service is checked against, instead of whatever was latest at build time.
- **Image: `tini` is PID 1**, so exited `git`/`ssh`/`buildx` children are reaped and signals reach
  the server. The image runs as `USER 2000:2000` (numeric, same `builder` user), and the `dev`
  target installs with `npm ci` from `package-lock.json`.
- **Chart: hardened pod defaults.** Non-root (uid/gid 2000), `allowPrivilegeEscalation: false`,
  all capabilities dropped, `RuntimeDefault` seccomp, a read-only root filesystem (`DOCKER_CONFIG`
  is now an `emptyDir`, next to the `/tmp` one), and no service account token. Overriding
  `podSecurityContext` or `securityContext` replaces these defaults key by key.
- **Chart: bundled BuildKit no longer creates the release namespace.** With
  `buildkit.deploy.enabled`, the chart rendered and owned the release `Namespace` (labeled
  privileged): installing into an existing namespace failed, and `helm uninstall` deleted the
  namespace. Now you create and label it yourself before installing
  (`kubectl label namespace <ns> pod-security.kubernetes.io/enforce=privileged`, see the Helm chart
  reference); `buildkit.manageNamespace: true` restores the old behavior. **Upgrading an existing
  bundled install is safe:** the chart detects a namespace the release already owns and keeps
  rendering it, now with `helm.sh/resource-policy: keep`, so neither the upgrade nor a later
  `helm uninstall` deletes it. Tools that can't `lookup` (`helm template | kubectl apply`, Argo CD)
  must set `buildkit.manageNamespace=true` for that upgrade, or annotate the namespace
  `helm.sh/resource-policy=keep` first.
- **Template: `hostRequirements` are minimums**, as in the Dev Container spec, instead of overriding
  the CPU/Memory/Disk parameters:
  - `cpus` and `memory` are **reserved** (pod requests), so a workspace lands on a node that has them,
    or stays Pending with a scheduling reason instead of being OOM-killed later;
  - the limits are the larger of the requirement and the parameter;
  - `storage` is the larger of it and the Disk parameter, so the volume never shrinks. It only
    applies when the workspace is created: the volume isn't resized afterwards.

  New template variables `max_cpu` (default 8) and `max_memory` (GiB, default 32) cap the
  reservation, with a build-log warning above them. The workspace page shows **Resources (reserved /
  limit)**. Without `hostRequirements` nothing changes (requests 250m CPU / 512Mi).
- **Breaking:** **Template: each workspace has its own image tag**, `ws-<workspace-id>-<rebuild>`,
  instead of `sha-<commit>` (see Fixed). Every existing workspace **rebuilds its image once** on its
  first start after the update, from its branch's latest commit, and the old `sha-<commit>` tag is
  deleted: update all workspaces on the same repository together.
- **Template: provider version bounds.** `deepspacecartel/devcontainer-builder` is
  `>= 0.3.0, < 2.0.0` (was unbounded), and `coder/coder` (`>= 2.5.0`) and `hashicorp/kubernetes`
  (`>= 2.16.0`) have minimums: the versions that introduced what the template uses. Terraform
  `>= 1.5`.
- **Template: workspace pods only run on `amd64` nodes** (`kubernetes.io/arch` node
  selector), the architecture of the agent binary the template always installed; on a mixed cluster
  they could land on an arm64 node and fail to start.
- **Template: `customizations.vscode.settings` are defaults.** A setting is written to the Machine
  settings only if it isn't there yet, or still has the value written last time, so a setting the
  user changed is no longer overwritten on every start, and a repository's change still reaches the
  ones the user didn't change.
- Template: the Memory parameter's options say GiB (what they always applied), and the Git repository
  parameter's description no longer says the repository needs a `devcontainer.json`.

### Deprecated

- The Terraform module `terraform/devcontainer-build`. It's removed in 2.0. Use the
  `deepspacecartel/devcontainer-builder` provider's `devcontainerbuilder_build` resource directly:
  the module only wraps it, and the provider is the Terraform surface 1.x keeps stable. Plans that
  use the module now show a deprecation warning.
- The template's uid/gid 1000 fallback for images built before 0.3.0. It's kept through 1.x so an
  upgraded workspace always starts, and removed in 2.0.

### Fixed

- **Template: VS Code in the browser and the forwarded-port apps on deployments without a wildcard
  access URL.** They were always subdomain apps, which Coder can't serve without
  `CODER_WILDCARD_ACCESS_URL`. The new template variable `subdomain_apps` (default `true`) serves
  them on paths of the main Coder URL when set to `false`.
- **Template: workspace parameters in a sensible order.** Git repository and Branch come first,
  then CPU, Memory, Disk size, Dev Container variables and Rebuild, instead of alphabetical.
- **Template: deleting or rebuilding a workspace no longer deletes other workspaces' image.** All
  workspaces built from the same repository and commit shared the `sha-<commit>` tag, and deleting
  the image (`DELETE /image`) on a Rebuild or a workspace's deletion removed it from under the others,
  which then failed to pull it.
- **Template: `postAttachCommand` runs after the other lifecycle commands**, once they've succeeded,
  instead of as soon as the clone had an index, concurrently with `postCreateCommand` and the rest.
  It gives up after 30 minutes.
- **Template: an interrupted clone is retried.** A workspace stopped mid-clone kept its partial
  `.git`, and the clone was never attempted again. A finished clone is now marked
  (`.git/devcontainer-cloned`); an unfinished one (no commit checked out) is removed and redone on
  the next start. A `.git` with a commit is always kept.
- **Template: the clone works with git older than 2.28** (no `git init -b`), and an image without
  `git` fails with a message saying to add the `ghcr.io/devcontainers/features/git:1` Feature.
- **Template: a workspace folder, repository, branch or extension ID containing `'`** broke the
  workspace's scripts; they're now quoted for the shell. Dev Container variable names are checked
  before they're used in a script.
- **Template: `seed-home` no longer stops the workspace from starting** when a file in the image's
  home can't be copied (e.g. unreadable by the remote user); it's skipped with a warning. It also
  uses portable `cp` flags (BusyBox images).
- **Template: a mount at a path the template already mounts** (`workspaceFolder` exactly
  `/workspaces` or the home, or a `devcontainer.json` mount at `/workspaces`, the home, the workspace
  folder, `/dev/shm`, or another mount's target) got the pod rejected. The colliding mount is now
  dropped, with a warning in the build log.

  See [ADR-0014](docs/decisions/0014-host-requirements-are-minimums.md).
- Release workflow: a pre-release tag (`vX.Y.Z-rc.N`) publishes the npm package under the `next`
  dist-tag, doesn't move the `latest` image tag, skips the VS Code Marketplace and Open VSX, and
  creates a GitHub pre-release. A release only moves `latest` when it's the highest version.

### Deprecated

- The Terraform module `terraform/devcontainer-build`. It's removed in 2.0. Use the
  `deepspacecartel/devcontainer-builder` provider's `devcontainerbuilder_build` resource directly:
  the module only wraps it, and the provider is the Terraform surface 1.x keeps stable. Plans that
  use the module now show a deprecation warning.

### Fixed

- **Docs: the Helm chart reference's `image.tag` default** is `""` (the chart's `appVersion`), not
  `"0.1.0"`; it now also lists `build.fallbackImage`, `buildkitBundled.*` and every new value. The
  `extraArgs` comment in `values.yaml` names the real entrypoint, `dist/index.js`.
- **Template: VS Code in the browser and the forwarded-port apps on deployments without a wildcard
  access URL.** They were always subdomain apps, which Coder can't serve without
  `CODER_WILDCARD_ACCESS_URL`. The new template variable `subdomain_apps` (default `true`) serves
  them on paths of the main Coder URL when set to `false`.
- **Template: workspace parameters in a sensible order.** Git repository and Branch come first,
  then CPU, Memory, Disk size, Dev Container variables and Rebuild, instead of alphabetical.

### Security

- The service pod runs under the Pod Security *restricted* profile's requirements by default, with
  a read-only root filesystem and no Kubernetes API token (see Changed).
- The image's Node.js moved off end-of-life Node 20, and its base image and `@devcontainers/cli` are
  pinned, so a rebuild can't silently pick up different code.

## [0.5.0] - 2026-10-07

### Added

- The VS Code extension is on the **VS Code Marketplace** as `deepspacecartel.devcontainer-builder`
  ("Dev Containers for Coder in K8S"), published by the release workflow. It was previously
  `deepspacecartel.devcontainer-builder-rebuild`, a VSIX only; the release still attaches it, as
  `devcontainer-builder.vsix`.
- **Coder: Clone Repository in Workspace…** in the VS Code extension (now
  `extensionKind: ["workspace", "ui"]`, so it also runs in a local window). It works like
  Dev Containers' *Clone Repository in Container Volume…*:
  - pick the repository in VS Code's own picker (Git: Clone's: GitHub repositories you can see,
    recent ones, or a URL), then a branch;
  - if you already have a workspace on that repository and branch, it opens it, starting it if
    needed; otherwise it creates `<repo>-<branch>` from the template that asks for a repository
    and a branch;
  - it follows the build, then opens VS Code Desktop on the cloned folder through the Coder
    extension.

  Login uses the Coder CLI's session, or a token from `/cli-auth`, which is stored in VS Code's
  secret storage.
- **Repositories without a devcontainer.json:**
  - The service's new `fallbackImage` setting (`--fallback-image`, `FALLBACK_IMAGE`,
    `build.fallbackImage`, [ADR-0013](docs/decisions/0013-fallback-config-for-repos-without-one.md))
    builds them on that image instead of failing. The chart defaults it to
    `mcr.microsoft.com/devcontainers/base:ubuntu`.
  - In the workspace, the extension shows **Add Dev Container config**, which runs Dev
    Containers' own *Add Dev Container Configuration Files…*.
  - You commit and push it, and the rebuild prompt moves the workspace onto it.

### Changed

- Template: `rebuild_extension_url` is now `vscode_extension`, a Marketplace ID by default
  (`deepspacecartel.devcontainer-builder`) or a VSIX URL. The extension is kept up to date on
  every start, and the old `deepspacecartel.devcontainer-builder-rebuild` is uninstalled.

## [0.4.0] - 2026-10-07

### Added

- **Rebuild prompt** (`vscode-extension/`, a VSIX on each GitHub Release): a VS Code extension the
  template installs into workspaces. When `.devcontainer/`, `.devcontainer.json` or the Dockerfile
  and build context devcontainer.json points at change on `origin/<branch>` after the image was
  built, it shows **Rebuild available** in the status bar and offers Rebuild / Later / Ignore This
  Commit. Rebuild bumps the workspace's **Rebuild** parameter through the Coder API (it needs
  `coder login` in the workspace; without it, it opens the workspace settings). Changes that
  aren't pushed get a "commit & push first" nudge instead. The template sets
  `DEVCONTAINER_IMAGE_COMMIT`, `DEVCONTAINER_BRANCH` and `DEVCONTAINER_REBUILD` for it and gains
  the `rebuild_extension_url` variable (empty to not install it).

### Changed

- **Breaking for the template's users:** `templates/coder-kubernetes` maps the rest of
  `devcontainer.json` onto the workspace (service and provider `>= 0.3.0`, see the guide's
  support table):
  - the pod runs as the image's remote user from the start (uid/gid recorded at build time);
    nothing starts as root, and the uid no longer has to be 1000;
  - the repo is cloned into `workspaceFolder` at the commit the image was built from, by the
    lifecycle script itself (the `git-clone` module is gone), and `initializeCommand` runs first;
  - `containerEnv`/`remoteEnv`, `${localEnv:…}` from a new **Dev Container variables** parameter,
    forwarded ports as apps, volume/tmpfs mounts, capabilities (beyond Pod Security baseline
    only with `allow_privileged`), `init`, `/dev/shm`, host aliases, and `hostRequirements`
    overriding CPU/Memory/Disk;
  - a **Rebuild** parameter rebuilds the image from the branch tip;
  - VS Code in the browser is Microsoft's VS Code Server (`vscode-web`, behind
    `accept_vscode_license`) instead of code-server;
  - what can't be honored is a Terraform warning in the build log.

  Images built by devcontainer-builder older than 0.3.0 must be rebuilt (bump **Rebuild**).

## [0.3.0] - 2026-10-07

### Added

- `GET /devcontainer` now returns everything a Kubernetes workspace needs
  beyond lifecycle commands (see
  [ADR-0012](docs/decisions/0012-dev-container-to-kubernetes-runtime-mapping.md)):
  - `runtime`: remote/container user, forwarded ports, volume and tmpfs mounts, capabilities,
    `privileged`, `init`, seccomp, `/dev/shm` size, hostname, host aliases and resources,
    translated from the merged configuration plus `runArgs`;
  - `envScripts`: `containerEnv`/`remoteEnv` as sourceable `export` scripts;
  - `variables`: every `${localEnv:…}`, `${containerEnv:…}` and workspace variable, with defaults;
  - `configuration.workspaceFolder`/`runArgs`/`initializeCommand` and
    `lifecycleScripts.initializeCommand`.

  Docker-only settings without a pod equivalent produce warnings.
- `POST /build` writes a second image label, `com.deepspacecartel.devcontainer-builder.config`,
  with the `devcontainer.json` properties the CLI's own label leaves out
  (`workspaceFolder`, `runArgs`, `initializeCommand`) plus the remote user's uid/gid/home (read
  from the image's `/etc/passwd` by a BuildKit stage, returned as `runtime.remoteUserUid`/`Gid`/`Home`),
  and reports the built `commit` (full SHA).
- `npm run test:unit`: fast, cluster-free tests of `GET /devcontainer`'s logic, also run in CI.

### Changed

- **Variables are rewritten, not left as-is:** in rendered lifecycle scripts, `${…}` references
  now become shell variables the caller sets at runtime (`${containerEnv:PATH}` → `${PATH}`,
  `${localEnv:X}` → `${DEVCONTAINER_LOCALENV_X}`, …), instead of passing through unsubstituted
  with a warning.

- `templates/coder-kubernetes` now follows the repo's `devcontainer.json`
  beyond the image, via the provider's new `devcontainerbuilder_devcontainer`
  data source (provider and service `>= 0.2.0`): the image's `remoteUser`
  decides whose home is persisted (the interim **Remote user** parameter is
  gone); `onCreateCommand`/`updateContentCommand`/`postCreateCommand`/
  `postStartCommand` run from a login-blocking script on **every** start
  (so they must be idempotent), `postAttachCommand` from a non-blocking one;
  and `customizations.vscode` extensions/settings are installed into
  `~/.vscode-server` from the Microsoft Marketplace for VS Code Desktop,
  which gets a button opening the cloned repo.

## [0.2.0] - 2026-10-07

### Added

- `GET /devcontainer?registry=&name=&tag=[&platform=]` — reads a built
  image's `devcontainer.metadata` label straight from its registry and
  returns `configuration` (exactly the Dev Containers CLI's
  `mergedConfiguration` shape), `lifecycleScripts` (each hook rendered as one
  POSIX `sh` script with the CLI's ordering/parallel/stop-on-failure
  semantics), `vscode` (extensions and settings merged the way VS Code does),
  `warnings`, and the raw `metadata`. `404` for a missing tag, `422` for an
  image without the label or the requested platform. See
  [ADR-0011](docs/decisions/0011-devcontainer-metadata-endpoint.md).
- `insecureRegistries` setting (`--insecure-registries`,
  `INSECURE_REGISTRIES`, settings file, chart value) — registry hosts the
  service's own registry calls (`/image`, `/devcontainer`) reach over plain
  HTTP. Empty by default; reported by `GET /config`.
- New metric `devcontainer_builder_devcontainer_lookups_total{result}`.

### Changed

- **Breaking:** `templates/coder-kubernetes` now persists the workspace's
  home *and* `/workspaces`. The `coder-<id>-home` PVC (mounted at
  `/home/coder`, which wasn't the image user's home, so nothing actually
  survived a restart) is replaced by one `coder-<id>-data` PVC, mounted via
  subPaths at the remote user's home and at `/workspaces`. A new `seed-home`
  init container copies the image's own home into the PVC on first start,
  so the mount doesn't hide the image's dotfiles. The `home_disk_size`
  parameter is renamed `disk_size`; a new, interim `remote_user` parameter
  (default `node`) sets which home is mounted, until the template reads
  `remoteUser` from `devcontainer.json`. code-server now installs under
  `~/.cache/code-server` instead of `/tmp`. **Upgrading:** workspaces
  created from the previous template version must be recreated.
- `templates/coder-kubernetes` now clones the repository into
  `/workspaces/<repo name>` on first start, using Coder's `git-clone`
  registry module (it only clones into an empty folder, so the working copy
  is never touched on later starts). code-server opens in that folder
  (terminals still start in `$HOME`: `coder_agent.dir` is deprecated). code-server now comes from Coder's
  `code-server` registry module instead of a hand-written startup script.
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*` are set from the workspace owner's
  name and email.

- `.github/workflows/release.yaml`'s `image` job now caches Docker layers
  via BuildKit's GitHub Actions cache backend (`cache-from`/`cache-to:
  type=gha`, `mode=max`) — `runtime-base`'s apt-get install (git,
  `docker-ce-cli`, `buildx`, `@devcontainers/cli`) never actually changes
  release to release, but was being rebuilt from scratch on both
  `linux/amd64` and `linux/arm64` every single time.

### Fixed

- `GET`/`DELETE /image` with a namespaced `registry` (e.g.
  `ghcr.io/deepspacecartel`, as `POST /build` returns it) built an invalid
  registry URL. The namespace is now part of the repository path, and
  ambient credentials stored for the bare host (`ghcr.io`) are found.
- `GET`/`DELETE /image` never sent credentials to registries that use Basic
  (htpasswd) auth instead of a Bearer token exchange.

## [0.1.5] - 2026-09-16

### Fixed

- `charts/devcontainer-builder`'s Deployment `spec.selector.matchLabels` and
  Service `spec.selector` no longer include `helm.sh/chart` (which changes
  every chart release) — only the stable `app.kubernetes.io/name`/`instance`
  identity labels, via a new `selectorLabels` helper. A Deployment's
  selector is immutable, so the old behavior broke the very first real
  `helm upgrade` any installation ever did, with `field is immutable`.
  **Upgrading from an already-deployed pre-fix chart version still needs a
  one-time manual `kubectl delete deployment <release>-devcontainer-builder`
  (Service/Secrets/ConfigMap untouched) before the next `helm upgrade`** —
  changing the selector's shape is itself an immutable-field change, so this
  fix can't retroactively repair an existing Deployment on its own.

## [0.1.4] - 2026-09-16

### Fixed

- `charts/devcontainer-builder`'s deployment template now defaults
  `image.tag` to the chart's own `.Chart.AppVersion` instead of the
  hardcoded, never-updated `"0.1.0"` in `values.yaml` — every chart release
  since the start shipped with this stale default, so a plain
  `helm install`/`helm upgrade` (no explicit `--set image.tag=...`) always
  ran the very first image ever published, regardless of which chart
  version was actually deployed.
- Chart icon added, clearing `helm lint`'s "icon is recommended" notice.

## [0.1.3] - 2026-09-16

### Added

- `GET /config` now reports `registryAuth` — which registries this instance
  has ambient push credentials for (hostnames only, never the credential
  material), read from the same Docker config file the `docker`/`buildx`
  CLI subprocess itself reads. Previously the only way to confirm ambient
  `registryAuth` actually took effect was decoding the K8s Secret directly.
- `service/README.md` — the published npm package had no README of its own.

## [0.1.2] - 2026-09-16

### Fixed

- `charts/devcontainer-builder`'s `fullname` template no longer duplicates
  the chart name onto the release name when the release is already named
  `devcontainer-builder` — Service/Secret/ServiceAccount names used to come
  out as `devcontainer-builder-devcontainer-builder`, now the standard
  `helm create`-style dedup applies.
- `.github/workflows/release.yaml`'s `image` job now waits for a
  just-published npm version to actually propagate before the `release`
  Dockerfile target tries to `npm install` it — hit a real race where the
  build started seconds after `npm publish` returned and the version wasn't
  resolvable yet.

## [0.1.1] - 2026-09-16

### Added

- `templates/coder-kubernetes/` — a real, runnable Coder Workspace Template
  (adapted from the official `coder/kubernetes` registry template) where a
  workspace-level git-repository parameter drives a real
  `devcontainerbuilder_build` before the workspace's pod ever starts, instead
  of a fixed image. See the new
  [Coder Workspace Template guide](docs/guides/coder-workspace-template.md).
- CLI/npm package: `service/` is now published to npm as
  `@deepspacecartel/devcontainer-builder`, runnable directly via
  `npx @deepspacecartel/devcontainer-builder`.
- Live, generated OpenAPI document (`GET /documentation/json`, Swagger UI at
  `GET /documentation`) — generated from the same TypeBox route schemas that
  validate every request, so it can't drift from what the service actually
  accepts. Restish and other OpenAPI-aware clients can auto-configure
  against a running instance.
- Optional bundled BuildKit dependency for the Helm chart
  (`buildkit.deploy.enabled`, off by default) — a single
  `helm install --set buildkit.deploy.enabled=true` now works with zero
  pre-existing BuildKit infra.
- `.github/workflows/release.yaml` — a `vX.Y.Z` tag now builds and
  publishes the Docker image (multi-arch, GHCR), the Helm chart (OCI, GHCR),
  and the npm package together, then cuts a GitHub Release.
- `.github/workflows/docs.yaml` — this documentation site now builds
  (`mkdocs build --strict`) and deploys (GitHub Pages, via the
  Actions-based flow) automatically.
- `GET /health/startup` — a Kubernetes `startupProbe`, wired into the Helm
  chart with a generous `failureThreshold` so slow pod scheduling/image
  pulls never trip `livenessProbe`/`readinessProbe`.
- `GET /metrics` — Prometheus text-format metrics (`prom-client`), Node.js
  process defaults plus real build/image-check/image-delete counters and a
  build-duration histogram.
- `GET /config` — read-only, non-sensitive view of the service's own
  loaded configuration (credential material always redacted).
- Optional Sentry/GlitchTip error tracking (`SENTRY_DSN`) and optional
  OpenTelemetry tracing (`OTEL_EXPORTER_OTLP_ENDPOINT`), both entirely off
  unless configured.
- The generated OpenAPI document now has real per-route tags (`Dev
  Containers`/`Images`/`Health`/`Configuration`/`Logs`) instead of the
  default catch-all group, and realistic request examples (real repo URLs,
  one showing `registryCredentials` explicitly) — upgraded to OpenAPI 3.1
  so TypeBox's own `examples` keyword survives `@fastify/swagger`'s
  transform (silently dropped under its default 3.0.x).
- `terraform/devcontainer-build` now wraps
  `terraform-provider-devcontainer-builder`'s `devcontainerbuilder_build`
  resource internally instead of `data "http"` — the module's
  variable/output interface is unchanged, but a real build now only runs
  on `terraform apply`, for an actual diff, not on every single `terraform
  plan`. `build.tftest.hcl` gains a real, mocked contract test
  (`mock_provider`) this now makes possible.
- Event-oriented structured logging: every log line now carries an
  explicit `event` name plus OpenTelemetry-semantic field names
  (`http.route`, `error.type`, `image.registry`, ...) instead of a
  free-text message, `service.name`/`service.version`/
  `deployment.environment.name` on every line (new `SERVICE_NAME`/
  `DEPLOYMENT_ENVIRONMENT` config fields, the latter also a first-class
  Helm chart value), and `trace.id`/`span.id` correlation with
  OpenTelemetry traces when tracing is enabled. See
  [ADR-0009](docs/decisions/0009-event-oriented-structured-logging.md).
- `git clone`/`devcontainer build --push` output is now captured to a file
  per invocation instead of being written straight to the pod's own
  stdout, fetchable/deletable via new `GET`/`DELETE /logs/{id}` routes
  (`POST /build` returns the relevant id as `gitCloneLogId`/
  `imageBuildLogId` on success, `logId` on failure). Retained per kind
  (`git`/`docker`), capped by the new `commandLogRetention` config field
  (default 10). See
  [ADR-0010](docs/decisions/0010-command-output-capture.md).
- `service/Dockerfile` now has two build targets instead of one: `dev`
  builds from this checkout's source (unchanged default behavior, no
  `--target` needed), `release` installs a specific version of the
  published npm package instead, so the shipped image and the published
  package are provably the same artifact.
  `.github/workflows/release.yaml`'s `npm` job now runs before (not
  parallel with) `image`, which builds the `release` target — and the npm
  Trusted Publisher grant moved from `stage` to full `publish`, since
  `image` needs that version live with no manual approval step in
  between.

### Changed

- The HTTP service is rebuilt on [Fastify](https://fastify.dev) instead of
  a bare `node:http` listener — every documented request/response shape
  and status code is unchanged (verified against every case in
  `service/features/request_validation.feature`).
- `charts/devcontainer-builder/values.yaml`'s `image.repository` now
  defaults to the real, published
  `ghcr.io/deepspacecartel/devcontainer-builder` image.
- Docs restructured into dedicated Application / Helm Chart / Terraform
  nav sections (previously a doc-type split of Concepts/Reference that
  didn't map to the three deployable pieces); the Quickstart now leads
  with the chart's bundled BuildKit dependency instead of requiring a
  pre-existing BuildKit daemon, and makes registry credentials explicit
  from its first example.
- The HTTP API reference is now two fully static, generated pages
  (`docs/api-reference.html` via Redoc, `docs/api-swagger-ui/` — the exact
  static bundle `GET /documentation` serves live) instead of a hand-written
  `docs/reference/API.md`.

### Fixed

- `service/package.json`'s `thomas` devDependency no longer points at a
  local sibling directory (`file:../../thomas`) that only resolved in one
  specific development environment — it's pinned to a real
  `github:DeepSpaceCartel/thomas` commit instead, which resolves in a
  fresh clone or CI with no sibling checkout needed.
- The docs site's Redoc-based API viewer used to be a `<script>` tag
  embedded inline in a markdown page — it silently broke under this
  theme's `navigation.instant` (client-side page transitions don't re-run
  an injected `<script>` tag, only a real full page load does). Replaced
  by the two fully static generated pages above, which don't depend on a
  script running after navigation at all.

[Unreleased]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/DeepSpaceCartel/devcontainer-builder/releases/tag/v0.1.1
