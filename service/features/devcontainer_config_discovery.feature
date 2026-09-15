Feature: devcontainer.json discovery after clone
  As an operator of devcontainer-builder
  I want the service to find devcontainer.json wherever the containers.dev spec allows it to live
  So that callers aren't forced into one specific repo layout

  See https://containers.dev/implementors/spec/#devcontainerjson - it
  recognizes three locations, in precedence order: .devcontainer/
  devcontainer.json, .devcontainer.json, and .devcontainer/<folder>/
  devcontainer.json (one sub-folder deep, <folder>'s name unspecified).
  test-git-server seeds one real repo per location (see
  charts/test-git-server/values.yaml's devcontainer-json-* entries) - these
  are real builds, so "success" means the devcontainer CLI actually found
  and used the config, not an inferred signal. Every seed repo in this
  feature shares byte-identical devcontainer.json content - only its
  location differs - so the resulting image reference carries no
  information this feature cares about; a 200 alone is already the full,
  direct proof discovery found and used the config (image *content*
  correctness is image_resolution.feature's own, separate concern).

  This deploys its own dedicated, trust-configured BuildKit instance
  (test-buildkit) and its own disposable in-cluster registry
  (test-registry) - unlike health.feature/request_validation.feature's
  Background, which only builds+pushes devcontainer-builder's own service
  image (to real GHCR, via the shared production BuildKit). The two never
  overlap: the shared production BuildKit only ever builds this repo's own
  known-good source; test-buildkit is what the *deployed service* uses at
  runtime to build the fixture repos below, so its trust config (an
  insecure-registry allowance for test-registry) never needs to extend
  past a registry this suite itself throws away afterwards - no node-level
  containerd trust is ever involved, since nothing here is ever pulled by
  kubelet (see /home/coder/rts-terraform/REGISTRY.md for why that would
  matter for a *pulled* image, e.g. this service's own).

  Background:
    Given the value of environment variable "CODER_WORKSPACE_OWNER_NAME", or "USER", or "local" is known as "<Owner>"
    And the value of environment variable "CUCUMBER_WORKER_ID" or "0" is known as "<WorkerId>"
    And the value "devcontainer-builder-<Owner>-w<WorkerId>" is known as "<Namespace>"

    Given Directory "<NamespaceChartDir>" at "../charts/test-namespace"
    And Helm Chart "<NamespaceChart>" in "<NamespaceChartDir>"
    And Helm Release known as "<NamespaceRelease>":
      | PROPERTY  | VALUE                      |
      | chart     | <NamespaceChart>           |
      | name      | test-namespace-<Namespace> |
      | namespace | default                    |
    When I upgrade Helm Release known as "<NamespaceRelease>" with:
      | OPTION    | VALUE                       |
      | --install | True                        |
      | --set     | targetNamespace=<Namespace> |
      | --set     | privileged=true             |
    Then the command exited with 0

    Given Directory "<TestRegistryChartDir>" at "../charts/test-registry"
    And Helm Chart "<TestRegistryChart>" in "<TestRegistryChartDir>"
    And Helm Release known as "<TestRegistryRelease>":
      | PROPERTY  | VALUE          |
      | chart     | <TestRegistryChart> |
      | name      | test-registry  |
      | namespace | <Namespace>    |
    When I upgrade Helm Release known as "<TestRegistryRelease>" with:
      | OPTION             | VALUE |
      | --install          | True  |
      | --wait              | True  |
      | --timeout           | 120s  |
    Then the command exited with 0
    Given the value "test-registry-test-registry.<Namespace>.svc.cluster.local:5000" is known as "<RegistryUrl>"

    When I create File known as "<BuildkitTrustFile>" at ".cache/fixtures/devcontainer-config-discovery-w<WorkerId>/buildkit-trust.toml" with:
      """
      [registry."test-registry-test-registry.<Namespace>.svc.cluster.local:5000"]
        http = true
        insecure = true
      """
    Given Helm Chart known as "<BuildkitChart>":
      | PROPERTY | VALUE                              |
      | chart    | buildkit-service                   |
      | repo     | https://andrcuns.github.io/charts  |
    And Helm Release known as "<TestBuildkitRelease>":
      | PROPERTY  | VALUE          |
      | chart     | <BuildkitChart> |
      | name      | test-buildkit  |
      | namespace | <Namespace>    |
    When I upgrade Helm Release known as "<TestBuildkitRelease>" with:
      | OPTION             | VALUE                                                             |
      | --install          | True                                                              |
      | --set-file         | buildkitdToml=.cache/fixtures/devcontainer-config-discovery-w<WorkerId>/buildkit-trust.toml |
      | --wait             | True                                                              |
      | --timeout          | 180s                                                              |
    Then the command exited with 0
    Given the value "tcp://test-buildkit-buildkit-service.<Namespace>.svc.cluster.local:1234" is known as "<BuildkitEndpoint>"

    Given Directory "<GitServerChartDir>" at "../charts/test-git-server"
    And Helm Chart "<GitServerChart>" in "<GitServerChartDir>"
    And Helm Release known as "<GitServerRelease>":
      | PROPERTY  | VALUE            |
      | chart     | <GitServerChart> |
      | name      | test-git-server  |
      | namespace | <Namespace>      |
    When I upgrade Helm Release known as "<GitServerRelease>" with:
      | OPTION             | VALUE |
      | --install          | True  |
      | --wait              | True  |
      | --timeout           | 180s  |
    Then the command exited with 0
    # Anonymous git:// protocol only - this feature's requests never touch
    # SSH/HTTPS, so the chart's default (empty) sshAuthorizedKey/tlsCert/
    # tlsKey are left unset; every container's readiness probe is a bare
    # TCP check, not conditioned on them being real (see git_source_
    # resolution.feature for where SSH/TLS actually get exercised).
    Given the value "git://test-git-server-test-git-server.<Namespace>.svc.cluster.local:9418" is known as "<GitUrl>"

    Given Docker Buildx Builder known as "<Builder>":
      | PROPERTY | VALUE                                                            |
      | name     | devcontainer-builder-config-discovery-w<WorkerId> |
      | endpoint | tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234 |
    When I create Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I build and push "ghcr.io/deepspacecartel/devcontainer-builder-test:test" from "." using Docker Buildx Builder known as "<Builder>" with:
      | OPTION | VALUE |
    Then the command exited with 0

    Given Directory "<ChartDirectory>" at "../charts/devcontainer-builder"
    And Helm Chart "<Chart>" in "<ChartDirectory>"
    And Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                              |
      | --install          | True                                                               |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test |
      | --set              | image.tag=test                                                     |
      | --set              | image.pullPolicy=Always                                            |
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                               |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0

    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"

  @client-request
  Scenario Outline: A devcontainer.json at the root or the standard .devcontainer/ location is found automatically
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                             |
      | BODY |     | {"repository":"<GitUrl>/location/<repo>.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | repo                       |
      | devcontainer-json-root     |
      | devcontainer-json-standard |

  @negative @client-request
  Scenario Outline: A devcontainer.json in a sub-folder is not found automatically - a known gap, not this service's own logic
    # The spec itself only says a sub-folder config MAY exist - it
    # deliberately leaves <folder>'s name unspecified, since a tool can't
    # know which of possibly several sub-folder configs to pick without
    # being told explicitly (the spec: "consider providing a mechanism for
    # users to select one when appropriate"). The devcontainer CLI reflects
    # exactly that: it auto-discovers only the root and standard
    # .devcontainer/devcontainer.json locations - a sub-folder config needs
    # an explicit --config <path>, which build.ts does not currently pass
    # (the /build request has no field for it). Three sub-folder names
    # prove this fails the same way regardless of which folder name is
    # used - it's not a naming mismatch, the location itself isn't checked.
    # The real "not found" text only ever reaches the pod's own stdout
    # (build.ts's run() uses stdio: "inherit"), never the HTTP response
    # body (which only ever gets "... exited with code 1") - so this needs
    # a real log check, not just a status/body assertion.
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                             |
      | BODY |     | {"repository":"<GitUrl>/location/<repo>.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 500:
      | SOURCE | CONDITION | VALUE               |
      | BODY   | contains  | exited with code 1  |
    When I poll logs for Pod known as "<AppPod>" every "1s" for up to "10s" until:
      | SOURCE | CONDITION | VALUE                 | OUTCOME |
      | STDOUT | contains  | Dev container config  | pass    |
      | STDOUT | contains  | not found             | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | repo                             |
      | devcontainer-json-subfolder-alpha |
      | devcontainer-json-subfolder-beta  |
      | devcontainer-json-subfolder-gamma |

  @negative @client-request
  Scenario: A repository with no devcontainer.json at any location fails clearly
    # Distinct from the sub-folder cases above: this repo has no config at
    # ANY of the three locations, not just an unchecked one - same CLI
    # error text either way, since "checked here, found nothing" and
    # "never checked here" are indistinguishable from the CLI's own output.
    # The distinction that matters is at the fixture level (see
    # devcontainer-json-missing in charts/test-git-server/values.yaml,
    # noConfig: true), proving this failure mode is reachable at all.
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                |
      | BODY |     | {"repository":"<GitUrl>/location/devcontainer-json-missing.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 500:
      | SOURCE | CONDITION | VALUE              |
      | BODY   | contains  | exited with code 1 |
    When I poll logs for Pod known as "<AppPod>" every "1s" for up to "10s" until:
      | SOURCE | CONDITION | VALUE                | OUTCOME |
      | STDOUT | contains  | Dev container config | pass    |
      | STDOUT | contains  | not found             | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0
