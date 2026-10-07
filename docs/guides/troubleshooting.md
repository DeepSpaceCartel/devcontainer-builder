<title>Troubleshooting</title>

# Troubleshooting

Symptoms first, then where to look. The first half is for developers
using a workspace; the second for the platform admin running
devcontainer-builder, BuildKit and the Coder template. Where another page
already covers a problem in depth, this page links to it.

## For developers

### The workspace build failed

Open the failed build in the Coder dashboard (the workspace → its latest
build). devcontainer-builder's error is in the build log. **Coder: Clone
Repository in Workspace…** in VS Code offers **Show Build Log** too.

The usual causes, roughly in order:

- **A `devcontainer.json` error** — invalid JSON, a Feature that fails to
  install, a Dockerfile step that fails. Reproduce it locally with the Dev
  Containers CLI (`devcontainer build`) or VS Code's *Dev Containers:
  Rebuild Container*.
- **The repository or branch doesn't exist, or you can't read it.** For
  a private repository, your template admin has to set up git access; see
  [Private repositories](coder-workspace-template.md#private-repositories).
  If the template uses a linked git account, re-link it in Coder (account
  → *External authentication*).
- **The repository has no `devcontainer.json`.** That's not an error: the
  workspace uses a fallback image. Add a configuration with
  [*Add Dev Container config*](working-in-a-workspace.md#add-a-configuration-to-a-repository-without-one).

### The workspace stays Pending

The repository's `hostRequirements` or `customizations.kubernetes` reserve
CPU, memory or GPUs, and no node has that much free, or its `nodeSelector`
matches no node. The dashboard's **Resources** item shows what was
requested. Lower the requirements or ask your platform admin for room;
see [Resources](coder-workspace-template.md#resources).

### A `devcontainer.json` setting seems ignored

Anything a Kubernetes pod can't honor (bind mounts, `--network`,
`privileged` without the template allowing it, …) is a **warning** in the
build log and counted in the dashboard's **Dev Container warnings** item.
See [devcontainer.json support](../reference/devcontainer-json.md) for
what maps to what.

### My tools or files disappeared after a restart

Only the persistent volume survives a stop/start; the rest of the
container's filesystem comes fresh from the image every time. See
[What persists](working-in-a-workspace.md#what-persists) and
[Lifecycle commands run on every start](working-in-a-workspace.md#lifecycle-commands-run-on-every-start).

### Other workspace problems

[Working in a workspace → When something goes wrong](working-in-a-workspace.md#when-something-goes-wrong)
covers the extension's status bar item, Workspace Trust and VS Code
extension installation.

## For platform admins

### `/health/ready` never reports ready

The service is up but can't use BuildKit.

```bash
kubectl -n devcontainer-builder get pods
kubectl -n devcontainer-builder get events --sort-by=.lastTimestamp
```

- **No BuildKit pod, and an event saying `violates PodSecurity`**: the
  namespace isn't labeled `pod-security.kubernetes.io/enforce=privileged`.
  See [Quickstart, step 2](../home/quickstart.md#2-install-the-chart) and
  [Security model](../concepts/security.md#buildkit-runs-privileged).
- **`buildkit.endpoint` unset** while `buildkit.deploy.enabled` is `false`:
  readiness never passes. See the [Helm chart reference](../reference/HELM.md#buildkit).
- **External BuildKit unreachable**: check the endpoint from inside the
  service pod's namespace, and any `NetworkPolicy` in between.

### A build returns `500`

A `500` body holds the failing command, its exit code and a `logId`, never
the real error text. Fetch the full output:

```bash
kubectl -n devcontainer-builder port-forward svc/devcontainer-builder 8080:8080 &
curl -s http://localhost:8080/logs/<logId>
```

Common findings there:

| In the log | Likely cause |
|---|---|
| `401`/`403` from the registry on push | Wrong or under-scoped `registryAuth.registries` entry; see [Helm chart → `registryAuth`](../reference/HELM.md#registryauth). |
| `http: server gave HTTP response to HTTPS client` | A plain-HTTP registry. BuildKit's trust for it is BuildKit's own server config (`buildkitd.toml`), not a client flag; the service's own registry calls also need it in [`insecureRegistries`](../reference/HELM.md#insecureregistries). |
| `Permission denied (publickey)`, `Host key verification failed` | SSH git credentials or host key policy; see [Credential handling](../concepts/credential-handling.md). |
| `Authentication failed`, `could not read Username` | Missing or expired HTTPS git token: server-side `gitCredentials`, template-wide credentials, or the user's linked account. |
| `toomanyrequests` from Docker Hub | Anonymous pull rate limit for base images; add Docker Hub credentials to `registryAuth`. |

The service's own structured logs (`kubectl -n devcontainer-builder logs
deploy/devcontainer-builder`) have a `build.failed` event with the same
`log.id`.

### Workspace pods sit in `ImagePullBackOff`

The nodes can't pull the built image from a private registry. Set the
template's `image_pull_secret_name`; see
[Set up the platform → Let the nodes pull the images](../getting-started/platform.md#2-let-the-nodes-pull-the-images)
and the template [Gotchas](coder-workspace-template.md#gotchas).

### A workspace pod is rejected by Pod Security

The repository asked for `privileged`, `seccomp=unconfined` or a
capability outside baseline, and the template has `allow_privileged = true`
but the workspace namespace doesn't allow it. Either label the namespace
accordingly or turn `allow_privileged` off; see
[Security model → Workspace pods](../concepts/security.md#workspace-pods-and-allow_privileged).

### More

- Template behavior, upgrades and caveats:
  [Operating the template](coder-workspace-template.md), especially
  [Gotchas](coder-workspace-template.md#gotchas) and
  [Upgrading](coder-workspace-template.md#upgrading).
- Every service setting: [Service configuration](../reference/CONFIGURATION.md).
- The full error contract: the
  [HTTP API reference](../api-reference.html){:target="_blank" rel="noopener"}.
