---
title: The sub-folder devcontainer.json location isn't auto-discoverable - a Coder Workspace Template gap
created: 2026-09-06
---

# The sub-folder devcontainer.json location isn't auto-discoverable

## What happened

While building `devcontainer_config_discovery.feature`, `test-git-server`
was given one seed repo per location the containers.dev spec recognizes
(https://containers.dev/implementors/spec/#devcontainerjson):

1. `.devcontainer/devcontainer.json`
2. `.devcontainer.json`
3. `.devcontainer/<folder>/devcontainer.json` (one sub-folder deep,
   `<folder>`'s name left unspecified by the spec)

Real builds against locations 1 and 2 succeed. Location 3 fails every time,
regardless of which folder name is used (tried `alpha`, `beta`, `gamma`):

```
Error: Dev container config (/tmp/devcontainer-build-.../repo/.devcontainer/devcontainer.json) not found.
    at .../devContainersSpecCLI.js:671:1942
```

## Root cause

`@devcontainers/cli` (confirmed on 0.89.0) only auto-discovers locations 1
and 2. It never looks inside `.devcontainer/*/` on its own. Finding a
sub-folder config requires the caller to pass an explicit `--config
<path-to-devcontainer.json>` - there is no flag that means "search
sub-folders and pick one."

This isn't a CLI oversight - it's the only correct behavior available to
it. The spec itself doesn't name `<folder>`, and explicitly acknowledges
this ambiguity: "It is valid that these files may exist in more than one
location, so consider providing a mechanism for users to select one when
appropriate." A repo can have several sub-folder configs
(`.devcontainer/backend/devcontainer.json`,
`.devcontainer/frontend/devcontainer.json`, ...) side by side - nothing
about the file layout says which one a given build should use. Only a
human (or something that already knows the intended target) can resolve
that ambiguity; guessing would silently build the wrong environment.

## Current state (a documented gap, not a fix)

`build.ts`'s `buildDevcontainer()` calls `devcontainer build
--workspace-folder <dir> --push`, with no `--config` flag and no request
field to supply one. So devcontainer-builder inherits the CLI's limit
exactly: it builds locations 1 and 2 correctly, and fails clearly (not
silently) on location 3, the same way for every folder name.

`devcontainer_config_discovery.feature` asserts this current behavior
directly rather than papering over it - locations 1/2 assert a real `200`;
the three location-3 repos (`devcontainer-json-subfolder-{alpha,beta,gamma}`
in `charts/test-git-server/values.yaml`) assert the exact `500` +
"Dev container config ... not found." signature, proving the failure is
the *location* not being checked at all, not a folder-naming mismatch.
This was a deliberate choice over extending the request contract now (a
`configPath` field threaded through to `--config`) - see the alternatives
below.

## What a real fix requires: a separate discovery step

Extending `devcontainer-builder`'s own `/build` request with a
caller-supplied `configPath` would make single-repository CI/API use cases
work, but it doesn't solve the actual problem for a **Coder Workspace
Template**: a developer picking a repo to open doesn't know its sub-folder
layout up front, and the git-clone-then-build request devcontainer-builder
accepts today has nowhere for a human to make that choice interactively
mid-flow.

Covering this properly in the Coder Workspace Template needs a **separate
discovery service** (or step), sitting *before* devcontainer-builder in the
flow:

1. Given a repository (and ref), clone or otherwise inspect it.
2. Enumerate every `devcontainer.json` it actually contains across all
   three spec locations - in particular, every `.devcontainer/*/
   devcontainer.json` sub-folder, whatever it's named.
3. If exactly one config exists, proceed automatically (this is the common
   case, and already handled fine by locations 1/2 alone, or would be
   trivial to also handle for a single lone sub-folder).
4. If more than one exists, return the list (folder name + whatever
   metadata is cheap to extract, e.g. each config's `name`/`image` field)
   so the Workspace Template can present them as a choice to the
   developer, and pass the one they pick to devcontainer-builder as an
   explicit `configPath`.

This is genuinely out of scope for devcontainer-builder itself (which
builds *one already-decided* target) - it's a new, small piece of
infrastructure the Workspace Template would call ahead of
devcontainer-builder, or a preliminary step folded into the Template's own
Terraform/data-source logic. Not started; noted here so the constraint
survives past this session, and doesn't get silently reintroduced as "just
add configPath to /build" without addressing where the human choice
actually happens.
