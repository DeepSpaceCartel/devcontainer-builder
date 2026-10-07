# coder-kubernetes

A [Coder](https://coder.com) template for Kubernetes: users enter a git
repository and branch, and get a workspace built from that repository's own
`devcontainer.json` by devcontainer-builder. It's adapted from Coder's
[`kubernetes`](https://registry.coder.com/templates/coder/kubernetes) template.

```bash
coder templates push kubernetes-devcontainer \
  --var namespace=coder-workspaces \
  --var devcontainer_builder_endpoint=http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080
```

devcontainer-builder and BuildKit must already run in the cluster; the
template doesn't deploy them. Start with [Set up the platform](https://deepspacecartel.github.io/devcontainer-builder/getting-started/platform/).
Then see:

- [Coder template reference](https://deepspacecartel.github.io/devcontainer-builder/reference/template/): variables, parameters, what's in a workspace;
- [devcontainer.json support](https://deepspacecartel.github.io/devcontainer-builder/reference/devcontainer-json/): every property and what it becomes;
- [Operating the template](https://deepspacecartel.github.io/devcontainer-builder/guides/coder-workspace-template/): private repositories, resources,
  persistence, upgrades.

The same template is copied to the Coder Registry
(`registry/deepspacecartel/templates/kubernetes-devcontainer`) and to
deployments' own repositories; changes here need to reach those copies too.
