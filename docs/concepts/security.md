<title>Security model</title>

# Security model

devcontainer-builder turns a git URL into a pushed container image, and the
Coder template turns that image into a running workspace pod. Both steps
handle credentials and both need some privilege. This page explains where
the trust boundaries are, what each component is trusted to do, and what a
platform admin is expected to add around it. It's background reading; the
settings themselves are in the [Helm chart](../reference/HELM.md) and
[Coder template](../reference/template.md) references.

## The API is unauthenticated, so it stays inside the cluster

The HTTP API has **no authentication of its own**. Anyone who can reach
`POST /build` can make the service clone any repository it can reach and
push an image to any registry it has credentials for, using the service's
own server-side git and registry credentials when the request doesn't
bring its own. `GET /logs/{id}` returns captured build output, and
`DELETE /image` deletes images.

That is a deliberate scope decision, not an oversight: the service is
platform infrastructure called by Coder's provisioner, in the same cluster.
The chart reflects it:

- one `ClusterIP` Service, no `Ingress`, no `LoadBalancer` — and none
  should be added;
- one replica, called only by in-cluster clients.

**Recommended: a `NetworkPolicy`.** "Cluster-internal" still means every
pod in the cluster can reach the service. On a multi-tenant cluster,
including one where Coder workspaces themselves run, restrict ingress to
the Coder provisioner's namespace. The chart doesn't ship one, because the
right selector depends on where Coder runs. A minimal example:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: devcontainer-builder-ingress
  namespace: devcontainer-builder
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: devcontainer-builder
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: coder
      ports:
        - port: 8080
```

Without a policy, a developer with a terminal in a workspace can call the
build service directly. That gives them nothing their own git access
doesn't — except the service's **server-side** credentials (see below),
which is the main reason to scope them narrowly and to add the policy.

## Credentials

### Per-build token forwarding

The template prefers credentials that belong to the person creating the
workspace. With `external_auth_id` set, Coder asks the user to link their
git account, and the template forwards **that user's token** with the one
`POST /build` that builds their workspace. The service uses it for that
clone only: written to a scratch `.netrc` in a per-request `$HOME`, never
on a command line or in the clone URL, and deleted when the request ends.
See [Credential handling](credential-handling.md) and
[ADR-0002](../decisions/0002-credentials-never-touch-argv-or-urls.md).

A user can therefore only build repositories they can already read. The
token is not persisted by the service.

### Server-side credentials

The service can also hold **deployment-wide** credentials: `registryAuth`
for pushing, and `gitCredentials` per git host. These apply to every
request that doesn't bring its own, so anyone who can call the API can use
them. Keep them to what the platform needs:

- a registry token scoped to the one repository namespace images are
  pushed to;
- git credentials only for hosts where every caller should have the same
  read access (or none at all, relying on per-build tokens).

Template-wide `git_credentials_username`/`git_credentials_token` work the
same way: every workspace built from that template uses them.

### What ends up in Terraform state

Coder keeps each workspace's Terraform state in its database. The
`devcontainerbuilder_build` resource stores its inputs there, including
`git_credentials` (the forwarded user token or the template-wide token)
and `registry_credentials` when set. They are marked **sensitive**, which
hides them from plan output, but state holds them in plain text. The
template ignores later changes to `git_credentials` so a refreshed token
doesn't rebuild the image, which means state keeps the token from the
last build until the next Rebuild.

Treat Coder's database and its backups as holding git tokens, and prefer
short-lived tokens (Coder's external auth refreshes OAuth tokens) over
long-lived personal access tokens in template variables.

## BuildKit runs privileged

BuildKit's default (rootful) mode needs a **privileged** container to run
OCI builds. That is inherent to BuildKit, not to devcontainer-builder, and
it's why the build runs in a separate, long-lived BuildKit instance instead
of Docker-in-Docker in the service pod
([ADR-0001](../decisions/0001-remote-buildkit-builder.md)).

Consequences:

- The namespace BuildKit runs in needs the `privileged`
  [Pod Security](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
  level. With the chart's bundled BuildKit, that's the release namespace —
  install it in its own namespace, never `default`
  ([Quickstart](../home/quickstart.md#2-install-the-chart)).
- A `RUN` step in any repository's Dockerfile executes inside BuildKit's
  build sandbox. Building untrusted repositories means trusting BuildKit's
  isolation; the service itself stays unprivileged and non-root.
- BuildKit's own endpoint is unauthenticated plain TCP in the bundled
  setup. Apply the same `NetworkPolicy` thinking to it: only the
  devcontainer-builder pod needs to reach it.

## Workspace pods and `allow_privileged`

Workspace pods run as the repository's `remoteUser` (`runAsUser` from the
image), not root, and the template keeps them within Pod Security
**baseline** by default. A `devcontainer.json` asking for more —
`privileged: true`, `securityOpt: seccomp=unconfined`, or capabilities
outside baseline's list such as `SYS_PTRACE` — is **not** honored; the
build log and the dashboard show a warning instead.

The template variable `allow_privileged` turns those on. Only set it when:

- the workspace namespace's Pod Security level allows it (otherwise the
  pod is rejected); and
- you accept that any repository a user points a workspace at can then get
  a privileged pod, which is effectively root on the node.

A safer pattern is a separate template, with `allow_privileged = true` and
its own namespace, offered only to the people who need it.

## Pod Security levels, summarized

| Namespace | Runs | Pod Security level |
|---|---|---|
| devcontainer-builder (with bundled BuildKit) | service + BuildKit | `privileged` (BuildKit) |
| devcontainer-builder (external BuildKit) | service only | `baseline` |
| BuildKit's own namespace, if separate | BuildKit | `privileged` |
| Coder workspaces | workspace pods | `baseline`; `privileged` only with `allow_privileged` |

## VS Code in the browser: Microsoft's license

VS Code in the browser (the **VS Code Web** button) runs Microsoft's VS
Code Server and installs extensions from the Microsoft Marketplace. Its
[license](https://aka.ms/vscode-server-license) permits use within your own
organization. The template variable `accept_vscode_license` (default
`true`) accepts it on your users' behalf. If you offer workspaces to people
outside your organization, set it to `false`: that removes the browser IDE,
and VS Code Desktop is unaffected. See
[Coder template](../reference/template.md#template-variables).

## What this model doesn't cover

- **Authentication and authorization of developers** is Coder's job: who
  can create workspaces, from which templates.
- **Image provenance and scanning.** Images are built from whatever the
  repository says; scan them in your registry if that matters to you.
- **Supply chain of Dev Container Features and base images**, which are
  fetched at build time from wherever `devcontainer.json` points.
