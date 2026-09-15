Feature: Service startup configuration loading
  As an operator deploying devcontainer-builder
  I want misconfiguration caught at startup rather than surfacing as mysterious per-request failures
  So that a bad deployment fails its readiness/liveness checks immediately instead of serving broken requests

  Runs the real service as a Kubernetes Deployment via its own Helm chart.
  A misconfiguration that crashes the process before it ever calls
  `server.listen()` means the pod can never pass its readiness probe - so
  rather than a `helm upgrade --install --wait` that's doomed to sit out
  its full timeout every time, "<cmd>" causes the deployment to crash loop
  applies the config (expecting the `helm` command itself to succeed - it
  only submits the manifest), then polls the pod's own restart count
  directly and captures the crashed instance's own stderr (`kubectl logs
  ... --previous`) as soon as it actually crashes, typically within a few
  seconds. "the startup error should mention" checks that captured text.

  Background:
    Given "echo devcontainer-builder-${CODER_WORKSPACE_OWNER_NAME:-${USER:-local}}-default" has been run
    And the command output is known as "<namespace>"
    And "kubectl create namespace <namespace> --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=privileged --overwrite" has been run
    And "docker buildx inspect devcontainer-builder-test || docker buildx create --name devcontainer-builder-test --driver remote tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234" has been run
    And "docker buildx build --builder devcontainer-builder-test -t ghcr.io/alexanderilyin/devcontainer-builder-test:test --push ../service" has been run

  @server-config
  Scenario: The service starts normally when no optional config paths are set
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=tcp://buildkit.example:1234 --set gitCredentials.enabled=false --set registryMapping.enabled=false --set updateStrategy.type=Recreate --wait --timeout 90s" has been run again
    Then the service should start successfully
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a GET request to "<base-url>/health/live"
    Then the response status should be 200

  @negative @server-config
  Scenario: A git credentials config path pointing at a nonexistent file prevents startup
    # Distinct from an *unset* path (a supported "feature not configured"
    # state, see "no optional config paths are set" above) and from a
    # malformed-but-present file (below) - this is a configured path that
    # simply isn't there (e.g. a Helm mount typo), which should fail the
    # same way a bad BUILDKIT_ENDPOINT would: fast, at startup, with a
    # message naming which config it couldn't read.
    Given the following is written to "/tmp/e2e-fixtures/git-cred-missing-path-values.yaml":
      """
      gitCredentials:
        enabled: false
      extraEnv:
        - name: GIT_CREDENTIALS_CONFIG_PATH
          value: /config/does-not-exist.json
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always -f /tmp/e2e-fixtures/git-cred-missing-path-values.yaml --set updateStrategy.type=Recreate" causes the deployment to crash loop
    Then the service should fail to start
    And the startup error should mention "failed to read git credentials config"

  @negative @server-config
  Scenario: A malformed git credentials config file prevents startup
    Given "kubectl create secret generic bad-git-creds-malformed -n <namespace> --from-literal='git-credentials.json={ this is not valid JSON' --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set gitCredentials.existingSecret=bad-git-creds-malformed --set updateStrategy.type=Recreate" causes the deployment to crash loop
    Then the service should fail to start
    And the startup error should mention "failed to parse git credentials config"

  @negative @server-config
  Scenario: A git credentials config file that isn't a JSON array prevents startup
    Given "kubectl create secret generic bad-git-creds-not-array -n <namespace> --from-literal='git-credentials.json={ \"host\": \"github.com\", \"kind\": \"https\", \"username\": \"svc-bot\", \"token\": \"ghp_example\" }' --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set gitCredentials.existingSecret=bad-git-creds-not-array --set updateStrategy.type=Recreate" causes the deployment to crash loop
    Then the service should fail to start
    And the startup error should mention "must be a JSON array"

  @server-config
  Scenario: One malformed entry in an otherwise-valid git credentials list is skipped, not fatal
    # Only checks that startup itself tolerates the bad entry - proving the
    # *valid* entry is actually usable would need a real network operation
    # against its host, which isn't reliable to depend on in a test (see the
    # SSH_HOST_KEY_POLICY scenario below for how that's done safely against
    # a real, disposable test fixture instead of a live third-party host).
    Given the following is written to "/tmp/e2e-fixtures/git-cred-one-bad-entry-values.yaml":
      """
      buildkit:
        endpoint: tcp://buildkit.example:1234
      gitCredentials:
        entries:
          - host: github.com
            kind: https
            username: svc-bot
            token: ghp_example
          - kind: https
            username: missing-host
            token: ghp_other
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always -f /tmp/e2e-fixtures/git-cred-one-bad-entry-values.yaml --set updateStrategy.type=Recreate --wait --timeout 90s" has been run again
    Then the service should start successfully
    And the devcontainer-builder's logs are captured
    And the invalid entry should have been logged and skipped

  @negative @server-config
  Scenario: A registry mapping config file that isn't a JSON array prevents startup
    Given "kubectl create configmap bad-registry-mapping-not-array -n <namespace> --from-literal='registry-mapping.json={ \"hostMatch\": \"github.com\", \"registry\": \"ghcr.io/example\" }' --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set registryMapping.existingConfigMap=bad-registry-mapping-not-array --set updateStrategy.type=Recreate" causes the deployment to crash loop
    Then the service should fail to start
    And the startup error should mention "must be a JSON array"

  @server-config
  Scenario: A missing registry mapping entry field is skipped, not fatal
    Given the following is written to "/tmp/e2e-fixtures/registry-mapping-missing-field-values.yaml":
      """
      buildkit:
        endpoint: tcp://buildkit.example:1234
      registryMapping:
        rules:
          - hostMatch: github.com
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always -f /tmp/e2e-fixtures/registry-mapping-missing-field-values.yaml --set updateStrategy.type=Recreate --wait --timeout 90s" has been run again
    Then the service should start successfully
    And the devcontainer-builder's logs are captured
    And the invalid entry should have been logged and skipped

  @negative @server-config
  Scenario: An unrecognized SSH_HOST_KEY_POLICY value prevents startup
    Given "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set sshHostKeyPolicy=strict --set updateStrategy.type=Recreate" causes the deployment to crash loop
    Then the service should fail to start
    And the startup error should mention "SSH_HOST_KEY_POLICY must be \"tofu\" or \"pinned\""

  @negative @server-config
  Scenario: An unrecognized CLI flag prevents startup
    # The CLI-flag config layer (see service_settings_file.feature for the
    # settings-file layer) fails the same way every other startup
    # misconfiguration in this file does - loudly, at startup, not silently
    # ignored.
    Given the following is written to "/tmp/e2e-fixtures/bogus-cli-flag-values.yaml":
      """
      extraArgs:
        - --bogus-flag
        - anything
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always -f /tmp/e2e-fixtures/bogus-cli-flag-values.yaml --set updateStrategy.type=Recreate" causes the deployment to crash loop
    Then the service should fail to start

  @server-config @needs-ssh-fixture
  Scenario: SSH_HOST_KEY_POLICY defaults to "tofu" when unset
    # Runs against a real, disposable git-ssh container rather than faking
    # the SSH protocol. The key generated below is deliberately never added
    # to the fixture's authorized_keys, so a real clone against it is
    # expected to fail - but at the *authentication* step, after host-key
    # verification already succeeded. That sequence is the real, observable
    # signature of "TOFU scanned and trusted the host key" as opposed to
    # "pinned" failing closed before ever attempting a connection.
    Given "kubectl create namespace <namespace> --dry-run=client -o yaml | kubectl apply -f -" has been run
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
    And "rm -f /tmp/e2e-fixtures/unauthorized-key /tmp/e2e-fixtures/unauthorized-key.pub && ssh-keygen -t ed25519 -N '' -f /tmp/e2e-fixtures/unauthorized-key -C unauthorized" has been run
    And "jq -n --arg host \"<git-host>\" --arg key \"$(cat /tmp/e2e-fixtures/unauthorized-key)\" '[{host: $host, kind: \"ssh\", privateKey: $key}]' > /tmp/e2e-fixtures/ssh-tofu-git-creds.json" has been run
    And "kubectl create secret generic ssh-tofu-git-creds -n <namespace> --from-file=git-credentials.json=/tmp/e2e-fixtures/ssh-tofu-git-creds.json --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set buildkit.endpoint=tcp://buildkit.example:1234 --set gitCredentials.existingSecret=ssh-tofu-git-creds --set updateStrategy.type=Recreate --wait --timeout 90s" has been run again
    Then the service should start successfully
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "https://<git-host>/example/example-devcontainer.git", "image": { "registry": "ghcr.io/example" } }
      """
    Then the response status should be 500
    And the response body should contain "git clone"
    And the devcontainer-builder's logs are captured
    And the service logs should not contain "Host key verification failed"

  @server-config @needs-ssh-fixture
  Scenario: A --ssh-host-key-policy CLI flag overrides both the env var and the settings file
    # Proves config.ts's full precedence chain (CLI flag > env var >
    # settings file > default) with one real, observable outcome: env var
    # and settings file both say "pinned" (which would fail closed before
    # ever attempting a connection, given no pinnedHostKey is configured)
    # here specifically to isolate the CLI flag's own precedence over
    # *both* lower sources at once - if the CLI layer were wired wrong
    # (ignored, or checked after the env var instead of before), this
    # would fail closed instead of reaching the authentication step, the
    # same signature "defaults to tofu" above proves.
    Given "kubectl create namespace <namespace> --dry-run=client -o yaml | kubectl apply -f -" has been run
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
    And "rm -f /tmp/e2e-fixtures/unauthorized-key /tmp/e2e-fixtures/unauthorized-key.pub && ssh-keygen -t ed25519 -N '' -f /tmp/e2e-fixtures/unauthorized-key -C unauthorized" has been run
    And "jq -n --arg host \"<git-host>\" --arg key \"$(cat /tmp/e2e-fixtures/unauthorized-key)\" '[{host: $host, kind: \"ssh\", privateKey: $key}]' > /tmp/e2e-fixtures/ssh-cli-override-git-creds.json" has been run
    And "kubectl create secret generic ssh-cli-override-git-creds -n <namespace> --from-file=git-credentials.json=/tmp/e2e-fixtures/ssh-cli-override-git-creds.json --dry-run=client -o yaml | kubectl apply -f -" has been run
    And the following is written to "/tmp/e2e-fixtures/ssh-cli-override-values.yaml":
      """
      buildkit:
        endpoint: tcp://buildkit.example:1234
      sshHostKeyPolicy: pinned
      settingsFile:
        content: |
          { "sshHostKeyPolicy": "pinned" }
        filename: settings.json
      extraArgs:
        - --ssh-host-key-policy
        - tofu
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set gitCredentials.existingSecret=ssh-cli-override-git-creds -f /tmp/e2e-fixtures/ssh-cli-override-values.yaml --set updateStrategy.type=Recreate --wait --timeout 90s" has been run again
    Then the service should start successfully
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a POST request to "<base-url>/build" with body:
      """
      { "repository": "https://<git-host>/example/example-devcontainer.git", "image": { "registry": "ghcr.io/example" } }
      """
    Then the response status should be 500
    And the response body should contain "git clone"
    And the devcontainer-builder's logs are captured
    And the service logs should not contain "Host key verification failed"
