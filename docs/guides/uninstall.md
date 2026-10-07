<title>Uninstall</title>

# Uninstall

Removing devcontainer-builder from a cluster, in the reverse order of
[setting it up](../getting-started/platform.md). Uninstalling the chart
doesn't touch workspaces, volumes or images; each has its own step.

## 1. Remove the Coder template and its workspaces

Coder won't delete a template that still has workspaces. List and delete
them first; deleting a workspace runs `terraform destroy` for it, which
removes its Deployment and PVC and (best effort) its image:

```bash
coder list --all --search 'template:devcontainer-kubernetes'
coder delete <owner>/<workspace>        # for each workspace
coder templates delete devcontainer-kubernetes
```

Use your template's name if you pushed it under another one.

!!! warning "Delete workspaces while the service is still running"
    A workspace's destroy calls devcontainer-builder's `DELETE /image` to
    remove its image. With the service already gone, that step fails and
    the workspace delete fails with it (`coder delete --orphan` then
    removes the workspace without running Terraform, leaving its
    Kubernetes resources behind).

## 2. Uninstall the chart

```bash
helm uninstall devcontainer-builder --namespace devcontainer-builder
```

This removes the service, its Secret and ServiceAccount, and the bundled
BuildKit if `buildkit.deploy.enabled` was set. If you installed BuildKit
yourself, remove it the way you installed it.

Then delete the namespace, if nothing else lives in it:

```bash
kubectl delete namespace devcontainer-builder
```

## 3. Clean up what's left behind

### Workspace volumes: `coder-<workspace-id>-data`

Every workspace has a PVC named `coder-<workspace-id>-data` in the
template's `namespace`. A normal workspace delete removes it; one deleted
with `--orphan`, or left over from a failed destroy, stays, and so does its
data. Find them by Coder's labels:

```bash
kubectl -n <workspace-namespace> get pvc -l com.coder.resource=true \
  -L com.coder.workspace.name,com.coder.user.username
kubectl -n <workspace-namespace> delete pvc coder-<workspace-id>-data
```

Copy out anything worth keeping first: deleting the PVC deletes the home
directory and the repository clone, including uncommitted and unpushed
work.

### Images in the registry

Every build pushed an image (`<registry>/<repo-name>:sha-<commit>` by
default). Destroying a workspace attempts to delete its image, but some
registries (Docker Hub notably) don't allow deletion through the registry
API, and earlier tags stay. Remove them with the registry's own tools or
UI, e.g. GHCR's package settings, or a retention policy.

### Secrets you created

The image pull secret (`image_pull_secret_name`) in the workspace
namespace, and any Secret passed to the chart as `existingSecret`, were
created by you and aren't removed by Helm:

```bash
kubectl -n <workspace-namespace> delete secret <image-pull-secret>
```

### Coder external auth and credentials

If you set up a Coder external auth provider only for this template
(`external_auth_id`), remove it from Coder's configuration, and revoke
any tokens you created for `registryAuth`, `gitCredentials` or the
template-wide `git_credentials_token`.

### The VS Code extension

Developers can uninstall **Dev Containers for Coder** from VS Code's
Extensions view.
