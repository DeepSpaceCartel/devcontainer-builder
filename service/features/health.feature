Feature: Liveness, readiness, and unknown routes
  As the Kubernetes Deployment running devcontainer-builder
  I want distinct liveness and readiness signals
  So that traffic is only routed to a pod that can actually accept a build

  Runs the real service as a Kubernetes Deployment via its own Helm chart,
  not a local process - each scenario needs a differently-configured pod,
  so the per-scenario `helm upgrade --install` lives in each Scenario, not
  the Background (only the namespace/image setup common to all of them
  does). Two of the four @server-config scenarios (the ones that leave
  buildkit.endpoint unset) deliberately produce a pod that will never pass
  its own readiness probe: those use `updateStrategy.type=Recreate` and
  skip --wait (it would time out waiting for a Ready state that never
  comes), then talk to the pod's own IP directly via a real HTTP Endpoint
  on a Pod, since a ClusterIP Service never routes to a not-Ready pod at
  all.

  Background:
    # A real ${CODER_WORKSPACE_OWNER_NAME:-${USER:-local}} fallback -
    # avoids collisions between different developers sharing this cluster.
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

    # Build and push this run's own real devcontainer-builder image - the
    # service's own real source, not a stand-in fixture - using the
    # already-running shared BuildKit instance and real GHCR credentials
    # (ambient `docker login`, not threaded through Gherkin/Thomas at all).
    Given Docker Buildx Builder known as "<Builder>":
      | PROPERTY | VALUE                                                            |
      | name     | devcontainer-builder-health-w<WorkerId> |
      | endpoint | tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234 |
    When I create Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I build and push "ghcr.io/deepspacecartel/devcontainer-builder-test:test" from "." using Docker Buildx Builder known as "<Builder>" with:
      | OPTION | VALUE |
    Then the command exited with 0

  @server-config
  Scenario: Liveness succeeds even when the service isn't configured to build anything
    Given Directory "<ChartDirectory>" at "../charts/devcontainer-builder"
    And Helm Chart "<Chart>" in "<ChartDirectory>"
    And Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                            |
      | --install          | True                                             |
      | --set               | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test |
      | --set               | image.tag=test                                   |
      | --set               | image.pullPolicy=Always                          |
      | --set               | buildkit.endpoint=                               |
      | --set               | updateStrategy.type=Recreate                     |
      | --timeout           | 60s                                              |
    Then the command exited with 0

    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    When I poll Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | KEY             | CONDITION  | VALUE | OUTCOME |
      | status.podIP    | exists     |       | pass    |

    And HTTP Endpoint "<AppApi>" on Pod known as "<AppPod>" port "8080"
    # A real IP doesn't mean the process inside is listening yet - a bare
    # "send a GET request" here races that real startup window and fails
    # ("fetch failed"). Retries the real request itself until it connects.
    When I poll Endpoint known as "<AppApi>" path "/health/live" every "2s" for up to "30s" until the GET request succeeds
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE |
      | BODY   | equals    | {"status":"ok"} |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: Liveness succeeds when the service is fully configured
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
    When I send a GET request to Endpoint known as "<AppApi>" path "/health/live"
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE |
      | BODY   | equals    | {"status":"ok"} |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: Readiness fails when buildkit.endpoint is not configured
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
      | --set              | buildkit.endpoint=                                                 |
      | --set              | updateStrategy.type=Recreate                                       |
      | --timeout          | 60s                                                                |
    Then the command exited with 0

    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    When I poll Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | KEY             | CONDITION  | VALUE | OUTCOME |
      | status.podIP    | exists     |       | pass    |

    And HTTP Endpoint "<AppApi>" on Pod known as "<AppPod>" port "8080"
    # Same real startup-window race as the liveness scenario above - a
    # 503 still needs a real, successful connection first.
    When I poll Endpoint known as "<AppApi>" path "/health/ready" every "2s" for up to "30s" until the GET request succeeds
    Then the response status is 503:
      | SOURCE | CONDITION | VALUE |
      | BODY   | equals    | {"status":"not ready","reason":"BUILDKIT_ENDPOINT not configured"} |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: Readiness succeeds when buildkit.endpoint is configured
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
    When I send a GET request to Endpoint known as "<AppApi>" path "/health/ready"
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE |
      | BODY   | equals    | {"status":"ready"} |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative
  Scenario Outline: Unknown routes and methods fall through to a generic 404
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
    When I send a <method> request to Endpoint known as "<AppApi>" path "<path>"
    Then the response status is 404:
      | SOURCE | CONDITION | VALUE |
      | BODY   | equals    | {"error":"not found"} |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | method | path          |
      | GET    | /build        |
      | POST   | /health/live  |
      | POST   | /health/ready |
      | GET    | /health       |
      | GET    | /             |
      | GET    | /nope         |
      | DELETE | /build        |
