Feature: Registry push authentication
  As a caller of devcontainer-builder
  I want to optionally supply my own registry push credentials
  So that I'm not limited to whatever the service's ambient registry auth covers

  Runs against two real registry fixtures: an anonymous one that accepts any
  push, and one that enforces HTTP basic auth (htpasswd) - only the latter
  can actually distinguish "right credentials" from "wrong/no credentials",
  which is what most of these scenarios are really testing. Same fixture
  shape as image_resolution.feature (its own test-registry +
  test-registry-authed + trust-configured test-buildkit + anonymous
  test-git-server); the devcontainer-builder Release again lives per
  Scenario, not Background, since "ambient registry auth" varies.

  "ambient registry auth not configured" is the chart's own default
  (registryAuth.registries defaults to an empty list, rendering
  {"auths":{}}), so most scenarios need no special config beyond the
  shared image/buildkit setup. Only the "correct ambient auth" scenario
  needs real ambient credentials - the same fixed "svc-bot"/"hunter2"
  test-registry-authed itself is configured with in Background, set
  directly as registryAuth.registries[0].username/password - the chart
  builds the real dockerconfigjson itself, no hand-built/pre-base64'd
  value needed.

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
      | PROPERTY  | VALUE               |
      | chart     | <TestRegistryChart> |
      | name      | test-registry       |
      | namespace | <Namespace>         |
    When I upgrade Helm Release known as "<TestRegistryRelease>" with:
      | OPTION             | VALUE |
      | --install          | True  |
      | --wait              | True  |
      | --timeout           | 120s  |
    Then the command exited with 0
    Given the value "test-registry-test-registry.<Namespace>.svc.cluster.local:5000" is known as "<RegistryUrl>"

    When I create File known as "<AuthedRegistryValuesFile>" at ".cache/fixtures/registry-auth-w<WorkerId>/registry-authed-values.yaml" with:
      """
      auth:
        enabled: true
        username: svc-bot
        password: hunter2
      """
    Given Helm Release known as "<TestRegistryAuthedRelease>":
      | PROPERTY  | VALUE                |
      | chart     | <TestRegistryChart>  |
      | name      | test-registry-authed |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<TestRegistryAuthedRelease>" with:
      | OPTION             | VALUE                                                    |
      | --install          | True                                                     |
      | -f                 | .cache/fixtures/registry-auth-w<WorkerId>/registry-authed-values.yaml |
      | --wait             | True                                                     |
      | --timeout          | 120s                                                     |
    Then the command exited with 0
    Given the value "test-registry-authed-test-registry.<Namespace>.svc.cluster.local:5000" is known as "<AuthedRegistryUrl>"

    When I create File known as "<BuildkitTrustFile>" at ".cache/fixtures/registry-auth-w<WorkerId>/buildkit-trust.toml" with:
      """
      [registry."test-registry-test-registry.<Namespace>.svc.cluster.local:5000"]
        http = true
        insecure = true
      [registry."test-registry-authed-test-registry.<Namespace>.svc.cluster.local:5000"]
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
      | OPTION             | VALUE                                                            |
      | --install          | True                                                             |
      | --set-file         | buildkitdToml=.cache/fixtures/registry-auth-w<WorkerId>/buildkit-trust.toml |
      | --wait             | True                                                             |
      | --timeout          | 180s                                                             |
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
      | name     | devcontainer-builder-registry-auth-w<WorkerId> |
      | endpoint | tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234 |
    When I create Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I build and push "ghcr.io/deepspacecartel/devcontainer-builder-test:test" from "." using Docker Buildx Builder known as "<Builder>" with:
      | OPTION | VALUE |
    Then the command exited with 0

    Given Directory "<ChartDirectory>" at "../charts/devcontainer-builder"
    And Helm Chart "<Chart>" in "<ChartDirectory>"

  @client-request
  Scenario: No credentials at all succeed against a registry that doesn't require auth
    Given Helm Release known as "<Release>":
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
      | --set              | gitCredentials.enabled=false                                       |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                            |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @client-request
  Scenario: Correct ambient registry auth succeeds against an auth-enforcing registry
    Given Helm Release known as "<Release>":
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
      | --set              | gitCredentials.enabled=false                                       |
      | --set              | registryAuth.registries[0].registry=<AuthedRegistryUrl>            |
      | --set              | registryAuth.registries[0].username=svc-bot                       |
      | --set              | registryAuth.registries[0].password=hunter2                       |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                 |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<AuthedRegistryUrl>"}} |
    Then the response status is 200

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @client-request
  Scenario: No ambient registry auth and no registryCredentials fails against an auth-enforcing registry
    Given Helm Release known as "<Release>":
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
      | --set              | gitCredentials.enabled=false                                       |
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

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                 |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<AuthedRegistryUrl>"}} |
    Then the response status is 500
    When I poll logs for Pod known as "<AppPod>" every "1s" for up to "10s" until:
      | SOURCE | CONDITION | VALUE | OUTCOME |
      | STDOUT | contains  | 401   | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @client-request
  Scenario: Correct registryCredentials succeed against an auth-enforcing registry with no ambient auth
    Given Helm Release known as "<Release>":
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
      | --set              | gitCredentials.enabled=false                                       |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                                                                                    |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<AuthedRegistryUrl>"},"registryCredentials":{"registry":"<AuthedRegistryUrl>","username":"svc-bot","password":"hunter2"}} |
    Then the response status is 200

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @client-request
  Scenario: Wrong registryCredentials fail against an auth-enforcing registry
    Given Helm Release known as "<Release>":
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
      | --set              | gitCredentials.enabled=false                                       |
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

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                                                                                           |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<AuthedRegistryUrl>"},"registryCredentials":{"registry":"<AuthedRegistryUrl>","username":"svc-bot","password":"wrong-password"}} |
    Then the response status is 500
    When I poll logs for Pod known as "<AppPod>" every "1s" for up to "10s" until:
      | SOURCE | CONDITION | VALUE | OUTCOME |
      | STDOUT | contains  | 401   | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @client-request
  Scenario: registryCredentials for a different registry than image.registry have no effect on the actual push
    Given Helm Release known as "<Release>":
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
      | --set              | gitCredentials.enabled=false                                       |
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

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                                                                          |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<AuthedRegistryUrl>"},"registryCredentials":{"registry":"<RegistryUrl>","username":"svc-bot","password":"hunter2"}} |
    Then the response status is 500
    When I poll logs for Pod known as "<AppPod>" every "1s" for up to "10s" until:
      | SOURCE | CONDITION | VALUE | OUTCOME |
      | STDOUT | contains  | 401   | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  Scenario: A registry-credentialed build against one registry and a plain build against another both succeed back to back
    # Regression anchor for the seed-from-ambient-DOCKER_CONFIG design: a
    # per-request registryCredentials override must not corrupt or replace
    # the ambient/buildx state that a later, differently-targeted request
    # relies on. Only observable from outside as "both requests still
    # work" - internal buildx builder reuse isn't visible over HTTP.
    Given Helm Release known as "<Release>":
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
      | --set              | gitCredentials.enabled=false                                       |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                                                                                    |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<AuthedRegistryUrl>"},"registryCredentials":{"registry":"<AuthedRegistryUrl>","username":"svc-bot","password":"hunter2"}} |
    Then the response status is 200
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                            |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0
