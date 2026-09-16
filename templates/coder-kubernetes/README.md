# coder-kubernetes

A [Coder](https://github.com/coder/coder) Workspace Template for
Kubernetes, adapted from the official
[`coder/kubernetes`](https://registry.coder.com/templates/coder/kubernetes)
registry template. The one real change: instead of a fixed/parameterized
`image` variable, a workspace-level **Git repository** parameter feeds a
[`devcontainerbuilder_build`](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder)
resource, which turns it into a real, pushed image before the Deployment
ever starts.

See [the full walkthrough](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/docs/guides/coder-workspace-template.md)
(or `docs/guides/coder-workspace-template.md` in this repo) for
prerequisites, the platform-infrastructure setup this template itself does
**not** do (devcontainer-builder and BuildKit are deployed once, separately
— see that guide for why), and real gotchas (private-registry
`imagePullSecrets`, credential resolution order).

```bash
coder templates push devcontainer-kubernetes \
  --var namespace=coder-workspaces \
  --var devcontainer_builder_endpoint=http://devcontainer-builder.devcontainer-builder.svc.cluster.local:8080
```
