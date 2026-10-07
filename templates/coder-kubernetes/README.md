# coder-kubernetes

A [Coder](https://github.com/coder/coder) Workspace Template for
Kubernetes, adapted from the official
[`coder/kubernetes`](https://registry.coder.com/templates/coder/kubernetes)
registry template. The one real change: instead of a fixed/parameterized
`image` variable, a workspace-level **Git repository** parameter feeds a
[`devcontainerbuilder_build`](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder)
resource, which turns it into a real, pushed image before the Deployment
ever starts.

The workspace's home and `/workspaces` persist on one PVC
(`coder-<id>-data`). The pod runs as the image's `remoteUser` (uid recorded
at build time), clones the repo into `workspaceFolder` at the image's
commit, and maps the rest of `devcontainer.json` — lifecycle commands, env
and `${localEnv:…}` variables, ports, mounts, capabilities,
`hostRequirements`, VS Code extensions — onto the pod and Coder. See the
guide's *devcontainer.json in a Kubernetes workspace* table.

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
