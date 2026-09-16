Feature: POST /build request shape validation
  As a caller of the devcontainer-builder API
  I want a clear 400 for a malformed request
  So that I can distinguish "my request was wrong" from "the build failed"

  This feature only covers the up-front shape check performed before any
  clone/build work starts (server.ts's isValidBuildRequest). It does not
  cover whether the *values* given are usable (unparseable git URLs,
  unresolvable registries, etc.) - see git_source_resolution.feature and
  image_resolution.feature for that. Scenarios documenting that a request
  "passes validation" deliberately use a nonexistent local file:// path as
  the repository, so the real clone attempt that follows fails fast and
  deterministically with no network dependency - src/server.ts's own
  catch-all turns any such downstream failure into a real 500, so "the
  response status is 500" here is real, direct proof shape validation let
  the request through, not a workaround for a missing assertion.

  Every scenario shares the exact same server configuration (unlike
  health.feature, where server config itself is what varies) - the Helm
  bring-up lives in the Background, which Cucumber reruns fresh (with a
  fresh World) before every scenario, and every scenario tears its own
  Release/Builder back down at its own end - there is no "run once for the
  whole file" construct in Gherkin.

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
    Then the command exited with 0

    Given Docker Buildx Builder known as "<Builder>":
      | PROPERTY | VALUE                                                            |
      | name     | devcontainer-builder-request-validation-w<WorkerId> |
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
      | --set              | buildkit.endpoint=tcp://buildkit.example:1234                     |
      | --wait             | True                                                               |
      | --timeout          | 90s                                                                |
    Then the command exited with 0

    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

  @negative
  Scenario: A malformed JSON body is rejected
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                     |
      | BODY |     | { this is not valid JSON |
    Then the response status is 400:
      | SOURCE | CONDITION | VALUE                         |
      | BODY   | equals    | {"error":"invalid JSON body"} |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative
  Scenario Outline: A well-formed but non-object JSON body is rejected
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE  |
      | BODY |     | <body> |
    Then the response status is 400

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | body       |
      | []         |
      | "a string" |
      | 42         |
      | true       |
      | null       |

  @negative @client-request
  Scenario: Missing repository is rejected
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE |
      | BODY |     | {}    |
    Then the response status is 400:
      | SOURCE | CONDITION | VALUE |
      | BODY   | equals    | {"error":"missing or invalid fields: repository (required); branch, image.{registry,name,tag}, gitCredentials.{username,token}, registryCredentials.{registry,username,password}, platforms, buildOptions.{noCache,cacheFrom,cacheTo,mode} (all optional)"} |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @client-request
  Scenario: Empty-string repository is rejected
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE              |
      | BODY |     | {"repository":""}  |
    Then the response status is 400

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @client-request
  Scenario: repository alone is a valid request shape
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                  |
      | BODY |     | {"repository":"file:///nonexistent-repo-for-validation-tests.git"}    |
    Then the response status is 500

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @client-request
  Scenario: An empty-string branch is rejected
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                              |
      | BODY |     | {"repository":"https://github.com/example/example-devcontainer.git","branch":""} |
    Then the response status is 400

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @client-request
  Scenario: An omitted branch is a valid request shape
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                               |
      | BODY |     | {"repository":"file:///nonexistent-repo-for-validation-tests.git"} |
    Then the response status is 500

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @client-request
  Scenario Outline: A null value for an optional image field is treated as "not provided"
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                               |
      | BODY |     | {"repository":"file:///nonexistent-repo-for-validation-tests.git","image":<image>}  |
    Then the response status is 500

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | image                                     |
      | {"registry":null,"name":null,"tag":null}  |
      | {"registry":"ghcr.io/example","name":null} |
      | null                                       |

  @negative @client-request
  Scenario Outline: An empty-string image field is rejected (unlike null)
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                  |
      | BODY |     | {"repository":"https://github.com/example/example-devcontainer.git","image":<image>}  |
    Then the response status is 400

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | image           |
      | {"registry":""} |
      | {"name":""}     |
      | {"tag":""}      |

  @negative @client-request
  Scenario Outline: An incomplete or malformed gitCredentials is rejected
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                    |
      | BODY |     | {"repository":"https://github.com/example/example-devcontainer.git","gitCredentials":<gitCredentials>} |
    Then the response status is 400

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | gitCredentials                           |
      | {"username":"svc-bot"}                   |
      | {"token":"ghp_example"}                  |
      | {"username":12345,"token":"ghp_example"} |
      | "svc-bot:ghp_example"                    |

  @client-request
  Scenario: gitCredentials with empty-string fields still passes shape validation
    # isValidBuildRequest only checks typeof "string" for gitCredentials
    # fields, not non-empty-ness - this documents that as current behavior.
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                            |
      | BODY |     | {"repository":"file:///nonexistent-repo-for-validation-tests.git","gitCredentials":{"username":"","token":""}} |
    Then the response status is 500

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @client-request
  Scenario Outline: An incomplete or empty-field registryCredentials is rejected
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                |
      | BODY |     | {"repository":"https://github.com/example/example-devcontainer.git","registryCredentials":<registryCredentials>}  |
    Then the response status is 400

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | registryCredentials                                                |
      | {"username":"svc-bot","password":"hunter2"}                       |
      | {"registry":"ghcr.io/example","password":"hunter2"}               |
      | {"registry":"ghcr.io/example","username":"svc-bot"}               |
      | {"registry":"","username":"svc-bot","password":"hunter2"}         |
      | {"registry":"ghcr.io/example","username":"","password":"hunter2"} |
      | {"registry":"ghcr.io/example","username":"svc-bot","password":""} |

  @client-request
  Scenario: A fully-specified registryCredentials passes shape validation
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                                |
      | BODY |     | {"repository":"file:///nonexistent-repo-for-validation-tests.git","registryCredentials":{"registry":"ghcr.io/example","username":"svc-bot","password":"hunter2"}} |
    Then the response status is 500

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @client-request
  Scenario: Unknown extra top-level fields are tolerated
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                          |
      | BODY |     | {"repository":"file:///nonexistent-repo-for-validation-tests.git","somethingTheServiceDoesNotKnowAbout":true} |
    Then the response status is 500

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @client-request
  Scenario: platforms and buildOptions fully specified pass shape validation
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                                                                                                          |
      | BODY |     | {"repository":"file:///nonexistent-repo-for-validation-tests.git","platforms":["linux/amd64","linux/arm64"],"buildOptions":{"noCache":true,"cacheFrom":"ghcr.io/example:cache","cacheTo":"ghcr.io/example:cache","mode":"never"}} |
    Then the response status is 500

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @client-request
  Scenario Outline: An invalid platforms field is rejected
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                            |
      | BODY |     | {"repository":"https://github.com/example/example-devcontainer.git","platforms":<platforms>}   |
    Then the response status is 400

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | platforms         |
      | "linux/amd64"     |
      | [123]              |
      | [""]               |
      | [null]             |

  @negative @client-request
  Scenario Outline: An invalid buildOptions field is rejected
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                 |
      | BODY |     | {"repository":"https://github.com/example/example-devcontainer.git","buildOptions":<buildOptions>}  |
    Then the response status is 400

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | buildOptions              |
      | {"noCache":"yes"}         |
      | {"cacheFrom":""}          |
      | {"cacheTo":""}            |
      | {"mode":"sometimes"}      |
      | "not-an-object"           |
