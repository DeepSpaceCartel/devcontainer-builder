Feature: Git source resolution - URL parsing, credential precedence, and protocol conversion
  As an operator of devcontainer-builder
  I want the service to resolve the right credential and clone protocol for a repository
  So that callers don't need to know or care whether a host is configured for HTTPS or SSH

  Runs against a real git server throughout - it genuinely serves all four
  protocols - git://, http://, https:// (real TLS via a self-signed CA
  generated per scenario), and ssh:// (a real authorized key, via a
  `command=` forced wrapper) - so most scenarios below prove an actual,
  working clone rather than inferring success from a specific failure
  signature. One deliberate limit remains, a real infrastructure constraint
  rather than a gap in the service's own logic: "credential resolution is
  correctly scoped per host" is provable as "requests to different hosts
  produce different, correct outcomes" (not accidentally cross-wired) - the
  netrc/SSH key *content* actually used per request is an internal detail
  with no other external signal once the process exits.

  Every scenario needs a differently-configured devcontainer-builder pod
  (server git credentials, SSH_HOST_KEY_POLICY, GIT_SSL_CAINFO), so - same
  shape as image_resolution.feature/registry_auth.feature - its Helm
  Release lives per Scenario, not Background. Unlike every other Helm value
  in this migration so far, `gitCredentials.entries`/`extraEnv`/
  `extraVolumes`/`extraVolumeMounts` are all *arrays* - Helm's own
  array-index `--set`/`--set-file` syntax (`gitCredentials.entries[0].host=...`,
  confirmed directly by rendering and decoding the chart's own generated
  Secret) handles every one of them through the same plain OPTION|VALUE
  table this migration already uses everywhere else, so no values-file
  detour is needed even for these.

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
      | --set     | privileged=true             |
    Then the command exited with 0

    Given Directory "<TestRegistryChartDir>" at "../charts/test-registry"
    And Helm Chart "<TestRegistryChart>" in "<TestRegistryChartDir>"
    And Helm Release known as "<TestRegistryRelease>":
      | PROPERTY  | VALUE               |
      | chart     | <TestRegistryChart> |
      | name      | test-registry       |
      | namespace | <Namespace>         |
    When I upgrade Helm Release known as "<TestRegistryRelease>" with:
      | OPTION             | VALUE |
      | --install          | True  |
      | --wait              | True  |
      | --timeout           | 120s  |
    Then the command exited with 0
    Given the value "test-registry-test-registry.<Namespace>.svc.cluster.local:5000" is known as "<RegistryUrl>"

    When I create File known as "<BuildkitTrustFile>" at ".cache/fixtures/git-source-resolution-w<WorkerId>/buildkit-trust.toml" with:
      """
      [registry."test-registry-test-registry.<Namespace>.svc.cluster.local:5000"]
        http = true
        insecure = true
      """
    Given Helm Chart known as "<BuildkitChart>":
      | PROPERTY | VALUE                              |
      | chart    | buildkit-service                   |
      | repo     | https://andrcuns.github.io/charts  |
    And Helm Release known as "<TestBuildkitRelease>":
      | PROPERTY  | VALUE           |
      | chart     | <BuildkitChart> |
      | name      | test-buildkit   |
      | namespace | <Namespace>     |
    When I upgrade Helm Release known as "<TestBuildkitRelease>" with:
      | OPTION             | VALUE                                                                    |
      | --install          | True                                                                     |
      | --set-file         | buildkitdToml=.cache/fixtures/git-source-resolution-w<WorkerId>/buildkit-trust.toml |
      | --wait             | True                                                                     |
      | --timeout          | 180s                                                                     |
    Then the command exited with 0
    Given the value "tcp://test-buildkit-buildkit-service.<Namespace>.svc.cluster.local:1234" is known as "<BuildkitEndpoint>"

    # The real authorized keypair - its public half seeds test-git-server's
    # own sshAuthorizedKey; its private half is what a "correct" SSH
    # gitCredentials entry uses below.
    When I create Directory known as "<AuthorizedKeyPairDirectory>" at ".cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-authorized"
    And I generate SSH Key Pair known as "<AuthorizedKeyPair>" in Directory known as "<AuthorizedKeyPairDirectory>" with:
      | OPTION | VALUE                                                          |
      | -t     | ed25519                                                        |
      | -f     | .cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-authorized/id_ed25519 |
      | -N     |                                                                |
      | -C     | devcontainer-builder-test                                      |
    Then the command exited with 0
    # A single-line, trimmed capture - test-git-server's sshAuthorizedKey
    # is a plain --set-string value, not a Secret field, so it can't go
    # through --set-file the way gitCredentials.entries[].privateKey does
    # (confirmed live: the raw file's own trailing newline breaks this
    # chart's un-nindent'd YAML block scalar).
    Given the content of file at ".cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-authorized/id_ed25519.pub" is known as "<AuthorizedPublicKeyContent>"

    # A second, real keypair deliberately never given to test-git-server -
    # every "wrong key" scenario below uses this one, to prove the real
    # rejection path (not a stand-in).
    When I create Directory known as "<UnauthorizedKeyPairDirectory>" at ".cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-unauthorized"
    And I generate SSH Key Pair known as "<UnauthorizedKeyPair>" in Directory known as "<UnauthorizedKeyPairDirectory>" with:
      | OPTION | VALUE                                                            |
      | -t     | ed25519                                                          |
      | -f     | .cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-unauthorized/id_ed25519 |
      | -N     |                                                                  |
      | -C     | unauthorized                                                     |
    Then the command exited with 0

    # A third keypair, used only for its own real public key line - the
    # "stale/incorrect pin" scenario needs a syntactically valid
    # known_hosts-shaped line that's genuinely wrong (a real, unrelated
    # keypair), not a parse error standing in for one.
    When I create Directory known as "<DecoyKeyPairDirectory>" at ".cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-decoy"
    And I generate SSH Key Pair known as "<DecoyKeyPair>" in Directory known as "<DecoyKeyPairDirectory>" with:
      | OPTION | VALUE                                                      |
      | -t     | ed25519                                                    |
      | -f     | .cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-decoy/id_ed25519 |
      | -N     |                                                            |
      | -C     | decoy                                                      |
    Then the command exited with 0
    Given the content of file at ".cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-decoy/id_ed25519.pub" is known as "<DecoyPublicKeyContent>"

    # A real self-signed CA and a leaf cert it signs, for test-git-server's
    # own HTTPS listener - the SAN matches the fixture's real Service DNS
    # name exactly, so a real, non-`-k`/non-bypassed TLS handshake against
    # it genuinely succeeds once GIT_SSL_CAINFO trusts this same CA.
    When I create Directory known as "<GitTlsCaDirectory>" at ".cache/fixtures/git-source-resolution-w<WorkerId>/git-tls-ca"
    And I generate Self-Signed CA known as "<GitTlsCa>" in Directory known as "<GitTlsCaDirectory>" with:
      | OPTION | VALUE                                  |
      | -days  | 2                                       |
      | -subj  | /CN=devcontainer-builder-test-ca       |
    Then the command exited with 0
    When I create Directory known as "<GitTlsCertDirectory>" at ".cache/fixtures/git-source-resolution-w<WorkerId>/git-tls-cert"
    And I generate TLS Certificate known as "<GitTlsCert>" in Directory known as "<GitTlsCertDirectory>" signed by Self-Signed CA known as "<GitTlsCa>" with:
      | OPTION  | VALUE                                                                                    |
      | -subj   | /CN=devcontainer-builder-test-git-server                                                |
      | -addext | subjectAltName=DNS:test-git-server-test-git-server.<Namespace>.svc.cluster.local        |
    Then the command exited with 0

    Given Directory "<GitServerChartDir>" at "../charts/test-git-server"
    And Helm Chart "<GitServerChart>" in "<GitServerChartDir>"
    And Helm Release known as "<GitServerRelease>":
      | PROPERTY  | VALUE            |
      | chart     | <GitServerChart> |
      | name      | test-git-server  |
      | namespace | <Namespace>      |
    When I upgrade Helm Release known as "<GitServerRelease>" with:
      | OPTION             | VALUE                                                              |
      | --install          | True                                                               |
      | --set-string        | sshAuthorizedKey=<AuthorizedPublicKeyContent>                      |
      | --set-file          | tlsCert=.cache/fixtures/git-source-resolution-w<WorkerId>/git-tls-cert/tls-cert.pem |
      | --set-file          | tlsKey=.cache/fixtures/git-source-resolution-w<WorkerId>/git-tls-cert/tls-key.pem   |
      | --wait              | True                                                               |
      | --timeout           | 180s                                                               |
    Then the command exited with 0
    Given the value "test-git-server-test-git-server.<Namespace>.svc.cluster.local" is known as "<GitHost>"
    Given the value "git://test-git-server-test-git-server.<Namespace>.svc.cluster.local:9418" is known as "<GitUrl>"
    Given the value "http://test-git-server-test-git-server.<Namespace>.svc.cluster.local:8080" is known as "<HttpUrl>"
    Given the value "ssh://git@test-git-server-test-git-server.<Namespace>.svc.cluster.local" is known as "<SshUrl>"

    Given Docker Buildx Builder known as "<Builder>":
      | PROPERTY | VALUE                                                            |
      | name     | devcontainer-builder-git-source-resolution-w<WorkerId> |
      | endpoint | tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234 |
    When I create Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I build and push "ghcr.io/deepspacecartel/devcontainer-builder-test:test" from "." using Docker Buildx Builder known as "<Builder>" with:
      | OPTION | VALUE |
    Then the command exited with 0

    Given Directory "<ChartDirectory>" at "../charts/devcontainer-builder"
    And Helm Chart "<Chart>" in "<ChartDirectory>"

  @client-request
  Scenario Outline: No credentials resolve anywhere - the given URL is cloned verbatim
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
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                               |
      | --set              | gitCredentials.enabled=false                                       |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                |
      | BODY |     | {"repository":"<repository>","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is <status>:
      | SOURCE | CONDITION | VALUE    |
      | BODY   | contains  | <expect> |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | repository                                     | status | expect               |
      | <GitUrl>/example/example-devcontainer.git      | 200    | example-devcontainer |
      | <HttpUrl>/example/example-devcontainer.git     | 200    | example-devcontainer |
      | git@<GitHost>:example/example-devcontainer.git | 500    | git clone             |
      | <SshUrl>/example/example-devcontainer.git      | 500    | git clone             |

  @negative @client-request
  Scenario: An unparseable repository URL is rejected
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
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                               |
      | --set              | gitCredentials.enabled=false                                       |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                 |
      | BODY |     | {"repository":"not a git url at all","image":{"registry":"<RegistryUrl>"}}           |
    Then the response status is 400:
      | SOURCE | CONDITION | VALUE                                                                    |
      | BODY   | equals    | {"error":"unable to parse git repository URL: not a git url at all"}    |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @client-request
  Scenario: Request-level gitCredentials rewrite an SCP-style URL to HTTPS
    # The ConfigMap has to exist BEFORE the Helm upgrade below - `--wait`
    # blocks until the pod is Ready, and a pod referencing a ConfigMap
    # volume that doesn't exist yet never becomes Ready at all (confirmed
    # live: `MountVolume.SetUp failed ... configmap "git-tls-ca" not
    # found`, `--wait` times out, the release is left in a real "failed"
    # state that cascades into every later scenario's own Background).
    When I create ConfigMap known as "<CaCertConfigMap>" named "git-tls-ca" in "<Namespace>" from file "ca-cert.pem" at ".cache/fixtures/git-source-resolution-w<WorkerId>/git-tls-ca/ca-cert.pem"
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
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                               |
      | --set              | gitCredentials.enabled=false                                       |
      | --set              | extraEnv[0].name=GIT_SSL_CAINFO                                    |
      | --set              | extraEnv[0].value=/etc/git-tls/ca-cert.pem                         |
      | --set              | extraVolumes[0].name=git-tls-ca                                    |
      | --set              | extraVolumes[0].configMap.name=git-tls-ca                          |
      | --set              | extraVolumeMounts[0].name=git-tls-ca                               |
      | --set              | extraVolumeMounts[0].mountPath=/etc/git-tls                        |
      | --set              | extraVolumeMounts[0].readOnly=true                                 |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                                      |
      | BODY |     | {"repository":"git@<GitHost>:example/example-devcontainer.git","gitCredentials":{"username":"svc-bot","token":"ghp_example"},"image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE                 |
      | BODY   | contains  | example-devcontainer |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete ConfigMap known as "<CaCertConfigMap>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: A server-configured HTTPS credential is used when the request supplies none
    When I create ConfigMap known as "<CaCertConfigMap>" named "git-tls-ca" in "<Namespace>" from file "ca-cert.pem" at ".cache/fixtures/git-source-resolution-w<WorkerId>/git-tls-ca/ca-cert.pem"
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
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                               |
      | --set              | gitCredentials.entries[0].host=<GitHost>                           |
      | --set              | gitCredentials.entries[0].kind=https                               |
      | --set              | gitCredentials.entries[0].username=svc-bot                         |
      | --set              | gitCredentials.entries[0].token=ghp_example                        |
      | --set              | extraEnv[0].name=GIT_SSL_CAINFO                                    |
      | --set              | extraEnv[0].value=/etc/git-tls/ca-cert.pem                         |
      | --set              | extraVolumes[0].name=git-tls-ca                                    |
      | --set              | extraVolumes[0].configMap.name=git-tls-ca                          |
      | --set              | extraVolumeMounts[0].name=git-tls-ca                               |
      | --set              | extraVolumeMounts[0].mountPath=/etc/git-tls                        |
      | --set              | extraVolumeMounts[0].readOnly=true                                 |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                        |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE                 |
      | BODY   | contains  | example-devcontainer |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete ConfigMap known as "<CaCertConfigMap>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: A server-configured SSH credential rewrites an HTTPS request URL to SSH
    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                                             |
      | --install          | True                                                                              |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                |
      | --set              | image.tag=test                                                                    |
      | --set              | image.pullPolicy=Always                                                           |
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                                              |
      | --set              | gitCredentials.entries[0].host=<GitHost>                                          |
      | --set              | gitCredentials.entries[0].kind=ssh                                               |
      | --set-file         | gitCredentials.entries[0].privateKey=.cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-authorized/id_ed25519 |
      | --set              | sshHostKeyPolicy=tofu                                                             |
      | --wait             | True                                                                              |
      | --timeout          | 120s                                                                              |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                          |
      | BODY |     | {"repository":"https://<GitHost>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE                 |
      | BODY   | contains  | example-devcontainer |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config @client-request
  Scenario: Request-level gitCredentials win over a server-configured SSH default for the same host
    # If this regressed (server SSH wrongly won), the clone would instead
    # try ssh://<GitHost>/... using the deliberately unauthorized key
    # below - a real, fast, clean "Permission denied" failure (not a hang
    # or timeout, since the SSH fixture genuinely listens and responds),
    # cleanly distinguishable from the 200 expected here.
    When I create ConfigMap known as "<CaCertConfigMap>" named "git-tls-ca" in "<Namespace>" from file "ca-cert.pem" at ".cache/fixtures/git-source-resolution-w<WorkerId>/git-tls-ca/ca-cert.pem"
    Then the command exited with 0
    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                                               |
      | --install          | True                                                                                |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                  |
      | --set              | image.tag=test                                                                      |
      | --set              | image.pullPolicy=Always                                                             |
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                                                |
      | --set              | gitCredentials.entries[0].host=<GitHost>                                            |
      | --set              | gitCredentials.entries[0].kind=ssh                                                 |
      | --set-file         | gitCredentials.entries[0].privateKey=.cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-unauthorized/id_ed25519 |
      | --set              | extraEnv[0].name=GIT_SSL_CAINFO                                                     |
      | --set              | extraEnv[0].value=/etc/git-tls/ca-cert.pem                                          |
      | --set              | extraVolumes[0].name=git-tls-ca                                                     |
      | --set              | extraVolumes[0].configMap.name=git-tls-ca                                           |
      | --set              | extraVolumeMounts[0].name=git-tls-ca                                                |
      | --set              | extraVolumeMounts[0].mountPath=/etc/git-tls                                         |
      | --set              | extraVolumeMounts[0].readOnly=true                                                  |
      | --wait             | True                                                                                |
      | --timeout          | 120s                                                                                |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                                          |
      | BODY |     | {"repository":"https://<GitHost>/example/example-devcontainer.git","gitCredentials":{"username":"svc-bot","token":"ghp_example"},"image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE                 |
      | BODY   | contains  | example-devcontainer |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete ConfigMap known as "<CaCertConfigMap>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: Each host uses only its own server-configured credential
    # git.invalid is a reserved TLD (RFC 2606) guaranteed to never resolve -
    # a genuinely wrong host that fails fast and cleanly on DNS lookup
    # alone, with no dependency on any second real server.
    When I create ConfigMap known as "<CaCertConfigMap>" named "git-tls-ca" in "<Namespace>" from file "ca-cert.pem" at ".cache/fixtures/git-source-resolution-w<WorkerId>/git-tls-ca/ca-cert.pem"
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
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                               |
      | --set              | gitCredentials.entries[0].host=<GitHost>                           |
      | --set              | gitCredentials.entries[0].kind=https                               |
      | --set              | gitCredentials.entries[0].username=svc-bot                         |
      | --set              | gitCredentials.entries[0].token=ghp_example                        |
      | --set              | gitCredentials.entries[1].host=git.invalid                         |
      | --set              | gitCredentials.entries[1].kind=https                               |
      | --set              | gitCredentials.entries[1].username=other-bot                       |
      | --set              | gitCredentials.entries[1].token=glpat_example                      |
      | --set              | extraEnv[0].name=GIT_SSL_CAINFO                                    |
      | --set              | extraEnv[0].value=/etc/git-tls/ca-cert.pem                         |
      | --set              | extraVolumes[0].name=git-tls-ca                                    |
      | --set              | extraVolumes[0].configMap.name=git-tls-ca                          |
      | --set              | extraVolumeMounts[0].name=git-tls-ca                               |
      | --set              | extraVolumeMounts[0].mountPath=/etc/git-tls                        |
      | --set              | extraVolumeMounts[0].readOnly=true                                 |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
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
      | TYPE | KEY | VALUE                                                                       |
      | BODY |     | {"repository":"git@<GitHost>:example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE                 |
      | BODY   | contains  | example-devcontainer |
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                      |
      | BODY |     | {"repository":"git@git.invalid:example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 500
    Given the value at "logId" from the last response is known as "<LogId>"
    When I send a GET request to Endpoint known as "<AppApi>" path "/logs/<LogId>"
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE                                |
      | BODY   | contains  | Could not resolve host: git.invalid |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I delete ConfigMap known as "<CaCertConfigMap>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: A host with no matching server credential falls back to a verbatim, unauthenticated clone
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
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                               |
      | --set              | gitCredentials.entries[0].host=example.com                        |
      | --set              | gitCredentials.entries[0].kind=https                               |
      | --set              | gitCredentials.entries[0].username=svc-bot                         |
      | --set              | gitCredentials.entries[0].token=ghp_example                        |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                |
      | BODY |     | {"repository":"<GitUrl>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: TOFU host key policy trusts the fixture's host key and proceeds to authentication
    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                                             |
      | --install          | True                                                                              |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                |
      | --set              | image.tag=test                                                                    |
      | --set              | image.pullPolicy=Always                                                           |
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                                              |
      | --set              | gitCredentials.entries[0].host=<GitHost>                                          |
      | --set              | gitCredentials.entries[0].kind=ssh                                               |
      | --set-file         | gitCredentials.entries[0].privateKey=.cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-unauthorized/id_ed25519 |
      | --set              | sshHostKeyPolicy=tofu                                                             |
      | --wait             | True                                                                              |
      | --timeout          | 120s                                                                              |
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
      | TYPE | KEY | VALUE                                                                |
      | BODY |     | {"repository":"ssh://<GitHost>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 500:
      | SOURCE | CONDITION | VALUE     |
      | BODY   | contains  | git clone |
    # Proves TOFU trusted the real host key and got PAST that check to
    # authentication - "Permission denied" (not "Host key verification
    # failed") only appears once host-key verification already succeeded.
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
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: Pinned host key policy without a configured pin fails closed
    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                                             |
      | --install          | True                                                                              |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                |
      | --set              | image.tag=test                                                                    |
      | --set              | image.pullPolicy=Always                                                           |
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                                              |
      | --set              | gitCredentials.entries[0].host=<GitHost>                                          |
      | --set              | gitCredentials.entries[0].kind=ssh                                               |
      | --set-file         | gitCredentials.entries[0].privateKey=.cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-unauthorized/id_ed25519 |
      | --set              | sshHostKeyPolicy=pinned                                                           |
      | --wait             | True                                                                              |
      | --timeout          | 120s                                                                              |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                |
      | BODY |     | {"repository":"ssh://<GitHost>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 400:
      | SOURCE | CONDITION | VALUE                                |
      | BODY   | contains  | no pinned key configured for host   |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: Pinned host key policy uses the configured pin without needing a scan
    When I scan the SSH host key for "test-git-server-test-git-server.<Namespace>.svc.cluster.local" with:
      | OPTION | VALUE   |
      | -t     | ed25519 |
    Then the command exited with 0
    Given the STDOUT of the last command is known as "<CurrentHostKey>"

    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                                             |
      | --install          | True                                                                              |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test                |
      | --set              | image.tag=test                                                                    |
      | --set              | image.pullPolicy=Always                                                           |
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                                              |
      | --set              | gitCredentials.entries[0].host=<GitHost>                                          |
      | --set              | gitCredentials.entries[0].kind=ssh                                               |
      | --set-file         | gitCredentials.entries[0].privateKey=.cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-unauthorized/id_ed25519 |
      | --set              | gitCredentials.entries[0].pinnedHostKey=<CurrentHostKey>                         |
      | --set              | sshHostKeyPolicy=pinned                                                           |
      | --wait             | True                                                                              |
      | --timeout          | 120s                                                                              |
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
      | TYPE | KEY | VALUE                                                                |
      | BODY |     | {"repository":"ssh://<GitHost>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
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
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @server-config
  Scenario: Pinned host key policy succeeds end to end with a correct pin and an authorized key
    # The other pinned scenarios above only prove the policy *branches*
    # correctly (skips the scan, fails closed with no pin) - none of them
    # ever reach a real success, so "pinned" reaching an actual working
    # clone was unverified. The unauthorized key used elsewhere is
    # deliberate there (isolates host-key behavior from auth); this one
    # swaps in the real authorized key specifically to prove "pinned" can
    # carry a request all the way through, not just fail predictably.
    When I scan the SSH host key for "test-git-server-test-git-server.<Namespace>.svc.cluster.local" with:
      | OPTION | VALUE   |
      | -t     | ed25519 |
    Then the command exited with 0
    Given the STDOUT of the last command is known as "<CurrentHostKey>"

    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                                           |
      | --install          | True                                                                            |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test              |
      | --set              | image.tag=test                                                                  |
      | --set              | image.pullPolicy=Always                                                         |
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                                            |
      | --set              | gitCredentials.entries[0].host=<GitHost>                                        |
      | --set              | gitCredentials.entries[0].kind=ssh                                             |
      | --set-file         | gitCredentials.entries[0].privateKey=.cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-authorized/id_ed25519 |
      | --set              | gitCredentials.entries[0].pinnedHostKey=<CurrentHostKey>                       |
      | --set              | sshHostKeyPolicy=pinned                                                         |
      | --wait             | True                                                                            |
      | --timeout          | 120s                                                                            |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                |
      | BODY |     | {"repository":"ssh://<GitHost>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE                 |
      | BODY   | contains  | example-devcontainer |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: Pinned host key policy rejects a stale or incorrect pin
    # A real, syntactically valid known_hosts-shaped line for this host -
    # just from an unrelated keypair - so this is a genuine host-key
    # mismatch (the actual security case "pinned" exists for), not a
    # parse error standing in for one.
    Given the value "<GitHost> <DecoyPublicKeyContent>" is known as "<WrongHostKey>"

    Given Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION             | VALUE                                                                         |
      | --install          | True                                                                          |
      | --set              | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test            |
      | --set              | image.tag=test                                                                |
      | --set              | image.pullPolicy=Always                                                       |
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                                          |
      | --set              | gitCredentials.entries[0].host=<GitHost>                                      |
      | --set              | gitCredentials.entries[0].kind=ssh                                           |
      | --set-file         | gitCredentials.entries[0].privateKey=.cache/fixtures/git-source-resolution-w<WorkerId>/git-ssh-authorized/id_ed25519 |
      | --set              | gitCredentials.entries[0].pinnedHostKey=<WrongHostKey>                       |
      | --set              | sshHostKeyPolicy=pinned                                                       |
      | --wait             | True                                                                          |
      | --timeout          | 120s                                                                          |
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
      | TYPE | KEY | VALUE                                                                |
      | BODY |     | {"repository":"ssh://<GitHost>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 500:
      | SOURCE | CONDITION | VALUE     |
      | BODY   | contains  | git clone |
    Given the value at "logId" from the last response is known as "<LogId>"
    When I send a GET request to Endpoint known as "<AppApi>" path "/logs/<LogId>"
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE                        |
      | BODY   | contains  | Host key verification failed |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative @server-config
  Scenario: A malformed SSH private key fails clearly at clone time, not at config load
    # config.ts's validation only checks privateKey is a non-empty string -
    # garbage content passes startup and is only ever exercised for real
    # once a request actually tries to use it.
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
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                               |
      | --set              | gitCredentials.entries[0].host=<GitHost>                           |
      | --set              | gitCredentials.entries[0].kind=ssh                                |
      | --set              | gitCredentials.entries[0].privateKey=this is not a real private key at all |
      | --set              | sshHostKeyPolicy=tofu                                              |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
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
      | TYPE | KEY | VALUE                                                                |
      | BODY |     | {"repository":"ssh://<GitHost>/example/example-devcontainer.git","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 500:
      | SOURCE | CONDITION | VALUE     |
      | BODY   | contains  | git clone |
    Given the value at "logId" from the last response is known as "<LogId>"
    When I send a GET request to Endpoint known as "<AppApi>" path "/logs/<LogId>"
    Then the response status is 200:
      | SOURCE | CONDITION | VALUE               |
      | BODY   | contains  | error in libcrypto |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  @negative
  Scenario Outline: A failed clone surfaces as a 500 regardless of the credential path used
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
      | --set              | buildkit.endpoint=<BuildkitEndpoint>                               |
      | --set              | gitCredentials.enabled=false                                       |
      | --wait             | True                                                               |
      | --timeout          | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                |
      | BODY |     | {"repository":"<repository>","image":{"registry":"<RegistryUrl>"}} |
    Then the response status is 500:
      | SOURCE | CONDITION | VALUE     |
      | BODY   | contains  | git clone |

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<GitServerRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

    Examples:
      | repository                                   |
      | <GitUrl>/example/nonexistent-repo.git        |
      | <HttpUrl>/example/nonexistent-repo.git       |
