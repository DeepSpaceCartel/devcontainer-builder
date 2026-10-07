---
title: List support - one build, list of images, one Coder agent per image
created: 2026-10-06
---

# List support: `/build` returns a list of images → one Coder agent per image

## Status (2026-10-07): Phase B step 1 (service) implemented; provider, module and template still open

The service side is on `feat/multi-config-builds`, recorded in
[ADR-0016](../../decisions/0016-one-image-per-devcontainer-json.md) (0013 was
already taken). It differs from this plan in these ways:

- **Additive, not breaking.** The 1.x API is stable
  ([Versioning](../../project/versioning.md)), so the response keeps
  `image`/`registry`/`name`/`tag`/`imageBuildLogId` and adds `images[]`. The
  top-level fields describe `images[0]`: `main` when there is a root config,
  else the first sub-folder item.
- **400, not 422,** for an unknown `instances` id, an id collision, or an
  empty id. The "no configs" case is also a 400, and only when there's no
  `fallbackImage`. With one, the fallback is a single `main` item, used only
  when no config exists at any of the three locations.
- **ids** also drop leading and trailing `-`, so they stay valid in image
  names and as DNS labels. Symlinked sub-folders are skipped.
- **`instances: []`** fails the shape check. Use `null` or omit it for "all".
- **Dry runs** count as `status="dry_run"` in `devcontainer_builder_builds_total`.
- **New code:** discovery is in `service/src/config-discovery.ts`, and
  `buildInstance()`/`devcontainerBuildArgs()` are in `build.ts`. BDD coverage
  is in `devcontainer_config_discovery.feature`, with new seed repos
  `devcontainer-json-{two-folders,root-and-folder,colliding-folders}`. Not run
  yet, because it needs the cluster.

Next: the provider's `images`/`instances`/dry run in `ModifyPlan` (step 2),
then the module (step 3), the template (step 4), and the guide and README
(step 5). Phase A (the template's list-of-one refactor) is still open.

## Context

The containers.dev spec allows `.devcontainer/<folder>/devcontainer.json`, and a
repo can contain several of these. Today devcontainer-builder never passes
`--config`, so these repos fail with a 500. That gap is pinned in
`service/features/devcontainer_config_discovery.feature` and in
`docs/claude/notes/devcontainer-subfolder-config-discovery.md`.

The Coder template has exactly one agent (`coder_agent.main`) and one
Deployment.

**The core idea:** this adds list support with no new endpoints. `POST /build`
finds every config in the repo, builds each one, and returns `images[]`. The
provider, module and template all move from one image to a map of images, and
the workspace runs one Coder agent per image. Today's behavior is a list of one,
`[main]`.

The only addition to the API is a `dryRun` flag on `/build`. It returns the same
list without building anything, so Terraform knows the list's keys at plan time.

## The list item

| field | root config | `.devcontainer/backend/devcontainer.json` |
|---|---|---|
| `id` (agent name / map key) | `main` | `backend` (folder lowercased, non-`[a-z0-9-]` → `-`) |
| `configPath` (repo-relative) | `.devcontainer/devcontainer.json` or `.devcontainer.json` | `.devcontainer/backend/devcontainer.json` |
| `image`, `registry`, `name`, `tag` | `<reg>/<repo>:sha-<7>` | `<reg>/<repo>-backend:sha-<7>` |
| `imageBuildLogId` | set once built, absent in a dryRun | same |

How the list is built:

- **Root config:** at most one counts, and `.devcontainer/devcontainer.json`
  wins, which is the CLI's own order.
- **Ordering:** `main` comes first, then the folders sorted alphabetically.
- **id collisions:** if two items would get the same `id`, or a folder's id
  collides with `main`, the request fails with a 422 that names the folders.
- **No configs found:** 422, instead of today's 500.
- **Naming:** image naming is the same as today for `main`. A folder item gets
  `-<id>` appended to the default name. If the caller sets an explicit
  `image.name`, it gets the same `-<id>` suffix for non-`main` items.

## Service (`service/`)

- **`src/config-discovery.ts` (new):** `discoverConfigs(repoDir)` returns the
  items' `id` and `configPath`. It replaces `readFirstExisting` (`build.ts:409`).
- **Refactor `build.ts`:**
  - The current per-image steps (`devcontainer build`, the remote-user probe and
    the config label, `build.ts:409-474`) become
    `buildInstance(repoDir, item, …)`. That function adds
    `--config <repoDir>/<configPath>` to the argv (`build.ts:457`) and reads the
    label from the item's own file.
  - `buildDevcontainer()` clones once, discovers the list, filters it, resolves
    a name for each item (`build.ts:333-393`), and then runs `buildInstance` for
    each item, one after another.
- **New request body fields** (`schemas.ts:93-138`):
  - `instances?: string[]` filters the list. An unknown id returns a 422 that
    lists the valid ids.
  - `dryRun?: boolean` stops after the clone, discovery and naming. It returns
    the same response with no build and no push.
- **Response:** `{ commit, gitCloneLogId, images: [item…] }` (`schemas.ts:141-154`,
  `types.ts`). This replaces the singular `image`/`registry`/`name`/`tag`/
  `imageBuildLogId` fields, which is a breaking change and fine under the
  no-pre-0.3.0-compat policy. The OpenAPI document is generated, so it follows
  automatically.
- **If one item fails:** the request fails, and the error says which images
  were already pushed.
- **What stays the same:** `GET`/`DELETE /image` and `GET /devcontainer` still
  work on one image at a time. Callers loop over the list.

## Provider (separate repo, `/workspaces/terraform-provider-devcontainer-builder`)

- **`devcontainerbuilder_build` input:** `instances` (optional set of strings,
  `RequiresReplace`).
- **`devcontainerbuilder_build` outputs:**
  - `images` (computed map of objects keyed by `id`: `config_path`, `image`,
    `registry`, `name`, `tag`) replaces the singular `image`/`resolved_*`
    attributes.
  - `commit` stays.
- **`ModifyPlan`** calls `POST /build` with `dryRun: true`:
  - When a resource is created or replaced, it plans `images` with fully known
    values. Image names are deterministic, so `for_each` works on the first
    create, and the plan shows the image refs.
  - When the resource already exists, a different key set (a config added or
    removed upstream) means `RequiresReplace`.
  - A 422 from the dry run (an unknown filter id, an id collision, no configs)
    shows up as a plan error.
- **Create** sends the planned ids as `instances`, so a push between plan and
  apply can't add an unplanned item.
- **Read** runs `GET /image` for each entry and drops the resource if any entry
  is missing. **Delete** runs `DELETE /image` for each entry.
- **Client types:** `client.BuildRequest` and `BuildResponse`
  (`internal/client/types.go:31`) gain `Instances`, `DryRun` and `Images`.
- Released as a minor version.

## Module (`terraform/devcontainer-build/`)

- New variable `instances` (default `null`, validated as non-empty strings).
- Outputs:
  - `images`, which is the map;
  - `image`, kept as `one(values(...images)).image` for list-of-one consumers.
    It errors clearly if there is more than one.
- Mock-provider tests cover a two-item map, both outputs, and a validation
  failure.

## Template (`templates/coder-kubernetes/main.tf`): everything is keyed by instance

- **The list:**
  - A new `devcontainers` parameter (`list(string)`, form_type `tag-select`,
    default `[]` meaning all, mutable) is passed as `instances`. An empty list
    is passed as `null`.
  - `local.instances = devcontainerbuilder_build.workspace.images`.
- **Per item, using `for_each = local.instances`:**
  - `data.devcontainerbuilder_devcontainer.workspace`, using the item's
    `registry`, `name` and `tag`;
  - `coder_agent.dev`, renamed from `main`, so the agent name is the key;
  - every `coder_script`, `coder_app` and `coder_env` that references the agent
    (lines 486–729);
  - `kubernetes_persistent_volume_claim_v1.data` and
    `kubernetes_deployment_v1.main`, with `image = each.value.image`.
- **Runtime-mapping locals (240–344):** today these are scalars over `local.dc`.
  They become `local.rt = { for k, dc in … : k => { remote_user, uid, gid,
  home_dir, workspace_folder, mounts, host_reqs, caps, warnings } }`. Resources
  read `local.rt[each.key]`, and the logic itself stays the same.
- **Kubernetes names:**
  - `main` keeps `coder-<ws>` and `coder-<ws>-data`, so upgrades don't recreate
    the PVC.
  - Any other item gets `coder-<ws>-<id>` and `coder-<ws>-<id>-data`.
  - Selectors gain `com.deepspacecartel.devcontainer-builder/instance=<id>`.
- **Upgrading existing workspaces:** `moved {}` blocks map each old singleton
  address to `["main"]`.
- **cpu/memory/disk parameters:** these apply to each item, and
  `hostRequirements` still overrides them per config. The parameter descriptions
  and the repository text at `main.tf:119` are updated to say so.

## Order of work

**Phase A: a list of one, with no behavior change (template only, one PR)**

- Hardcode `local.instances = { main = { image = …workspace.image, registry = …resolved_registry, name = …, tag = … } }`.
- Do the whole per-instance refactor, including the `moved` blocks.
- **Acceptance:** for an existing workspace, the plan shows only `moved`
  entries.

**Phase B: real lists**

1. Service: `discoverConfigs`, `buildInstance`, `images[]`, `instances`,
   `dryRun`, and the feature file.
2. Provider: `images`, `instances`, the dry run in `ModifyPlan`, and per-entry
   Read and Delete, then a release.
3. Module: `instances` and `images`.
4. Template: point `local.instances` at `…images` and add the `devcontainers`
   parameter. This is a small diff.
5. ADR-0013 "List of images per build; one agent per image". It supersedes the
   note, and the note links to it. Update
   `docs/guides/coder-workspace-template.md` and `README.md:58`.

## Known caveats (to document)

- The dry run happens on every plan. If an item disappears upstream, or is
  deselected, the build is replaced and that item's PVC is destroyed on the
  next start.
- Any change to the list rebuilds every image, because they share one resource.
- Every plan now costs a shallow clone.
- Each item is its own pod. On the 2-node dev cluster, the CPU and memory
  requests add up quickly.
- Configs that use `dockerComposeFile` are out of scope.

## Verification

- **Phase A:** `terraform validate`, then push the template to Coder. Upgrading
  an existing workspace must show only `moved` entries and keep the PVC. Start
  and restart must still work.
- **Service:** `cd service && npm run build`, then the BDD feature:
  - root repos return `images` with a single `main`;
  - sub-folder repos return 200 with one image per folder;
  - an unknown filter id returns 422 with the valid ids;
  - a `dryRun` result matches the real build's list and pushes nothing (check
    with `GET /image` → 404).

  Add seed repos with two folders, and with a root config plus a folder, to
  `charts/test-git-server/values.yaml`. If npm isn't available, I'll say so.
- **Provider:** `go test ./...`, plus an acceptance test that plans `for_each`
  over `images` on the first create.
- **Module:** `terraform fmt -check`, `validate` and `test`.
- **Template end to end:**
  - `.devcontainer/{backend,frontend}` brings up agents `backend` and
    `frontend`;
  - the filter `[backend]` brings up only that one;
  - the filter `[nope]` fails at plan with the valid ids;
  - a root plus a folder brings up `main` plus the folder.
