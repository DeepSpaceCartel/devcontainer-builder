Feature: Liveness, readiness, and unknown routes
  As the Kubernetes Deployment running devcontainer-builder
  I want distinct liveness and readiness signals
  So that traffic is only routed to a pod that can actually accept a build

  Runs the real service as a Kubernetes Deployment via its own Helm chart,
  not a local process - each scenario needs a differently-configured pod,
  so the per-scenario `helm upgrade --install` + readiness handling lives
  in each Scenario, not a Background (only the namespace/image setup common
  to all of them does). Two of the four @server-config scenarios (the ones
  that leave BUILDKIT_ENDPOINT unset) deliberately produce a pod that will
  never pass its own readiness probe: those use `updateStrategy.type=
  Recreate` and skip `--wait` (it would time out waiting for a Ready state
  that never comes), then talk to the pod's own IP directly instead of the
  Service, since a ClusterIP Service never routes to a not-Ready pod at
  all. Every per-scenario `helm upgrade --install` below uses "has been run
  again" rather than the memoized "has been run", because this file's
  config deliberately repeats (the third scenario reverts to the same
  unset config the first one used) - memoization would otherwise skip
  re-applying it, leaving the pod in whatever the *previous* scenario left
  it in.

  Background:
    Given "echo devcontainer-builder-${CODER_WORKSPACE_OWNER_NAME:-${USER:-local}}-default" has been run
    And the command output is known as "<namespace>"
    And "kubectl create namespace <namespace> --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=privileged --overwrite" has been run
    And "docker buildx inspect devcontainer-builder-test || docker buildx create --name devcontainer-builder-test --driver remote tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234" has been run
    And "docker buildx build --builder devcontainer-builder-test -t ghcr.io/alexanderilyin/devcontainer-builder-test:test --push ../service" has been run

  @server-config
  Scenario: Liveness succeeds even when the service isn't configured to build anything
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint= --set updateStrategy.type=Recreate --timeout 60s" has been run again
    And "timeout 30 bash -c 'while true; do IP=$(kubectl get pod -n <namespace> -l app.kubernetes.io/instance=devcontainer-builder -o jsonpath={.items[0].status.podIP} 2>/dev/null); DT=$(kubectl get pod -n <namespace> -l app.kubernetes.io/instance=devcontainer-builder -o jsonpath={.items[0].metadata.deletionTimestamp} 2>/dev/null); if [ -z \"$DT\" ] && [ -n \"$IP\" ] && (exec 3<>/dev/tcp/$IP/8080) 2>/dev/null; then echo $IP; break; fi; sleep 1; done'" has been run again
    And the command output is known as "<pod-ip>"
    And the value "http://<pod-ip>:8080" is known as "<base-url>"
    When I send a GET request to "<base-url>/health/live"
    Then the response status should be 200
    And the response body should equal:
      """
      { "status": "ok" }
      """

  @server-config
  Scenario: Liveness succeeds when the service is fully configured
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=tcp://buildkit.example:1234 --set updateStrategy.type=Recreate --wait --timeout 90s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a GET request to "<base-url>/health/live"
    Then the response status should be 200
    And the response body should equal:
      """
      { "status": "ok" }
      """

  @server-config
  Scenario: Readiness fails when BUILDKIT_ENDPOINT is not configured
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint= --set updateStrategy.type=Recreate --timeout 60s" has been run again
    And "timeout 30 bash -c 'while true; do IP=$(kubectl get pod -n <namespace> -l app.kubernetes.io/instance=devcontainer-builder -o jsonpath={.items[0].status.podIP} 2>/dev/null); DT=$(kubectl get pod -n <namespace> -l app.kubernetes.io/instance=devcontainer-builder -o jsonpath={.items[0].metadata.deletionTimestamp} 2>/dev/null); if [ -z \"$DT\" ] && [ -n \"$IP\" ] && (exec 3<>/dev/tcp/$IP/8080) 2>/dev/null; then echo $IP; break; fi; sleep 1; done'" has been run again
    And the command output is known as "<pod-ip>"
    And the value "http://<pod-ip>:8080" is known as "<base-url>"
    When I send a GET request to "<base-url>/health/ready"
    Then the response status should be 503
    And the response body should equal:
      """
      { "status": "not ready", "reason": "BUILDKIT_ENDPOINT not configured" }
      """

  @server-config
  Scenario: Readiness succeeds when BUILDKIT_ENDPOINT is configured
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=tcp://buildkit.example:1234 --set updateStrategy.type=Recreate --wait --timeout 90s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a GET request to "<base-url>/health/ready"
    Then the response status should be 200
    And the response body should equal:
      """
      { "status": "ready" }
      """

  @negative
  Scenario Outline: Unknown routes and methods fall through to a generic 404
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=tcp://buildkit.example:1234 --set updateStrategy.type=Recreate --wait --timeout 90s" has been run
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a <method> request to "<base-url><path>"
    Then the response status should be 404
    And the response body should equal:
      """
      { "error": "not found" }
      """

    Examples:
      | method | path          |
      | GET    | /build        |
      | POST   | /health/live  |
      | POST   | /health/ready |
      | GET    | /health       |
      | GET    | /             |
      | GET    | /nope         |
      | DELETE | /build        |
