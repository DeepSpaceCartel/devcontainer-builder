<title>Working in a workspace</title>

# Working in a workspace

How-tos for developers using workspaces built from a repository's
`devcontainer.json`. To get started, see [Your first
workspace](../getting-started/first-workspace.md).

## Rebuild when the configuration changes

A workspace's image is built once, from the branch on the remote
(`origin/<branch>`). The **Dev Containers for Coder in K8S** extension
compares the commit the image was built from with `origin/<branch>`, over
the files that go into the image:

- `.devcontainer/` and `.devcontainer.json`;
- the Dockerfile and build context `devcontainer.json` points at. If the
  context is the repository root, every change counts.

It fetches every 5 minutes (`devcontainerBuilder.checkIntervalMinutes`),
and also checks when you fetch, commit or edit those files. The status bar
shows the result:

| Status bar | Meaning | Click |
|---|---|---|
| `a1b2c3d` | The image is up to date with the branch's configuration. | Check now |
| **Rebuild available** | The configuration changed on `origin/<branch>` since the image was built. The tooltip lists the files. | Rebuild / Later / Ignore This Commit |
| **Push Dev Container changes** | You changed the configuration here, but it isn't on `origin/<branch>` yet, so a rebuild wouldn't include it. | Source Control view |
| **Add Dev Container config** | The repository has no `devcontainer.json`; the workspace runs on a generic image. | Add configuration (below) |
| `?` | It couldn't check, e.g. the fetch failed. The tooltip says why. | Check again |

![Rebuild available](../assets/screenshots/vscode-rebuild-available.png)

When it becomes **Rebuild available**, a notification offers:

- **Rebuild** restarts the workspace on a new image built from
  `origin/<branch>`. Your home and the repository folder, including
  uncommitted work, are kept. The rest of the filesystem comes from the new
  image.
- **Later** shows no more notifications until the window reloads.
- **Ignore This Commit** shows no more notifications until `origin/<branch>`
  moves again.

Clicking **Rebuild available** brings the choices back, and **Dev Container:
Rebuild Workspace** in the Command Palette rebuilds at any time.

**One-click Rebuild needs a Coder session in the workspace.** Run `coder
login <your Coder URL>` once in its terminal; the session is kept in your
home. Without it, Rebuild opens the workspace's settings, where you increase
the **Rebuild** parameter by hand. That works from the dashboard too, with
or without the extension.

## Add a configuration to a repository without one

A repository without `.devcontainer/devcontainer.json` or
`.devcontainer.json` gets a workspace on a generic image
(`mcr.microsoft.com/devcontainers/base:ubuntu` by default), and the status
bar shows **Add Dev Container config**:

1. Click it, or **Add Configuration** in its notification. It runs the Dev
   Containers extension's **Add Dev Container Configuration Files…**:
   pick a template, its options and Features. This needs VS Code Desktop with
   the Dev Containers extension (`ms-vscode-remote.remote-containers`).
2. Review the files it adds, then commit and push.
3. **Rebuild available** appears. Rebuild.

## Dev Container variables

`${localEnv:NAME}` in `devcontainer.json` refers to the developer's machine,
which a workspace doesn't have. Values come from the workspace's **Dev
Container variables** setting instead (**Workspace settings → Parameters**),
one `NAME=value` per line, applied on the next restart. If the repository
uses a variable that has no value and no default, the build log and the
dashboard's **Dev Container variables** item name it.

Values are visible to anyone who can see the workspace's settings, so don't put
secrets there that others shouldn't read.

## Forwarded ports

Each of `forwardPorts` becomes an app on the workspace page, labeled from
`portsAttributes` (http or https), through Coder's proxy. VS Code's own port
forwarding works as usual too.

## What persists

| Kept across restarts and rebuilds | Fresh from the image on every start |
|---|---|
| Your home (`/home/<user>`) | Everything else: `/usr`, `/opt`, … |
| `/workspaces` (the repository) | Anything installed outside home and `/workspaces` |
| Volume mounts from `devcontainer.json` | `tmpfs` mounts |

On the first start, your home is seeded from the image's home (dotfiles,
nvm, oh-my-zsh, …). After that it's yours: rebuilds don't re-seed it.

## Lifecycle commands run on every start

`onCreateCommand`, `updateContentCommand`, `postCreateCommand` and
`postStartCommand` run in that order on **every** start, before you can
log in; `postAttachCommand` runs once per start without blocking. In Dev
Containers, the first three run once per container, but here the root
filesystem is fresh on every start. So they must be idempotent, and tools
they install outside your home are best moved into the image or a Feature.
Their output is in the workspace's startup logs.

## VS Code

`customizations.vscode.extensions` are installed from the Microsoft
Marketplace, and `customizations.vscode.settings` are applied as machine
settings, for both VS Code Desktop and VS Code in the browser. A Desktop
window that connects before that's done picks up the rest after
**Developer: Reload Window**.

## When something goes wrong

- **The build failed.** The workspace's build log (dashboard → the workspace →
  the failed build) has devcontainer-builder's error. **Coder: Clone
  Repository in Workspace…** offers **Show Build Log** too.
- **A setting from `devcontainer.json` seems ignored.** Anything the
  workspace can't honor (bind mounts, `--network`, …) is listed as a warning
  in the build log and counted in the dashboard's **Dev Container warnings**
  item. See [devcontainer.json support](../reference/devcontainer-json.md).
- **No status bar item from the extension.** VS Code doesn't run it in
  Restricted Mode: trust the folder (**Workspaces: Manage Workspace Trust**).
- **The workspace stays Pending.** The repository's `hostRequirements` reserve
  CPU and memory, and no node has that much free. The dashboard's
  **Resources** item shows what was requested; ask your platform admin.
