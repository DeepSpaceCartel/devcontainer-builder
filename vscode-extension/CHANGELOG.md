# Changelog

All notable changes to **Dev Containers for Coder in K8S** are documented in this file. The
extension is released together with
[devcontainer-builder](https://github.com/DeepSpaceCartel/devcontainer-builder) and shares its
version numbers; the project's own
[CHANGELOG](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/CHANGELOG.md) covers
the service, chart and template.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Also published to **Open VSX**, for VSCodium, Cursor and other editors.
- **Coder: Clone Repository in Workspace…** opens the template's git account link page and waits
  for it, instead of failing on create.
- Restricted Mode support: in an untrusted folder the clone command works, and checking for Dev
  Container changes waits until you trust the folder (a shield in the status bar). Virtual
  workspaces aren't supported.

### Changed

- **Breaking:** **Extension: requires VS Code 1.140 or newer** (was 1.90), to build against current
  VS Code APIs. Editors on an older VS Code base can keep using 0.5.0.
- `devcontainerBuilder.coderUrl` and `devcontainerBuilder.template` are user settings only
  (application scope); a folder's `.vscode/settings.json` no longer sets them.
- `devcontainerBuilder.checkIntervalMinutes` is at most 1440 (a day).
- The rebuild prompt also warns about Dev Container changes that aren't pushed yet.
- An image commit that's no longer on origin (force-pushed away) shows **Rebuild available** with
  the reason, instead of an unknown status.

### Fixed

- **Check for Rebuild** could report the result of a check that was already running instead of
  the one it asked for.
- Opening an existing workspace whose last build failed, or that is stopping, now starts it (after
  the stop finishes) instead of failing.
- Following a workspace's start no longer gives up on one network error (retried with backoff),
  no longer waits forever on an agent that never connects (a failure after 3 minutes timed out or
  disconnected), and offers **Keep Waiting** or **Open in Dashboard** after 20 minutes.
- Rebuild found the `coder login` session only in `~/.config/coderv2`; it now follows
  `XDG_CONFIG_HOME`, macOS and Windows locations like the Coder CLI.
- A stored token that no longer works is deleted, and an unreachable stored deployment falls back to
  the Coder CLI's session or a new login instead of failing.
- Trailing commas in `devcontainer.json` are removed without touching strings like `"a,]"`.
- Paths from `devcontainer.json` are passed to git as literal paths, not globs or pathspec magic.
- A git command that times out is killed together with the processes it started, and background
  fetches stop waiting on `GIT_ASKPASS` after it hangs once.

### Security

- A stored Coder session token is kept per deployment URL and only ever sent to that deployment. It
  was one token for whatever `coderUrl` said, which a repository's workspace settings could point
  elsewhere. The existing token is moved to the URL it was stored with.
- Repository URLs with credentials in them (`https://user:token@…`) are refused instead of being
  logged and saved as a workspace parameter.
- Every Coder API call times out after 30 seconds.

## [0.5.0] - 2026-10-07

### Added

- On the VS Code Marketplace as `deepspacecartel.devcontainer-builder`, "Dev Containers for Coder
  in K8S". It was previously `deepspacecartel.devcontainer-builder-rebuild`, a VSIX only.
- **Coder: Clone Repository in Workspace…**, in a local window too (`extensionKind: ["workspace",
  "ui"]`): pick a repository and branch in VS Code's own picker, open your workspace on it or
  create `<repo>-<branch>` from the template, follow the build, then open VS Code Desktop on the
  cloned folder through the Coder extension. Login uses the Coder CLI's session, or a token from
  `/cli-auth` stored in VS Code's secret storage.
- **Add Dev Container config** for a repository without a devcontainer.json, which runs Dev
  Containers' own *Add Dev Container Configuration Files…*.

## [0.4.0] - 2026-10-07

### Added

- The rebuild prompt, as `deepspacecartel.devcontainer-builder-rebuild` (a VSIX on each GitHub
  Release). When `.devcontainer/`, `.devcontainer.json` or the Dockerfile and build context
  devcontainer.json points at change on `origin/<branch>` after the workspace's image was built, the
  status bar shows **Rebuild available** and a notification offers Rebuild / Later / Ignore This
  Commit. Rebuild increases the workspace's **Rebuild** parameter through the Coder API. Changes
  that aren't pushed get a "commit and push first" nudge instead.

[Unreleased]: https://github.com/DeepSpaceCartel/devcontainer-builder/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/DeepSpaceCartel/devcontainer-builder/releases/tag/v0.5.0
[0.4.0]: https://github.com/DeepSpaceCartel/devcontainer-builder/releases/tag/v0.4.0
