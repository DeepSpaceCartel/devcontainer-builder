Feature: Service startup configuration loading
  As an operator deploying devcontainer-builder
  I want misconfiguration caught at startup rather than surfacing as mysterious per-request failures
  So that a bad deployment fails its readiness/liveness checks immediately instead of serving broken requests

  Runs the real service as a Kubernetes Deployment via its own Helm chart.
  A misconfiguration that crashes the process before it ever calls
  server.listen() means the pod can never pass its readiness probe - so
  rather than a doomed `--wait` that sits out its full timeout, every
  crash-loop scenario here installs without `--wait`, waits for the real
  Pod to become discoverable, then polls its own logs for the exact
  fatal-startup log line (same shape as every other log-based assertion
  already used throughout this migration - a container repeatedly
  crashing on a fatal startup error still deterministically re-produces
  the same log line on every attempt).

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
      | name     | devcontainer-builder-startup-configuration-w<WorkerId> |
      | endpoint | tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234 |
    When I create Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I build and push "ghcr.io/deepspacecartel/devcontainer-builder-test:test" from "." using Docker Buildx Builder known as "<Builder>" with:
      | OPTION | VALUE |
    Then the command exited with 0

    Given Directory "<ChartDirectory>" at "../charts/devcontainer-builder"
    And Helm Chart "<Chart>" in "<ChartDirectory>"

  @server-config
  Scenario: The service starts normally when no optional config paths are set
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
      | --set              | buildkit.endpoint=tcp://buildkit.example:1234                     |
      | --set              | gitCredentials.enabled=false                                       |
      | --set              | registryMapping.enabled=false                                      |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"
    When I send a GET request to Endpoint known as "<AppApi>" path "/health/live"
    Then the response status is 200

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: A git credentials config path pointing at a nonexistent file prevents startup
    # Distinct from an *unset* path (a supported "feature not configured"
    # state, see "no optional config paths are set" above) and from a
    # malformed-but-present file (below) - this is a configured path that
    # simply isn't there (e.g. a Helm mount typo), which should fail the
    # same way a bad BUILDKIT_ENDPOINT would: fast, at startup, with a
    # message naming which config it couldn't read.
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
      | --set              | gitCredentials.enabled=false                                       |
      | --set              | extraEnv[0].name=GIT_CREDENTIALS_CONFIG_PATH                       |
      | --set              | extraEnv[0].value=/config/does-not-exist.json                      |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    When I poll logs for Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | SOURCE | CONDITION | VALUE                                | OUTCOME |
      | STDOUT | contains  | failed to read git credentials config | pass   |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: A malformed git credentials config file prevents startup
    When I create File known as "<BadCredsFile>" at ".cache/fixtures/service-startup-configuration-w<WorkerId>/bad-git-creds-malformed.json" with:
      """
      { this is not valid JSON
      """
    When I create Secret known as "<BadCredsSecret>" named "bad-git-creds-malformed" in "<Namespace>" from file "git-credentials.json" at ".cache/fixtures/service-startup-configuration-w<WorkerId>/bad-git-creds-malformed.json"
    Then the command exited with 0
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
      | --set              | gitCredentials.existingSecret=bad-git-creds-malformed              |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    When I poll logs for Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | SOURCE | CONDITION | VALUE                                 | OUTCOME |
      | STDOUT | contains  | failed to parse git credentials config | pass   |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete Secret known as "<BadCredsSecret>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: A git credentials config file that isn't a JSON array prevents startup
    When I create File known as "<BadCredsFile>" at ".cache/fixtures/service-startup-configuration-w<WorkerId>/bad-git-creds-not-array.json" with:
      """
      { "host": "github.com", "kind": "https", "username": "svc-bot", "token": "ghp_example" }
      """
    When I create Secret known as "<BadCredsSecret>" named "bad-git-creds-not-array" in "<Namespace>" from file "git-credentials.json" at ".cache/fixtures/service-startup-configuration-w<WorkerId>/bad-git-creds-not-array.json"
    Then the command exited with 0
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
      | --set              | gitCredentials.existingSecret=bad-git-creds-not-array              |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    When I poll logs for Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | SOURCE | CONDITION | VALUE               | OUTCOME |
      | STDOUT | contains  | must be a JSON array | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete Secret known as "<BadCredsSecret>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: One malformed entry in an otherwise-valid git credentials list is skipped, not fatal
    # Only checks that startup itself tolerates the bad entry - proving
    # the *valid* entry is actually usable would need a real network
    # operation against its host, which isn't reliable to depend on here
    # (see the SSH_HOST_KEY_POLICY scenarios below for how that's done
    # safely against a real, disposable test fixture instead of a live
    # third-party host).
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
      | --set              | buildkit.endpoint=tcp://buildkit.example:1234                     |
      | --set              | gitCredentials.entries[0].host=github.com                          |
      | --set              | gitCredentials.entries[0].kind=https                               |
      | --set              | gitCredentials.entries[0].username=svc-bot                         |
      | --set              | gitCredentials.entries[0].token=ghp_example                        |
      | --set              | gitCredentials.entries[1].kind=https                               |
      | --set              | gitCredentials.entries[1].username=missing-host                    |
      | --set              | gitCredentials.entries[1].token=ghp_other                          |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
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
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: A registry mapping config file that isn't a JSON array prevents startup
    When I create File known as "<BadMappingFile>" at ".cache/fixtures/service-startup-configuration-w<WorkerId>/bad-registry-mapping-not-array.json" with:
      """
      { "hostMatch": "github.com", "registry": "ghcr.io/example" }
      """
    When I create ConfigMap known as "<BadMappingConfigMap>" named "bad-registry-mapping-not-array" in "<Namespace>" from file "registry-mapping.json" at ".cache/fixtures/service-startup-configuration-w<WorkerId>/bad-registry-mapping-not-array.json"
    Then the command exited with 0
    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                                 |
      | --install          | True                                                                  |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test    |
      | --set              | image.tag=test                                                        |
      | --set              | image.pullPolicy=Always                                               |
      | --set              | registryMapping.existingConfigMap=bad-registry-mapping-not-array     |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    When I poll logs for Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | SOURCE | CONDITION | VALUE               | OUTCOME |
      | STDOUT | contains  | must be a JSON array | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete ConfigMap known as "<BadMappingConfigMap>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: A missing registry mapping entry field is skipped, not fatal
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
      | --set              | buildkit.endpoint=tcp://buildkit.example:1234                     |
      | --set              | registryMapping.rules[0].hostMatch=github.com                      |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I poll logs for Pod known as "<AppPod>" every "1s" for up to "10s" until:
      | SOURCE | CONDITION | VALUE                                                   | OUTCOME |
      | STDOUT | contains  | skipping invalid registry mapping config entry at index 0 | pass  |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: An unrecognized SSH_HOST_KEY_POLICY value prevents startup
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
      | --set              | sshHostKeyPolicy=strict                                            |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    When I poll logs for Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | SOURCE | CONDITION | VALUE                                          | OUTCOME |
      | STDOUT | contains  | SSH_HOST_KEY_POLICY must be \"tofu\" or \"pinned\" | pass  |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: An unrecognized CLI flag prevents startup
    # The CLI-flag config layer (see service_settings_file.feature for the
    # settings-file layer) fails the same way every other startup
    # misconfiguration in this file does - loudly, at startup, not
    # silently ignored.
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
      | --set              | extraArgs[0]=--bogus-flag                                          |
      | --set              | extraArgs[1]=anything                                              |
    Then the command exited with 0
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"
    When I wait for Pod known as "<AppPod>" every "2s" for up to "30s"
    # Real, exact text `node:util`'s own `parseArgs({ strict: true })`
    # throws for an unrecognized option (confirmed directly) - same
    # poll-logs shape as every other crash-loop scenario in this file.
    # (A `status.phase equals Running`/`pass` + `CrashLoopBackOff`/`fail`
    # poll - the shape kubernetes-full.feature's own ErrImagePull scenario
    # uses - doesn't fit here: unlike a bad image, this container DOES
    # start and briefly run before parseArgs throws, so `status.phase`
    # reaches "Running" almost immediately and ends the poll long before
    # any crash is ever observed - confirmed live, a real false pass.)
    When I poll logs for Pod known as "<AppPod>" every "2s" for up to "30s" until:
      | SOURCE | CONDITION | VALUE                          | OUTCOME |
      | STDOUT | contains  | Unknown option '--bogus-flag'  | pass    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config @needs-ssh-fixture
  Scenario: SSH_HOST_KEY_POLICY defaults to "tofu" when unset
    # Runs against a real, disposable git-ssh container rather than
    # faking the SSH protocol. The key used below is deliberately never
    # added to the fixture's authorized_keys (test-git-server's own
    # sshAuthorizedKey is left at its empty default), so a real clone
    # against it is expected to fail - but at the *authentication* step,
    # after host-key verification already succeeded. "Permission denied"
    # (rather than "Host key verification failed") is that real,
    # observable signature - see git_source_resolution.feature's TOFU
    # scenario for the same real proof shape.
    Given Directory "<GitServerChartDir>" at "../charts/test-git-server"
    And Helm Chart "<GitServerChart>" in "<GitServerChartDir>"
    And Helm Release known as "<GitServerRelease>":
      | PROPERTY  | VALUE            |
      | chart     | <GitServerChart> |
      | name      | test-git-server  |
      | namespace | <Namespace>      |
    When I upgrade Helm Release known as "<GitServerRelease>" with:
      | OPTION             | VALUE |
      | --install          | True  |
      | --wait              | True  |
      | --timeout           | 180s  |
    Then the command exited with 0
    Given the value "test-git-server-test-git-server.<Namespace>.svc.cluster.local" is known as "<GitHost>"

    When I create Directory known as "<UnauthorizedKeyPairDirectory>" at ".cache/fixtures/service-startup-configuration-w<WorkerId>/unauthorized-key-tofu"
    And I generate SSH Key Pair known as "<UnauthorizedKeyPair>" in Directory known as "<UnauthorizedKeyPairDirectory>" with:
      | OPTION | VALUE                                                                        |
      | -t     | ed25519                                                                      |
      | -f     | .cache/fixtures/service-startup-configuration-w<WorkerId>/unauthorized-key-tofu/id_ed25519 |
      | -N     |                                                                              |
      | -C     | unauthorized                                                                |
    Then the command exited with 0

    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                                                                     |
      | --install          | True                                                                                                      |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                                        |
      | --set              | image.tag=test                                                                                             |
      | --set              | image.pullPolicy=Always                                                                                   |
      | --set              | buildkit.endpoint=tcp://buildkit.example:1234                                                             |
      | --set              | gitCredentials.entries[0].host=<GitHost>                                                                  |
      | --set              | gitCredentials.entries[0].kind=ssh                                                                        |
      | --set-file         | gitCredentials.entries[0].privateKey=.cache/fixtures/service-startup-configuration-w<WorkerId>/unauthorized-key-tofu/id_ed25519 |
      | --wait             | True                                                                                                      |
      | --timeout          | 120s                                                                                                      |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                        |
      | BODY |     | {"repository":"https://<GitHost>/example/example-devcontainer.git","image":{"registry":"ghcr.io/example"}} |
    Then the response status is 500:
      | SOURCE | CONDITION | VALUE     |
      | BODY   | contains  | git clone |
    Given the value at "logId" from the last response is known as "<LogId>"
    When I send a GET request to Endpoint known as "<AppApi>" path "/logs/<LogId>"
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE             |
      | BODY   | contains  | Permission denied |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config @needs-ssh-fixture
  Scenario: A --ssh-host-key-policy CLI flag overrides the settings file
    # Proves config.ts's real precedence (CLI flag > settings file >
    # default) with one real, observable outcome: the chart's own
    # sshHostKeyPolicy value (which always flows into the rendered
    # settings file - see charts/devcontainer-builder/templates/
    # _helpers.tpl's settingsJson helper) says "pinned" (which would fail
    # closed before ever attempting a connection, given no pinnedHostKey
    # is configured) specifically so the CLI flag's own override is the
    # only thing that can make this reach the authentication step at all -
    # if the CLI layer were wired wrong (ignored, or checked after the
    # settings file instead of before), this would fail closed instead of
    # reaching it, the same "Permission denied" signature the TOFU-default
    # scenario above proves.
    Given Directory "<GitServerChartDir>" at "../charts/test-git-server"
    And Helm Chart "<GitServerChart>" in "<GitServerChartDir>"
    And Helm Release known as "<GitServerRelease>":
      | PROPERTY  | VALUE            |
      | chart     | <GitServerChart> |
      | name      | test-git-server  |
      | namespace | <Namespace>      |
    When I upgrade Helm Release known as "<GitServerRelease>" with:
      | OPTION             | VALUE |
      | --install          | True  |
      | --wait              | True  |
      | --timeout           | 180s  |
    Then the command exited with 0
    Given the value "test-git-server-test-git-server.<Namespace>.svc.cluster.local" is known as "<GitHost>"

    When I create Directory known as "<UnauthorizedKeyPairDirectory>" at ".cache/fixtures/service-startup-configuration-w<WorkerId>/unauthorized-key-cli-override"
    And I generate SSH Key Pair known as "<UnauthorizedKeyPair>" in Directory known as "<UnauthorizedKeyPairDirectory>" with:
      | OPTION | VALUE                                                                                |
      | -t     | ed25519                                                                              |
      | -f     | .cache/fixtures/service-startup-configuration-w<WorkerId>/unauthorized-key-cli-override/id_ed25519 |
      | -N     |                                                                                      |
      | -C     | unauthorized                                                                        |
    Then the command exited with 0

    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                                                                              |
      | --install          | True                                                                                                               |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                                                 |
      | --set              | image.tag=test                                                                                                     |
      | --set              | image.pullPolicy=Always                                                                                            |
      | --set              | buildkit.endpoint=tcp://buildkit.example:1234                                                                     |
      | --set              | gitCredentials.entries[0].host=<GitHost>                                                                          |
      | --set              | gitCredentials.entries[0].kind=ssh                                                                                |
      | --set-file         | gitCredentials.entries[0].privateKey=.cache/fixtures/service-startup-configuration-w<WorkerId>/unauthorized-key-cli-override/id_ed25519 |
      | --set              | sshHostKeyPolicy=pinned                                                                                            |
      | --set              | extraArgs[0]=--ssh-host-key-policy                                                                                 |
      | --set              | extraArgs[1]=tofu                                                                                                  |
      | --wait             | True                                                                                                               |
      | --timeout          | 120s                                                                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"
    Given Pod "<AppPod>"
    And "<AppPod>" namespace is "<Namespace>"
    And "<AppPod>" label "app.kubernetes.io/instance" is "devcontainer-builder"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                        |
      | BODY |     | {"repository":"https://<GitHost>/example/example-devcontainer.git","image":{"registry":"ghcr.io/example"}} |
    Then the response status is 500:
      | SOURCE | CONDITION | VALUE     |
      | BODY   | contains  | git clone |
    Given the value at "logId" from the last response is known as "<LogId>"
    When I send a GET request to Endpoint known as "<AppApi>" path "/logs/<LogId>"
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE             |
      | BODY   | contains  | Permission denied |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0
