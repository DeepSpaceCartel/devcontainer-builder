<title>Public repositories and GHCR</title>

# Public repositories and GHCR

The simplest setup: anyone can clone the repositories, and the images go to
GitHub Container Registry (GHCR) under your organization. No git credentials
are involved anywhere.

## What you need

- devcontainer-builder installed as in [Set up the platform](../getting-started/platform.md).
- A GitHub token with `write:packages` for pushing, and one with `read:packages` for the nodes'
  pull secret. A single fine-grained or classic token can do both; prefer a bot account's.

## 1. Push to your organization on GHCR

In your Helm values:

```yaml
registryAuth:
  registries:
    - registry: ghcr.io
      username: <github-user>
      password: <token-with-write:packages>

registryMapping:
  rules:
    - hostMatch: github.com
      registry: ghcr.io/<your-org>
```

Every `github.com/<owner>/<repo>` is built as `ghcr.io/<your-org>/<repo>:<tag>`.
To send only your organization's repositories there, add
`pathPrefix: <your-org>/` to the rule. Rules are tried in order, so you can
add more for other hosts ([ADR-0003](../decisions/0003-registry-resolution-via-mapping-rules.md)).

## 2. Let the nodes pull

New GHCR packages are private by default, so the workspaces namespace needs
a pull secret:

```bash
kubectl -n coder-workspaces create secret docker-registry devcontainer-images \
  --docker-server=ghcr.io --docker-username=<github-user> --docker-password=<token-with-read:packages>
```

Then push the template with `--var image_pull_secret_name=devcontainer-images`.

If you make the packages public in GitHub's package settings, the pull secret
isn't needed.

## 3. Try it

```bash
coder create try-public --template kubernetes-devcontainer \
  --parameter repository=https://github.com/DeepSpaceCartel/devcontainer-builder-examples.git \
  --parameter branch=docs-demo
```

The image appears under your organization's packages as
`devcontainer-builder-examples`, tagged for the workspace.

## Keeping the registry tidy

Each workspace builds its own tag (`ws-<workspace-id>-<rebuild>`). GHCR doesn't
support deleting through the registry API, so old tags stay after workspaces
are rebuilt or deleted. Add a retention policy, for example a scheduled
GitHub Actions job that deletes package versions older than a few weeks.
