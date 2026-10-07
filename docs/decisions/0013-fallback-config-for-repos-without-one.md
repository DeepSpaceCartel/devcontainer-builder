<title>ADR-0013</title>

# ADR-0013: A fallback image for repositories without a devcontainer.json

Status: accepted
Date: 2026-10-07

## Context

Dev Containers' **Clone Repository in Container Volume…** works on any
repository. One without a `devcontainer.json` still gets a container, and
VS Code offers to add a configuration from a Dev Container Template.
devcontainer-builder failed such a build instead, because `devcontainer build` needs
a config. So "clone this repo into a Coder workspace" was only possible
for repositories that already had one.

A Coder workspace can't decide this itself. The template only learns
anything about the repository from the build. It has no way to see,
before the build, that there's no config, and so no way to pick another
image.

## Decision

The service gets an optional `fallbackImage` setting
(`--fallback-image`, `FALLBACK_IMAGE`, `build.fallbackImage`). When a
cloned repository has neither `.devcontainer/devcontainer.json` nor
`.devcontainer.json`, it writes `{"image": "<fallbackImage>"}` to
`.devcontainer/devcontainer.json` **in its scratch clone** and builds that.
Nothing else changes: the image gets the same labels, user probe and tag
(`sha-<commit>`) as any other build.

- **Off by default in the service** (today's error), **on in the chart**
  (`mcr.microsoft.com/devcontainers/base:ubuntu`: git, curl and a non-root
  `vscode` user, uid 1000).
- **Only an image, not a whole config.** Anything richer belongs in the
  repository, which is where the workspace leads you. The rebuild prompt
  extension sees there's no config at the image's commit or on origin,
  and offers **Add Configuration**, which runs Dev Containers' own **Add Dev
  Container Configuration Files…**. You then commit and push it, and the existing **Rebuild
  available** prompt moves the workspace onto the real image.
- **The repository is never written to** by the service. The fallback
  config exists only in the scratch clone, which is why the workspace can
  tell "no config" from git alone, with no new label or API field.

## Consequences

- Any repository can be opened in a workspace. A typo'd repository still
  fails at the clone, not later.
- A repository whose config is in a sub-folder (not auto-discovered, see
  `devcontainer_config_discovery.feature`) now silently gets the fallback
  image instead of an error. The workspace's "Add Configuration" prompt
  makes that visible.
- Operators who want the old behavior set `build.fallbackImage: ""`.
