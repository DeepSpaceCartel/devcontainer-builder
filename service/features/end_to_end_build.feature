@smoke
Feature: End-to-end build scenarios
  As a maintainer of devcontainer-builder
  I want a small set of full request/response round trips covering several axes at once
  So that a regression touching more than one area is caught by a single scenario

  These complement the narrowly-scoped scenarios in the other feature
  files; they intentionally combine several resolution axes in one
  request rather than isolating a single one. "Ambient registry auth not
  configured" is the chart's own default (`registryAuth.registries`
  defaults to an empty list, rendering `{"auths":{}}`), so scenarios that
  want that need no extra config. A resolved image's exact sha suffix is
  real and content-derived (see the other migrated files' own header
  comments for why this suite compares a `<registry>/<name>:sha-`
  *prefix* via
  `contains` rather than independently re-deriving the exact sha) - the
  one exception is the "non-default branch" scenario below, where the
  exact sha is genuinely the point; proving that without a second,
  independent git query uses a different, more direct proof (see that
  scenario's own comment).

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

    When I create File known as "<AuthedRegistryValuesFile>" at ".cache/fixtures/end-to-end-build-w<WorkerId>/registry-authed-values.yaml" with:
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
      | OPTION             | VALUE                                                             |
      | --install          | True                                                              |
      | -f                 | .cache/fixtures/end-to-end-build-w<WorkerId>/registry-authed-values.yaml      |
      | --wait             | True                                                              |
      | --timeout          | 120s                                                              |
    Then the command exited with 0
    Given the value "test-registry-authed-test-registry.<Namespace>.svc.cluster.local:5000" is known as "<AuthedRegistryUrl>"

    When I create File known as "<BuildkitTrustFile>" at ".cache/fixtures/end-to-end-build-w<WorkerId>/buildkit-trust.toml" with:
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
      | OPTION             | VALUE                                                               |
      | --install          | True                                                                |
      | --set-file         | buildkitdToml=.cache/fixtures/end-to-end-build-w<WorkerId>/buildkit-trust.toml |
      | --wait             | True                                                                |
      | --timeout          | 180s                                                                |
    Then the command exited with 0
    Given the value "tcp://test-buildkit-buildkit-service.<Namespace>.svc.cluster.local:1234" is known as "<BuildkitEndpoint>"

    # A real authorized keypair this time (unlike most other migrated
    # files' deliberately-unauthorized ones) - "server-configured SSH
    # default" below needs a real, working clone to prove resolution
    # actually completed, not just that it reached authentication.
    When I create Directory known as "<AuthorizedKeyPairDirectory>" at ".cache/fixtures/end-to-end-build-w<WorkerId>/git-ssh-authorized"
    And I generate SSH Key Pair known as "<AuthorizedKeyPair>" in Directory known as "<AuthorizedKeyPairDirectory>" with:
      | OPTION | VALUE                                                        |
      | -t     | ed25519                                                      |
      | -f     | .cache/fixtures/end-to-end-build-w<WorkerId>/git-ssh-authorized/id_ed25519 |
      | -N     |                                                              |
      | -C     | devcontainer-builder-test                                    |
    Then the command exited with 0
    Given the content of file at ".cache/fixtures/end-to-end-build-w<WorkerId>/git-ssh-authorized/id_ed25519.pub" is known as "<AuthorizedPublicKeyContent>"

    Given Directory "<GitServerChartDir>" at "../charts/test-git-server"
    And Helm Chart "<GitServerChart>" in "<GitServerChartDir>"
    And Helm Release known as "<GitServerRelease>":
      | PROPERTY  | VALUE            |
      | chart     | <GitServerChart> |
      | name      | test-git-server  |
      | namespace | <Namespace>      |
    When I upgrade Helm Release known as "<GitServerRelease>" with:
      | OPTION             | VALUE                                          |
      | --install          | True                                           |
      | --set-string        | sshAuthorizedKey=<AuthorizedPublicKeyContent> |
      | --wait              | True                                           |
      | --timeout           | 180s                                           |
    Then the command exited with 0
    Given the value "test-git-server-test-git-server.<Namespace>.svc.cluster.local" is known as "<GitHost>"
    Given the value "git://test-git-server-test-git-server.<Namespace>.svc.cluster.local:9418" is known as "<GitUrl>"

    Given Docker Buildx Builder known as "<Builder>":
      | PROPERTY | VALUE                                                            |
      | name     | devcontainer-builder-e2e-w<WorkerId> |
      | endpoint | tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234 |
    When I create Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I build and push "ghcr.io/deepspacecartel/devcontainer-builder-test:test" from "." using Docker Buildx Builder known as "<Builder>" with:
      | OPTION | VALUE |
    Then the command exited with 0

    Given Directory "<ChartDirectory>" at "../charts/devcontainer-builder"
    And Helm Chart "<Chart>" in "<ChartDirectory>"

  Scenario: A fully server-resolved bare request derives everything
    When I create File known as "<MappingFile>" at ".cache/fixtures/end-to-end-build-w<WorkerId>/mapping-1.yaml" with:
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
      | -f                 | .cache/fixtures/end-to-end-build-w<WorkerId>/mapping-1.yaml                    |
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

  Scenario: A fully caller-specified request wins over a server default it could have used
    When I create File known as "<MappingFile>" at ".cache/fixtures/end-to-end-build-w<WorkerId>/mapping-2.yaml" with:
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
      | -f                 | .cache/fixtures/end-to-end-build-w<WorkerId>/mapping-2.yaml                    |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                                                                                                       |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","branch":"release","image":{"registry":"<AuthedRegistryUrl>","name":"custom-name","tag":"v9.9.9"},"registryCredentials":{"registry":"<AuthedRegistryUrl>","username":"svc-bot","password":"hunter2"}} |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ActualImage>"
    Given the value "<AuthedRegistryUrl>/custom-name:v9.9.9" is known as "<ExpectedImage>"
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

  Scenario: Server-resolved registry composes with request-supplied credentials for it
    When I create File known as "<MappingFile>" at ".cache/fixtures/end-to-end-build-w<WorkerId>/mapping-3.yaml" with:
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
      | -f                 | .cache/fixtures/end-to-end-build-w<WorkerId>/mapping-3.yaml                    |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                                        |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","registryCredentials":{"registry":"<AuthedRegistryUrl>","username":"svc-bot","password":"hunter2"}} |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ActualImage>"
    Given the value "<AuthedRegistryUrl>/example-devcontainer:sha-" is known as "<ExpectedImagePrefix>"
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

  Scenario: A server-configured SSH default combines with a registry mapping rule
    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                                              |
      | --install          | True                                                                               |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                 |
      | --set              | image.tag=test                                                                     |
      | --set              | image.pullPolicy=Always                                                            |
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                                               |
      | --set              | gitCredentials.entries[0].host=<GitHost>                                           |
      | --set              | gitCredentials.entries[0].kind=ssh                                                |
      | --set-file         | gitCredentials.entries[0].privateKey=.cache/fixtures/end-to-end-build-w<WorkerId>/git-ssh-authorized/id_ed25519 |
      | --set              | sshHostKeyPolicy=tofu                                                              |
      | --set              | registryMapping.rules[0].pathPrefix=example/                                       |
      | --set              | registryMapping.rules[0].registry=<RegistryUrl>                                    |
      | --wait             | True                                                                               |
      | --timeout          | 120s                                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                            |
      | BODY |     | {"repository":"https://<GitHost>/example/example-devcontainer.git"} |
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

  Scenario: A non-default branch is actually checked out, not silently ignored
    # Old approach (independently fetching "release"'s own real sha via
    # git ls-remote to compare against) would have needed a new, narrowly-
    # scoped "discover a real git ref" Thomas capability for exactly one
    # scenario in this whole migration - not obviously worth it. A more
    # direct, self-contained proof needs no second git round trip at all:
    # build the SAME repo twice, once on each branch, and assert the two
    # real resolved image tags differ. Since both branches share
    # byte-identical devcontainer.json content (see charts/test-git-server/
    # values.yaml's extraBranches comment) and the only per-build-varying
    # part of the tag is the real, content-derived sha, two DIFFERENT
    # real tags is already direct, sufficient proof `branch` was honored -
    # if it were silently ignored (always building "main"), both requests
    # would resolve to the exact same real tag.
    When I create File known as "<MappingFile>" at ".cache/fixtures/end-to-end-build-w<WorkerId>/mapping-5.yaml" with:
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
      | -f                 | .cache/fixtures/end-to-end-build-w<WorkerId>/mapping-5.yaml                    |
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
    Given the value at "image" from the last response is known as "<MainImage>"
    Given the value "<RegistryUrl>/example-devcontainer:sha-" is known as "<ExpectedImagePrefix>"
    Then the value known as "<MainImage>" contains "<ExpectedImagePrefix>"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                             |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","branch":"release"}    |
    Then the response status is 200
    Given the value at "image" from the last response is known as "<ReleaseImage>"
    Then the value known as "<ReleaseImage>" contains "<ExpectedImagePrefix>"
    Then the value known as "<ReleaseImage>" not_equals "<MainImage>"

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

  @negative
  Scenario: A failing clone surfaces its real underlying error end to end
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
      | TYPE | KEY | VALUE                                                                                                                                          |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","branch":"does-not-exist","image":{"registry":"<RegistryUrl>","name":"custom-name","tag":"v1.0.0"}} |
    Then the response status is 500:
      | SOURCE | CONDITION | VALUE                                                              |
      | BODY   | contains  | git clone --branch does-not-exist --single-branch --depth 1       |

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
