# devcontainer-builder

Builds a container image from a git repository's `.devcontainer.json` using a
remote [BuildKit](https://github.com/moby/buildkit) builder, and pushes it to
a registry - so a [Coder](https://github.com/coder/coder) Workspace Template
running on Kubernetes can boot a workspace straight from a repo URL, without
a dedicated CI pipeline to pre-build the image.

## Why

Coder Workspace Templates on Kubernetes need a container image at
pod-scheduling time. Templates are applied by coderd's own isolated Terraform
provisioner, which can't install tools once and reuse that across workspace
provisions - so building the devcontainer image has to happen in a separate,
long-running service, called from the template the same way it already calls
out to Kubernetes to provision a PersistentVolumeClaim before the pod.

## Layout

- [`service/`](service) - the HTTP service: clones the repo, configures
  `docker buildx` against a remote BuildKit endpoint, runs `devcontainer
  build --push`, and returns the resulting image reference.
- [`charts/devcontainer-builder/`](charts/devcontainer-builder) - a Helm
  chart that deploys the service into a Kubernetes cluster.
- [`terraform/devcontainer-build/`](terraform/devcontainer-build) - a
  Terraform module that calls an already-running instance of the service and
  exposes the built image as an output, for use from a Workspace Template.

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

## Status

Early scaffold. Not yet wired into any real infrastructure or published as a
Coder Registry module - see the sequencing notes in each subdirectory's
README/comments for what's still open (git-credential handling on private
repos, request/response contract stability, end-to-end tests against a live
BuildKit endpoint).

## License

MIT (see [LICENSE](LICENSE)) - placeholder, change if you want something else.
