# devcontainer-builder

**Dev Containers for Coder on Kubernetes: self-hosted Codespaces.** Pick a
git repository and get a [Coder](https://coder.com) workspace built from its
own `devcontainer.json` (image, Features, Dockerfile, lifecycle commands,
env, ports, VS Code extensions), on your own cluster. Push a change to the
Dev Container configuration and the workspace offers to rebuild. A repository
without one gets a generic image and a prompt to add it.

Docs: <https://deepspacecartel.github.io/devcontainer-builder/>

- **Platform admins:** [Set up the platform](https://deepspacecartel.github.io/devcontainer-builder/getting-started/platform/). One Helm chart, one
  template push.
- **Developers:** [Your first workspace](https://deepspacecartel.github.io/devcontainer-builder/getting-started/first-workspace/). Install
  [Dev Containers for Coder in K8S](https://marketplace.visualstudio.com/items?itemName=deepspacecartel.devcontainer-builder)
  and run **Coder: Clone Repository in Workspace…**.

## Layout

- [`service/`](service) - devcontainer-builder, the build service: clones a repository, builds its
  Dev Container image with the Dev Containers CLI on a remote BuildKit, pushes it, and reads a
  built image's merged configuration back.
- [`charts/devcontainer-builder/`](charts/devcontainer-builder) - the Helm chart for the service
  (optionally with BuildKit).
- [`templates/coder-kubernetes/`](templates/coder-kubernetes) - the Coder template: a repository
  and branch in, a workspace pod built from its `devcontainer.json` out.
- [`vscode-extension/`](vscode-extension) - *Dev Containers for Coder in K8S*: clone into a
  workspace, rebuild prompt, add a configuration.
- [`terraform/devcontainer-build/`](terraform/devcontainer-build) - **deprecated** (removed in
  2.0); use the [Terraform provider](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder)
  directly.

The Terraform provider (`deepspacecartel/devcontainer-builder`) lives in
[its own repository](https://github.com/DeepSpaceCartel/terraform-provider-devcontainer-builder).

## Documentation

User and operator docs are published at
<https://deepspacecartel.github.io/devcontainer-builder/> (source in [`docs/`](docs)).
[`docs/claude/`](docs/claude) holds internal plans and investigation notes, not part of the
published site.

- [`.agents/skills/`](.agents/skills) - reusable [Agent
  Skills](https://www.skills.sh/) distilling hard-won gotchas from building
  this repo's Helm charts, BuildKit/buildx usage, git protocol test
  fixtures, and disposable-Kubernetes-test-fixture pattern - loaded
  automatically by tools that support the convention.

## License

MIT (see [LICENSE](LICENSE)).
