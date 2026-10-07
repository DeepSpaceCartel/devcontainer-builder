# Dev Container Rebuild for Coder

Tells you when a Coder workspace built by
[devcontainer-builder](https://github.com/DeepSpaceCartel/devcontainer-builder)
is behind its branch's Dev Container configuration, and rebuilds it in one click.

A workspace's image is built once, from `origin/<branch>`. When a change to
`.devcontainer/`, `.devcontainer.json`, or the Dockerfile and build context
devcontainer.json points at reaches `origin/<branch>`, the status bar shows
**Rebuild available** and a notification offers:

- **Rebuild**: increases the workspace's *Rebuild* parameter. The workspace
  restarts on a new image built from `origin/<branch>`, and the repo folder and
  home are kept.
- **Later**: no more prompts until the window reloads.
- **Ignore This Commit**: no more prompts until `origin/<branch>` moves again.

A rebuild only ever builds what's pushed (*Commit Your Code*). Dev Container
changes that are only in this workspace (uncommitted or unpushed) show up as
**Push Dev Container changes**.

## Requirements

- A workspace from devcontainer-builder's Coder template, which installs this
  extension and sets `DEVCONTAINER_IMAGE_COMMIT`, `DEVCONTAINER_BRANCH` and
  `DEVCONTAINER_REBUILD`. Anywhere else the extension stays inactive.
- For one-click rebuilds, run `coder login <your Coder URL>` once in the
  workspace; the session is kept in your home. Without it, **Rebuild** opens the
  workspace's settings page, where you increase *Rebuild* yourself.

## Commands and settings

- **Dev Container: Check for Rebuild** fetches the branch and checks now.
- **Dev Container: Rebuild Workspace** rebuilds, even with no changes.
- Clicking **Rebuild available** in the status bar brings the Rebuild /
  Later / Ignore choices back, even after Later or Ignore, and after the
  notification has gone. A rebuild is always an explicit button press.
- `devcontainerBuilder.checkIntervalMinutes` sets how often to fetch the
  branch (default 5; 0 turns it off). Fetches and local edits are noticed as they happen.

The output channel *Dev Container Rebuild* logs each check.
