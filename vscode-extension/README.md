# Dev Containers for Coder

Dev Containers' everyday flow for Coder workspaces built by
[devcontainer-builder](https://github.com/DeepSpaceCartel/devcontainer-builder):

- clone a repository into a workspace;
- add a configuration when there's none;
- rebuild when the configuration changes.

## Coder: Clone Repository in Workspace… (local window)

The Coder counterpart of *Clone Repository in Container Volume…*.

1. Run **Coder: Clone Repository in Workspace…** in a local VS Code window.
2. Pick the repository in VS Code's own picker, the one **Git: Clone** uses. If you're signed
   in to GitHub in VS Code, its **GitHub** source lists and filters the repositories you can
   see, then their branches. Recent repositories and a typed URL work too; for a URL, the
   branches come from `git ls-remote`, the default first.
3. If you already have a workspace on that repository and branch, you can open it. Otherwise
   a new `<repo>-<branch>` workspace is created from devcontainer-builder's Coder template.
4. Progress shows until the workspace is ready. Then VS Code Desktop opens on the cloned
   folder, through the [Coder extension](https://marketplace.visualstudio.com/items?itemName=coder.coder-remote).

**Logging in:**
- If you've run `coder login` with the Coder CLI, that session is used.
- Otherwise the command asks once for your Coder URL and a session token from its
  `/cli-auth` page, and keeps the token in VS Code's secret storage.

Settings:
- `devcontainerBuilder.coderUrl` picks the deployment;
- `devcontainerBuilder.template` picks the template when several ask for a repository.

Install the release's `devcontainer-builder-rebuild.vsix` locally with **Extensions: Install
from VSIX…**. Inside workspaces, the template installs it for you.

## Rebuild available (in a workspace)

A workspace's image is built once, from `origin/<branch>`. A change can reach
`origin/<branch>` in `.devcontainer/`, in `.devcontainer.json`, or in the Dockerfile and build
context devcontainer.json points at. When it does, the status bar shows **Rebuild
available** and a notification offers:

- **Rebuild**: increases the workspace's *Rebuild* parameter. The workspace restarts on a
  new image, and the repo folder and home are kept.
- **Later**: no more prompts until the window reloads.
- **Ignore This Commit**: no more prompts until `origin/<branch>` moves again.

Clicking **Rebuild available** brings these choices back. **Dev Container: Rebuild
Workspace** rebuilds directly.

A rebuild only ever builds what's pushed (*Commit Your Code*). Dev Container changes that
exist only in the workspace show **Push Dev Container changes**.

One-click Rebuild needs `coder login <your Coder URL>` once in the workspace. Without it,
Rebuild opens the workspace's settings page.

## Add Dev Container config (in a workspace)

A repository without a devcontainer.json runs on the service's fallback image. The status bar
then shows **Add Dev Container config**, and a notification offers **Add Configuration**. Both
run the Dev Containers extension's **Add Dev Container Configuration Files…** (VS Code
Desktop), with its templates, options and Features. Commit and push what it adds, and
**Rebuild available** follows.

## Commands and settings

- **Coder: Clone Repository in Workspace…**
- **Dev Container: Check for Rebuild** fetches the branch and checks now (in a workspace).
- **Dev Container: Rebuild Workspace** (in a workspace)
- `devcontainerBuilder.checkIntervalMinutes` sets how often to fetch the branch (default 5;
  0 turns it off).

The *Dev Container Rebuild* output channel logs what the extension does.
