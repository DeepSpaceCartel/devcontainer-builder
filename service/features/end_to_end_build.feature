@smoke
Feature: End-to-end build scenarios
  As a maintainer of devcontainer-builder
  I want a small set of full request/response round trips covering several axes at once
  So that a regression touching more than one area is caught by a single scenario

  These complement the narrowly-scoped scenarios in the other feature files;
  they intentionally combine several resolution axes in one request rather
  than isolating a single one. Runs the real service as a Kubernetes
  Deployment - see git_source_resolution.feature's Background comment for
  the per-scenario "has been run again" / SSH-credential-via-Secret
  mechanics reused here. "Ambient registry auth not configured" is the
  chart's own default (`registryAuth.dockerConfigJson` defaults to an
  empty `{"auths":{}}`), so scenarios that want that need no extra config.

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
    And the value "test-git-server-test-git-server.<namespace>.svc.cluster.local" is known as "<git-host>"
    And the value "git://test-git-server-test-git-server.<namespace>.svc.cluster.local:9418" is known as "<git-url>"
    And the content of "/tmp/e2e-fixtures/git-ssh/id_ed25519" is known as "<authorized-key>"

    And "docker buildx inspect devcontainer-builder-test || docker buildx create --name devcontainer-builder-test --driver remote tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234" has been run
    And "docker buildx build --builder devcontainer-builder-test -t ghcr.io/alexanderilyin/devcontainer-builder-test:test --push ../service" has been run

  Scenario: A fully server-resolved bare request derives everything
    Given the following is written to "/tmp/e2e-fixtures/e2e-mapping-1-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/e2e-mapping-1-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    And "git ls-remote git://test-git-server-test-git-server.<namespace>.svc.cluster.local:9418/example/example-devcontainer.git HEAD | cut -c1-7" has been run
    And the command output is known as "<expected-sha>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<git-url>/example/example-devcontainer.git" }
      """
    Then the response status should be 200
    And the resolved image should be "<registry-url>/example-devcontainer:sha-<expected-sha>"

  Scenario: A fully caller-specified request wins over a server default it could have used
    Given the following is written to "/tmp/e2e-fixtures/e2e-mapping-2-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/e2e-mapping-2-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "branch": "release",
        "image": { "registry": "<authed-registry-url>", "name": "custom-name", "tag": "v9.9.9" },
        "registryCredentials": { "registry": "<authed-registry-url>", "username": "svc-bot", "password": "hunter2" }
      }
      """
    Then the response status should be 200
    And the resolved image should be "<authed-registry-url>/custom-name:v9.9.9"

  Scenario: Server-resolved registry composes with request-supplied credentials for it
    Given the following is written to "/tmp/e2e-fixtures/e2e-mapping-3-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <authed-registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/e2e-mapping-3-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    And "git ls-remote git://test-git-server-test-git-server.<namespace>.svc.cluster.local:9418/example/example-devcontainer.git HEAD | cut -c1-7" has been run
    And the command output is known as "<expected-sha>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "registryCredentials": { "registry": "<authed-registry-url>", "username": "svc-bot", "password": "hunter2" }
      }
      """
    Then the response status should be 200
    And the resolved image should be "<authed-registry-url>/example-devcontainer:sha-<expected-sha>"

  Scenario: A server-configured SSH default combines with a registry mapping rule
    Given "jq -n --arg host \"<git-host>\" --arg key \"$(cat /tmp/e2e-fixtures/git-ssh/id_ed25519)\" '[{host: $host, kind: \"ssh\", privateKey: $key}]' > /tmp/e2e-fixtures/e2e-ssh-creds.json" has been run
    And "kubectl create secret generic e2e-ssh-creds -n <namespace> --from-file=git-credentials.json=/tmp/e2e-fixtures/e2e-ssh-creds.json --dry-run=client -o yaml | kubectl apply -f -" has been run
    And the following is written to "/tmp/e2e-fixtures/e2e-mapping-4-values.yaml":
      """
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.existingSecret=e2e-ssh-creds --set sshHostKeyPolicy=tofu -f /tmp/e2e-fixtures/e2e-mapping-4-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    And "git ls-remote git://test-git-server-test-git-server.<namespace>.svc.cluster.local:9418/example/example-devcontainer.git HEAD | cut -c1-7" has been run
    And the command output is known as "<expected-sha>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "https://<git-host>/example/example-devcontainer.git" }
      """
    Then the response status should be 200
    And the resolved image should be "<registry-url>/example-devcontainer:sha-<expected-sha>"

  Scenario: A non-default branch is actually checked out, not silently ignored
    # Asserting against "release"'s own real HEAD sha (a genuinely different
    # commit from "main"'s, see charts/test-git-server/values.yaml's
    # extraBranches) - not just that the request succeeds - is what proves
    # `branch` actually took effect. If it were silently ignored (always
    # building "main" regardless), this would fail on a sha mismatch rather
    # than pass for the wrong reason.
    Given the following is written to "/tmp/e2e-fixtures/e2e-mapping-5-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/e2e-mapping-5-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    And "git ls-remote git://test-git-server-test-git-server.<namespace>.svc.cluster.local:9418/example/example-devcontainer.git release | cut -c1-7" has been run
    And the command output is known as "<expected-sha>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<git-url>/example/example-devcontainer.git", "branch": "release" }
      """
    Then the response status should be 200
    And the resolved image should be "<registry-url>/example-devcontainer:sha-<expected-sha>"

  @negative
  Scenario: A failing clone surfaces its real underlying error end to end
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "branch": "does-not-exist",
        "image": { "registry": "<registry-url>", "name": "custom-name", "tag": "v1.0.0" }
      }
      """
    Then the response status should be 500
    And the response body should contain "git clone --branch does-not-exist --single-branch --depth 1"
