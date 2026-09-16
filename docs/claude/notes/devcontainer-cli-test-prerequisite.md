---
title: The devcontainer CLI must be installed on the machine running the BDD suite, not just baked into the image
created: 2026-09-06
---

# The devcontainer CLI is a host-level test prerequisite

## What happened

Every real-build scenario (`end_to_end_build.feature`,
`git_source_resolution.feature`, `image_resolution.feature`, both
`devcontainer_config_*.feature` files) started failing uniformly with:

```json
{"error":"spawn devcontainer ENOENT"}
```

regardless of which repo, branch, or credentials the request used - a
different environment/session had simply never had the `devcontainer` CLI
installed.

## Root cause

`build.ts`'s `buildDevcontainer()` shells out directly to a `devcontainer`
binary on `PATH` (`spawn("devcontainer", ["build", ...])`). The
`Dockerfile` installs `@devcontainers/cli` into the *deployed service's*
container image - but the BDD suite runs the compiled `dist/server.js`
directly on the host machine (see `features/support/service_process.js`),
never inside that image. So the CLI has to be separately available on
whatever machine actually runs `npm run test:*` - a prerequisite that
lived nowhere in writing.

## Fix applied

Installed to a user-writable prefix (global `npm install -g` needs root
here) and symlinked into the directory already on `PATH`:

```sh
npm install --prefix ~/.npm-global @devcontainers/cli
ln -sf ~/.npm-global/node_modules/.bin/devcontainer ~/.local/bin/devcontainer
```

The symlink matters: editing `~/.bashrc` to extend `PATH` does **not**
take effect for the remainder of an already-running session (`.bashrc` is
sourced once at session start, not per-command) - symlinking into a
directory already on `PATH` (`~/.local/bin` here) works immediately and
also survives future sessions, since `.bashrc` already puts that directory
first on `PATH`.

## Not yet done

This fix was applied by hand, once, in one dev environment. It is not:

- Recorded as a setup step anywhere a new contributor/session would see it
  before hitting the same `ENOENT` (this note is the first place it's
  written down).
- Automated - no `postinstall` script, devcontainer feature, or CI step
  installs `@devcontainers/cli` for the test environment itself (only the
  *deployed image*'s `Dockerfile` installs it, for production use).

If this repo gets its own `.devcontainer.json` for local development (see
`docs/claude/plans/001-devcontainer.md`), installing `@devcontainers/cli`
there - or documenting it as a manual prerequisite in
`service/package.json`'s scripts section or a `service/README.md` - would
close this gap properly instead of relying on whoever hits the error first
rediscovering the fix.
