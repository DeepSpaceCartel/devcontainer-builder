Feature: devcontainer.json content validity, once it's been found
  As an operator of devcontainer-builder
  I want a build to fail clearly when a devcontainer.json is discoverable but unusable
  So that "found the file" and "could actually build from it" aren't confused

  Distinct from devcontainer_config_discovery.feature, which is only about
  *where* the file lives - every repo here has its devcontainer.json at the
  plain root location, found without ambiguity. What's under test is
  whether its *content* is enough to build anything, including the
  alternate "build": {"dockerfile": ...} shape (every other fixture repo in
  this suite uses a plain "image" reference instead - a materially
  different real path through the devcontainer CLI and BuildKit). Same
  fixture shape as devcontainer_config_discovery.feature (its own dedicated
  trust-configured test-buildkit + disposable test-registry, anonymous
  git:// only) - see that file's own header comment for why that's safe
  here (nothing built against test-registry is ever pulled by kubelet).

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
      | PROPERTY  | VALUE                |
      | chart     | <TestRegistryChart>  |
      | name      | test-registry        |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<TestRegistryRelease>" with:
      | OPTION             | VALUE |
      | --install          | True  |
      | --wait              | True  |
      | --timeout           | 120s  |
    Then the command exited with 0
    Given the value "test-registry-test-registry.<Namespace>.svc.cluster.local:5000" is known as "<RegistryUrl>"

    When I create File known as "<BuildkitTrustFile>" at ".cache/fixtures/devcontainer-config-content-w<WorkerId>/buildkit-trust.toml" with:
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
      | PROPERTY  | VALUE           |
      | chart     | <BuildkitChart> |
      | name      | test-buildkit   |
      | namespace | <Namespace>     |
    When I upgrade Helm Release known as "<TestBuildkitRelease>" with:
      | OPTION             | VALUE                                                                        |
      | --install          | True                                                                         |
      | --set-file         | buildkitdToml=.cache/fixtures/devcontainer-config-content-w<WorkerId>/buildkit-trust.toml |
      | --wait             | True                                                                         |
      | --timeout          | 180s                                                                         |
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
    # Anonymous git:// protocol only - see devcontainer_config_discovery.feature's
    # own Background comment for why SSH/TLS values are left unset here.
    Given the value "git://test-git-server-test-git-server.<Namespace>.svc.cluster.local:9418" is known as "<GitUrl>"

    Given Docker Buildx Builder known as "<Builder>":
      | PROPERTY | VALUE                                                            |
      | name     | devcontainer-builder-config-content-w<WorkerId> |
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

  @negative @client-request
  Scenario: A syntactically valid but empty devcontainer.json fails clearly
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                          |
      | BODY |     | {"repository":"<GitUrl>/location/devcontainer-json-empty-config.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 500:
      | SOURCE | CONDITION | VALUE              |
      | BODY   | contains  | exited with code 1 |
    Given the value at "logId" from the last response is known as "<LogId>"
    When I send a GET request to Endpoint known as "<AppApi>" path "/logs/<LogId>"
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE                                                |
      | BODY   | contains  | No image information specified in devcontainer.json |

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

  @negative @client-request
  Scenario: A devcontainer.json referencing a Dockerfile that was never seeded fails clearly
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                 |
      | BODY |     | {"repository":"<GitUrl>/location/devcontainer-json-missing-dockerfile.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 500:
      | SOURCE | CONDITION | VALUE              |
      | BODY   | contains  | exited with code 1 |
    Given the value at "logId" from the last response is known as "<LogId>"
    When I send a GET request to Endpoint known as "<AppApi>" path "/logs/<LogId>"
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE                     |
      | BODY   | contains  | no such file or directory |
      | BODY   | contains  | Dockerfile                 |

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

  @client-request
  Scenario: A devcontainer.json using "build": {"dockerfile": ...} with a real Dockerfile succeeds
    # Distinct real path through the devcontainer CLI/BuildKit from every
    # other fixture repo in this suite (a plain "image" reference) - proves
    # the Dockerfile-build shape works end to end, not just that a valid
    # devcontainer.json exists. The exact resolved image tag isn't asserted
    # here (see devcontainer_config_discovery.feature's own header comment
    # for why) - a 200 is already direct proof the Dockerfile build path
    # succeeded; tag/registry correctness is image_resolution.feature's
    # own, separate concern.
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                |
      | BODY |     | {"repository":"<GitUrl>/location/devcontainer-json-dockerfile-build.git","image":{"registry":"<RegistryUrl>"}} |
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
