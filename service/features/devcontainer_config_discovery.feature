Feature: devcontainer.json discovery after clone
  As an operator of devcontainer-builder
  I want the service to find devcontainer.json wherever the containers.dev spec allows it to live
  So that callers aren't forced into one specific repo layout

  See https://containers.dev/implementors/spec/#devcontainerjson - it
  recognizes three locations, in precedence order: .devcontainer/
  devcontainer.json, .devcontainer.json, and .devcontainer/<folder>/
  devcontainer.json (one sub-folder deep, <folder>'s name unspecified).
  test-git-server seeds one real repo per location (see
  charts/test-git-server/values.yaml's devcontainer-json-* entries) - these
  are real builds, so "success" means the devcontainer CLI actually found
  and used the config, not an inferred signal.

  Background:
    Given "echo devcontainer-builder-${CODER_WORKSPACE_OWNER_NAME:-${USER:-local}}-default" has been run
    And the command output is known as "<namespace>"
    And "kubectl create namespace <namespace> --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=privileged --overwrite" has been run

    And "helm upgrade --install test-registry ../charts/test-registry -n <namespace> --wait --timeout 120s" has been run
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/test-registry-test-registry.<namespace>.svc.cluster.local/5000); do sleep 1; done'" has been run
    And the value "test-registry-test-registry.<namespace>.svc.cluster.local:5000" is known as "<registry-url>"

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
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set updateStrategy.type=Recreate --wait --timeout 120s" has been run
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"

  @client-request
  Scenario Outline: A devcontainer.json at the root or the standard .devcontainer/ location is found automatically
    Given "git ls-remote git://test-git-server-test-git-server.<namespace>.svc.cluster.local:9418/location/<repo>.git HEAD | cut -c1-7" has been run
    And the command output is known as "<expected-sha>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<git-url>/location/<repo>.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 200
    And the resolved image should be "<registry-url>/<repo>:sha-<expected-sha>"

    Examples:
      | repo                       |
      | devcontainer-json-root     |
      | devcontainer-json-standard |

  @negative @client-request
  Scenario Outline: A devcontainer.json in a sub-folder is not found automatically - a known gap, not this service's own logic
    # The spec itself only says a sub-folder config MAY exist - it
    # deliberately leaves <folder>'s name unspecified, since a tool can't
    # know which of possibly several sub-folder configs to pick without
    # being told explicitly (the spec: "consider providing a mechanism for
    # users to select one when appropriate"). The devcontainer CLI (0.89.0)
    # reflects exactly that: it auto-discovers only the root and standard
    # .devcontainer/devcontainer.json locations - a sub-folder config needs
    # an explicit `--config <path>`, which build.ts does not currently pass
    # (the /build request has no field for it). Three sub-folder names
    # prove this fails the same way regardless of which folder name is
    # used - it's not a naming mismatch, the location itself isn't checked.
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<git-url>/location/<repo>.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 500
    And the response body should contain "exited with code 1"
    And the devcontainer-builder's logs are captured
    And the service logs should contain "Dev container config"
    And the service logs should contain "not found"

    Examples:
      | repo                             |
      | devcontainer-json-subfolder-alpha |
      | devcontainer-json-subfolder-beta  |
      | devcontainer-json-subfolder-gamma |

  @negative @client-request
  Scenario: A repository with no devcontainer.json at any location fails clearly
    # Distinct from the sub-folder cases above: this repo has no config at
    # ANY of the three locations, not just an unchecked one - same CLI
    # error text either way, since "checked here, found nothing" and
    # "never checked here" are indistinguishable from the CLI's own output.
    # The distinction that matters is at the fixture level (see
    # devcontainer-json-missing in charts/test-git-server/values.yaml,
    # `noConfig: true`), proving this failure mode is reachable at all.
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<git-url>/location/devcontainer-json-missing.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 500
    And the response body should contain "exited with code 1"
    And the devcontainer-builder's logs are captured
    And the service logs should contain "Dev container config"
    And the service logs should contain "not found"
