Feature: The chart-rendered settings file
  As an operator deploying devcontainer-builder
  I want the chart to render its own settings file from real values
  So that I never hand-author or escape a JSON/YAML blob myself

  Distinct from service_startup_configuration.feature's other scenarios,
  which exercise individual env vars and the two dedicated
  GIT_CREDENTIALS_CONFIG_PATH/REGISTRY_MAPPING_CONFIG_PATH files - this
  file is about the general SERVICE_CONFIG_PATH settings file itself:
  that the chart renders it automatically from buildkit.endpoint/
  sshHostKeyPolicy/registryMapping.rules (no settingsFile.* value exists
  any more - see charts/devcontainer-builder/templates/_helpers.tpl's
  settingsJson helper), and that config.ts's own parser/validator still
  fails loudly on malformed content, now reached through the chart's
  generic extraVolumes/extraVolumeMounts/extraEnv escape hatches rather
  than a dedicated value (gitCredentials is deliberately never part of
  the chart-rendered settings file - GIT_CREDENTIALS_CONFIG_PATH always
  wins over it - so the malformed-git-credentials-entry scenario below is
  the one negative case that has to inject its own settings file with
  gitCredentials.enabled=false, to actually exercise that embedded-list
  validation path in config.ts rather than the dedicated one).

  Background:
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

    Given Docker Buildx Builder known as "<Builder>":
      | PROPERTY | VALUE                                                            |
      | name     | devcontainer-builder-settings-file-w<WorkerId> |
      | endpoint | tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234 |
    When I create Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I build and push "ghcr.io/deepspacecartel/devcontainer-builder-test:test" from "." using Docker Buildx Builder known as "<Builder>" with:
      | OPTION | VALUE |
    Then the command exited with 0

    Given Directory "<ChartDirectory>" at "../charts/devcontainer-builder"
    And Helm Chart "<Chart>" in "<ChartDirectory>"

  @server-config
  Scenario: buildkit, ssh host key policy, git credentials, and registry mapping set via values all reach the rendered settings file
    Given Helm Release known as "<Release>":
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
      | --set              | buildkit.endpoint=tcp://buildkit.example:1234                      |
      | --set              | sshHostKeyPolicy=pinned                                            |
      | --set              | gitCredentials.entries[0].host=github.com                         |
      | --set              | gitCredentials.entries[0].kind=https                               |
      | --set              | gitCredentials.entries[0].username=svc-bot                        |
      | --set              | gitCredentials.entries[0].token=ghp_example                        |
      | --set              | registryMapping.rules[0].hostMatch=github.com                      |
      | --set              | registryMapping.rules[0].registry=ghcr.io/example                  |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"
    When I send a GET request to Endpoint known as "<AppApi>" path "/health/ready"
    Then the response status is 200

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: A malformed settings file mounted via extraVolumes prevents startup - invalid JSON
    When I create File known as "<SettingsFile>" at ".cache/fixtures/service-settings-file-w<WorkerId>/settings-bad-json.json" with:
      """
      { this is not valid JSON
      """
    When I create ConfigMap known as "<BadSettingsConfigMap>" named "bad-settings-json-w<WorkerId>" in "<Namespace>" from file "settings.json" at ".cache/fixtures/service-settings-file-w<WorkerId>/settings-bad-json.json"
    Then the command exited with 0
    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION     | VALUE                                                                                                                       |
      | --install  | True                                                                                                                        |
      | --set      | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                                                          |
      | --set      | image.tag=test                                                                                                              |
      | --set      | image.pullPolicy=Always                                                                                                    |
      | --set-json | extraVolumes=[{"name":"bad-settings","configMap":{"name":"bad-settings-json-w<WorkerId>"}}]                                |
      | --set-json | extraVolumeMounts=[{"name":"bad-settings","mountPath":"/home/builder/.config/bad-settings.json","subPath":"settings.json"}] |
      | --set-json | extraEnv=[{"name":"SERVICE_CONFIG_PATH","value":"/home/builder/.config/bad-settings.json"}]                                |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    When I poll logs for Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | SOURCE | CONDITION | VALUE                          | OUTCOME |
      | STDOUT | contains  | failed to parse settings config | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete ConfigMap known as "<BadSettingsConfigMap>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: A malformed settings file mounted via extraVolumes prevents startup - invalid YAML
    When I create File known as "<SettingsFile>" at ".cache/fixtures/service-settings-file-w<WorkerId>/settings-bad-yaml.yaml" with:
      """
      buildkit: [ unterminated
      """
    When I create ConfigMap known as "<BadSettingsConfigMap>" named "bad-settings-yaml-w<WorkerId>" in "<Namespace>" from file "settings.yaml" at ".cache/fixtures/service-settings-file-w<WorkerId>/settings-bad-yaml.yaml"
    Then the command exited with 0
    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION     | VALUE                                                                                                                     |
      | --install  | True                                                                                                                      |
      | --set      | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                                                        |
      | --set      | image.tag=test                                                                                                            |
      | --set      | image.pullPolicy=Always                                                                                                  |
      | --set-json | extraVolumes=[{"name":"bad-settings","configMap":{"name":"bad-settings-yaml-w<WorkerId>"}}]                              |
      | --set-json | extraVolumeMounts=[{"name":"bad-settings","mountPath":"/home/builder/.config/bad-settings.yaml","subPath":"settings.yaml"}] |
      | --set-json | extraEnv=[{"name":"SERVICE_CONFIG_PATH","value":"/home/builder/.config/bad-settings.yaml"}]                              |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    When I poll logs for Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | SOURCE | CONDITION | VALUE                          | OUTCOME |
      | STDOUT | contains  | failed to parse settings config | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete ConfigMap known as "<BadSettingsConfigMap>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: A settings file that isn't a JSON/YAML object prevents startup
    When I create File known as "<SettingsFile>" at ".cache/fixtures/service-settings-file-w<WorkerId>/settings-not-object.json" with:
      """
      [ "not", "an", "object" ]
      """
    When I create ConfigMap known as "<BadSettingsConfigMap>" named "bad-settings-not-object-w<WorkerId>" in "<Namespace>" from file "settings.json" at ".cache/fixtures/service-settings-file-w<WorkerId>/settings-not-object.json"
    Then the command exited with 0
    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION     | VALUE                                                                                                                       |
      | --install  | True                                                                                                                        |
      | --set      | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                                                          |
      | --set      | image.tag=test                                                                                                              |
      | --set      | image.pullPolicy=Always                                                                                                    |
      | --set-json | extraVolumes=[{"name":"bad-settings","configMap":{"name":"bad-settings-not-object-w<WorkerId>"}}]                          |
      | --set-json | extraVolumeMounts=[{"name":"bad-settings","mountPath":"/home/builder/.config/bad-settings.json","subPath":"settings.json"}] |
      | --set-json | extraEnv=[{"name":"SERVICE_CONFIG_PATH","value":"/home/builder/.config/bad-settings.json"}]                                |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    When I poll logs for Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | SOURCE | CONDITION | VALUE                        | OUTCOME |
      | STDOUT | contains  | must be a JSON/YAML object   | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete ConfigMap known as "<BadSettingsConfigMap>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: A wrong-typed settings file field prevents startup
    When I create File known as "<SettingsFile>" at ".cache/fixtures/service-settings-file-w<WorkerId>/settings-wrong-type.json" with:
      """
      { "buildkit": { "endpoint": 1234 } }
      """
    When I create ConfigMap known as "<BadSettingsConfigMap>" named "bad-settings-wrong-type-w<WorkerId>" in "<Namespace>" from file "settings.json" at ".cache/fixtures/service-settings-file-w<WorkerId>/settings-wrong-type.json"
    Then the command exited with 0
    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION     | VALUE                                                                                                                       |
      | --install  | True                                                                                                                        |
      | --set      | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                                                          |
      | --set      | image.tag=test                                                                                                              |
      | --set      | image.pullPolicy=Always                                                                                                    |
      | --set-json | extraVolumes=[{"name":"bad-settings","configMap":{"name":"bad-settings-wrong-type-w<WorkerId>"}}]                          |
      | --set-json | extraVolumeMounts=[{"name":"bad-settings","mountPath":"/home/builder/.config/bad-settings.json","subPath":"settings.json"}] |
      | --set-json | extraEnv=[{"name":"SERVICE_CONFIG_PATH","value":"/home/builder/.config/bad-settings.json"}]                                |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    When I poll logs for Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | SOURCE | CONDITION | VALUE                                                        | OUTCOME |
      | STDOUT | contains  | settings file field \"buildkit.endpoint\" must be a string    | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete ConfigMap known as "<BadSettingsConfigMap>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: One malformed entry in a settings file's embedded git credentials list is skipped, not fatal
    # Mirrors "One malformed entry in an otherwise-valid git credentials
    # list is skipped, not fatal" in service_startup_configuration.feature
    # for the dedicated GIT_CREDENTIALS_CONFIG_PATH file - same real
    # validation code path (config.ts's validateEntries), reached from a
    # settings file instead. gitCredentials.enabled=false is required here
    # (unlike the positive scenario above) - GIT_CREDENTIALS_CONFIG_PATH
    # always wins over a settings file's own gitCredentials, so it must be
    # unset for this settings file's embedded list to actually be read at
    # all.
    When I create File known as "<SettingsFile>" at ".cache/fixtures/service-settings-file-w<WorkerId>/settings-bad-entry.json" with:
      """
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
    When I create ConfigMap known as "<BadSettingsConfigMap>" named "bad-settings-entry-w<WorkerId>" in "<Namespace>" from file "settings.json" at ".cache/fixtures/service-settings-file-w<WorkerId>/settings-bad-entry.json"
    Then the command exited with 0
    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION     | VALUE                                                                                                                       |
      | --install  | True                                                                                                                        |
      | --set      | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                                                          |
      | --set      | image.tag=test                                                                                                              |
      | --set      | image.pullPolicy=Always                                                                                                    |
      | --set      | gitCredentials.enabled=false                                                                                                |
      | --set-json | extraVolumes=[{"name":"bad-settings","configMap":{"name":"bad-settings-entry-w<WorkerId>"}}]                               |
      | --set-json | extraVolumeMounts=[{"name":"bad-settings","mountPath":"/home/builder/.config/bad-settings.json","subPath":"settings.json"}] |
      | --set-json | extraEnv=[{"name":"SERVICE_CONFIG_PATH","value":"/home/builder/.config/bad-settings.json"}]                                |
      | --wait     | True                                                                                                                        |
      | --timeout  | 120s                                                                                                                        |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I poll logs for Pod known as "<AppPod>" every "1s" for up to "10s" until:
      | SOURCE | CONDITION | VALUE                                                    | OUTCOME |
      | STDOUT | contains  | skipping invalid git credentials config entry at index 1 | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete ConfigMap known as "<BadSettingsConfigMap>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0
