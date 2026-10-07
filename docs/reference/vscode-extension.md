<title>VS Code extension</title>

# VS Code extension

**Dev Containers for Coder in K8S**, `deepspacecartel.devcontainer-builder`.
It's on the [VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=deepspacecartel.devcontainer-builder)
and [Open VSX](https://open-vsx.org/extension/deepspacecartel/devcontainer-builder),
and each [GitHub Release](https://github.com/DeepSpaceCartel/devcontainer-builder/releases)
has it as `devcontainer-builder.vsix`. The source is
[`vscode-extension/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/vscode-extension).

It runs in one of two modes, chosen when VS Code starts it
(`extensionKind: ["workspace", "ui"]`):

| Mode | When | What it does |
|---|---|---|
| **Workspace** | In a workspace from the [Coder template](template.md), which installs it and sets `DEVCONTAINER_IMAGE_COMMIT`/`DEVCONTAINER_BRANCH` | The rebuild prompt and the **Add Dev Container config** prompt. The clone command works too. |
| **Local** | Anywhere else, e.g. a local VS Code window | The clone command only. |

## Commands

| Command | Mode | What it does |
|---|---|---|
| **Coder: Clone Repository in Workspace…** | both | Pick a repository (VS Code's *Git: Clone* picker, including GitHub) and a branch. It then opens your workspace on it, or creates `<repo>-<branch>` from the template that asks for a `repository` and `branch`, linking a git account first if the template requires one. It follows the build and opens VS Code Desktop on the cloned folder through the Coder extension (`coder.coder-remote`). |
| **Dev Container: Check for Rebuild** | workspace | Fetches the branch and checks now. |
| **Dev Container: Rebuild Workspace** | workspace | Rebuilds the workspace now, increasing its **Rebuild** parameter through the Coder API. |

The status bar items and their states are in [Working in a
workspace](../guides/working-in-a-workspace.md#rebuild-when-the-configuration-changes).

## Settings

| Setting | Default | Purpose |
|---|---|---|
| `devcontainerBuilder.checkIntervalMinutes` | `5` | How often to fetch the branch and check. `0`: only on start and on demand. |
| `devcontainerBuilder.coderUrl` | `""` | The Coder deployment for the clone command. Empty: the one the Coder CLI is logged in to, else asked once. |
| `devcontainerBuilder.template` | `""` | The template the clone command creates workspaces from. Empty: the only one that asks for a repository and a branch, else asked. |

## Logging in to Coder

The clone command and Rebuild call the Coder API as you:

- **Clone command:** the Coder CLI's session (`coder login`) if there is one.
  Otherwise it asks once for the URL and a token from `<coder>/cli-auth`, kept
  in VS Code's secret storage.
- **Rebuild, in a workspace:** the session from `coder login` run in the
  workspace, stored in its persisted home. Without one, Rebuild opens the
  workspace's settings instead.

Rebuild uses `POST /api/v2/workspaces/{id}/builds` with the new `rebuild`
value, because `coder restart/start --parameter` keep an existing
workspace's value (Coder v2.37).

## Adding a configuration

**Add Dev Container config** runs the Dev Containers extension's own **Add
Dev Container Configuration Files…** (`remote-containers.createDevContainerFile`),
so it needs VS Code Desktop with `ms-vscode-remote.remote-containers`. In the
browser, it offers to install it.

The extension's output channel, *Dev Container Rebuild*, logs every check
and request.
