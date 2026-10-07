<title>Versioning and upgrades</title>

# Versioning and upgrades

devcontainer-builder follows [Semantic Versioning](https://semver.org/).
One `vX.Y.Z` tag releases all of these together, with the same version:

- the service image;
- the npm package;
- the Helm chart;
- the Coder template in this repository;
- the VS Code extension.

The [Terraform provider](../reference/TERRAFORM-PROVIDER.md) has its own
repository and releases, and the template states the provider version it
needs.

## What 1.x keeps stable

Within 1.x, these change only in backward-compatible ways: new optional
fields, variables, settings and commands may appear, but nothing that works
stops working.

| Surface | What's covered |
|---|---|
| **HTTP API** | Paths, request and response fields, and status codes as documented in the [OpenAPI reference](../api-reference.html){:target="_blank" rel="noopener"}. |
| **Service configuration** | CLI flags, environment variables and settings-file fields ([Configuration](../reference/CONFIGURATION.md)). |
| **Helm chart** | Values ([Helm chart](../reference/HELM.md)). |
| **Coder template** | Template variables, workspace parameter names, and the `DEVCONTAINER_*` environment variables ([Coder template](../reference/template.md)). |
| **devcontainer.json mapping** | What each property becomes in a workspace ([support matrix](../reference/devcontainer-json.md)). Newly supported properties can be added; supported ones don't silently change meaning. |
| **VS Code extension** | The ID `deepspacecartel.devcontainer-builder`, its commands and settings ([VS Code extension](../reference/vscode-extension.md)). |

**Not covered,** so these may change in a minor release:

- log lines and event names;
- metrics;
- image labels written by the service;
- dashboard (agent metadata) items;
- the BDD suite;
- anything not documented.

**Deprecations:** something deprecated keeps working through the rest of
1.x, is marked in the docs and the CHANGELOG, warns where it can, and is
removed in the next major version. Currently deprecated:

- the [Terraform module](../reference/TERRAFORM.md). Use the provider's
  `devcontainerbuilder_build` instead.
- the template's uid/gid 1000 fallback for images built before 0.3.0, which
  don't record their user's uid/gid. It's kept through 1.x so that upgrading
  a workspace never dead-ends (it must start once on the new template version
  before it can be rebuilt), and removed in 2.0: rebuild such workspaces
  before then.

## Upgrading to 1.0 from 0.x

Upgrade the service (chart) first, then the template. The service and
provider stay compatible with older templates. In order of the versions
that introduced each change:

1. **Chart pin 1.0.0.** Repositories without a `devcontainer.json` now build
   on `build.fallbackImage` (since 0.5.0) instead of failing. Set it to `""`
   to keep the old behavior.
2. **Template variables:**
   - `rebuild_extension_url` (0.4.0) is now `vscode_extension` (since 0.5.0), a Marketplace ID by
     default. Drop any value you set for the old name.
   - New and optional: `external_auth_id` for private repositories, `max_cpu`/`max_memory`.
3. **`hostRequirements` are minimums (1.0).** They're now reserved as pod
   requests instead of replacing the CPU/Memory/Disk parameters. Repositories
   that set them now hold those resources on the node; size `max_cpu`/`max_memory`
   to your nodes.
4. **The VS Code extension's ID changed in 0.5.0** from
   `deepspacecartel.devcontainer-builder-rebuild` (a VSIX) to
   `deepspacecartel.devcontainer-builder` (Marketplace and Open VSX). The
   template uninstalls the old one in workspaces. Locally, uninstall the old one
   and install the new one.
5. **Images built before 0.3.0** don't record their user's uid/gid. They run as
   uid 1000 with a warning until rebuilt. Updating to 1.0 rebuilds every
   workspace's image once anyway (item 7); on older template versions, update
   each workspace, let one start finish, then rebuild
   ([why](../guides/coder-workspace-template.md#upgrading)).
6. **The Terraform module is deprecated.** If you use it outside the
   template, move to the provider's `devcontainerbuilder_build`.
7. **Each workspace has its own image tag (1.0)**, `ws-<workspace-id>-<rebuild>`,
   instead of `sha-<commit>` shared by every workspace on the same repository
   and commit. So every existing workspace **rebuilds once** on its first
   start after the update, from its branch's latest commit, and the old
   `sha-<commit>` tag is deleted. Workspaces still on the old version that
   used the same tag can't pull it on a fresh node until they're updated too,
   so update all of them ([details](../guides/coder-workspace-template.md#upgrading)).
8. **Template requirements (1.0):** provider versions are bounded
   (`coder/coder` ≥ 2.5.0, `hashicorp/kubernetes` ≥ 2.16.0,
   `deepspacecartel/devcontainer-builder` ≥ 0.3.0 and < 2.0.0), workspace
   pods only schedule on `amd64` nodes (as the agent always required), and
   the image needs `git` for the clone ([Requirements](../reference/template.md#requirements)).
9. **VS Code settings from `customizations.vscode.settings` are defaults (1.0).**
   They no longer overwrite a Machine setting the user has changed.

The [CHANGELOG](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/CHANGELOG.md)
has every change, version by version.

## Tested with

| | Version |
|---|---|
| Coder | v2.37 |
| Terraform provider `deepspacecartel/devcontainer-builder` | ≥ 0.3.0, < 2.0.0 |
| Dev Containers CLI (inside the service image) | the latest when the image is built |
| Kubernetes Pod Security | *baseline* in the workspaces namespace; *privileged* for BuildKit's own namespace |
