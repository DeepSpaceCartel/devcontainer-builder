Feature: Dev Container metadata of a built image
  As a Coder template (or any other caller) that boots a devcontainer-builder image
  I want the image's merged Dev Container configuration, ready-to-run lifecycle scripts and VS Code customizations
  So that I can run postCreateCommand & co. and pre-install extensions without the Dev Containers CLI

  Every scenario builds a real image with POST /build, then reads it back
  with GET /devcontainer - the label is whatever the real `devcontainer
  build` wrote, never a hand-written fixture. Fixture repositories are
  branches of the public DeepSpaceCartel/devcontainer-builder-examples repo
  (cloned over HTTPS from github.com, so no test git server here):
  `lifecycle-and-extensions` has a local Feature that contributes its own
  hooks and customizations; `features-and-settings` uses real Features from
  ghcr.io. The test registries are plain HTTP, so the release lists both in
  `insecureRegistries` - BuildKit's own trust file covers the push side.

  Rendered scripts are asserted as text here (each scenario only has the
  response, and executing them would need the script back out of a captured
  value); their run-time semantics are covered by the ADR-0011 notes.

  Background:
    Given the value of environment variable "CODER_WORKSPACE_OWNER_NAME", or "USER", or "local" is known as "<Owner>"
    And the value of environment variable "CUCUMBER_WORKER_ID" or "0" is known as "<WorkerId>"
    And the value "devcontainer-builder-<Owner>-w<WorkerId>" is known as "<Namespace>"
    And the value "https://github.com/deepspacecartel/devcontainer-builder-examples.git" is known as "<ExamplesRepo>"

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
      | OPTION    | VALUE |
      | --install | True  |
      | --wait    | True  |
      | --timeout | 120s  |
    Then the command exited with 0
    Given the value "test-registry-test-registry.<Namespace>.svc.cluster.local:5000" is known as "<RegistryUrl>"

    When I create File known as "<AuthedRegistryValuesFile>" at ".cache/fixtures/devcontainer-metadata-w<WorkerId>/registry-authed-values.yaml" with:
      """
      auth:
        enabled: true
        username: svc-bot
        password: hunter2
      """
    Given Helm Release known as "<TestRegistryAuthedRelease>":
      | PROPERTY  | VALUE                |
      | chart     | <TestRegistryChart>  |
      | name      | test-registry-authed |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<TestRegistryAuthedRelease>" with:
      | OPTION    | VALUE                                                                         |
      | --install | True                                                                          |
      | -f        | .cache/fixtures/devcontainer-metadata-w<WorkerId>/registry-authed-values.yaml |
      | --wait    | True                                                                          |
      | --timeout | 120s                                                                          |
    Then the command exited with 0
    Given the value "test-registry-authed-test-registry.<Namespace>.svc.cluster.local:5000" is known as "<AuthedRegistryUrl>"

    When I create File known as "<BuildkitTrustFile>" at ".cache/fixtures/devcontainer-metadata-w<WorkerId>/buildkit-trust.toml" with:
      """
      [registry."test-registry-test-registry.<Namespace>.svc.cluster.local:5000"]
        http = true
        insecure = true
      [registry."test-registry-authed-test-registry.<Namespace>.svc.cluster.local:5000"]
        http = true
        insecure = true
      """
    Given Helm Chart known as "<BuildkitChart>":
      | PROPERTY | VALUE                             |
      | chart    | buildkit-service                  |
      | repo     | https://andrcuns.github.io/charts |
    And Helm Release known as "<TestBuildkitRelease>":
      | PROPERTY  | VALUE           |
      | chart     | <BuildkitChart> |
      | name      | test-buildkit   |
      | namespace | <Namespace>     |
    When I upgrade Helm Release known as "<TestBuildkitRelease>" with:
      | OPTION     | VALUE                                                                         |
      | --install  | True                                                                          |
      | --set-file | buildkitdToml=.cache/fixtures/devcontainer-metadata-w<WorkerId>/buildkit-trust.toml |
      | --wait     | True                                                                          |
      | --timeout  | 180s                                                                          |
    Then the command exited with 0
    Given the value "tcp://test-buildkit-buildkit-service.<Namespace>.svc.cluster.local:1234" is known as "<BuildkitEndpoint>"

    Given Docker Buildx Builder known as "<Builder>":
      | PROPERTY | VALUE                                                           |
      | name     | devcontainer-builder-metadata-w<WorkerId>                       |
      | endpoint | tcp://buildkit-buildkit-service.buildkit.svc.cluster.local:1234 |
    When I create Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I build and push "ghcr.io/deepspacecartel/devcontainer-builder-test:test" from "." using Docker Buildx Builder known as "<Builder>" with:
      | OPTION | VALUE |
    Then the command exited with 0

    When I create File known as "<ReleaseValuesFile>" at ".cache/fixtures/devcontainer-metadata-w<WorkerId>/release-values.yaml" with:
      """
      gitCredentials:
        enabled: false
      insecureRegistries:
        - test-registry-test-registry.<Namespace>.svc.cluster.local:5000
        - test-registry-authed-test-registry.<Namespace>.svc.cluster.local:5000
      """
    Given Directory "<ChartDirectory>" at "../charts/devcontainer-builder"
    And Helm Chart "<Chart>" in "<ChartDirectory>"
    And Helm Release known as "<Release>":
      | PROPERTY  | VALUE                |
      | chart     | <Chart>              |
      | name      | devcontainer-builder |
      | namespace | <Namespace>          |
    When I upgrade Helm Release known as "<Release>" with:
      | OPTION    | VALUE                                                              |
      | --install | True                                                               |
      | --set     | image.repository=ghcr.io/deepspacecartel/devcontainer-builder-test |
      | --set     | image.tag=test                                                     |
      | --set     | image.pullPolicy=Always                                            |
      | --set     | buildkit.endpoint=<BuildkitEndpoint>                               |
      | -f        | .cache/fixtures/devcontainer-metadata-w<WorkerId>/release-values.yaml |
      | --wait    | True                                                               |
      | --timeout | 120s                                                               |
    Then the command exited with 0
    Given Service known as "<AppService>":
      | PROPERTY                   | VALUE                |
      | namespace                  | <Namespace>          |
      | app.kubernetes.io/instance | devcontainer-builder |
    And HTTP Endpoint "<AppApi>" on "<AppService>" port "8080"

  Scenario: A local Feature's hooks and customizations merge with devcontainer.json's
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                              |
      | BODY |     | {"repository":"<ExamplesRepo>","branch":"lifecycle-and-extensions","image":{"registry":"<RegistryUrl>","name":"lifecycle-and-extensions"}} |
    Then the response status is 200
    Given the value at "tag" from the last response is known as "<Tag>"

    When I send a GET request to Endpoint known as "<AppApi>" path "/devcontainer" with:
      | TYPE  | KEY      | VALUE                    |
      | QUERY | registry | <RegistryUrl>            |
      | QUERY | name     | lifecycle-and-extensions |
      | QUERY | tag      | <Tag>                    |
    Then the response status is 200

    # configuration: the CLI's own mergedConfiguration shape.
    Given the value at "configuration.remoteUser" from the last response is known as "<RemoteUser>"
    Then the value known as "<RemoteUser>" equals "vscode"
    Given the value at "length(configuration.postCreateCommands)" from the last response is known as "<PostCreateCount>"
    Then the value known as "<PostCreateCount>" equals "2"
    Given the value at "configuration.postCreateCommands[0]" from the last response is known as "<FirstPostCreate>"
    Then the value known as "<FirstPostCreate>" equals "echo post-create from the hello Feature"
    Given the value at "length(metadata)" from the last response is known as "<EntryCount>"
    Then the value known as "<EntryCount>" equals "5"

    # vscode: union with case-insensitive de-dup, "-id" removal, per-key settings.
    Given the value at "length(vscode.extensions)" from the last response is known as "<ExtensionCount>"
    Then the value known as "<ExtensionCount>" equals "2"
    Given the value at "contains(vscode.extensions, 'hashicorp.terraform')" from the last response is known as "<HasTerraform>"
    Then the value known as "<HasTerraform>" equals "true"
    Given the value at "contains(vscode.extensions, 'redhat.vscode-yaml')" from the last response is known as "<HasYaml>"
    Then the value known as "<HasYaml>" equals "true"
    Given the value at "contains(vscode.extensions, 'ms-python.python')" from the last response is known as "<HasPython>"
    Then the value known as "<HasPython>" equals "false"
    Given the value at "vscode.settings.\"editor.tabSize\"" from the last response is known as "<TabSize>"
    Then the value known as "<TabSize>" equals "2"
    Given the value at "vscode.settings.\"files.trimTrailingWhitespace\"" from the last response is known as "<TrimWhitespace>"
    Then the value known as "<TrimWhitespace>" equals "true"

    # lifecycleScripts: one sh script per hook, CLI semantics.
    Given the value at "lifecycleScripts.postCreateCommand" from the last response is known as "<PostCreateScript>"
    Then the value known as "<PostCreateScript>" contains "echo 'devcontainer: postCreateCommand from ./hello'"
    Then the value known as "<PostCreateScript>" contains "/bin/sh -c 'echo post-create from the hello Feature' || { dc_rc=$?;"
    Then the value known as "<PostCreateScript>" contains "'printf' '%s\n' 'post-create from devcontainer.json' || { dc_rc=$?;"
    Given the value at "lifecycleScripts.postStartCommand" from the last response is known as "<PostStartScript>"
    Then the value known as "<PostStartScript>" contains "(parallel: first, second)"
    Then the value known as "<PostStartScript>" contains "/bin/sh -c 'echo post-start first' & dc_pid_1_0=$!"
    Then the value known as "<PostStartScript>" contains "'echo' 'post-start second' & dc_pid_1_1=$!"
    Then the value known as "<PostStartScript>" contains "[ \"$dc_rc\" -eq 0 ] || {"
    # A hook no entry sets is null - asserted via type(), since a captured
    # JSON null reads as "no value found".
    Given the value at "type(lifecycleScripts.postAttachCommand)" from the last response is known as "<PostAttachType>"
    Then the value known as "<PostAttachType>" equals "null"

    # ${containerWorkspaceFolder} becomes a shell variable the workspace
    # sets at runtime - detected, not substituted, and no longer a warning.
    Given the value at "length(warnings)" from the last response is known as "<WarningCount>"
    Then the value known as "<WarningCount>" equals "0"
    Given the value at "lifecycleScripts.onCreateCommand" from the last response is known as "<OnCreateScript>"
    Then the value known as "<OnCreateScript>" contains "${DEVCONTAINER_WORKSPACE_FOLDER}"
    Given the value at "length(variables[?name == 'containerWorkspaceFolder'])" from the last response is known as "<WorkspaceVariable>"
    Then the value known as "<WorkspaceVariable>" equals "1"

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  Scenario: A Dockerfile-based config's runtime settings translate for Kubernetes
    # runtime-and-env builds from a Dockerfile - the path where the Dev
    # Containers CLI ignores `devcontainer build --label`, so this also
    # proves the build's own config label (workspaceFolder, runArgs,
    # initializeCommand) still lands in the image.
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                              |
      | BODY |     | {"repository":"<ExamplesRepo>","branch":"runtime-and-env","image":{"registry":"<RegistryUrl>","name":"runtime-and-env"}} |
    Then the response status is 200
    Given the value at "tag" from the last response is known as "<Tag>"
    Given the value at "length(commit)" from the last response is known as "<CommitLength>"
    Then the value known as "<CommitLength>" equals "40"

    When I send a GET request to Endpoint known as "<AppApi>" path "/devcontainer" with:
      | TYPE  | KEY      | VALUE           |
      | QUERY | registry | <RegistryUrl>   |
      | QUERY | name     | runtime-and-env |
      | QUERY | tag      | <Tag>           |
    Then the response status is 200

    # From the build's config label.
    Given the value at "configuration.workspaceFolder" from the last response is known as "<WorkspaceFolder>"
    Then the value known as "<WorkspaceFolder>" equals "/workspaces/${localWorkspaceFolderBasename}-app"
    Given the value at "lifecycleScripts.initializeCommand" from the last response is known as "<InitializeScript>"
    Then the value known as "<InitializeScript>" contains "/bin/sh -c 'cp -n .env.example .env'"

    # runtime: users, runArgs, ports, mounts, resources.
    Given the value at "runtime.remoteUser" from the last response is known as "<RemoteUser>"
    Then the value known as "<RemoteUser>" equals "dev"
    # Probed from the image's /etc/passwd at build time (the Dockerfile
    # creates dev with uid 1001).
    Given the value at "runtime.remoteUserUid" from the last response is known as "<RemoteUserUid>"
    Then the value known as "<RemoteUserUid>" equals "1001"
    Given the value at "runtime.remoteUserHome" from the last response is known as "<RemoteUserHome>"
    Then the value known as "<RemoteUserHome>" equals "/home/dev"
    Given the value at "contains(runtime.capAdd, 'SYS_PTRACE')" from the last response is known as "<HasPtrace>"
    Then the value known as "<HasPtrace>" equals "true"
    Given the value at "runtime.init" from the last response is known as "<Init>"
    Then the value known as "<Init>" equals "true"
    Given the value at "runtime.shmSizeBytes" from the last response is known as "<ShmSize>"
    Then the value known as "<ShmSize>" equals "268435456"
    Given the value at "runtime.hostAliases[0].hostnames[0]" from the last response is known as "<HostAlias>"
    Then the value known as "<HostAlias>" equals "fixture.internal"
    Given the value at "length(runtime.ports)" from the last response is known as "<PortCount>"
    Then the value known as "<PortCount>" equals "1"
    Given the value at "runtime.ports[0].label" from the last response is known as "<PortLabel>"
    Then the value known as "<PortLabel>" equals "Fixture web"
    Given the value at "runtime.mounts[0].target" from the last response is known as "<MountTarget>"
    Then the value known as "<MountTarget>" equals "${containerWorkspaceFolder}/node_modules"
    Given the value at "runtime.resources.cpus" from the last response is known as "<Cpus>"
    Then the value known as "<Cpus>" equals "2"

    # Variables and env scripts: rewritten for the shell, nothing substituted.
    Given the value at "length(variables[?kind == 'localEnv'])" from the last response is known as "<LocalEnvCount>"
    Then the value known as "<LocalEnvCount>" equals "3"
    Given the value at "variables[?name == 'FIXTURE_ORG'] | [0].default" from the last response is known as "<OrgDefault>"
    Then the value known as "<OrgDefault>" equals "DeepSpaceCartel"
    Given the value at "envScripts.containerEnv" from the last response is known as "<ContainerEnvScript>"
    Then the value known as "<ContainerEnvScript>" contains "export PATH=\"${PATH}:/opt/fixture/bin\""
    Given the value at "envScripts.remoteEnv" from the last response is known as "<RemoteEnvScript>"
    Then the value known as "<RemoteEnvScript>" contains "export FIXTURE_ORG=\"${DEVCONTAINER_LOCALENV_FIXTURE_ORG:-DeepSpaceCartel}\""

    # Docker-only settings without a pod equivalent are reported.
    Given the value at "length(warnings)" from the last response is known as "<WarningCount>"
    Then the value known as "<WarningCount>" equals "3"

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  Scenario: Features pulled from ghcr.io contribute to the merged metadata
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE                                                                                                                      |
      | BODY |     | {"repository":"<ExamplesRepo>","branch":"features-and-settings","image":{"registry":"<RegistryUrl>","name":"features-and-settings"}} |
    Then the response status is 200
    Given the value at "tag" from the last response is known as "<Tag>"

    When I send a GET request to Endpoint known as "<AppApi>" path "/devcontainer" with:
      | TYPE  | KEY      | VALUE                 |
      | QUERY | registry | <RegistryUrl>         |
      | QUERY | name     | features-and-settings |
      | QUERY | tag      | <Tag>                 |
    Then the response status is 200
    Given the value at "contains(vscode.extensions, 'dbaeumer.vscode-eslint')" from the last response is known as "<HasEslint>"
    Then the value known as "<HasEslint>" equals "true"
    Given the value at "length(metadata[?id == 'ghcr.io/devcontainers/features/node:1'])" from the last response is known as "<NodeFeatureEntries>"
    Then the value known as "<NodeFeatureEntries>" equals "1"
    Given the value at "configuration.remoteEnv.APP_ENV" from the last response is known as "<AppEnv>"
    Then the value known as "<AppEnv>" equals "devcontainer"
    Given the value at "lifecycleScripts.postCreateCommand" from the last response is known as "<PostCreateScript>"
    Then the value known as "<PostCreateScript>" contains "/bin/sh -c 'node --version && gh --version'"

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  Scenario: An authenticated registry needs the caller's credentials
    When I send a POST request to Endpoint known as "<AppApi>" path "/build" with:
      | TYPE | KEY | VALUE |
      | BODY |     | {"repository":"<ExamplesRepo>","branch":"lifecycle-and-extensions","image":{"registry":"<AuthedRegistryUrl>","name":"lifecycle-and-extensions"},"registryCredentials":{"registry":"<AuthedRegistryUrl>","username":"svc-bot","password":"hunter2"}} |
    Then the response status is 200
    Given the value at "tag" from the last response is known as "<Tag>"

    When I send a GET request to Endpoint known as "<AppApi>" path "/devcontainer" with:
      | TYPE   | KEY                 | VALUE                    |
      | QUERY  | registry            | <AuthedRegistryUrl>      |
      | QUERY  | name                | lifecycle-and-extensions |
      | QUERY  | tag                 | <Tag>                    |
      | HEADER | X-Registry-Username | svc-bot                  |
      | HEADER | X-Registry-Password | hunter2                  |
    Then the response status is 200
    Given the value at "configuration.remoteUser" from the last response is known as "<RemoteUser>"
    Then the value known as "<RemoteUser>" equals "vscode"

    When I send a GET request to Endpoint known as "<AppApi>" path "/devcontainer" with:
      | TYPE  | KEY      | VALUE                    |
      | QUERY | registry | <AuthedRegistryUrl>      |
      | QUERY | name     | lifecycle-and-extensions |
      | QUERY | tag      | <Tag>                    |
    Then the response status is 502

    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0

  Scenario: Images without usable Dev Container metadata are reported, not guessed
    # A plain image with no devcontainer.metadata label, pushed straight to
    # the test registry through the in-namespace BuildKit (the one that
    # trusts plain-HTTP registries).
    When I create File known as "<PlainDockerfile>" at ".cache/fixtures/devcontainer-metadata-w<WorkerId>/plain/Dockerfile" with:
      """
      FROM scratch
      LABEL org.opencontainers.image.title=plain
      """
    Given Docker Buildx Builder known as "<TestBuilder>":
      | PROPERTY | VALUE                                          |
      | name     | devcontainer-builder-metadata-test-w<WorkerId> |
      | endpoint | <BuildkitEndpoint>                             |
    When I create Docker Buildx Builder known as "<TestBuilder>"
    Then the command exited with 0
    When I build and push "<RegistryUrl>/plain:v1" from ".cache/fixtures/devcontainer-metadata-w<WorkerId>/plain" using Docker Buildx Builder known as "<TestBuilder>" with:
      | OPTION | VALUE |
    Then the command exited with 0

    When I send a GET request to Endpoint known as "<AppApi>" path "/devcontainer" with:
      | TYPE  | KEY      | VALUE         |
      | QUERY | registry | <RegistryUrl> |
      | QUERY | name     | plain         |
      | QUERY | tag      | v1            |
    Then the response status is 422:
      | SOURCE | CONDITION | VALUE                            |
      | BODY   | contains  | has no devcontainer.metadata label |

    When I send a GET request to Endpoint known as "<AppApi>" path "/devcontainer" with:
      | TYPE  | KEY      | VALUE         |
      | QUERY | registry | <RegistryUrl> |
      | QUERY | name     | plain         |
      | QUERY | tag      | does-not-exist |
    Then the response status is 404

    When I send a GET request to Endpoint known as "<AppApi>" path "/devcontainer" with:
      | TYPE  | KEY      | VALUE         |
      | QUERY | registry | <RegistryUrl> |
      | QUERY | name     | plain         |
    Then the response status is 400

    When I remove Docker Buildx Builder known as "<TestBuilder>"
    Then the command exited with 0
    When I remove Docker Buildx Builder known as "<Builder>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<Release>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestBuildkitRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryAuthedRelease>"
    Then the command exited with 0
    When I uninstall Helm Release known as "<TestRegistryRelease>"
    Then the command exited with 0
    When I uninstall Helm Release "<NamespaceRelease>" with --wait --timeout 120s
    Then the command exited with 0
