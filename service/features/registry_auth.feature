Feature: Registry push authentication
  As a caller of devcontainer-builder
  I want to optionally supply my own registry push credentials
  So that I'm not limited to whatever the service's ambient registry auth covers

  Runs against two real registry fixtures: an anonymous one that accepts any
  push, and one that enforces HTTP basic auth (htpasswd) - only the latter
  can actually distinguish "right credentials" from "wrong/no credentials",
  which is what most of these scenarios are really testing. A real,
  disposable BuildKit instance does the actual push in every scenario.

  Runs the real service as a Kubernetes Deployment - "ambient registry auth
  not configured" is the chart's own default (`registryAuth.dockerConfigJson`
  defaults to an empty `{"auths":{}}`), so most scenarios need no special
  config at all beyond the shared image/buildkit setup. Only the "correct
  ambient auth" scenario needs a real `dockerConfigJson` value, built from a
  base64'd `user:pass` via the existing "<cmd> has been run" +
  "the command output is known as" primitives.

  Background:
    Given "echo devcontainer-builder-${CODER_WORKSPACE_OWNER_NAME:-${USER:-local}}-default" has been run
    And the command output is known as "<namespace>"
    And "kubectl create namespace <namespace> --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=privileged --overwrite" has been run
    And "helm upgrade --install test-registry ../charts/test-registry -n <namespace> --wait --timeout 120s" has been run
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/test-registry-test-registry.<namespace>.svc.cluster.local/5000); do sleep 1; done'" has been run
    And the value "test-registry-test-registry.<namespace>.svc.cluster.local:5000" is known as "<registry-url>"
    And the following is written to "/tmp/e2e-fixtures/registry-authed-values.yaml":
      """
      auth:
        enabled: true
        username: svc-bot
        password: hunter2
      """
    And "helm upgrade --install test-registry-authed ../charts/test-registry -n <namespace> -f /tmp/e2e-fixtures/registry-authed-values.yaml --wait --timeout 120s" has been run
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/test-registry-authed-test-registry.<namespace>.svc.cluster.local/5000); do sleep 1; done'" has been run
    And the value "test-registry-authed-test-registry.<namespace>.svc.cluster.local:5000" is known as "<authed-registry-url>"
    And the following is written to "/tmp/e2e-fixtures/buildkit-trust.toml":
      """
      [registry."test-registry-test-registry.<namespace>.svc.cluster.local:5000"]
        http = true
        insecure = true
      [registry."test-registry-authed-test-registry.<namespace>.svc.cluster.local:5000"]
        http = true
        insecure = true
      """
    And "helm upgrade --install test-buildkit buildkit-service --repo https://andrcuns.github.io/charts -n <namespace> --set-file buildkitdToml=/tmp/e2e-fixtures/buildkit-trust.toml --wait --timeout 180s" has been run
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/test-buildkit-buildkit-service.<namespace>.svc.cluster.local/1234); do sleep 1; done'" has been run
    And the value "tcp://test-buildkit-buildkit-service.<namespace>.svc.cluster.local:1234" is known as "<buildkit-endpoint>"
    And "rm -rf /tmp/e2e-fixtures/git-tls && mkdir -p /tmp/e2e-fixtures/git-tls" has been run
    And "rm -rf /tmp/e2e-fixtures/git-ssh && mkdir -p /tmp/e2e-fixtures/git-ssh" has been run
    And "openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/e2e-fixtures/git-tls/ca-key.pem -out /tmp/e2e-fixtures/git-tls/ca-cert.pem -days 2 -subj /CN=devcontainer-builder-test-ca" has been run
    And "openssl req -newkey rsa:2048 -nodes -keyout /tmp/e2e-fixtures/git-tls/server-key.pem -out /tmp/e2e-fixtures/git-tls/server.csr -subj /CN=devcontainer-builder-test-git-server" has been run
    And the following is written to "/tmp/e2e-fixtures/git-tls/san.cnf":
      """
      subjectAltName=DNS:test-git-server-test-git-server.<namespace>.svc.cluster.local
      """
    And "openssl x509 -req -in /tmp/e2e-fixtures/git-tls/server.csr -CA /tmp/e2e-fixtures/git-tls/ca-cert.pem -CAkey /tmp/e2e-fixtures/git-tls/ca-key.pem -CAcreateserial -out /tmp/e2e-fixtures/git-tls/server-cert.pem -days 2 -extfile /tmp/e2e-fixtures/git-tls/san.cnf" has been run
    And "ssh-keygen -t ed25519 -N '' -f /tmp/e2e-fixtures/git-ssh/id_ed25519 -C devcontainer-builder-test" has been run
    And "helm upgrade --install test-git-server ../charts/test-git-server -n <namespace> --set-string sshAuthorizedKey=\"$(cat /tmp/e2e-fixtures/git-ssh/id_ed25519.pub)\" --set-file tlsCert=/tmp/e2e-fixtures/git-tls/server-cert.pem --set-file tlsKey=/tmp/e2e-fixtures/git-tls/server-key.pem --wait --timeout 180s" has been run
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/test-git-server-test-git-server.<namespace>.svc.cluster.local/9418); do sleep 1; done'" has been run
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/test-git-server-test-git-server.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/test-git-server-test-git-server.<namespace>.svc.cluster.local/443); do sleep 1; done'" has been run
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/test-git-server-test-git-server.<namespace>.svc.cluster.local/22); do sleep 1; done'" has been run
    And the value "git://test-git-server-test-git-server.<namespace>.svc.cluster.local:9418" is known as "<git-url>"
    And "docker buildx inspect devcontainer-builder-test || docker buildx create --name devcontainer-builder-test --driver remote tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234" has been run
    And "docker buildx build --builder devcontainer-builder-test -t ghcr.io/alexanderilyin/devcontainer-builder-test:test --push ../service" has been run

  @client-request
  Scenario: No credentials at all succeed against a registry that doesn't require auth
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "image": { "registry": "<registry-url>" }
      }
      """
    Then the response status should be 200

  @client-request
  Scenario: Correct ambient registry auth succeeds against an auth-enforcing registry
    Given "printf '%s' 'svc-bot:hunter2' | base64" has been run
    And the command output is known as "<basic-auth>"
    And the following is written to "/tmp/e2e-fixtures/ambient-auth-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryAuth:
        dockerConfigJson: |
          {"auths":{"<authed-registry-url>":{"auth":"<basic-auth>"}}}
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/ambient-auth-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "image": { "registry": "<authed-registry-url>" }
      }
      """
    Then the response status should be 200

  @negative @client-request
  Scenario: No ambient registry auth and no registryCredentials fails against an auth-enforcing registry
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "image": { "registry": "<authed-registry-url>" }
      }
      """
    Then the response status should be 500
    And the devcontainer-builder's logs are captured
    And the service logs should contain "401"

  @client-request
  Scenario: Correct registryCredentials succeed against an auth-enforcing registry with no ambient auth
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "image": { "registry": "<authed-registry-url>" },
        "registryCredentials": { "registry": "<authed-registry-url>", "username": "svc-bot", "password": "hunter2" }
      }
      """
    Then the response status should be 200

  @negative @client-request
  Scenario: Wrong registryCredentials fail against an auth-enforcing registry
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "image": { "registry": "<authed-registry-url>" },
        "registryCredentials": { "registry": "<authed-registry-url>", "username": "svc-bot", "password": "wrong-password" }
      }
      """
    Then the response status should be 500
    And the devcontainer-builder's logs are captured
    And the service logs should contain "401"

  @negative @client-request
  Scenario: registryCredentials for a different registry than image.registry have no effect on the actual push
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "image": { "registry": "<authed-registry-url>" },
        "registryCredentials": { "registry": "<registry-url>", "username": "svc-bot", "password": "hunter2" }
      }
      """
    Then the response status should be 500
    And the devcontainer-builder's logs are captured
    And the service logs should contain "401"

  Scenario: A registry-credentialed build against one registry and a plain build against another both succeed back to back
    # Regression anchor for the seed-from-ambient-DOCKER_CONFIG design: a
    # per-request registryCredentials override must not corrupt or replace
    # the ambient/buildx state that a later, differently-targeted request
    # relies on. Only observable from outside as "both requests still
    # work" - internal buildx builder reuse isn't visible over HTTP.
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "image": { "registry": "<authed-registry-url>" },
        "registryCredentials": { "registry": "<authed-registry-url>", "username": "svc-bot", "password": "hunter2" }
      }
      """
    Then the response status should be 200
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "image": { "registry": "<registry-url>" }
      }
      """
    Then the response status should be 200
