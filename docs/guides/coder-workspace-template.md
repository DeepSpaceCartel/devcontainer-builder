<title>Coder Workspace Template</title>

# Guide: a Coder Workspace Template that builds from a git URL

Wire devcontainer-builder into a real
[Coder](https://github.com/coder/coder) Workspace Template so creating a
workspace looks like: type in a git repository URL, get a running pod built
from its `.devcontainer.json` — no separate `curl /build` step, no
hand-authored Dockerfile. The real, runnable template this guide walks
through lives at
[`templates/coder-kubernetes/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/templates/coder-kubernetes),
adapted from the official
[`coder/kubernetes`](https://registry.coder.com/templates/coder/kubernetes)
registry template — the only real change is what feeds the container's
`image`.

## What this template does — and, just as importantly, doesn't do

The template's `devcontainerbuilder_build` resource (from the
[Terraform provider](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder))
calls an **already-running** devcontainer-builder instance's `POST /build`
whenever a workspace is created, and wires the real, pushed image it
returns straight into `kubernetes_deployment_v1.main`'s container `image` —
that part is genuinely new versus the upstream template's fixed `image`
variable.

What it deliberately does **not** do: deploy devcontainer-builder itself,
or BuildKit. Both are **cluster-level platform infrastructure**, set up
once by whoever administers the cluster — not per-workspace-template state.
This isn't a corner cut for time; a `devcontainerbuilder_build` resource
inside the template would need a devcontainer-builder endpoint that already
exists and is reachable before the template's own `terraform apply` (run by
coderd's provisioner, on every workspace create) even starts — there's no
hook to stand up a brand-new Service and wait for it mid-apply. It's the
same "can't configure a provider from a value computed in the same apply"
problem that splitting infrastructure into separate Terraform states
generally exists to solve. And BuildKit's default mode is genuinely
privileged (see [ADR-0001](../decisions/0001-remote-buildkit-builder.md)) —
not something to grant a PodSecurity exemption for on every ephemeral
workspace-template apply.

## Prerequisites

- A Coder deployment, already running, with a Kubernetes cluster it can
  provision workspaces into.
- Cluster-admin access to that same cluster, to deploy the platform-level
  pieces below **once**.
- The [Terraform provider](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder)
  (published on the Terraform Registry as `deepspacecartel/devcontainer-builder`)
  available wherever `coder templates push` runs from — a plain
  `required_providers` block resolves it normally, same as `coder`/`hashicorp/kubernetes`.

## 1. Deploy devcontainer-builder (and, optionally, BuildKit) as platform infrastructure

If you already run BuildKit somewhere reachable from this cluster, just
point `buildkit.endpoint` at it:

```bash
helm install devcontainer-builder oci://ghcr.io/deepspacecartel/charts/devcontainer-builder \
  --namespace devcontainer-builder --create-namespace \
  --set buildkit.endpoint="tcp://<your-buildkit-host>:<port>" \
  --set registryAuth.registries[0].registry=https://index.docker.io/v1/ \
  --set registryAuth.registries[0].username=<user> \
  --set registryAuth.registries[0].password=<token>
```

Starting from nothing? Skip sourcing a second chart — bundle BuildKit with
this one (see [Helm chart reference](../reference/HELM.md#buildkit) for the
real, non-optional PodSecurity prerequisite this doesn't remove):

```bash
helm install devcontainer-builder oci://ghcr.io/deepspacecartel/charts/devcontainer-builder \
  --namespace devcontainer-builder \
  --set buildkit.deploy.enabled=true \
  --set registryAuth.registries[0].registry=https://index.docker.io/v1/ \
  --set registryAuth.registries[0].username=<user> \
  --set registryAuth.registries[0].password=<token>
```

Note **no `--create-namespace`** in the second command — the chart creates
and labels its own release namespace when `buildkit.deploy.enabled` is
true; passing both conflicts. Confirm it's actually ready before moving on
(see [Quickstart](../home/quickstart.md)'s same check):

```bash
kubectl port-forward -n devcontainer-builder svc/devcontainer-builder 8080:8080 &
curl -s http://localhost:8080/health/ready
```

!!! danger "Never expose this Service outside the cluster"
    Same warning as the [Quickstart](../home/quickstart.md) — the API has
    no authentication of its own. `ClusterIP` only, reachable from wherever
    `coder templates push`/coderd's provisioner runs (inside the cluster),
    nothing else.

## 2. Push the template

```bash
git clone https://github.com/DeepSpaceCartel/devcontainer-builder.git
cd devcontainer-builder/templates/coder-kubernetes

coder templates push devcontainer-kubernetes \
  --var namespace=coder-workspaces \
  --var devcontainer_builder_endpoint=http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080
```

`namespace` and `devcontainer_builder_endpoint` are **template-level**
variables — set once here, not per-workspace. `image_pull_secret_name`,
`git_credentials_username`/`git_credentials_token`, `external_auth_id`, `max_cpu`/`max_memory`, `vscode_extension`
and the others below are optional template
variables too (see the template's own `variable` blocks for what each
does); leave them unset to start.

## 3. Create a workspace

In the Coder UI (or `coder create`), the workspace-level parameters are
now **Git repository** and **Branch** — instead of a fixed image. Point it
at any repo with a `.devcontainer.json` (or `.devcontainer/devcontainer.json`)
at its root:

```bash
coder create my-workspace --template devcontainer-kubernetes \
  --parameter repository=https://github.com/microsoft/vscode-remote-try-node.git
```

`coder create` calls the template's `terraform apply`, which runs
`devcontainerbuilder_build` (a real clone + build + push against the
platform infrastructure from step 1), then boots
`kubernetes_deployment_v1.main` from the image it returns.

### From VS Code: Clone Repository in Workspace…

The same extension that runs the [rebuild prompt](#the-repository-clone)
inside workspaces also works in a **local** VS Code window. Install the
extension once on your machine: search the Extensions view for **Dev
Containers for Coder in K8S** (`deepspacecartel.devcontainer-builder`).
Then **Coder: Clone Repository in
Workspace…** works like Dev Containers' *Clone Repository in
Container Volume…*:

1. **Log in.** It uses the Coder CLI's login if you have one (`coder
   login`); otherwise it asks for your Coder URL and a token from its
   `/cli-auth` page, once.
2. **Choose the repository and branch** in VS Code's own repository
   picker, the one **Git: Clone** uses. Signed in to GitHub in VS Code,
   its **GitHub** source lists and filters your repositories, then their
   branches. For a typed URL, the branches come from `git ls-remote`, the
   default first. For a private repository without local git credentials,
   type the branch name.
3. **Reuse or create.** If you already have a workspace on that
   repository and branch, it offers to open it (starting it if it's
   stopped). Otherwise it creates `<repo>-<branch>` from the template
   that asks for a repository and a branch (setting
   `devcontainerBuilder.template` when there are several), with the
   template's defaults for everything else.
4. **Open.** It follows the build to ready, then opens VS Code Desktop on
   the cloned folder through the Coder extension, which it offers to
   install. If the build fails, it offers the build log.

### Repositories without a devcontainer.json

With the chart's default `build.fallbackImage`, a repository without any
Dev Container configuration still builds, on
`mcr.microsoft.com/devcontainers/base:ubuntu`
([ADR-0013](../decisions/0013-fallback-config-for-repos-without-one.md)).
In the workspace, the status bar shows **Add Dev Container config**, and a
notification offers **Add Configuration**. Both run the Dev Containers
extension's own **Add Dev Container Configuration Files…** (VS Code
Desktop), with its templates, options and Features. Commit and push what it
adds: a rebuild builds `origin/<branch>`, so **Rebuild available** appears
once it's there, and Rebuild moves the workspace onto the new image.

## Persistence

Each workspace gets one PVC, `coder-<workspace-id>-data` (sized by the
**Disk size** parameter, or `hostRequirements.storage` if that is larger — see below),
mounted via subPaths:

| PVC path            | Mounted at                                                  |
| ------------------- | ----------------------------------------------------------- |
| `home/`             | the remote user's home (`/home/<user>`, or `/root`)         |
| `workspaces/`       | `/workspaces`                                               |
| `workspace-folder/` | a `workspaceFolder` outside `/workspaces`, if there is one  |
| `volumes/<name>/`   | each `type=volume` mount from devcontainer.json             |

Everything else (the image's root filesystem) is fresh on every pod start,
so anything installed outside those paths has to come from the image.

A mount hides whatever the image had at that path, so a `seed-home` init
container runs first, with the same image: on the workspace's **first**
start only, it copies the image's own home (`.bashrc`, nvm, oh-my-zsh, …)
into the PVC. After that the home is the user's — later image rebuilds
don't re-seed it, and a dotfile deleted by the user stays deleted.

## The user

The pod runs as devcontainer.json's `remoteUser` (else `containerUser`,
else the image's `USER`) — **as that user from the start**:
`runAsUser`/`runAsGroup`/`fsGroup` come from the uid/gid devcontainer-builder
recorded from the image's `/etc/passwd` at build time, so nothing starts as
root and any uid works. `fsGroup` (with `OnRootMismatch`) keeps the PVC
writable for it. An image without that record (built by devcontainer-builder
older than 0.3.0) runs as uid/gid 1000 instead — what earlier template
versions did — with a warning to bump **Rebuild**.

!!! note "Upgrading a workspace from an older template version"
    **Rebuild** only takes effect once a start has succeeded on this
    template version: the rebuild is triggered when its tracker *changes*,
    and the first start on this version only *creates* it. So update the
    workspace, let that first start finish (on its old image, as uid 1000),
    then bump **Rebuild**.

## The repository clone

On a workspace's first start, the login-blocking "Dev Container lifecycle"
script clones the **Git repository**'s **Branch** into devcontainer.json's
`workspaceFolder` (default `/workspaces/<repo name>`), **at the commit the
image was built from**, so the hooks run the scripts the image was built
for. VS Code Desktop and VS Code in the browser open that folder;
terminals and SSH sessions start in `$HOME` (the agent's `dir` setting is
deprecated and would break Coder Desktop file sync). An existing working
copy is never touched again — local changes and other branches survive
restarts and rebuilds.

**Private repositories.** Two clones need access: devcontainer-builder's,
for the image build, and the workspace's own. The simplest setup covers both
with the user's own account:

1. Configure an [external auth provider](https://coder.com/docs/admin/external-auth)
   for the git host on Coder (e.g. a GitHub OAuth or GitHub App, id `github`).
2. Push the template with `--var external_auth_id=github`.

Creating a workspace then asks the user to link that account (once; the
VS Code clone command opens the link page for you). After that:

- **The workspace's clone** uses it through the agent's `GIT_ASKPASS`.
- **The image build** uses it too. The template sends the user's token with
  the build request (`git_credentials`, username `oauth2`), so
  devcontainer-builder needs no credentials of its own and users only build
  what they can read. The token goes into a scratch `.netrc` for the clone and
  is never logged or put in argv ([Credential handling](../concepts/credential-handling.md)).
  A refreshed token doesn't trigger a rebuild; the next Rebuild uses the
  current one.

Without `external_auth_id`:
- the build uses credentials configured on devcontainer-builder (`gitCredentials`, per host) or the
  template-wide `git_credentials_username`/`git_credentials_token`;
- the workspace's clone needs one of:
  - **HTTPS:** an external auth provider linked by the user anyway, so the agent's `GIT_ASKPASS` can
    supply a token;
  - **SSH** (`git@…` or `ssh://` URLs): the owner's Coder SSH public key (`coder publickey`) added to
    their GitHub account. The agent's `coder gitssh` uses it.

If the clone fails, the lifecycle script fails (the workspace shows a
startup error) and its log says why.

**Rebuild.** The image is built when the workspace is created. Bump the
**Rebuild** parameter (workspace settings) to rebuild it from the branch's
latest commit on the next start, e.g. after `devcontainer.json` changes.
The working copy is left as it is.

**The rebuild prompt.** You don't have to remember when to bump Rebuild.
The template installs a small VS Code extension (`vscode-extension/` in
this repo, `deepspacecartel.devcontainer-builder` from the Marketplace, or
a VSIX URL, per `var.vscode_extension`) into VS Code Desktop
and VS Code in the browser. It compares the image's commit with
`origin/<branch>` over the files that go into the image:

- `.devcontainer/` and `.devcontainer.json`;
- the Dockerfile and build context devcontainer.json points at. If the
  context is the repo root, every change counts.

The extension fetches every 5 minutes, and also checks when you fetch or
edit. When something relevant lands on origin, the status bar shows
**Rebuild available** and a notification offers **Rebuild**, **Later**
(until the window reloads) or **Ignore This Commit** (until origin moves
again).

A rebuild only ever builds what's pushed, *Commit Your Code*. So Dev
Container changes that exist only in the workspace show **Push Dev
Container changes** instead.

**Rebuild** needs a Coder session in the workspace: run `coder login
<your Coder URL>` once (the session is kept in the persisted home).
Without one, it opens the workspace's settings page to bump Rebuild by
hand.

Behind the button is the Coder API (`POST /api/v2/workspaces/{id}/builds`
with the new `rebuild` value): `coder restart/start --parameter` keep an
existing workspace's value (Coder v2.37).

## devcontainer.json in a Kubernetes workspace

A `devcontainerbuilder_devcontainer` data source reads the built image's
merged Dev Container configuration from devcontainer-builder
(`GET /devcontainer`, service and provider `>= 0.3.0`) — what the repo's
`devcontainer.json`, its Features and its base image say, merged the way
the Dev Containers CLI merges them, plus a translation into pod terms
([ADR-0012](../decisions/0012-dev-container-to-kubernetes-runtime-mapping.md)).

| devcontainer.json | In the workspace |
|---|---|
| `image`, `build`, `features` | the image devcontainer-builder built |
| `remoteUser`, `containerUser` | the pod's user (see *The user*) |
| `workspaceFolder` | where the repo is cloned and the IDEs open |
| `onCreate`/`updateContent`/`postCreate`/`postStartCommand` | run in order, before login, on **every** start (below) |
| `postAttachCommand` | once per start, not blocking login |
| `initializeCommand` | first, before `onCreateCommand`, in the repo folder (there's no host) |
| `containerEnv`, `remoteEnv` (and `runArgs -e`) | exported before the agent starts — terminals, IDEs and hooks all see them; `${PATH}:/x` expands against the image's real `PATH` |
| `${localEnv:NAME}` | the **Dev Container variables** setting (below) |
| `${containerWorkspaceFolder}`, `${devcontainerId}` | the workspace folder, the Coder workspace ID |
| `forwardPorts`, `portsAttributes` | dashboard apps (label, http/https), through Coder's proxy; up to `max_forwarded_ports` |
| `mounts` / `--mount` / `-v` (volume) | the PVC, `volumes/<name>` — persists |
| `mounts` / `--tmpfs` (tmpfs) | an in-memory `emptyDir` |
| `capAdd`, `--cap-add` | `securityContext.capabilities.add` — beyond Pod Security *baseline*'s list (e.g. `SYS_PTRACE`) only with `allow_privileged` |
| `init`, `--init` | `shareProcessNamespace` (the pause container reaps zombies) |
| `--shm-size` | `/dev/shm` as an in-memory `emptyDir` of that size (default 64 Mi) |
| `--add-host`, `--hostname` | pod `hostAliases`, `hostname` |
| `privileged`, `securityOpt: seccomp=unconfined` | only with `allow_privileged` |
| `hostRequirements` (`cpus`, `memory`, `storage`, `gpu`), `--cpus`, `--memory` | **minimums**, as in the spec: `cpus`/`memory` are **reserved** (pod requests, capped by the template variables `max_cpu`/`max_memory`, with a warning above them), and the limits are the larger of them and the CPU/Memory parameters; `storage` → the larger of it and the Disk parameter; `gpu` → `nvidia.com/gpu: 1` (needs the NVIDIA device plugin). Without them, requests are 250m CPU / 512Mi. The workspace page shows what it got under **Resources (reserved / limit)** |
| `customizations.vscode` | extensions (Microsoft Marketplace) and settings for VS Code Desktop and in the browser (below) |
| bind mounts, `--network`, `--device`, `--gpus`, `host:port` forwards | ❌ no pod equivalent — reported as warnings |
| `dockerComposeFile`, `shutdownAction`, `updateRemoteUserUID` | ❌ not supported |

Everything the workspace can't honor shows up as a **warning in the
workspace's build log** ("Check block assertion failed", one line per item)
and as a count in the dashboard's "Dev Container warnings" item.

!!! warning "Every start runs every hook"
    Dev Containers runs `onCreate`/`updateContent`/`postCreate` once per
    container. A workspace pod gets a fresh root filesystem on **every**
    start, so here they run on every start: they must be idempotent (and
    anything they install outside `$HOME` or `/workspaces` is gone after a
    restart anyway — put that in the image or a Feature instead).

**Dev Container variables.** `${localEnv:NAME}` refers to the developer's
machine, which a workspace doesn't have. Values come from the workspace's
**Dev Container variables** setting instead — one `NAME=value` per line,
applied on the next restart. The build log and the dashboard name any the
repo uses without a value or default. Coder can't offer one field per
variable: template parameters are evaluated once, when the template is
imported, so they can't depend on the repository a workspace uses. Values
are visible to anyone who can see the workspace's settings.

**VS Code.** A non-blocking script installs
`customizations.vscode.extensions` from the **Microsoft Marketplace** into
`~/.vscode-server/extensions`, and merges `customizations.vscode.settings`
into `~/.vscode-server/data/Machine/settings.json`. That's the folder both
VS Code Desktop's remote server and **VS Code in the browser** (Microsoft's
VS Code Server, the `vscode-web` module) use, on the persisted home. The
browser IDE needs the template variable `accept_vscode_license` (default
`true`): Microsoft's [license](https://aka.ms/vscode-server-license) allows
it within your own organization. A Desktop window that attaches before the
script finishes picks up the rest after **Developer: Reload Window**.

!!! warning "Upgrading from the first template version"
    Workspaces created before this layout used a `coder-<id>-home` PVC
    mounted at `/home/coder`. They must be **recreated**; copy anything
    worth keeping out first.

## Real gotchas worth knowing before you hit them

- **A private registry needs `image_pull_secret_name`.** devcontainer-builder
  pushing an image is a separate concern from the *Kubernetes node* being
  able to *pull* it back — if `registryAuth`/the resolved registry is
  private, create a `kubernetes.io/dockerconfigjson` Secret in the
  template's `namespace` and pass its name as the
  `image_pull_secret_name` template variable, or every workspace's pod will
  sit in `ImagePullBackOff`.
- **`repository`/`branch` are immutable workspace parameters** (see the
  template's `data "coder_parameter"` blocks) — changing them on an
  existing workspace doesn't trigger a rebuild-in-place; it forces a new
  resource, same as any other immutable Coder parameter. That's deliberate,
  matching `devcontainerbuilder_build`'s own "every attribute forces
  replacement" design (see that provider's README) — there's no
  partial-update story on the service side to rebuild in place anyway.
- **Git/registry credentials default to devcontainer-builder's own ambient
  config**, not anything workspace- or template-specific — the simplest,
  most common case (public repo, one shared push registry) needs zero
  credential wiring in the template at all. The optional
  `git_credentials_username`/`git_credentials_token` template variables
  exist for a template-wide default that's still simpler than per-host
  server config; see
  [Credential handling](../concepts/credential-handling.md) for the full
  resolution order.
