<title>Operating the template</title>

# Operating the template

How-tos for platform admins running the [Coder template](../reference/template.md)
after [setting up the platform](../getting-started/platform.md):

- private repositories;
- resources;
- what persists;
- the workspace user;
- the repository clone;
- rebuilds;
- VS Code;
- upgrades.

## What the template does, and what it doesn't

When a workspace is created, the template's `devcontainerbuilder_build`
resource (from the [Terraform provider](../reference/TERRAFORM-PROVIDER.md))
calls devcontainer-builder's `POST /build`. The image that comes back becomes
the workspace pod's image. A `devcontainerbuilder_devcontainer` data source
then reads the image's merged Dev Container configuration (`GET
/devcontainer`), and the template maps it onto the pod
([devcontainer.json support](../reference/devcontainer-json.md)).

The template does **not** deploy devcontainer-builder or BuildKit. They're
cluster-level infrastructure, installed once. A template can't stand up a
service and wait for it in the same `terraform apply` that calls it, and
BuildKit needs Pod Security *privileged*, which you don't want to grant per
workspace ([ADR-0001](../decisions/0001-remote-buildkit-builder.md)).

## Private repositories

Two clones need access: devcontainer-builder's, for the image build, and
the workspace's own. The simplest setup covers both with each user's own
account:

1. Configure a Coder [external auth provider](https://coder.com/docs/admin/external-auth)
   for the git host, e.g. a GitHub App or OAuth app with the ID `github`.
2. Push the template with `--var external_auth_id=github`.

Creating a workspace then requires the user to link that account, once. The
VS Code clone command opens the link page and waits. After that:

- **The workspace's clone** uses it through the agent's `GIT_ASKPASS`.
- **The image build** uses it too. The template sends the user's token with
  the build request (`git_credentials`, username `oauth2`), so
  devcontainer-builder needs no credentials of its own, and users only build
  what they can read. The token goes into a scratch `.netrc` for the clone and
  is never logged or put in argv ([Credential
  handling](../concepts/credential-handling.md)). A refreshed token doesn't
  trigger a rebuild; the next Rebuild uses the current one.

Without `external_auth_id`:

- **The build** uses the template-wide `git_credentials_username`/`git_credentials_token`, or
  devcontainer-builder's own per-host `gitCredentials` ([Configuration](../reference/CONFIGURATION.md)).
- **The workspace's clone** needs one of:
  - **HTTPS:** an external auth provider the user has linked anyway, for the agent's `GIT_ASKPASS`;
  - **SSH** (`git@…` or `ssh://` URLs): the owner's Coder SSH public key (`coder publickey`) added to
    their account on the git host. The agent's `coder gitssh` uses it.

## Resources

The **CPU** and **Memory** parameters are the workspace's limits; requests
are 250m CPU / 512Mi, so workspaces pack densely.

A repository's `hostRequirements` are **minimums**, as in the Dev Container
spec:

- `cpus` and `memory` are **reserved**: they become the pod's requests, so the
  workspace lands on a node that has them free.
- The limits are the larger of the requirement and the parameter.
- `storage` makes the volume at least that big.

`max_cpu` (default 8) and `max_memory` (default 32 GiB) cap what a
repository can reserve. Above them, the workspace gets the cap and a warning
in its build log.

A workspace whose requirements no node can satisfy stays **Pending** with
Kubernetes' scheduling reason until a node frees up or your autoscaler adds
one. On a small cluster, lower `max_cpu`/`max_memory` to fit your nodes. The
workspace page's **Resources (reserved / limit)** item shows what each
workspace got.

## Persistence

Each workspace gets one PVC, `coder-<workspace-id>-data`. It's sized by the
**Disk size** parameter, or by `hostRequirements.storage` if that's larger,
and mounted via subPaths:

| PVC path            | Mounted at                                                  |
| ------------------- | ----------------------------------------------------------- |
| `home/`             | the remote user's home (`/home/<user>`, or `/root`)         |
| `workspaces/`       | `/workspaces`                                               |
| `workspace-folder/` | a `workspaceFolder` outside `/workspaces`, if there is one  |
| `volumes/<name>/`   | each `type=volume` mount from devcontainer.json             |

Everything else (the image's root filesystem) is fresh on every pod start.

A mount hides whatever the image had at that path, so a `seed-home` init
container runs first, with the same image. On the workspace's **first** start
only, it copies the image's own home (`.bashrc`, nvm, oh-my-zsh, …) into the
PVC. After that the home is the user's: later rebuilds don't re-seed it.

## The workspace user

The pod runs as devcontainer.json's `remoteUser` (else `containerUser`,
else the image's `USER`), **as that user from the start**:

- `runAsUser`/`runAsGroup`/`fsGroup` come from the uid/gid devcontainer-builder recorded from the
  image's `/etc/passwd` at build time, so nothing starts as root and any uid works;
- `fsGroup` (with `OnRootMismatch`) keeps the PVC writable.

An image without that record (built by devcontainer-builder older than
0.3.0) runs as uid/gid 1000, with a warning to rebuild.

## The repository clone

On a workspace's first start, the login-blocking *Dev Container lifecycle*
script clones the **Branch** into `workspaceFolder` (default
`/workspaces/<repo>`), **at the commit the image was built from**, so the
lifecycle commands run the scripts the image was built for. Then it runs
`initializeCommand` and the other lifecycle commands.

An existing working copy is never touched again: local changes and other
branches survive restarts and rebuilds. If the clone fails, the script fails,
the workspace shows a startup error, and its log says why.

**Repository** and **Branch** can't be changed on an existing workspace.
Create another workspace for another branch.

## Rebuilds

The image is built when the workspace is created. Increasing the
**Rebuild** parameter rebuilds it from the branch's latest commit on the next
start: the old image tag is deleted and the new commit built. The
[VS Code extension](../reference/vscode-extension.md) does this for users, and
prompts them when the configuration changes on the branch
([Working in a workspace](working-in-a-workspace.md#rebuild-when-the-configuration-changes)).

The template keeps that extension installed and up to date in every
workspace (`vscode_extension`). Set it to `""` to opt out, or to a VSIX URL
to try an unreleased build.

## VS Code

- **VS Code Desktop** connects through the Coder extension and opens
  `workspaceFolder`.
- **VS Code in the browser** is Microsoft's VS Code Server (the `vscode-web` module, extensions from
  the Microsoft Marketplace). It needs `accept_vscode_license` (default `true`): Microsoft's
  [license](https://aka.ms/vscode-server-license) allows it within your own organization. Set it to
  `false` if workspaces are offered to others.

Both share `~/.vscode-server` on the persisted home, so the repository's
`customizations.vscode` extensions and settings, installed by a non-blocking
script on every start, apply to both.

## Upgrading

See [Versioning and upgrades](../project/versioning.md) for what changes
between versions. For existing workspaces:

!!! note "Rebuild after updating the template"
    **Rebuild** only takes effect once a start has succeeded on the new
    template version: the rebuild is triggered when its tracker *changes*,
    and the first start on a version only *creates* it. So update the
    workspace, let that first start finish, then rebuild.

!!! warning "Workspaces from the first template version"
    Workspaces created before the `coder-<id>-data` layout used a
    `coder-<id>-home` PVC mounted at `/home/coder`. They must be
    **recreated**; copy anything worth keeping out first.

## Gotchas

- **A private registry needs `image_pull_secret_name`.** devcontainer-builder pushing an image is
  separate from the nodes pulling it. Without the pull secret, pods sit in `ImagePullBackOff`.
- **Lifecycle commands run on every start,** because the root filesystem is fresh each time. They
  must be idempotent; tools belong in the image or a Feature
  ([Working in a workspace](working-in-a-workspace.md#lifecycle-commands-run-on-every-start)).
- **`${localEnv:…}`** comes from each workspace's **Dev Container variables** setting. Coder
  evaluates template parameters when the template is imported, so it can't offer one field per
  variable.
