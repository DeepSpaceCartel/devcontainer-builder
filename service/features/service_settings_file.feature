Feature: Loading settings from a JSON or YAML file
  As an operator deploying devcontainer-builder
  I want to set the service's configuration from one file instead of many env vars
  So that a deployment can ship one mounted settings file alongside (or instead of) individual env vars

  Distinct from service_startup_configuration.feature's other scenarios,
  which exercise individual env vars and the two dedicated
  GIT_CREDENTIALS_CONFIG_PATH/REGISTRY_MAPPING_CONFIG_PATH files - this
  file is about the general SERVICE_CONFIG_PATH settings file itself:
  its JSON/YAML parsing, its shape (deliberately mirroring
  charts/devcontainer-builder/values.yaml), and its own validation
  behavior. Precedence between this file, env vars, and CLI flags is
  covered separately in service_startup_configuration.feature's
  SSH_HOST_KEY_POLICY precedence scenarios, which can prove a real
  behavioral difference between sources - a settings-file-only scenario
  here can only prove the file loaded without error, the same modest
  scope the dedicated-file scenarios already use for the same reason.

  Runs the real service as a Kubernetes Deployment, same as
  service_startup_configuration.feature - see that file's Background
  comment for the crash-loop-detection mechanics negative scenarios here
  use ("<cmd>" causes the deployment to crash loop).

  Background:
    Given "echo devcontainer-builder-${CODER_WORKSPACE_OWNER_NAME:-${USER:-local}}-default" has been run
    And the command output is known as "<namespace>"
    And "kubectl create namespace <namespace> --dry-run=client -o yaml | kubectl apply -f -" has been run
    And "kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=privileged --overwrite" has been run
    And "docker buildx inspect devcontainer-builder-test || docker buildx create --name devcontainer-builder-test --driver remote tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234" has been run
    And "docker buildx build --builder devcontainer-builder-test -t ghcr.io/alexanderilyin/devcontainer-builder-test:test --push ../service" has been run

  @server-config
  Scenario: A JSON settings file can set buildkit, ssh host key policy, git credentials, and registry mapping together
    Given the following is written to "/tmp/e2e-fixtures/settings-json-values.yaml":
      """
      settingsFile:
        filename: settings.json
        content: |
          {
            "buildkit": { "endpoint": "tcp://buildkit.example:1234" },
            "sshHostKeyPolicy": "pinned",
            "gitCredentials": {
              "entries": [
                { "host": "github.com", "kind": "https", "username": "svc-bot", "token": "ghp_example" }
              ]
            },
            "registryMapping": {
              "rules": [
                { "hostMatch": "github.com", "registry": "ghcr.io/example" }
              ]
            }
          }
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always -f /tmp/e2e-fixtures/settings-json-values.yaml --set updateStrategy.type=Recreate --wait --timeout 90s" has been run again
    Then the service should start successfully
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a GET request to "<base-url>/health/ready"
    Then the response status should be 200

  @server-config
  Scenario: The identical settings in YAML produce the same outcome
    Given the following is written to "/tmp/e2e-fixtures/settings-yaml-values.yaml":
      """
      settingsFile:
        filename: settings.yaml
        content: |
          buildkit:
            endpoint: tcp://buildkit.example:1234
          sshHostKeyPolicy: pinned
          gitCredentials:
            entries:
              - host: github.com
                kind: https
                username: svc-bot
                token: ghp_example
          registryMapping:
            rules:
              - hostMatch: github.com
                registry: ghcr.io/example
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always -f /tmp/e2e-fixtures/settings-yaml-values.yaml --set updateStrategy.type=Recreate --wait --timeout 90s" has been run again
    Then the service should start successfully
    And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local/8080); do sleep 1; done'" has been run again
    And the value "http://devcontainer-builder-devcontainer-builder.<namespace>.svc.cluster.local:8080" is known as "<base-url>"
    When I send a GET request to "<base-url>/health/ready"
    Then the response status should be 200

  @negative @server-config
  Scenario: A settings file with invalid JSON prevents startup
    Given the following is written to "/tmp/e2e-fixtures/settings-bad-json-values.yaml":
      """
      settingsFile:
        filename: settings.json
        content: |
          { this is not valid JSON
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always -f /tmp/e2e-fixtures/settings-bad-json-values.yaml --set updateStrategy.type=Recreate" causes the deployment to crash loop
    Then the service should fail to start
    And the startup error should mention "failed to parse settings config"

  @negative @server-config
  Scenario: A settings file with invalid YAML prevents startup
    Given the following is written to "/tmp/e2e-fixtures/settings-bad-yaml-values.yaml":
      """
      settingsFile:
        filename: settings.yaml
        content: |
          buildkit: [ unterminated
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always -f /tmp/e2e-fixtures/settings-bad-yaml-values.yaml --set updateStrategy.type=Recreate" causes the deployment to crash loop
    Then the service should fail to start
    And the startup error should mention "failed to parse settings config"

  @negative @server-config
  Scenario: A settings file that isn't a JSON/YAML object prevents startup
    Given the following is written to "/tmp/e2e-fixtures/settings-not-object-values.yaml":
      """
      settingsFile:
        filename: settings.json
        content: |
          [ "not", "an", "object" ]
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always -f /tmp/e2e-fixtures/settings-not-object-values.yaml --set updateStrategy.type=Recreate" causes the deployment to crash loop
    Then the service should fail to start
    And the startup error should mention "must be a JSON/YAML object"

  @negative @server-config
  Scenario: A wrong-typed settings file field prevents startup
    Given the following is written to "/tmp/e2e-fixtures/settings-wrong-type-values.yaml":
      """
      settingsFile:
        filename: settings.json
        content: |
          { "buildkit": { "endpoint": 1234 } }
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always -f /tmp/e2e-fixtures/settings-wrong-type-values.yaml --set updateStrategy.type=Recreate" causes the deployment to crash loop
    Then the service should fail to start
    And the startup error should mention "settings file field \"buildkit.endpoint\" must be a string"

  @server-config
  Scenario: One malformed entry in a settings file's embedded git credentials list is skipped, not fatal
    # Mirrors "One malformed entry in an otherwise-valid git credentials
    # list is skipped, not fatal" in service_startup_configuration.feature
    # for the dedicated GIT_CREDENTIALS_CONFIG_PATH file - same validation
    # code path (validateEntries), reached from the settings file instead.
    Given the following is written to "/tmp/e2e-fixtures/settings-bad-entry-values.yaml":
      """
      settingsFile:
        filename: settings.json
        content: |
          {
            "buildkit": { "endpoint": "tcp://buildkit.example:1234" },
            "gitCredentials": {
              "entries": [
                { "host": "github.com", "kind": "https", "username": "svc-bot", "token": "ghp_example" },
                { "kind": "https", "username": "missing-host", "token": "ghp_other" }
              ]
            }
          }
      """
    And "helm upgrade --install devcontainer-builder ../charts/devcontainer-builder -n <namespace> --set image.repository=ghcr.io/alexanderilyin/devcontainer-builder-test --set image.tag=test --set image.pullPolicy=Always --set gitCredentials.enabled=false -f /tmp/e2e-fixtures/settings-bad-entry-values.yaml --set updateStrategy.type=Recreate --wait --timeout 90s" has been run again
    Then the service should start successfully
    And the devcontainer-builder's logs are captured
    And the invalid entry should have been logged and skipped
