<title>ADR-0012</title>

# ADR-0012: Dev Container → Kubernetes runtime mapping

Status: accepted
Date: 2026-10-07

## Context

[ADR-0011](0011-devcontainer-metadata-endpoint.md) made a built image's
merged `devcontainer.json` readable through `GET /devcontainer`, enough to
run lifecycle commands and install VS Code extensions in a Coder workspace.
The rest of `devcontainer.json` still did nothing: `containerEnv` and
`remoteEnv`, `forwardPorts`, `mounts`, `runArgs`, `hostRequirements`,
`workspaceFolder`, `initializeCommand`, and `${…}` variables everywhere.

Three constraints shape how they can work:

1. **The image is the only input that exists when the pod is planned.** The
   repository is cloned later, inside the running workspace.
2. **Some properties never reach the image.** The Dev Containers CLI's
   `devcontainer.metadata` label carries what's needed to *attach* to a
   container. `workspaceFolder`, `runArgs` and `initializeCommand` are
   re-read from the repo when the CLI *creates* one, so they're not in it.
3. **Variables refer to things this service doesn't have.**
   `${localEnv:X}` is the developer's machine, `${containerEnv:X}` the
   running container, `${containerWorkspaceFolder}` and
   `${devcontainerId}` are decided by whoever creates the container. In a
   Coder workspace that's the template, at runtime.

Spikes in Coder (2026-10-07) also showed that **template parameters can't
depend on the image or the repository**. Coder evaluates a provider's data
sources only once, at template import, and its dynamic-parameter preview
reuses that value. So neither per-variable parameters nor `hostRequirements`
as parameter defaults are possible.

## Decision

**A second image label, written by the build.**
`com.deepspacecartel.devcontainer-builder.config` holds `workspaceFolder`,
`runArgs` and `initializeCommand`, raw, from the repo's
`devcontainer.json` (JSONC, found the way the CLI finds it). It's added by
a second, layer-less BuildKit build (`FROM <image>` plus `--label`) after
`devcontainer build --push`. `devcontainer build --label` only works on
the CLI's image+Features path, not for `build.dockerfile` configs (CLI
0.89.0). Images built before this change have no such label; they still
work, with defaults and a warning.

The same label records the **remote user's account** (`remoteUserAccount`:
name, uid, gid, home). Kubernetes needs a numeric uid
(`securityContext.runAsUser`), but devcontainer.json names a user, and the
mapping lives in the image's `/etc/passwd`. A throwaway BuildKit stage
(`FROM <image>`, `getent passwd <user>`, exported as one file) reads it at
build time, so a pod can run as that user from the start
(`runAsUser`/`runAsGroup`/`fsGroup`): no root start and no user switching
inside the container. It's best effort: an image without a shell gets no
account, and `runtime.remoteUserUid` is null.

**`GET /devcontainer` stays a function of the image alone, with no query
parameters.** Variables are **detected and rewritten, never substituted.**
In every script the service renders, a reference becomes a shell variable
that the workspace sets at runtime:

| Reference | Becomes |
|---|---|
| `${containerEnv:X[:default]}` | `${X:-default}`, the container's real environment |
| `${localEnv:X[:default]}` (and `${env:…}`) | `${DEVCONTAINER_LOCALENV_X:-default}` |
| `${containerWorkspaceFolder}`, `${localWorkspaceFolder}` | `${DEVCONTAINER_WORKSPACE_FOLDER}` |
| their `…Basename` forms | `${DEVCONTAINER_WORKSPACE_FOLDER_BASENAME}` |
| `${devcontainerId}` | `${DEVCONTAINER_ID}` |

`variables` lists every reference with its default and where it's used.
`envScripts.containerEnv` and `envScripts.remoteEnv` are `export K="…"`
scripts, meant to be sourced in that order before anything starts, so a
value like `"${PATH}:/opt/bin"` expands against the image's real `PATH`.
That's what `devcontainer up` produces; `devcontainer read-configuration`
itself leaves `${containerEnv:…}` unresolved. Values Kubernetes needs
before the container runs (`workspaceFolder`, mount targets, `hostname`)
keep their placeholders for the template to fill in.

**`runtime`: the translation into pod terms.**
- `remoteUser`: remoteUser, then containerUser, then the image's `USER`, then root.
  Also `remoteUserUid`/`remoteUserGid`/`remoteUserHome` from the recorded account.
- `containerUser`.
- `ports`: numeric `forwardPorts` with their `portsAttributes`.
- `mounts`: volume and tmpfs.
- `capAdd`, `privileged`, `init`, `seccompUnconfined`, `shmSizeBytes`, `hostname`, `hostAliases`.
- `resources`, from `hostRequirements`, or `--cpus`/`--memory` when given.

The supported `runArgs` are `--cap-add`, `--privileged`, `--security-opt`,
`--init`, `--shm-size`, `-e`/`--env`, `--cpus`, `-m`/`--memory`,
`--hostname`, `--add-host`, `--mount`/`-v` (volumes only) and `--tmpfs`.
Everything without a pod equivalent produces a **warning**, never silence:
bind mounts, `host:port` forwards, `--network`, `--device`, `--gpus`,
other `securityOpt`s and unknown flags.

**`POST /build` reports the commit it built** (`commit`, full SHA), so a
workspace can check out exactly the source its image came from.

## Consequences

- One tested place does the parsing and quoting that would otherwise be
  rewritten in HCL in every template. Shell rendering is checked by unit
  tests that *run* the generated scripts; variable handling is checked
  against the CLI's own substitution.
- **`${localEnv:…}` values come from the user at runtime**, through one
  multi-line workspace parameter, not one parameter per variable
  (impossible in Coder, see above). The dashboard lists the variables the
  image uses and which are unset.
- **`hostRequirements` override the template's CPU, Memory and Disk
  parameters** when the image sets them; parameter defaults can't come from
  the image.
- An image's config label is fixed at build time: changing
  `workspaceFolder` or `runArgs` takes a rebuild, like any other
  `devcontainer.json` change.
- Not mapped: Docker-in-Docker, bind mounts, `--network`/`--device`,
  `dockerComposeFile`, `updateRemoteUserUID` and `shutdownAction` (Coder's
  auto-stop can't be set from template Terraform).
