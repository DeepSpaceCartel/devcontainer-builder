# devcontainer-builder

[![Open in Coder](https://coder.deepspacecartel.com/open-in-coder.svg)](https://coder.deepspacecartel.com/templates/coder/kubernetes-devcontainer-dsc/workspace?mode=manual&param.repository=https%3A%2F%2Fgithub.com%2FDeepSpaceCartel%2Fdevcontainer-builder.git&param.branch=main)

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

- [`docs/claude/plans/`](docs/claude/plans) - implementation plans written
  before a change lands, numbered in the order they were authored.
  - [001-devcontainer](docs/claude/plans/001-devcontainer.md) - adds
    `.devcontainer.json` and manual-mode bootstrap scripts so this repo can be
    developed from a Dev Container (or a plain pod, until Dev Containers are
    wired up in this Coder/K8s setup).
  - [002-service](docs/claude/plans/002-service.md) - hybrid git/registry
    credential resolution, HTTPS/SSH protocol conversion, and registry
    auto-resolution for the service.
- [`docs/claude/notes/`](docs/claude/notes) - findings and deferred
  infrastructure work that isn't a pre-change plan for a specific PR.
  - [registry-pull-through-cache](docs/claude/notes/registry-pull-through-cache.md) -
    Docker Hub anonymous rate-limiting hit during BDD testing, the immediate
    fixture-level mitigation, and a deferred pull-through cache idea.
  - [fixture-startup-installs](docs/claude/notes/fixture-startup-installs.md) -
    why `test-git-server`'s pods show transient `Unhealthy` readiness-probe
    events on every fresh start (installing packages at container startup
    instead of a pre-built image), and the deferred fix.
  - [devcontainer-subfolder-config-discovery](docs/claude/notes/devcontainer-subfolder-config-discovery.md) -
    the devcontainer CLI doesn't auto-discover a `.devcontainer/<folder>/`
    config; a real fix needs a discovery step ahead of devcontainer-builder,
    not just a `configPath` field on `/build`.
  - [devcontainer-cli-test-prerequisite](docs/claude/notes/devcontainer-cli-test-prerequisite.md) -
    the BDD suite's real-build scenarios need the `devcontainer` CLI on the
    *host* running `npm test`, not just baked into the deployable image -
    easy to hit fresh as `spawn devcontainer ENOENT`.
  - [git-ssh-interactive-prompt-hang](docs/claude/notes/git-ssh-interactive-prompt-hang.md) -
    a git-over-SSH clone with no credential configured could hang on a real
    host-key/password prompt - invisible to the BDD suite (no TTY ever
    attached), fixed with `-o BatchMode=yes`.
- [`.agents/skills/`](.agents/skills) - reusable [Agent
  Skills](https://www.skills.sh/) distilling hard-won gotchas from building
  this repo's Helm charts, BuildKit/buildx usage, git protocol test
  fixtures, and disposable-Kubernetes-test-fixture pattern - loaded
  automatically by tools that support the convention.

## License

MIT (see [LICENSE](LICENSE)).
