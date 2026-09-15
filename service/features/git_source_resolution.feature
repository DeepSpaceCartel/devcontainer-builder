Feature: Git source resolution - URL parsing, credential precedence, and protocol conversion
  As an operator of devcontainer-builder
  I want the service to resolve the right credential and clone protocol for a repository
  So that callers don't need to know or care whether a host is configured for HTTPS or SSH

  Runs against a real git server throughout - it genuinely serves all four
  protocols - git://, http://, https:// (real TLS via a self-signed CA
  generated per test run), and ssh:// (a real authorized key, via a
  `command=` forced wrapper) - so most scenarios below prove an actual,
  working clone rather than inferring success from a specific failure
  signature. One deliberate limit remains, a real infrastructure constraint
  rather than a gap in the service's own logic: "credential resolution is
  correctly scoped per host" is provable as "requests to different hosts
  produce different, correct outcomes" (not accidentally cross-wired) - the
  netrc/SSH key *content* actually used per request is an internal detail
  with no other external signal once the process exits.

  Runs the real service as a Kubernetes Deployment - each scenario needs a
  differently-configured pod (server git credentials, SSH_HOST_KEY_POLICY,
  GIT_SSL_CAINFO), so the per-scenario `helm upgrade --install` lives in
  each Scenario, using "has been run again" since the release name repeats
  (see service_startup_configuration.feature's Background comment). SSH
  private keys go through a real Secret (`jq` + `kubectl create secret` +
  `gitCredentials.existingSecret`) rather than inline YAML, since a raw
  multi-line key breaks YAML block-scalar indentation when substituted in.
  GIT_SSL_CAINFO needs the CA cert mounted *into* the pod (it's no longer
  the same filesystem as the test runner) via the chart's generic
  `extraVolumes`/`extraVolumeMounts`.

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
    And the value "test-git-server-test-git-server.<namespace>.svc.cluster.local" is known as "<git-host>"
    And the value "git://test-git-server-test-git-server.<namespace>.svc.cluster.local:9418" is known as "<git-url>"
    And the value "http://test-git-server-test-git-server.<namespace>.svc.cluster.local:8080" is known as "<http-url>"
    And the value "ssh://git@test-git-server-test-git-server.<namespace>.svc.cluster.local" is known as "<ssh-url>"

    And "rm -f /tmp/e2e-fixtures/unauthorized-key /tmp/e2e-fixtures/unauthorized-key.pub && ssh-keygen -t ed25519 -N '' -f /tmp/e2e-fixtures/unauthorized-key -C unauthorized" has been run
    And the content of "/tmp/e2e-fixtures/unauthorized-key" is known as "<unauthorized-key>"
    And the content of "/tmp/e2e-fixtures/git-ssh/id_ed25519" is known as "<authorized-key>"

    And "kubectl create configmap git-tls-ca -n <namespace> --from-file=ca-cert.pem=/tmp/e2e-fixtures/git-tls/ca-cert.pem --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "docker buildx inspect devcontainer-builder-test || docker buildx create --name devcontainer-builder-test --driver remote tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234" has been run
    And "docker buildx build --builder devcontainer-builder-test -t ghcr.io/alexanderilyin/devcontainer-builder-test:test --push ../service" has been run

  @client-request
  Scenario Outline: No credentials resolve anywhere - the given URL is cloned verbatim
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<repository>", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be <status>
    And the response body should contain "<expect>"

    Examples:
      | repository                                                    | status | expect               |
      | <git-url>/example/example-devcontainer.git            | 200    | example-devcontainer |
      | <http-url>/example/example-devcontainer.git           | 200    | example-devcontainer |
      | git@<git-host>:example/example-devcontainer.git       | 500    | git clone            |
      | <ssh-url>/example/example-devcontainer.git            | 500    | git clone            |

  @negative @client-request
  Scenario: An unparseable repository URL is rejected
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "not a git url at all", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 400
    And the response body should include:
      """
      { "error": "unable to parse git repository URL: not a git url at all" }
      """

  @client-request
  Scenario: Request-level gitCredentials rewrite an SCP-style URL to HTTPS
    Given the following is written to "/tmp/e2e-fixtures/git-tls-ca-values.yaml":
      """
      extraEnv:
        - name: GIT_SSL_CAINFO
          value: /etc/git-tls/ca-cert.pem
      extraVolumes:
        - name: git-tls-ca
          configMap:
            name: git-tls-ca
      extraVolumeMounts:
        - name: git-tls-ca
          mountPath: /etc/git-tls
          readOnly: true
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false -f /tmp/e2e-fixtures/git-tls-ca-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "git@<git-host>:example/example-devcontainer.git",
        "gitCredentials": { "username": "svc-bot", "token": "ghp_example" },
        "image": { "registry": "<registry-url>" }
      }
      """
    Then the response status should be 200
    And the response body should contain "example-devcontainer"

  @server-config
  Scenario: A server-configured HTTPS credential is used when the request supplies none
    Given the following is written to "/tmp/e2e-fixtures/https-cred-values.yaml":
      """
      gitCredentials:
        entries:
          - host: <git-host>
            kind: https
            username: svc-bot
            token: ghp_example
      extraEnv:
        - name: GIT_SSL_CAINFO
          value: /etc/git-tls/ca-cert.pem
      extraVolumes:
        - name: git-tls-ca
          configMap:
            name: git-tls-ca
      extraVolumeMounts:
        - name: git-tls-ca
          mountPath: /etc/git-tls
          readOnly: true
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/https-cred-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<git-url>/example/example-devcontainer.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 200
    And the response body should contain "example-devcontainer"

  @server-config
  Scenario: A server-configured SSH credential rewrites an HTTPS request URL to SSH
    Given "jq -n --arg host \"<git-host>\" --arg key \"$(cat /tmp/e2e-fixtures/git-ssh/id_ed25519)\" '[{host: $host, kind: \"ssh\", privateKey: $key}]' > /tmp/e2e-fixtures/ssh-authorized-creds.json" has been run
    And "kubectl create secret generic ssh-authorized-creds -n <namespace> --from-file=git-credentials.json=/tmp/e2e-fixtures/ssh-authorized-creds.json --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.existingSecret=ssh-authorized-creds --set sshHostKeyPolicy=tofu --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "https://<git-host>/example/example-devcontainer.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 200
    And the response body should contain "example-devcontainer"

  @server-config @client-request
  Scenario: Request-level gitCredentials win over a server-configured SSH default for the same host
    # If this regressed (server SSH wrongly won), the clone would instead
    # try ssh://<git-host>/... using the deliberately unauthorized
    # key below - a real, fast, clean "Permission denied" failure (not a
    # hang or timeout, since the SSH fixture genuinely listens and
    # responds), cleanly distinguishable from the 200 expected here.
    Given "jq -n --arg host \"<git-host>\" --arg key \"$(cat /tmp/e2e-fixtures/unauthorized-key)\" '[{host: $host, kind: \"ssh\", privateKey: $key}]' > /tmp/e2e-fixtures/ssh-unauthorized-creds.json" has been run
    And "kubectl create secret generic ssh-unauthorized-creds -n <namespace> --from-file=git-credentials.json=/tmp/e2e-fixtures/ssh-unauthorized-creds.json --dry-run=client -o yaml | kubectl apply -f -" has been run
    And the following is written to "/tmp/e2e-fixtures/git-tls-ca-values.yaml":
      """
      extraEnv:
        - name: GIT_SSL_CAINFO
          value: /etc/git-tls/ca-cert.pem
      extraVolumes:
        - name: git-tls-ca
          configMap:
            name: git-tls-ca
      extraVolumeMounts:
        - name: git-tls-ca
          mountPath: /etc/git-tls
          readOnly: true
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.existingSecret=ssh-unauthorized-creds -f /tmp/e2e-fixtures/git-tls-ca-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      {
        "repository": "https://<git-host>/example/example-devcontainer.git",
        "gitCredentials": { "username": "svc-bot", "token": "ghp_example" },
        "image": { "registry": "<registry-url>" }
      }
      """
    Then the response status should be 200
    And the response body should contain "example-devcontainer"

  @server-config
  Scenario: Each host uses only its own server-configured credential
    # git.invalid is a reserved TLD (RFC 2606) guaranteed to never resolve -
    # a genuinely wrong host that fails fast and cleanly on DNS lookup
    # alone, with no dependency on any second real server.
    Given the following is written to "/tmp/e2e-fixtures/two-host-cred-values.yaml":
      """
      gitCredentials:
        entries:
          - host: <git-host>
            kind: https
            username: svc-bot
            token: ghp_example
          - host: git.invalid
            kind: https
            username: other-bot
            token: glpat_example
      extraEnv:
        - name: GIT_SSL_CAINFO
          value: /etc/git-tls/ca-cert.pem
      extraVolumes:
        - name: git-tls-ca
          configMap:
            name: git-tls-ca
      extraVolumeMounts:
        - name: git-tls-ca
          mountPath: /etc/git-tls
          readOnly: true
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/two-host-cred-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "git@<git-host>:example/example-devcontainer.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 200
    And the response body should contain "example-devcontainer"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "git@git.invalid:example/example-devcontainer.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 500
    And the devcontainer-builder's logs are captured
    And the service logs should contain "Could not resolve host: git.invalid"

  @server-config
  Scenario: A host with no matching server credential falls back to a verbatim, unauthenticated clone
    Given the following is written to "/tmp/e2e-fixtures/unrelated-host-cred-values.yaml":
      """
      gitCredentials:
        entries:
          - host: example.com
            kind: https
            username: svc-bot
            token: ghp_example
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/unrelated-host-cred-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<git-url>/example/example-devcontainer.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 200

  @server-config
  Scenario: TOFU host key policy trusts the fixture's host key and proceeds to authentication
    Given "jq -n --arg host \"<git-host>\" --arg key \"$(cat /tmp/e2e-fixtures/unauthorized-key)\" '[{host: $host, kind: \"ssh\", privateKey: $key}]' > /tmp/e2e-fixtures/ssh-tofu-creds.json" has been run
    And "kubectl create secret generic ssh-tofu-creds -n <namespace> --from-file=git-credentials.json=/tmp/e2e-fixtures/ssh-tofu-creds.json --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.existingSecret=ssh-tofu-creds --set sshHostKeyPolicy=tofu --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "ssh://<git-host>/example/example-devcontainer.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 500
    And the response body should contain "git clone"
    And the devcontainer-builder's logs are captured
    And the service logs should not contain "Host key verification failed"

  @server-config
  Scenario: Pinned host key policy uses the configured pin without needing a scan
    Given "ssh-keyscan -t ed25519 test-git-server-test-git-server.<namespace>.svc.cluster.local 2>/dev/null | grep -v '^#' | head -1" has been run
    And the command output is known as "<current-host-key>"
    And "jq -n --arg host \"<git-host>\" --arg key \"$(cat /tmp/e2e-fixtures/unauthorized-key)\" --arg pin \"<current-host-key>\" '[{host: $host, kind: \"ssh\", privateKey: $key, pinnedHostKey: $pin}]' > /tmp/e2e-fixtures/ssh-pinned-creds.json" has been run
    And "kubectl create secret generic ssh-pinned-creds -n <namespace> --from-file=git-credentials.json=/tmp/e2e-fixtures/ssh-pinned-creds.json --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.existingSecret=ssh-pinned-creds --set sshHostKeyPolicy=pinned --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "ssh://<git-host>/example/example-devcontainer.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 500
    And the response body should contain "git clone"
    And the devcontainer-builder's logs are captured
    And the service logs should not contain "Host key verification failed"

  @negative @server-config
  Scenario: Pinned host key policy without a configured pin fails closed
    Given "jq -n --arg host \"<git-host>\" --arg key \"$(cat /tmp/e2e-fixtures/unauthorized-key)\" '[{host: $host, kind: \"ssh\", privateKey: $key}]' > /tmp/e2e-fixtures/ssh-nopin-creds.json" has been run
    And "kubectl create secret generic ssh-nopin-creds -n <namespace> --from-file=git-credentials.json=/tmp/e2e-fixtures/ssh-nopin-creds.json --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.existingSecret=ssh-nopin-creds --set sshHostKeyPolicy=pinned --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "ssh://<git-host>/example/example-devcontainer.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 400
    And the response body should contain "no pinned key configured for host"

  @server-config
  Scenario: Pinned host key policy succeeds end to end with a correct pin and an authorized key
    # The other pinned scenarios above only prove the policy *branches*
    # correctly (skips the scan, fails closed with no pin) - none of them
    # ever reach a real success, so "pinned" reaching an actual working
    # clone was unverified. The unauthorized key used elsewhere is
    # deliberate there (isolates host-key behavior from auth); this one
    # swaps in the real authorized key specifically to prove "pinned" can
    # carry a request all the way through, not just fail predictably.
    Given "ssh-keyscan -t ed25519 test-git-server-test-git-server.<namespace>.svc.cluster.local 2>/dev/null | grep -v '^#' | head -1" has been run
    And the command output is known as "<current-host-key>"
    And "jq -n --arg host \"<git-host>\" --arg key \"$(cat /tmp/e2e-fixtures/git-ssh/id_ed25519)\" --arg pin \"<current-host-key>\" '[{host: $host, kind: \"ssh\", privateKey: $key, pinnedHostKey: $pin}]' > /tmp/e2e-fixtures/ssh-pinned-ok-creds.json" has been run
    And "kubectl create secret generic ssh-pinned-ok-creds -n <namespace> --from-file=git-credentials.json=/tmp/e2e-fixtures/ssh-pinned-ok-creds.json --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.existingSecret=ssh-pinned-ok-creds --set sshHostKeyPolicy=pinned --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "ssh://<git-host>/example/example-devcontainer.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 200
    And the response body should contain "example-devcontainer"

  @negative @server-config
  Scenario: Pinned host key policy rejects a stale or incorrect pin
    # "<wrong-host-key>" is a real, syntactically valid known_hosts line for
    # this host - just from an unrelated keypair - so this is a genuine
    # host-key mismatch (the actual security case "pinned" exists for),
    # not a parse error standing in for one.
    Given "rm -f /tmp/e2e-fixtures/decoy-key /tmp/e2e-fixtures/decoy-key.pub && ssh-keygen -t ed25519 -N '' -f /tmp/e2e-fixtures/decoy-key -C decoy" has been run
    And "sed 's/^/<git-host> /' /tmp/e2e-fixtures/decoy-key.pub" has been run
    And the command output is known as "<wrong-host-key>"
    And "jq -n --arg host \"<git-host>\" --arg key \"$(cat /tmp/e2e-fixtures/git-ssh/id_ed25519)\" --arg pin \"<wrong-host-key>\" '[{host: $host, kind: \"ssh\", privateKey: $key, pinnedHostKey: $pin}]' > /tmp/e2e-fixtures/ssh-wrongpin-creds.json" has been run
    And "kubectl create secret generic ssh-wrongpin-creds -n <namespace> --from-file=git-credentials.json=/tmp/e2e-fixtures/ssh-wrongpin-creds.json --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.existingSecret=ssh-wrongpin-creds --set sshHostKeyPolicy=pinned --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "ssh://<git-host>/example/example-devcontainer.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 500
    And the response body should contain "git clone"
    And the devcontainer-builder's logs are captured
    And the service logs should contain "Host key verification failed"

  @negative @server-config
  Scenario: A malformed SSH private key fails clearly at clone time, not at config load
    # config.ts's validation only checks privateKey is a non-empty string -
    # garbage content passes startup and is only ever exercised for real
    # once a request actually tries to use it.
    Given the following is written to "/tmp/e2e-fixtures/bad-key-values.yaml":
      """
      gitCredentials:
        entries:
          - host: <git-host>
            kind: ssh
            privateKey: this is not a real private key at all
      sshHostKeyPolicy: tofu
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> -f /tmp/e2e-fixtures/bad-key-values.yaml --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "ssh://<git-host>/example/example-devcontainer.git", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 500
    And the response body should contain "git clone"
    And the devcontainer-builder's logs are captured
    And the service logs should contain "error in libcrypto"

  @negative
  Scenario Outline: A failed clone surfaces as a 500 regardless of the credential path used
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=<buildkit-endpoint> --set gitCredentials.enabled=false --set updateStrategy.type=Recreate --wait --timeout 120s" has been run again
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "<repository>", "image": { "registry": "<registry-url>" } }
      """
    Then the response status should be 500
    And the response body should contain "git clone"

    Examples:
      | repository                                            |
      | <git-url>/example/nonexistent-repo.git         |
      | <http-url>/example/nonexistent-repo.git        |
