# Pattern: "When I deploy ... without waiting" only dispatches helm (install/
# upgrade/scale) and returns - it never blocks on rollout status. Every Then
# step polls its own resource independently with its own timeout, so several
# unrelated signals (events, logs, replica counts, rollout state) can all be
# checked off the back of a single fire-and-forget action, in any order,
# without one slow check delaying the others' assertions.

# Okay I see there are at least two different use cases how "describe" data could be handled:
# 1. Simple key=value which could be 
# | key | value |
# | .Status | Running |
# but this implies assertion of "equval" then we extend
# | key | assert | value |
# | .Status | equval | Running |
# 
# Then let's look on .Labels
# | key | assert | value |
# | .Labels | has | app.kubernetes.io/instance=devcontainer-builder  |
# | .Labels | has | app.kubernetes.io/managed-by=Helm  |



Feature: Async verification of Kubernetes deployments
  As an SRE
  I want to trigger a deployment once and then check whatever signals matter
  So that I'm not stuck waiting on helm's own readiness gate to see what's happening

# Example below is built from a real pod pulled live from the
# devcontainer-builder-technopriest-default namespace (test-registry fixture)
# to show the key/assert/value and conditions tables against actual `describe`
# data rather than made-up field names.
Rule: Arbitrary describe fields, conditions, and events can be asserted generically

  Scenario: Verifying a running fixture pod's fields, conditions, and events
    Given pod "test-registry-test-registry-6754879766-mmtfq" in namespace "devcontainer-builder-technopriest-default" exists
    Then the pod should report:
      | key                                        | assert | value                         |
      | .status.phase                               | equals | Running                       |
      | .status.containerStatuses[0].ready          | equals | true                          |
      | .status.containerStatuses[0].restartCount   | equals | 0                             |
      | .status.containerStatuses[0].image          | equals | docker.io/library/registry:3  |
      | .metadata.labels                            | has    | app.kubernetes.io/name=test-registry |
      | .metadata.labels                            | has    | app.kubernetes.io/managed-by=Helm    |
    And the pod's conditions should be:
      | type                      | status |
      | PodScheduled              | True   |
      | Initialized               | True   |
      | PodReadyToStartContainers | True   |
      | ContainersReady           | True   |
      | Ready                     | True   |
    And the following events should be observed:
      | kind | name                                          | event     | within |
      | Pod  | test-registry-test-registry-6754879766-mmtfq | Scheduled | 10s    |
      | Pod  | test-registry-test-registry-6754879766-mmtfq | Pulled    | 15s    |
      | Pod  | test-registry-test-registry-6754879766-mmtfq | Created   | 15s    |
      | Pod  | test-registry-test-registry-6754879766-mmtfq | Started   | 20s    |

Rule: A resource can be registered once as a named selector and referenced by alias afterward

  Scenario: Checking a fixture deployment through a selector registered in World
    Given "Deployment" known as "@BuildkitDeployment" matches:
      | label                        | value                  |
      | app.kubernetes.io/instance   | test-buildkit          |
      | app.kubernetes.io/managed-by | Helm                   |
      | app.kubernetes.io/name       | buildkit-service       |
      | app.kubernetes.io/version    | v0.31.0                |
      | helm.sh/chart                | buildkit-service-1.8.0 |
    Then the following resource should exist in "30s":
      | kind       | name               |
      | Deployment | @BuildkitDeployment |
    And the following events should be observed:
      | kind | name                 | event   | within |
      | Pod  | @BuildkitDeployment  | Pulled  | 60s    |
      | Pod  | @BuildkitDeployment  | Started | 90s    |
    And "@BuildkitDeployment" should report:
      | key                                      | assert | value |
      | .status.readyReplicas                    | equals | 1     |

Rule: A fire-and-forget deploy can be checked from multiple independent angles

  Scenario: Pod lifecycle events appear after a fire-and-forget install
    Given helm chart "microservice-name" is available at "./charts/microservice-name"
    When I deploy "microservice-name" helm chart with CLI options:
      | option | value |
      | wait   | false |
    Then the following resource should exist in "5s":
      | kind       | name              |
      | Deployment | microservice-name |
    And the following events should be observed:
      | kind | name              | event     | within |
      | Pod  | microservice-name | Scheduled | 15s    |
      | Pod  | microservice-name | Pulled    | 60s    |
      | Pod  | microservice-name | Started   | 90s    |
    And all pods in deployment "microservice-name" should be Running and healthy in "120s"

  Scenario: Replicas, networking, and logs are all checked off one deploy
    Given helm chart "microservice-name" is available at "./charts/microservice-name"
    And values for "microservice-name" helm chart are:
      | key              | value                         |
      | replicaCount     | 3                             |
      | image.repository | myregistry/microservice-name  |
      | image.tag        | latest                        |
    When I deploy "microservice-name" helm chart without waiting for readiness
    Then deployment "microservice-name" should have 3 replicas in "60s"
    And service "microservice-name" should be available in "30s"
    And ingress "microservice-name" should be available in "30s"
    And logs for pod "microservice-name" should contain "listening on port" in "60s"
    And logs for pod "microservice-name" should not contain "Error" in "60s"

Rule: Failures should surface on their own timeline, not by blocking the whole scenario

  Scenario: A crash-looping container is caught via events instead of a hung helm --wait
    Given helm chart "microservice-name" is available at "./charts/microservice-name"
    And values for "microservice-name" helm chart are:
      | key       | value             |
      | image.tag | broken-entrypoint |
    When I deploy "microservice-name" helm chart without waiting for readiness
    Then pod for deployment "microservice-name" should emit event "BackOff" in "60s"
    And pod for deployment "microservice-name" should be in phase "CrashLoopBackOff" in "90s"
    And logs for pod "microservice-name" should contain "exec format error" in "30s"

Rule: In-flight rollouts can be observed mid-transition, not just at the end

  Scenario: Old and new ReplicaSets briefly coexist during a rolling upgrade
    Given deployment "microservice-name" is already Running and healthy
    When I upgrade "microservice-name" helm chart without waiting for readiness with:
      | key       | value |
      | image.tag | v2    |
    Then deployment "microservice-name" should report a rollout in progress in "10s"
    And at least 1 pod from the previous ReplicaSet should still be Running in "30s"
    And at least 1 pod from the new ReplicaSet should be Running and healthy in "60s"
    And deployment "microservice-name" should report rollout complete in "120s"

Rule: Scaling actions follow the same fire-then-poll shape

  @outline-tag
  Scenario Outline: Scaling a deployment is reflected in ready replicas
    Given deployment "microservice-name" is already Running and healthy
    When I scale "microservice-name" deployment to <replicas> replicas without waiting
    Then deployment "microservice-name" should have <replicas> replicas in "60s"
    And all pods in deployment "microservice-name" should be Running and healthy in "90s"

    Examples:
      | replicas |
      | 1        |
      | 5        |
