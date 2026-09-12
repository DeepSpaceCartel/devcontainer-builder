<title>Testing philosophy</title>

# Testing philosophy

The BDD suite (`service/features/`) makes no attempt to test this
service in isolation from what it actually does: clone real git repos
over git/http/https/ssh, push real images through a real BuildKit
daemon, read real Kubernetes Secrets/ConfigMaps at startup. Every
scenario runs against a real, disposable Kubernetes namespace and real
fixture services — there is no mocked git server, no stubbed BuildKit,
no faked HTTP client. See
[0005: The BDD suite runs on Thomas](../decisions/0005-bdd-suite-on-thomas.md)
for the decision record, and
[Running the tests](../project/testing.md) for how to actually run it.

## Why real commands, not mocks

A mock only proves the code calls the mock the way the test expects —
it can drift silently from what the real dependency actually does
(a real `git clone`'s exact error text on a bad branch, whether BuildKit
actually respects an insecure-registry trust config, whether an SSH
host key policy really fails closed with no pin configured). Every
scenario in this suite is written so a failure means the *real*
behavior changed, not that a mock's assumptions did. Concretely: SSH
credential scenarios run against a real, disposable `git-daemon`/`git
http-backend`/`sshd` fixture
([`charts/test-git-server`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/charts/test-git-server)),
registry scenarios push to a real, disposable registry
([`charts/test-registry`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/charts/test-registry)),
and every build scenario runs a real `docker buildx build --push`
against a real BuildKit daemon.

## Built on Thomas

The suite is written in [Thomas](https://alexander.ilyin.eu/Thomas/), a
separate, general-purpose real-command BDD framework this project's own
suite was migrated onto. Thomas owns the actual step-definition
vocabulary (Helm, Kubernetes, HTTP, Docker/buildx, SSH, TLS) and the
"define, then act" pattern every scenario follows — a pure `Given <Type>
known as "<Alias>":` step constructs a typed object, a separate `When`
step performs the real action. That vocabulary is documented on
Thomas's own site, not duplicated here — see its
[BDD conventions](https://alexander.ilyin.eu/Thomas/concepts/bdd-conventions/)
and per-domain reference pages.

## What each `.feature` file actually covers

| File | What it proves |
|---|---|
| `health.feature` | Liveness/readiness signals, including a deliberately-never-ready pod |
| `request_validation.feature` | `/build`'s up-front shape check, independent of whether the values are usable |
| `devcontainer_config_discovery.feature` | The devcontainer CLI's real auto-discovery locations (root, `.devcontainer/`, *not* an arbitrary sub-folder) |
| `devcontainer_config_content.feature` | A discoverable-but-unusable `devcontainer.json` fails clearly, including the `"build":{"dockerfile":...}` path |
| `image_resolution.feature` | Name/tag/registry defaulting and mapping-rule resolution |
| `registry_auth.feature` | Ambient vs. per-request registry push credentials against a real auth-enforcing registry |
| `git_source_resolution.feature` | URL parsing, credential precedence, and HTTPS/SSH protocol conversion |
| `service_settings_file.feature` | The unified `SERVICE_CONFIG_PATH` JSON/YAML settings file |
| `service_startup_configuration.feature` | Every other startup config source, including real crash-loop detection for misconfiguration |
| `end_to_end_build.feature` | A handful of full round trips combining several resolution axes at once (`@smoke`) |

## Fixture cost is real and accepted

Every scenario that needs a deployed `devcontainer-builder` pod builds
and pushes this repository's own current source first (via the shared,
already-running production BuildKit instance and real GHCR
credentials — never a disposable in-cluster registry for *this* image,
since it's the one thing the deployed pod's own `kubelet` needs to
genuinely pull, and `kubelet` pulls can't be routed through
BuildKit's own, separately-configurable registry trust). A scenario
whose server configuration needs to vary (most of them) installs its
own Helm release rather than reusing one across scenarios — real,
measured cost (minutes per file, not seconds), accepted deliberately
in exchange for every scenario being a genuinely independent, real
round trip rather than one sharing hidden state with whichever
scenario happened to run before it.
