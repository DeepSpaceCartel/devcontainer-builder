Feature: devcontainer.json discovery after clone
  As an operator of devcontainer-builder
  I want the service to find devcontainer.json wherever the containers.dev spec allows it to live
  So that callers aren't forced into one specific repo layout

  See https://containers.dev/implementors/spec/#devcontainerjson - it
  recognizes three locations, in precedence order: .devcontainer/
  devcontainer.json, .devcontainer.json, and .devcontainer/<folder>/
  devcontainer.json (one sub-folder deep, <folder>'s name unspecified).
  The service builds one image per config it finds (ADR-0016): the root
  one as "main", each sub-folder one as an item named after its folder,
  listed in the response's `images`. test-git-server seeds one real repo
  per location, plus repos with several configs (see
  charts/test-git-server/values.yaml's devcontainer-json-* entries) -
  these are real builds, so "success" means the devcontainer CLI actually
  found and used the config, not an inferred signal. Every seed repo in
  this feature shares byte-identical devcontainer.json content - only its
  location differs - so what matters is the list of items and their
  names (image *content* correctness is image_resolution.feature's own,
  separate concern). The service runs without a fallbackImage here, so a
  repository with no config at all is an error rather than a fallback
  build - except in the one scenario that turns it on.

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
      | --set              | extraEnv[0].name=ALLOW_INSECURE_GIT_PROTOCOLS                      |
      | --set-string       | extraEnv[0].value=true                                             |
      | --set-string       | build.fallbackImage=                                               |
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
  Scenario Outline: A devcontainer.json at the root or the standard .devcontainer/ location is the main image
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                             |
      | BODY |     | {"repository":"<GitUrl>/location/<repo>.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200
    Given the value at "join(',', images[*].id)" from the last response is known as "<Ids>"
    Then the value known as "<Ids>" equals "main"
    Given the value at "images[0].configPath" from the last response is known as "<ConfigPath>"
    Then the value known as "<ConfigPath>" equals "<configPath>"
    # The single-image fields every 1.x caller reads are images[0], named
    # exactly as before this list existed.
    Given the value at "name" from the last response is known as "<Name>"
    Then the value known as "<Name>" equals "<repo>"
    Given the value at "images[0].image" from the last response is known as "<ItemImage>"
    Given the value at "image" from the last response is known as "<TopImage>"
    Then the value known as "<TopImage>" equals "<ItemImage>"

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
      | repo                       | configPath                      |
      | devcontainer-json-root     | .devcontainer.json              |
      | devcontainer-json-standard | .devcontainer/devcontainer.json |

  @client-request
  Scenario Outline: A devcontainer.json in a sub-folder is built with --config, as an image named after the folder
    # The devcontainer CLI only finds the root and standard locations on
    # its own; a sub-folder config needs an explicit --config <path>,
    # which the service passes for each one it finds (ADR-0016). Three
    # folder names prove discovery isn't tied to a particular one. A
    # sub-folder item's image name gets "-<id>" appended; with no root
    # config, it's also the first item, so the single-image fields
    # describe it.
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                             |
      | BODY |     | {"repository":"<GitUrl>/location/<repo>.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200
    Given the value at "join(',', images[*].id)" from the last response is known as "<Ids>"
    Then the value known as "<Ids>" equals "<folder>"
    Given the value at "images[0].configPath" from the last response is known as "<ConfigPath>"
    Then the value known as "<ConfigPath>" equals ".devcontainer/<folder>/devcontainer.json"
    Given the value at "name" from the last response is known as "<Name>"
    Then the value known as "<Name>" equals "<repo>-<folder>"

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
      | repo                              | folder |
      | devcontainer-json-subfolder-alpha | alpha  |
      | devcontainer-json-subfolder-beta  | beta   |
      | devcontainer-json-subfolder-gamma | gamma  |

  @client-request
  Scenario: Every devcontainer.json in a repository becomes its own pushed image
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                      |
      | BODY |     | {"repository":"<GitUrl>/location/devcontainer-json-root-and-folder.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200
    Given the value at "join(',', images[*].id)" from the last response is known as "<Ids>"
    Then the value known as "<Ids>" equals "main,tools"
    Given the value at "name" from the last response is known as "<MainName>"
    Then the value known as "<MainName>" equals "devcontainer-json-root-and-folder"
    Given the value at "images[1].name" from the last response is known as "<ToolsName>"
    Then the value known as "<ToolsName>" equals "devcontainer-json-root-and-folder-tools"
    Given the value at "images[1].imageBuildLogId" from the last response is known as "<ToolsLogId>"
    Given the value at "tag" from the last response is known as "<Tag>"

    When I send a GET request to Endpoint known as "<AppApi>" path "/image" with:
      | TYPE  | KEY      | VALUE                                   |
      | QUERY | registry | <RegistryUrl>                           |
      | QUERY | name     | devcontainer-json-root-and-folder-tools |
      | QUERY | tag      | <Tag>                                   |
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE           |
      | BODY   | contains  | "exists":true   |
    When I send a GET request to Endpoint known as "<AppApi>" path "/logs/<ToolsLogId>"
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE                                                 |
      | BODY   | contains  | building "tools" from .devcontainer/tools/devcontainer.json |

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
  Scenario: Sub-folder items without a root config are sorted by id, and instances picks some
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                         |
      | BODY |     | {"repository":"<GitUrl>/location/devcontainer-json-two-folders.git","image":{"registry":"<RegistryUrl>"},"instances":["frontend"]} |
    Then the response status is 200
    Given the value at "join(',', images[*].id)" from the last response is known as "<Ids>"
    Then the value known as "<Ids>" equals "frontend"
    Given the value at "name" from the last response is known as "<Name>"
    Then the value known as "<Name>" equals "devcontainer-json-two-folders-frontend"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                          |
      | BODY |     | {"repository":"<GitUrl>/location/devcontainer-json-two-folders.git","image":{"registry":"<RegistryUrl>"},"dryRun":true} |
    Then the response status is 200
    Given the value at "join(',', images[*].id)" from the last response is known as "<AllIds>"
    Then the value known as "<AllIds>" equals "backend,frontend"

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
  Scenario: A dry run returns the list with its image names, and pushes nothing
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                      |
      | BODY |     | {"repository":"<GitUrl>/location/devcontainer-json-root-and-folder.git","image":{"registry":"<RegistryUrl>"},"dryRun":true} |
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE           |
      | BODY   | contains  | "id":"main"     |
      | BODY   | contains  | "id":"tools"    |
    Given the value at "images[1].image" from the last response is known as "<ToolsImage>"
    Then the value known as "<ToolsImage>" contains "<RegistryUrl>/devcontainer-json-root-and-folder-tools:sha-"
    Given the value at "tag" from the last response is known as "<Tag>"
    Given the value at "imageBuildLogId || images[0].imageBuildLogId || images[1].imageBuildLogId || 'none'" from the last response is known as "<BuildLogId>"
    Then the value known as "<BuildLogId>" equals "none"

    When I send a GET request to Endpoint known as "<AppApi>" path "/image" with:
      | TYPE  | KEY      | VALUE                                   |
      | QUERY | registry | <RegistryUrl>                           |
      | QUERY | name     | devcontainer-json-root-and-folder-tools |
      | QUERY | tag      | <Tag>                                   |
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE            |
      | BODY   | contains  | "exists":false   |

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
  Scenario Outline: A list the service can't build is a 400 before anything is built
    # The Background deploys without a fallbackImage, so a repository with
    # no devcontainer.json anywhere is a request problem too.
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                       |
      | BODY |     | {"repository":"<GitUrl>/location/<repo>.git","image":{"registry":"<RegistryUrl>"}<extra>} |
    Then the response status is 400:
      | SOURCE | CONDITION | VALUE   |
      | BODY   | contains  | <error> |

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
      | repo                                | extra                 | error                                                                  |
      | devcontainer-json-root-and-folder   | ,"instances":["nope"] | unknown instance id(s) \\"nope\\" - this repository has: \\"main\\", \\"tools\\" |
      | devcontainer-json-colliding-folders |                       | map to the same instance id: \\"back-end\\"                              |
      | devcontainer-json-missing           |                       | no devcontainer.json found in repository                               |

  @client-request
  Scenario: With a fallbackImage, a repository without any devcontainer.json is a single main item
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION         | VALUE                                                         |
      | --reuse-values | True                                                          |
      | --set          | build.fallbackImage=mcr.microsoft.com/devcontainers/base:alpine-3.20 |
      | --wait         | True                                                          |
      | --timeout      | 120s                                                          |
    Then the command exited with 0
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                              |
      | BODY |     | {"repository":"<GitUrl>/location/devcontainer-json-missing.git","image":{"registry":"<RegistryUrl>"},"dryRun":true} |
    Then the response status is 200
    Given the value at "join(',', images[*].id)" from the last response is known as "<Ids>"
    Then the value known as "<Ids>" equals "main"
    Given the value at "images[0].configPath" from the last response is known as "<ConfigPath>"
    Then the value known as "<ConfigPath>" equals ".devcontainer/devcontainer.json"

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
