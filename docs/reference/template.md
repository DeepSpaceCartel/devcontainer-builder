<title>Coder template</title>

# Coder template

[`templates/coder-kubernetes/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/templates/coder-kubernetes)
is a Coder template, adapted from Coder's
[`kubernetes`](https://registry.coder.com/templates/coder/kubernetes)
template. It turns a git repository and branch into a workspace pod built
from the repository's `devcontainer.json`. How to run it is covered in
[Operating the template](../guides/coder-workspace-template.md); what each
`devcontainer.json` property becomes is in [devcontainer.json
support](devcontainer-json.md).

## Template variables

Set by a template admin with `coder templates push --var name=value`, once
per template.

| Variable | Default | Purpose |
|---|---|---|
| `namespace` | *(required)* | Namespace the workspace Deployments and PVCs are created in. It must exist. |
| `devcontainer_builder_endpoint` | *(required)* | devcontainer-builder's in-cluster URL, e.g. `http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080`. |
| `image_pull_secret_name` | `""` | A `kubernetes.io/dockerconfigjson` Secret in `namespace`, for pulling the built images from a private registry. |
| `external_auth_id` | `""` | A Coder external auth provider (e.g. `github`). Creating a workspace then requires the user to link it, and both the image build and the workspace's clone use their token. See [Private repositories](../guides/coder-workspace-template.md#private-repositories). |
| `git_credentials_username`, `git_credentials_token` | `""` | Template-wide HTTPS git credentials for the image build. They take precedence over `external_auth_id`. |
| `max_cpu` | `8` | Most CPU cores a repository can reserve, through `hostRequirements.cpus` or `customizations.kubernetes.resources.requests.cpu`. |
| `max_memory` | `32` | Most memory (GiB) a repository can reserve, through `hostRequirements.memory` or `customizations.kubernetes.resources.requests.memory`. |
| `allow_node_placement` | `false` | Honor a repository's `customizations.kubernetes` `nodeSelector` and `tolerations`, e.g. for GPU or other tainted nodes. The template's own `kubernetes.io/arch` selector always wins. Off: they're ignored, with a warning. |
| `allow_privileged` | `false` | Honor `privileged`, `seccomp=unconfined` and capabilities beyond Pod Security *baseline*. The namespace's Pod Security level must allow them. |
| `max_forwarded_ports` | `10` | How many `forwardPorts` get a dashboard app. Coder needs a fixed number of app slots. |
| `accept_vscode_license` | `true` | Accept [Microsoft's VS Code Server license](https://aka.ms/vscode-server-license) for VS Code in the browser (`vscode-web`). `false` removes the browser IDE; VS Code Desktop is unaffected. |
| `subdomain_apps` | `true` | Serve VS Code in the browser and the forwarded-port apps on their own subdomains. Needs a [wildcard access URL](https://coder.com/docs/admin/networking/wildcard-access-url) on the Coder deployment; `false` serves them on paths of the main Coder URL instead. |
| `vscode_extension` | `deepspacecartel.devcontainer-builder` | The [VS Code extension](vscode-extension.md) installed into every workspace: a Marketplace ID, or the `http(s)://` URL of a VSIX. `""` to not install it. |
| `use_kubeconfig` | `false` | `true` when coderd runs outside the cluster and should use its `~/.kube/config`. |

## Workspace parameters

Chosen by the user when creating a workspace. "Mutable" ones can be changed
later in the workspace's settings and apply on the next start.

| Parameter | Default | Mutable | Purpose |
|---|---|---|---|
| **Git repository** (`repository`) | *(required)* | no | `https://`, `ssh://` or `git@host:path`. Without a `devcontainer.json`, the workspace gets devcontainer-builder's fallback image. |
| **Branch** (`branch`) | `main` | no | The branch to build and clone. |
| **CPU** (`cpu`) | `2` | yes | Cores: 2, 4, 6 or 8. The limit; `hostRequirements.cpus` or a CPU request can raise it, and `customizations.kubernetes.resources.limits.cpu` replaces it. |
| **Memory** (`memory`) | `2` | yes | GiB: 2, 4, 6 or 8. The limit; `hostRequirements.memory` or a memory request can raise it, and `customizations.kubernetes.resources.limits.memory` replaces it. |
| **Disk size** (`disk_size`) | `10` | no | GiB for the persistent volume (home + `/workspaces`), set when the workspace is created. `hostRequirements.storage` or `customizations.kubernetes.storage` can raise it, also only at creation. |
| **Dev Container variables** (`devcontainer_variables`) | `""` | yes | `NAME=value` lines for `${localEnv:NAME}`. |
| **Rebuild** (`rebuild`) | `0` | yes | Increase to rebuild the image from the branch's latest commit. The [extension](vscode-extension.md)'s Rebuild does this for you. |

## In the workspace

**Apps:** VS Code Desktop, VS Code in the browser (with
`accept_vscode_license`), and one app per forwarded port.

**Dashboard items (agent metadata):**

| Item | Shows |
|---|---|
| Dev Container variables | Variables the repository uses without a value, if any. |
| Resources (reserved / limit) | CPU, memory, disk and any other resources the workspace got, and where they came from: `customizations.kubernetes`, `hostRequirements`, or the parameters. |
| Dev Container warnings | How many `devcontainer.json` settings the workspace can't honor (listed in the build log). |
| CPU / RAM usage, data disk, host load | Usage, as in Coder's `kubernetes` template. |

**Scripts:** *Dev Container lifecycle* (clone, then the lifecycle commands;
blocks login), *Dev Container postAttachCommand* (once the lifecycle script
has succeeded; it gives up after 30 minutes), and *Dev Container VS Code
extensions* (installs extensions, and adds the repository's settings that
aren't set yet).

**Environment** (besides the repository's `containerEnv`/`remoteEnv`):

| Variable | Value |
|---|---|
| `DEVCONTAINER_IMAGE_COMMIT` | The commit the image was built from. |
| `DEVCONTAINER_BRANCH` | The **Branch** parameter. |
| `DEVCONTAINER_REBUILD` | The **Rebuild** parameter's current value. |
| `DEVCONTAINER_WORKSPACE_FOLDER`, `DEVCONTAINER_WORKSPACE_FOLDER_BASENAME`, `DEVCONTAINER_ID` | `${containerWorkspaceFolder}`, `${containerWorkspaceFolderBasename}`, `${devcontainerId}`. |
| `GIT_AUTHOR_*`, `GIT_COMMITTER_*` | The workspace owner's name and email. |

**Resources:** without `hostRequirements` or `customizations.kubernetes`,
requests are 250m CPU / 512Mi and the limits are the CPU/Memory parameters.
With them, see [devcontainer.json support](devcontainer-json.md).

**Storage:** one PVC per workspace, `coder-<workspace-id>-data`; see
[Operating the template](../guides/coder-workspace-template.md#persistence).

**Image:** each workspace has its own tag,
`<registry>/<name>:ws-<workspace-id>-<rebuild>` (registry and name resolved
by devcontainer-builder as usual), deleted when the workspace is rebuilt or
deleted. Workspaces never share an image tag.

## Requirements

- Coder v2 with Kubernetes access to `namespace`, and `linux/amd64` nodes
  (the pod has a `kubernetes.io/arch: amd64` node selector, matching the
  agent, which a repository's `nodeSelector` can't override).
- devcontainer-builder ≥ 0.3.0 (service and chart), reachable at
  `devcontainer_builder_endpoint`. Repositories without a configuration
  need ≥ 0.5.0 (`fallbackImage`).
- Terraform ≥ 1.5 (Coder's bundled Terraform is newer) and these providers,
  resolved from the Terraform Registry when the template is pushed:

  | Provider | Version |
  |---|---|
  | `coder/coder` | ≥ 2.5.0 |
  | `hashicorp/kubernetes` | ≥ 2.16.0 |
  | `deepspacecartel/devcontainer-builder` | ≥ 0.3.0, < 2.0.0 |

- `git` in the image, to clone the repository (any version). The fallback
  image and the `mcr.microsoft.com/devcontainers/*` images have it; otherwise
  add the Feature `ghcr.io/devcontainers/features/git:1`. Without it, the
  workspace's first start fails with a message saying so.
