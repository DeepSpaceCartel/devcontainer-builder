Feature: Image name, tag, and registry resolution
  As a caller of devcontainer-builder
  I want sensible defaults for the pushed image reference
  So that I don't have to compute a registry, name, or tag myself for every build

  Runs real builds against a real git server and the anonymous test
  registry. Almost every scenario needs its own registryMapping.rules, so -
  unlike every other migrated file so far - the devcontainer-builder Helm
  Release itself is NOT in the Background; only the fixtures every
  scenario shares (test-registry, test-registry-authed, test-buildkit,
  test-git-server, this repo's own service image) are. gitCredentials
  stays disabled throughout (this file never needs git auth), so only
  registryMapping varies per scenario.

  A resolved image's exact sha suffix is a real, content-derived value
  this suite can't dictate (it depends on the seed commit's real
  timestamp) - rather than independently re-deriving it via a second git
  query (the old suite's `git ls-remote ... | cut -c1-7`), scenarios that
  need one compare a *prefix* (registry/name:sha-) via `contains`, which is
  exactly as precise for what's actually under test here (did resolution
  pick the right registry/name and correctly default to a sha-tag) without
  a second, independent fixture round-trip. Scenarios with a fully literal
  expected tag (no sha involved) compare with `equals` instead. Both use
  the new `the value known as ... {condition} ...` comparison (see
  docs/reference/REST.md) to compare the response's real resolved image
  against an expected value composed from <RegistryUrl>/<AuthedRegistryUrl>
  (namespace-dependent, so not writable as a fixed literal).

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

    When I create File known as "<AuthedRegistryValuesFile>" at ".cache/fixtures/image-resolution-w<WorkerId>/registry-authed-values.yaml" with:
      """
      auth:
        enabled: true
        username: svc-bot
        password: hunter2
      """
    Given Helm Release known as "<TestRegistryAuthedRelease>":
      | PROPERTY  | VALUE               |
      | chart     | <TestRegistryChart> |
      | name      | test-registry-authed |
      | namespace | <Namespace>         |
    When I upgrade Helm Release known as "<TestRegistryAuthedRelease>" with:
      | OPTION             | VALUE                                                       |
      | --install          | True                                                        |
      | -f                 | .cache/fixtures/image-resolution-w<WorkerId>/registry-authed-values.yaml |
      | --wait             | True                                                        |
      | --timeout          | 120s                                                        |
    Then the command exited with 0
    Given the value "test-registry-authed-test-registry.<Namespace>.svc.cluster.local:5000" is known as "<AuthedRegistryUrl>"

    When I create File known as "<BuildkitTrustFile>" at ".cache/fixtures/image-resolution-w<WorkerId>/buildkit-trust.toml" with:
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
      | OPTION             | VALUE                                                    |
      | --install          | True                                                     |
      | --set-file         | buildkitdToml=.cache/fixtures/image-resolution-w<WorkerId>/buildkit-trust.toml |
      | --wait             | True                                                     |
      | --timeout          | 180s                                                     |
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
    Given the value "test-git-server-test-git-server.<Namespace>.svc.cluster.local" is known as "<GitHost>"
    Given the value "git://test-git-server-test-git-server.<Namespace>.svc.cluster.local:9418" is known as "<GitUrl>"

    Given Docker Buildx Builder known as "<Builder>":
      | PROPERTY | VALUE                                                            |
      | name     | devcontainer-builder-image-resolution-w<WorkerId> |
      | endpoint | tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234 |
    When I create Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I build and push "ghcr.io/deepspacecartel/devcontainer-builder-test:test" from "." using Docker Buildx Builder known as "<Builder>" with:
      | OPTION | VALUE |
    Then the command exited with 0

    Given Directory "<ChartDirectory>" at "../charts/devcontainer-builder"
    And Helm Chart "<Chart>" in "<ChartDirectory>"

  @client-request
  Scenario: A fully-specified image target is used verbatim
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
      | TYPE | KEY | VALUE                                                                                                             |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>","name":"custom-name","tag":"v1.2.3"}} |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ActualImage>"
    Given the value "<RegistryUrl>/custom-name:v1.2.3" is known as "<ExpectedImage>"
    Then the value known as "<ActualImage>" equals "<ExpectedImage>"

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

  @server-config @client-request
  Scenario: Omitting image entirely derives registry, name, and tag
    When I create File known as "<MappingFile>" at ".cache/fixtures/image-resolution-w<WorkerId>/mapping-1.yaml" with:
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <RegistryUrl>
      """
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
      | -f                 | .cache/fixtures/image-resolution-w<WorkerId>/mapping-1.yaml                    |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                          |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git"}    |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ActualImage>"
    Given the value "<RegistryUrl>/example-devcontainer:sha-" is known as "<ExpectedImagePrefix>"
    Then the value known as "<ActualImage>" contains "<ExpectedImagePrefix>"

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
  Scenario: A partially-specified image target derives only the missing fields
    When I create File known as "<MappingFile>" at ".cache/fixtures/image-resolution-w<WorkerId>/mapping-2.yaml" with:
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <RegistryUrl>
      """
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
      | -f                 | .cache/fixtures/image-resolution-w<WorkerId>/mapping-2.yaml                    |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                              |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"name":"custom-name"}} |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ActualImage>"
    Given the value "<RegistryUrl>/custom-name:sha-" is known as "<ExpectedImagePrefix>"
    Then the value known as "<ActualImage>" contains "<ExpectedImagePrefix>"

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
  Scenario Outline: The derived name strips a trailing .git and uses the last path segment
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
      | TYPE | KEY | VALUE                                                                        |
      | BODY |     | {"repository":"<repository>","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ActualImage>"
    Given the value "<RegistryUrl>/<expected-name>:sha-" is known as "<ExpectedImagePrefix>"
    Then the value known as "<ActualImage>" contains "<ExpectedImagePrefix>"

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

    Examples:
      | repository                                     | expected-name         |
      | <GitUrl>/example/example-devcontainer.git      | example-devcontainer  |
      | <GitUrl>/example/sub/example-devcontainer      | example-devcontainer  |
      | <GitUrl>/solo-repo.git                         | solo-repo             |

  @server-config
  Scenario: A registry mapping rule matching on hostMatch only applies to any path on that host
    When I create File known as "<MappingFile>" at ".cache/fixtures/image-resolution-w<WorkerId>/mapping-3.yaml" with:
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - hostMatch: <GitHost>
            registry: <RegistryUrl>
      """
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
      | -f                 | .cache/fixtures/image-resolution-w<WorkerId>/mapping-3.yaml                    |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                       |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git"} |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ActualImage>"
    Given the value "<RegistryUrl>/example-devcontainer:sha-" is known as "<ExpectedImagePrefix>"
    Then the value known as "<ActualImage>" contains "<ExpectedImagePrefix>"

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

  @server-config
  Scenario: A registry mapping rule matching on pathPrefix only applies regardless of host
    When I create File known as "<MappingFile>" at ".cache/fixtures/image-resolution-w<WorkerId>/mapping-4.yaml" with:
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <RegistryUrl>
      """
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
      | -f                 | .cache/fixtures/image-resolution-w<WorkerId>/mapping-4.yaml                    |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                       |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git"} |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ActualImage>"
    Given the value "<RegistryUrl>/example-devcontainer:sha-" is known as "<ExpectedImagePrefix>"
    Then the value known as "<ActualImage>" contains "<ExpectedImagePrefix>"

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

  @server-config
  Scenario: A rule with neither hostMatch nor pathPrefix is a universal fallback
    When I create File known as "<MappingFile>" at ".cache/fixtures/image-resolution-w<WorkerId>/mapping-5.yaml" with:
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - registry: <RegistryUrl>
      """
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
      | -f                 | .cache/fixtures/image-resolution-w<WorkerId>/mapping-5.yaml                    |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                       |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git"} |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ActualImage>"
    Given the value "<RegistryUrl>/example-devcontainer:sha-" is known as "<ExpectedImagePrefix>"
    Then the value known as "<ActualImage>" contains "<ExpectedImagePrefix>"

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

  @server-config
  Scenario: The first matching rule wins when more than one rule matches
    When I create File known as "<MappingFile>" at ".cache/fixtures/image-resolution-w<WorkerId>/mapping-6.yaml" with:
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <RegistryUrl>
          - registry: <AuthedRegistryUrl>
      """
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
      | -f                 | .cache/fixtures/image-resolution-w<WorkerId>/mapping-6.yaml                    |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                       |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git"} |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ActualImage>"
    Given the value "<RegistryUrl>/example-devcontainer:sha-" is known as "<ExpectedImagePrefix>"
    Then the value known as "<ActualImage>" contains "<ExpectedImagePrefix>"

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
  Scenario: An explicit image.registry wins over a matching registry mapping rule
    When I create File known as "<MappingFile>" at ".cache/fixtures/image-resolution-w<WorkerId>/mapping-7.yaml" with:
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <AuthedRegistryUrl>
      """
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
      | -f                 | .cache/fixtures/image-resolution-w<WorkerId>/mapping-7.yaml                    |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                    |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ActualImage>"
    Given the value "<RegistryUrl>/example-devcontainer:sha-" is known as "<ExpectedImagePrefix>"
    Then the value known as "<ActualImage>" contains "<ExpectedImagePrefix>"

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
  Scenario: No image.registry given and no rule matches is a 400, not a 500
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
      | TYPE | KEY | VALUE                                                       |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git"} |
    Then the response status is 400:
      | SOURCE | CONDITION | VALUE                            |
      | BODY   | contains  | no registry resolved for repository |

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

  @negative @server-config
  Scenario: A non-matching registry mapping rule does not accidentally apply
    When I create File known as "<MappingFile>" at ".cache/fixtures/image-resolution-w<WorkerId>/mapping-8.yaml" with:
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - hostMatch: gitlab.internal.example.com
            registry: <RegistryUrl>
      """
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
      | -f                 | .cache/fixtures/image-resolution-w<WorkerId>/mapping-8.yaml                    |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                       |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git"} |
    Then the response status is 400

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
