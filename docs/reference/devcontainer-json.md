<title>devcontainer.json support</title>

# devcontainer.json support

What each `devcontainer.json` property becomes in a workspace built by the
[Coder template](template.md). The image is built by the official Dev
Containers CLI, so everything that goes **into the image** works as in Dev
Containers. Properties that describe **the running container** are
translated into Kubernetes terms
([ADR-0012](../decisions/0012-dev-container-to-kubernetes-runtime-mapping.md)).
devcontainer-builder reads them back from the built image's merged
configuration (base image + Features + `devcontainer.json`), merged the way
the Dev Containers CLI merges them.

| devcontainer.json | In the workspace |
|---|---|
| `image`, `build` (`dockerfile`, `context`, `args`, `target`), `features` | the image devcontainer-builder builds |
| *(no `devcontainer.json`)* | the service's `fallbackImage` (chart default `mcr.microsoft.com/devcontainers/base:ubuntu`), and an **Add Dev Container config** prompt ([ADR-0013](../decisions/0013-fallback-config-for-repos-without-one.md)) |
| `remoteUser`, `containerUser` | the pod's user, from the start: uid/gid recorded from the image's `/etc/passwd` at build time |
| `workspaceFolder` | where the repository is cloned (with the image's `git`) and the IDEs open (default `/workspaces/<repo>`) |
| `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand` | run in order, before login, on **every** start |
| `postAttachCommand` | once per start, not blocking login, after the other lifecycle commands have succeeded |
| `initializeCommand` | first, before `onCreateCommand`, in the repository folder (there's no host) |
| `containerEnv`, `remoteEnv`, `runArgs -e` | exported before the agent starts: terminals, IDEs and hooks all see them; `${PATH}:/x` expands against the image's real `PATH` |
| `${localEnv:NAME}` | the workspace's **Dev Container variables** setting |
| `${containerWorkspaceFolder}`, `${devcontainerId}` | the workspace folder; the Coder workspace ID |
| `forwardPorts`, `portsAttributes` | dashboard apps (label, http/https) through Coder's proxy, up to the template's `max_forwarded_ports` |
| `mounts`, `--mount`, `-v` (volume) | a directory on the workspace's volume (`volumes/<name>`), so it persists |
| `mounts`, `--tmpfs` (tmpfs) | an in-memory `emptyDir` |
| a volume or tmpfs mount at `/workspaces`, the home, the workspace folder, `/dev/shm`, or another mount's target | ⚠️ not mounted, with a warning: the path is already a mount point, and a pod can't mount two volumes at one path |
| `capAdd`, `--cap-add` | `securityContext.capabilities.add`; beyond Pod Security *baseline*'s list (e.g. `SYS_PTRACE`) only with the template's `allow_privileged` |
| `privileged`, `securityOpt: seccomp=unconfined` | only with `allow_privileged` |
| `init`, `--init` | `shareProcessNamespace` (the pause container reaps zombies) |
| `--shm-size` | `/dev/shm` as an in-memory `emptyDir` of that size (default 64 Mi) |
| `--add-host`, `--hostname` | pod `hostAliases`, `hostname` |
| `hostRequirements.cpus`, `.memory`, `--cpus`, `--memory` | **minimums**: reserved as pod requests (capped by `max_cpu`/`max_memory`, with a warning above them); limits are the larger of the requirement and the CPU/Memory parameters. ⚠️ Ignored, with a warning, when `customizations.kubernetes.resources` sets any request or limit |
| `hostRequirements.storage` | the larger of it and the Disk parameter, **when the workspace is created**: raising it later (and rebuilding) doesn't grow the volume. `customizations.kubernetes.storage` replaces it |
| `hostRequirements.gpu` | `nvidia.com/gpu: 1` (needs the NVIDIA device plugin), unless `customizations.kubernetes.resources` sets `nvidia.com/gpu` |
| `customizations.kubernetes.resources` (`requests`, `limits`) | the pod's resources, Kubernetes quantities as written: `cpu`/`memory` requests capped by `max_cpu`/`max_memory`; without a `cpu`/`memory` limit, the larger of the request and the CPU/Memory parameter; a limit below its request is raised to it. `ephemeral-storage` passed through; extended resources (`nvidia.com/gpu`, …) and `hugepages-*` set as limits. Invalid names or quantities are dropped with a warning ([ADR-0015](../decisions/0015-kubernetes-customizations.md), [how-to](../guides/working-in-a-workspace.md#size-the-workspace-in-kubernetes-terms)) |
| `customizations.kubernetes.storage` | like `hostRequirements.storage` (a minimum, when the workspace is created), and wins over it |
| `customizations.kubernetes.nodeSelector`, `.tolerations` | the pod's `nodeSelector` (the template's `kubernetes.io/arch` always wins) and `tolerations`, **only with the template's `allow_node_placement`**; otherwise ignored with a warning |
| `customizations.vscode.extensions`, `.settings` | installed from the Microsoft Marketplace, and applied as machine settings, for VS Code Desktop and VS Code in the browser. Settings are defaults: one the user has set to something else is left alone |
| bind mounts, `--network`, `--device`, `--gpus`, `host:port` in `forwardPorts` | ❌ no pod equivalent; reported as warnings |
| `overrideCommand: false` | ❌ the pod always runs the Coder agent; the image's own `ENTRYPOINT`/`CMD` doesn't run (use `postStartCommand`) |
| `dockerComposeFile`, `shutdownAction`, `updateRemoteUserUID` | ❌ not supported |

## Warnings

Everything a workspace can't honor shows up:

- in the workspace's **build log**, as a Terraform warning ("Check block
  assertion failed") listing each item;
- as a count in the dashboard's **Dev Container warnings** item.

Variables without a value are listed the same way, under **Dev Container
variables**.

## Where the configuration is found

`.devcontainer/devcontainer.json`, then `.devcontainer.json`, at the root of
the repository, as the Dev Containers CLI looks for them. Configurations in
sub-folders (`.devcontainer/<name>/devcontainer.json`) aren't picked up; such
a repository gets the fallback image.
