---
title: Dev Containers parity for Coder Kubernetes workspaces
created: 2026-10-01
---

# Dev Containers parity for Coder Kubernetes workspaces

## Status (2026-10-07): done

Every feature below has shipped, several in a different shape than planned here. This
plan is kept as the record of the starting point; the current design lives in:

- [ADR-0011](../../decisions/0011-devcontainer-metadata-endpoint.md): `GET /devcontainer`,
  the image's merged metadata, lifecycle scripts, VS Code customizations.
- [ADR-0012](../../decisions/0012-dev-container-to-kubernetes-runtime-mapping.md): the
  runtime mapping, variables, the build's config label, the recorded remote-user uid.
- The guide's support table: [devcontainer.json in a Kubernetes workspace](../../guides/coder-workspace-template.md#devcontainerjson-in-a-kubernetes-workspace).

| Feature | Outcome |
|---|---|
| F0 plan-time configuration | **Replaced.** Coder evaluates provider data sources only at template import, so nothing can be known at plan time per workspace. Instead `GET /devcontainer` reads the *built image* (service 0.2.0/0.3.0), and the template consumes it at apply time. |
| F1 commit pinning, rebuild | Done, simplified. `POST /build` reports the commit; a fresh clone checks it out; a **Rebuild** parameter (`replace_triggered_by`) rebuilds from the branch tip. There's no commit input. |
| F2 persistence | Done. PVC subPaths for home, `/workspaces`, an outside `workspaceFolder`, and volumes. |
| F3 users | Done, differently. The build records the remote user's uid/gid/home (BuildKit probe of `/etc/passwd`), and the pod runs as that user from the start. There's no root plus `setpriv`. Older images fall back to uid 1000. |
| F4 lifecycle | Done. The service renders each hook (CLI semantics); one blocking `coder_script` runs them on every start; `initializeCommand` runs first. |
| F5 clone | Done. The lifecycle script clones into `workspaceFolder` at the image's commit (the `git-clone` module was dropped: it can't clone into a folder holding mount points). |
| F6 extensions | Done. Installed from the Microsoft Marketplace into `~/.vscode-server`, used by VS Code Desktop and vscode-web. |
| F7 env | Done. `envScripts` are sourced by the startup wrapper; `${…}` variables become shell references; `${localEnv:…}` comes from a **Dev Container variables** parameter. |
| F8 ports | Done. `coder_app` slots (fixed count, unused ones hidden). |
| F9 mounts, runArgs | Done, without DinD. Volumes, tmpfs, capabilities (beyond Pod Security baseline only with `allow_privileged`), init, shm, host aliases, resources from `hostRequirements`. |
| F10 IDE folder | Done. vscode-web (replacing code-server) and VS Code Desktop open `workspaceFolder`. |
| F11 git identity | Done. |
| F12 sandbox2 | Done. |
| F13 Features for this repo | Done. Terraform, kubectl/helm, gh, Go and Claude Code come from Features; docker CLI, devcontainers CLI, 1Password, k9s, Starship and pipx from the local `.devcontainer/workspace-tools` Feature. Per-start hooks dropped from about 100 s to about 11 s. |
| F14 rts sync | Done. rts-terraform #24, #27, #29, #30. |
| F15 rebuild prompt | Done. A VS Code extension (`vscode-extension/`) compares the image's commit with `origin/<branch>` over the Dev Container files and build context, and offers Rebuild (Coder API, after `coder login`). No service or provider changes. |

## Context

v1 of the `kubernetes-devcontainer-dsc` template proves the build path: the pod runs the
image devcontainer-builder pushed. The template is a copy of
`templates/coder-kubernetes/main.tf` and lives at
`rts-terraform/environments/dev/kubernetes/coder-templates/templates/kubernetes-devcontainer/main.tf`.

Everything in `devcontainer.json` except the image is ignored, and the workspace doesn't
survive a restart:

- **Home isn't persisted.** The PVC is mounted at `/home/coder`, but the image user is
  `node` with home `/home/node`. In this workspace the pod restarted at 19:42 and the
  tools were re-installed by hand at 19:51.
- **Nothing else runs.** There are no lifecycle commands, no repo clone and no git
  identity, and code-server opens the wrong folder.
- **Root cause:** Terraform never sees the devcontainer config. The service returns only
  `{image, registry, name, tag, logIds}` (`service/src/build.ts:410`,
  `schemas.ts:141-153`).

The target is for a new workspace to behave like VS Code's "Clone Repository in
Container Volume", adapted to K8s pods.

**Confirmed decisions:**
- Lifecycle commands run on every pod start.
- The provider repo is in scope.
- Workspaces stay on the commit they were created from; rebuilding from latest is opt-in.

Each feature below lists its changes per layer: **Service** (`service/src`), **Provider**
(`/home/coder/terraform-provider-devcontainer-builder`, cloned from
`DeepSpaceCartel/terraform-provider-devcontainer-builder`), **Template**
(`templates/coder-kubernetes/main.tf`, then synced to the rts-terraform copy), and
**Verify**.

---

> **Update, 2026-10-07:** `GET /devcontainer` ([ADR-0011](../../decisions/0011-devcontainer-metadata-endpoint.md))
> reads the built image's `devcontainer.metadata` label from the registry
> and returns the CLI's own `mergedConfiguration` plus rendered
> `lifecycleScripts` and merged `vscode` extensions/settings. It covers
> the service side of F4 and F6, and of F7–F9 as data (`remoteEnv`,
> `forwardPorts`, `mounts`, ... are in `configuration`). It replaces F0's
> `POST /configuration` for everything known only after the build — the
> spike is no longer needed. F0 still applies to anything needed at **plan**
> time before an image exists (e.g. `for_each` over `forwardPorts` on the
> first create). The provider data source and the template wiring for this
> endpoint are the next steps.

## Feature 0: plan-time devcontainer configuration (foundation for 1-7)

Every feature that changes the pod spec or creates `coder_app`s needs the merged
devcontainer config at **plan** time.

- **Service.** Add a new `POST /configuration` (`server.ts`, `schemas.ts`, `types.ts`).
  - Request: `{repository, ref, gitCredentials?}`.
  - Extract a shared `cloneRepository()` from `buildDevcontainer`. It reuses
    `parseRepositoryUrl`/`toCloneUrl`, the netrc/ssh scratch helpers (`build.ts:157-212`)
    and command logging.
  - Then run `devcontainer read-configuration --workspace-folder <repo> --include-merged-configuration`.
  - Return a **normalized** response with:
    - `commit` and `repositoryName`
    - `remoteUser`, `containerUser` and `workspaceFolder` (default `/workspaces/<repoName>`)
    - the per-feature fields defined below
    - `warnings[]`
- **Spike first.** Check whether merged configuration works without a docker daemon for
  both `image:` and `build.dockerfile` configs; it should fall back to registry
  inspection. If it doesn't, read the `devcontainer.metadata` label through
  `registry-client.ts` instead. Record the outcome in `docs/claude/notes/`.
- **Provider.** Add a new data source `devcontainerbuilder_configuration`.
  - Inputs: `repository`, `ref`, `git_credentials`.
  - Outputs: `commit`, `repository_name`, `remote_user`, `workspace_folder`, and
    `configuration_json` (the full response).
- **Template.** Add `data "devcontainerbuilder_configuration" "ws" { count = start_count }`
  and `locals { dc = jsondecode(...configuration_json) }`. Using `count = start_count`
  means stopping a workspace never depends on the builder being up.
- **Docs.** ADR-0011, plan-time configuration endpoint (why not read the image label at
  runtime).
- **Verify.**
  - New `service/features/configuration.feature`, modelled on
    `devcontainer_config_content.feature`.
  - `terraform plan` shows the `coder_app` for_each as known on first create.
  - Stopping a workspace while the builder is scaled to 0 succeeds.

## Feature 1: commit pinning and opt-in rebuild

- **Service.** `POST /build` accepts `commit`: after the clone, `git fetch --depth 1 origin <sha>`
  and check it out. The response adds `commit`, and the default tag stays `sha-<7>`.
- **Provider.** `devcontainerbuilder_build` gets an optional `commit` input (forces
  replacement) and a computed `commit` output.
- **Template.**
  ```hcl
  data "coder_parameter" "rebuild_generation" { type = "number", mutable = true, default = 0 }
  data "devcontainerbuilder_configuration" "latest" { count = start_count; ref = branch }
  resource "terraform_data" "pinned_commit" {
    input            = data.devcontainerbuilder_configuration.latest[0].commit
    triggers_replace = data.coder_parameter.rebuild_generation.value
    lifecycle { ignore_changes = [input] }
  }
  # the "ws" configuration and devcontainerbuilder_build both use terraform_data.pinned_commit.output
  ```
- **Risk.** This relies on `terraform_data` planning `output = input` when the input is
  known. If it doesn't, fall back to `ref = branch` for the first create.
- **Verify.** Push a commit and restart: the image is unchanged. Bump the parameter: a new
  image is built at the new SHA.

## Feature 2: persistence of `/workspaces` and home

> **Done (template), 2026-10-02.** Two deviations, both until F0/F3 land:
> - The remote user comes from an interim `remote_user` workspace parameter (default
>   `node`), not `local.dc.remoteUser`. Swap it in `locals` once F0 exists.
> - `seed-home` runs as uid 1000, not root, because the pod is still non-root. So there's
>   no `chown`, and it also checks that the user's uid is 1000. Move it to root in F3.
>
> Verified end-to-end on dev Coder via the side-by-side `kubernetes-devcontainer-v2-dsc`
> template: after a stop/start, `~/.claude/x`, `/workspaces/f2test/y` and a `.bashrc` edit
> survived, and `seed-home` didn't seed again. F14 still has to fold v2 back into
> `kubernetes-devcontainer`.

- **Template.**
  - Replace PVC `coder-<id>-home` with a single `coder-<id>-data`, mounted through subPaths:
    - `home/` at `/home/<remoteUser>` (`/root` if the user is root)
    - `workspaces/` at `/workspaces`
  - Rename the `home_disk_size` parameter to `disk_size`.
  - Add an **initContainer `seed-home`**. It uses the same image, runs as root, and mounts
    the PVC at `/mnt/data`. It:
    - resolves the user's home with `getent` and fails if it differs from the planned path
    - on first run only, does `cp -a --no-clobber <image home>/. /mnt/data/home/` and then
      `chown`, so the image's `.bashrc`, `.oh-my-zsh` and nvm config aren't hidden by the
      mount.
  - Move the code-server install prefix from `/tmp` to `~/.cache/code-server`.
- **Breaking change:** v1 workspaces must be recreated. Document this in the CHANGELOG
  and the guide.
- **Verify.** Write `~/.claude/x` and `/workspaces/<repo>/y`, restart the workspace, and
  check both survive. `.bashrc` from the image is present.

## Feature 3: users (containerUser and remoteUser)

- **Template.** Remove the hard-coded `run_as_user/fs_group = 1000` and `run_as_non_root`.
  - The container runs as `containerUser`, which defaults to root as in Dev Containers.
  - The `command` becomes an entrypoint wrapper. It drops to `remoteUser` (using `setpriv`,
    falling back to `runuser`, then `su`), sets `HOME` from `getent`, and execs
    `coder_agent.main.init_script`.
- **Infra.** The namespace's PodSecurity level must allow root; baseline is enough.
- **Verify.**
  - `whoami` = node and `$HOME=/home/node`.
  - An alpine fixture also boots (busybox fallbacks).

## Feature 4: lifecycle commands mapped to K8s

Each pod start is a new container with a fresh root filesystem, so all of these hooks run
on **every start**, in the main container. Commands must be idempotent.

- **Service.**
  - The response includes `lifecycleScripts{onCreate, updateContent, postCreate,
    postStart, postAttach}` and `waitFor`. Each script is pre-rendered POSIX sh.
  - Hooks are merged in spec order: features first, then `devcontainer.json`.
  - Command forms:
    - string: run with `sh -c`
    - array: run as quoted argv
    - object: run as parallel `&` jobs, then `wait`, then check for failures
  - `initializeCommand` runs on the host in Dev Containers, so it isn't supported and
    becomes a warning.
- **Template.** Add `coder_script "devcontainer_lifecycle"` with `run_on_start` and
  `start_blocks_login = true`.
  - It runs `onCreate`, `updateContent`, `postCreate` and `postStart` in order, each from
    the `workspaceFolder`, and logs to `/tmp/devcontainer-lifecycle.log`.
  - It runs after the clone (Feature 5) and the extension installs (Feature 6).
  - `postAttach` is a separate, non-blocking `coder_script`.
- **Docs.** ADR-0012, Dev Container lifecycle and runtime settings in K8s: every-start
  semantics, privilege drop, and unsupported properties.
- **Verify.** postCreate output is in the log after each restart, and `k9s`/`bun` are on
  PATH. BDD scenarios cover all three command forms.

## Feature 5: clone the repo following the Dev Containers convention

> **Done (template), 2026-10-02**, using Coder's `git-clone` registry module (2.0.5) with
> `base_dir = "/workspaces"` and `folder_name = local.repo_name`, not a hand-written
> script. The folder comes from the repository URL until F0. Still open:
> - checking out the pinned commit (F1); the module can't do this without resetting HEAD
>   on every start
> - the F4 lifecycle script runs in parallel with the module, so it must wait for `.git`
>
> Clone verified on dev Coder via `kubernetes-devcontainer-v2-dsc`, 2026-10-01: the repo
> lands in `/workspaces/<repoName>` on the branch parameter. Not yet checked: local edits
> surviving a restart (the module skips an existing clone, so they should).
>
> "The agent's `dir` is set to `workspaceFolder`" was dropped: `coder_agent.dir` is
> deprecated, and any value other than `$HOME` breaks Coder Desktop file sync.

- **Template.** This is the first step of the lifecycle `coder_script`.
  - If `/workspaces/<repoName>/.git` is missing, clone with
    `git clone --branch <branch> <repo> /workspaces/<repoName>`, then check out the
    pinned commit.
  - The clone uses the agent's `GIT_ASKPASS` and `coder gitssh`.
  - An existing working copy is never touched.
  - `workspaceFolder` comes from the config and defaults to `/workspaces/<repoName>`.
  - The agent's `dir` is set to `workspaceFolder`.
- **Verify.**
  - The repo is at `/workspaces/devcontainer-builder`, and `git status` is clean on the
    pinned commit.
  - Local edits survive a restart.

## Feature 6: `customizations.vscode.extensions`

- **Service.** The response includes `extensions[]` and `settings{}`.
- **Template.**
  - The lifecycle script runs `code-server --install-extension <id>` for each extension
    from Open VSX, before postCreate. Failures are only warnings, because not every
    Marketplace extension is on Open VSX.
  - `settings` is merged into code-server's `User/settings.json`.
  - Add the `vscode-desktop` registry module. VS Code Desktop gets extensions via
    `.vscode/extensions.json` recommendations; document this as a limitation.
- **Verify.** Extensions show as installed in code-server.

## Feature 7: `containerEnv` and `remoteEnv`

- **Service.**
  - Substitute `${containerEnv:X}` and `${containerWorkspaceFolder}`.
  - `${localEnv:*}` becomes empty, with a warning.
- **Template.**
  - `containerEnv` becomes a dynamic `env` on the container.
  - `remoteEnv` becomes `coder_env` resources (for_each) on the agent.
- **Verify.** Fixture variables show up both in a terminal and in the pod spec.

## Feature 8: `forwardPorts` and `portsAttributes` as `coder_app`s

- **Service.**
  - The response includes numeric `forwardPorts[]` and `portsAttributes{}`.
  - `host:port` entries are dropped, with a warning.
- **Template.** `coder_app` for_each port:
  - `url = http://localhost:<port>`
  - `display_name` from `portsAttributes[port].label`
  - `subdomain = true`, `share = "owner"`
- **Verify.** A fixture with `forwardPorts: [3000]` and a label shows the app in the
  dashboard.

## Feature 9: `mounts` and `runArgs`

- **Service.**
  - `mounts[]` is normalized to `{type, source, target}`. Bind mounts are dropped with a
    warning.
  - `capAdd`, `privileged`, `init` and `securityOpt` are merged with a parsed subset of
    `runArgs`: `--cap-add`, `--privileged`, `--security-opt`, `--init`, `--shm-size` and
    `-e/--env`.
  - `--network`, `--device` and unknown flags become warnings.
- **Template.**
  - A `type=volume` mount becomes a dynamic `volume_mount` with subPath `volumes/<source>`
    on the data PVC.
  - Added capabilities go into `security_context.capabilities.add`.
  - `privileged` is honored only if the new template variable `allow_privileged` is set
    (default false). Otherwise the template fails with a clear message.
  - `--shm-size` becomes an `emptyDir{medium=Memory}` at `/dev/shm`.
  - `warnings[]` are shown as `coder_agent` metadata ("Dev Container warnings").
- **Verify.**
  - A volume mount persists across a restart.
  - `--cap-add=SYS_PTRACE` appears in the pod spec.

## Feature 10: code-server opens the workspace folder

> **Done (template), 2026-10-02.** code-server now comes from Coder's `code-server`
> registry module (1.6.0) with `folder = local.workspace_folder` and
> `install_prefix = "$HOME/.cache/code-server"`. The module's `extensions`/`settings`
> inputs may cover F6.

- **Template.** The code-server `coder_app` URL becomes
  `http://localhost:13337?folder=${local.dc.workspaceFolder}`, and the healthcheck is
  unchanged.
- **Verify.** Opening code-server lands in `/workspaces/<repoName>`.

## Feature 11: git identity

> **Done (template), 2026-10-02**, as planned.

- **Template.** `coder_env` resources:
  - `GIT_AUTHOR_NAME` and `GIT_COMMITTER_NAME` = `coalesce(owner.full_name, owner.name)`
  - `GIT_AUTHOR_EMAIL` and `GIT_COMMITTER_EMAIL` = `owner.email`
- **Verify.** `git commit` in the workspace records the owner's name and email.

## Feature 12: remove `sandbox2/`

> **Done, 2026-10-01.** The directory itself was already gone; only references remained.
> The unused `script_dir` in `typescript-node.sh` went with them.

- **Repo.**
  - Delete the sandbox2 block in `.devcontainer/typescript-node.sh` (lines 9-10 and 58-63,
    and the echo at line 66).
  - Remove the comment at `.devcontainer/postCreateCommand.sh:24`.
  - In `.vscode/settings.json`, point the cucumber globs at `service/features/**` only.
- **Verify.** `grep -rn sandbox2 --exclude-dir={node_modules,.git}` returns nothing.

## Feature 13: this repo's devcontainer moves rootfs installs into Features

Features run during the build now, so the comment saying Features "aren't usable yet" is
obsolete. Moving installs out of postCreate keeps the every-start lifecycle fast.

- **Repo.**
  - Terraform, kubectl/helm, GitHub CLI and the docker CLI become
    `ghcr.io/devcontainers/features/*` entries in `devcontainer.json`.
  - `postCreateCommand.sh` keeps only `$HOME`-scoped, idempotent steps: bun, krew/tree,
    starship, helm tui, pipx mkdocs, the kubeconfig from the ServiceAccount, and the
    Claude CLI.
  - Remove the duplicate `HashiCorp.terraform` extension entry.
- **Verify.** A cold workspace start takes under about 2 minutes after the image build.

## Feature 14: sync the rts-terraform template

> **In progress, 2026-10-01.** v2 folded into `kubernetes-devcontainer` and the v2 template
> removed in [rts-terraform#24](https://github.com/DeepSpaceCartel/rts-terraform/pull/24)
> (stacked on #20), not applied. Updating an existing v1 workspace to it deletes its old
> home PVC, so v1 workspaces must be recreated. Later features are synced the same way.

- **Infra.** Port the final `templates/coder-kubernetes/main.tf` into
  `rts-terraform/.../templates/kubernetes-devcontainer/main.tf`.
  - Keep the rts-only deltas: `service_account_name`, node_selector/toleration, and the
    `image_pull_secret_name` description.
  - Bump the provider constraint and apply `coder-templates`.
- **Verify.** The full end-to-end run on dev Coder: create a workspace for
  `DeepSpaceCartel/devcontainer-builder` and walk the Verify steps of Features 1-11.

---

## Order and cross-cutting work

1. Spike (F0).
2. Service F0, F1, F4, F6-F9, with BDD (`cd service && npm run build && npm test`).
3. Service release.
4. Provider F0 and F1, with acceptance tests and a release.
   `docs/reference/TERRAFORM-PROVIDER.md` is updated here.
5. Template F2-F11 (`terraform init && terraform validate`).
6. F12 and F13.
7. F14.

Docs that land alongside:
- ADR-0011 and ADR-0012, plus rows in `docs/decisions/index.md` and `mkdocs.yml` nav.
- Rewrite `docs/guides/coder-workspace-template.md` around a property-support matrix.
- Update `templates/coder-kubernetes/README.md` and the `[Unreleased]` section of
  `CHANGELOG.md`.
