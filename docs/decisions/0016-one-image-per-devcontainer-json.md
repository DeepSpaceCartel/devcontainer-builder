<title>ADR-0016</title>

# ADR-0016: One image per devcontainer.json, listed in `POST /build`'s response

Status: accepted
Date: 2026-10-07

## Context

The [containers.dev spec](https://containers.dev/implementors/spec/#devcontainerjson)
allows a devcontainer.json in three places: `.devcontainer/devcontainer.json`,
`.devcontainer.json`, and `.devcontainer/<folder>/devcontainer.json`. A
repository can have several of the sub-folder kind side by side (`backend`,
`frontend`, ...). The Dev Containers CLI only finds the first two on its own;
a sub-folder config needs `--config <path>`. devcontainer-builder never passed
`--config`, so a repository with only sub-folder configs failed, or (since
[ADR-0013](0013-fallback-config-for-repos-without-one.md)) quietly got the
fallback image. See
[the note on sub-folder discovery](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/docs/claude/notes/devcontainer-subfolder-config-discovery.md).

The note concluded that picking *one* sub-folder config needs a human. Plan
004 sidesteps the choice: build all of them, one image each, and let the
caller (the Coder template) run one agent per image, with an optional filter.

`POST /build` is part of the stable 1.x HTTP API
([Versioning](../project/versioning.md)): existing callers read the
single-image fields `image`, `registry`, `name`, `tag` and `imageBuildLogId`,
and must keep working unchanged.

## Decision

**Discovery.** After the clone, the service lists every config:

- **`main`:** the root config. At most one counts:
  `.devcontainer/devcontainer.json`, else `.devcontainer.json` (the CLI's own
  order).
- **One item per `.devcontainer/<folder>/devcontainer.json`,** exactly one
  level deep. Its `id` is the folder name lower-cased, with every character
  outside `[a-z0-9-]` replaced by `-` and leading and trailing `-` removed, so
  it fits an image name and a Kubernetes DNS label. Symlinked folders and
  files are skipped: an untrusted clone shouldn't point the build outside
  itself.
- **Order:** `main` first, then the folders sorted by `id`.
- **400 before anything is built** when two locations give the same `id`
  (`Back_End` and `back-end`, or a folder named `main` next to a root config),
  or a folder name leaves an empty `id`. The error names the folders.

**Response, additive.** The response gains
`images: [{id, configPath, image, registry, name, tag, imageBuildLogId}]`.
The existing top-level fields stay and **describe `images[0]`**:

- A repository with a root config, and no `instances` filter that leaves it
  out, gets exactly today's response, plus `images` holding the `main` item.
  `main` is built with today's argv (no `--config`), and named as before.
- With no root config, `images[0]` is the first sub-folder item in `id`
  order, so the top-level fields describe it. We chose this over leaving
  them empty, which would break the schema for every 1.x caller, and over
  inventing a synthetic "main", which would name an image nobody built. A
  1.x caller that knows nothing about lists still gets a real, pushed,
  deterministic image. Before this change it got the fallback image or an
  error.

**Naming.** `main` keeps today's name (`image.name`, else the derived
default). Every other item gets `-<id>` appended to that same name, whether
it was derived or given explicitly. `tag` (`image.tag`, else `sha-<7>`) and
`registry` are the same for every item, so a caller's per-workspace tag
applies to all of them.

**Building.** Items are built one after another, each in its own
`image.build_push` span with its own captured log (`imageBuildLogId`) and its
own build timeout. A non-root item passes `--config <clone>/<configPath>` to
`devcontainer build`. The config label and the remote-user probe
([ADR-0012](0012-dev-container-to-kubernetes-runtime-mapping.md)) read that
item's own devcontainer.json and its own pushed image. If one item fails,
the request fails with 500 as before, and when it selected more than one
item, the error message ends with that item's id and config path and the
images already pushed (`already pushed: <ref>, ...` or `none`). Already
pushed images are not rolled back.

**Request, additive.** Two optional fields:

- `instances: string[] | null` builds only those ids, in discovery order.
  An unknown id is a **400** listing the repository's ids. Plan 004 said 422.
  We chose 400 because every other request problem found after the clone (no
  registry resolved, a pinned host key missing) is already a 400
  `BuildRequestError`, and this endpoint has never returned a 422.
- `dryRun: boolean` clones, discovers, filters and resolves names, then
  stops. It returns the same response without `imageBuildLogId` and builds
  nothing. It exists so Terraform can know the list's keys and image
  references at plan time. It counts as `status="dry_run"` in
  `devcontainer_builder_builds_total`.

**Fallback image** ([ADR-0013](0013-fallback-config-for-repos-without-one.md))
applies only when **no** config is found at any of the three locations. The
result is a single `main` item with `configPath:
.devcontainer/devcontainer.json`, a file that exists only in the scratch
clone. A repository with only sub-folder configs builds those, not the
fallback. With no configs and no `fallbackImage`, the request is now a
**400** (`no devcontainer.json found in repository ...`) before anything
runs. Before, it was a 500 from the CLI's "Dev container config ... not
found".

**Unchanged:** `GET /devcontainer` and `GET`/`DELETE /image` work on one
image at a time. A caller loops over `images`.

## Consequences

- Repositories with sub-folder configs build. ADR-0013's consequence that
  such repositories "silently get the fallback image" no longer holds.
- A 1.x caller that predates `images` (an older Terraform provider) still
  works. But for a repository with several configs, it only tracks
  `images[0]`. The other images are built and pushed, and an older provider
  won't delete them on destroy. A repository with a single root config, which
  is the case every caller handled before, is unaffected.
- The single-image fields change meaning slightly for a repository with no
  root config. They used to describe the fallback image, or the request
  failed. Now they describe its first sub-folder item, named `<name>-<id>`.
- Repositories without any config, on a service without `fallbackImage`,
  now get a 400 instead of a 500. The chart sets `fallbackImage` by default,
  so most deployments never see this.
- A build with N items takes about N times as long, and its timeout applies
  per item, not to the whole request. A failure part-way leaves the earlier
  images pushed. The error says which, so the caller can clean them up with
  `DELETE /image`.
- Every `dryRun` costs a shallow clone. Callers that plan often (Terraform)
  pay that on every plan.
- `dockerComposeFile` configs are not specially handled. They fail the same
  way they did before, now per item.
