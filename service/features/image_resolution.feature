Feature: Image name, tag, and registry resolution
  As a caller of devcontainer-builder
  I want sensible defaults for the pushed image reference
  So that I don't have to compute a registry, name, or tag myself for every build

  Runs real builds against a real git server and the anonymous test
  registry - "git ls-remote ... | cut -c1-7" captures the fixture repo's
  actual current HEAD short sha (a real, content-derived value, not one a
  scenario can dictate) for later assertions to reference by name.

  Runs the real service as a Kubernetes Deployment - almost every scenario
  needs its own `registryMapping.rules`, so (per the accepted cost of this
  approach - see the migration plan) each one triggers its own rollout via
  "has been run again", same mechanics as git_source_resolution.feature.
  gitCredentials stays disabled throughout (this file never needs git
  auth), so only registryMapping varies per scenario.

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

    And "docker buildx inspect devcontainer-builder-test || docker buildx create --name devcontainer-builder-test --driver remote tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234" has been run
    And "docker buildx build --builder devcontainer-builder-test -t ghcr.io/alexanderilyin/devcontainer-builder-test:test --push ../service" has been run

  @client-request
  Scenario: A fully-specified image target is used verbatim
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "image": { "registry": "<registry-url>", "name": "custom-name", "tag": "v1.2.3" }
      }
      """
    Then the response status should be 200
    And the resolved image should be "<registry-url>/custom-name:v1.2.3"

  @server-config @client-request
  Scenario: Omitting image entirely derives registry, name, and tag
    Given the following is written to "/tmp/e2e-fixtures/img-mapping-1-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/img-mapping-1-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
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

  @client-request
  Scenario: A partially-specified image target derives only the missing fields
    Given the following is written to "/tmp/e2e-fixtures/img-mapping-2-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/img-mapping-2-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    And "git ls-remote git://test-git-server-test-git-server.<namespace>.svc.cluster.local:9418/example/example-devcontainer.git HEAD | cut -c1-7" has been run
    And the command output is known as "<expected-sha>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "image": { "name": "custom-name" }
      }
      """
    Then the response status should be 200
    And the resolved image should be "<registry-url>/custom-name:sha-<expected-sha>"

  @client-request
  Scenario Outline: The derived name strips a trailing .git and uses the last path segment
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    And "git ls-remote git://test-git-server-test-git-server.<namespace>.svc.cluster.local:9418/<repo-path> HEAD | cut -c1-7" has been run
    And the command output is known as "<expected-sha>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<repository>", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 200
    And the resolved image should be "<registry-url>/<expected-name>:sha-<expected-sha>"

    Examples:
      | repository                                            | repo-path                          | expected-name            |
      | <git-url>/example/example-devcontainer.git    | example/example-devcontainer.git   | example-devcontainer     |
      | <git-url>/example/sub/example-devcontainer     | example/sub/example-devcontainer   | example-devcontainer     |
      | <git-url>/solo-repo.git                        | solo-repo.git                      | solo-repo                |

  @server-config
  Scenario: A registry mapping rule matching on hostMatch only applies to any path on that host
    Given the following is written to "/tmp/e2e-fixtures/img-mapping-3-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - hostMatch: <git-host>
            registry: <registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/img-mapping-3-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
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

  @server-config
  Scenario: A registry mapping rule matching on pathPrefix only applies regardless of host
    Given the following is written to "/tmp/e2e-fixtures/img-mapping-4-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/img-mapping-4-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
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

  @server-config
  Scenario: A rule with neither hostMatch nor pathPrefix is a universal fallback
    Given the following is written to "/tmp/e2e-fixtures/img-mapping-5-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - registry: <registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/img-mapping-5-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
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

  @server-config
  Scenario: The first matching rule wins when more than one rule matches
    Given the following is written to "/tmp/e2e-fixtures/img-mapping-6-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <registry-url>
          - registry: <authed-registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/img-mapping-6-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
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

  @client-request
  Scenario: An explicit image.registry wins over a matching registry mapping rule
    Given the following is written to "/tmp/e2e-fixtures/img-mapping-7-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - pathPrefix: example/
            registry: <authed-registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/img-mapping-7-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    And "git ls-remote git://test-git-server-test-git-server.<namespace>.svc.cluster.local:9418/example/example-devcontainer.git HEAD | cut -c1-7" has been run
    And the command output is known as "<expected-sha>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "<git-url>/example/example-devcontainer.git",
        "image": { "registry": "<registry-url>" }
      }
      """
    Then the response status should be 200
    And the resolved image should be "<registry-url>/example-devcontainer:sha-<expected-sha>"

  @negative @client-request
  Scenario: No image.registry given and no rule matches is a 400, not a 500
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<git-url>/example/example-devcontainer.git" }
      """
    Then the response status should be 400
    And the response body should contain "no registry resolved for repository"

  @negative @server-config
  Scenario: A non-matching registry mapping rule does not accidentally apply
    Given the following is written to "/tmp/e2e-fixtures/img-mapping-8-values.yaml":
      """
      gitCredentials:
        enabled: false
      registryMapping:
        rules:
          - hostMatch: gitlab.internal.example.com
            registry: <registry-url>
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/img-mapping-8-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<git-url>/example/example-devcontainer.git" }
      """
    Then the response status should be 400
