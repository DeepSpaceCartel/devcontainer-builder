import { Type, type Static } from "@sinclair/typebox";
import { IMAGE_NAME_PATTERN, IMAGE_REGISTRY_PATTERN, IMAGE_TAG_PATTERN, PLATFORM_PATTERN } from "./image-ref.js";

// TypeBox schemas for every route this service exposes - the single source
// of truth for both real Fastify request validation and the OpenAPI
// document @fastify/swagger derives from these same route schemas (see
// server.ts). Field/schema `description`s below are real API documentation,
// not code comments - @fastify/swagger renders them into the generated
// OpenAPI document (bundled statically into the docs site as
// docs/api-reference.html/docs/api-swagger-ui/, see
// docs/project/installing.md#this-documentation-site; live at
// GET /documentation on a running instance), which is why they read like
// prose rather than "why not what" implementation
// notes. Nothing here should describe *this file*, only the contract callers
// actually see.
//
// A few fields (image.{registry,name,tag}, branch, buildOptions.{cacheFrom,cacheTo})
// accept `null` as "not provided" but reject `""` - a real anyOf on each
// (Type.Union([Type.Null(), Type.String({minLength: 1})])), not a
// convention left to callers to notice. Each is inlined per-field rather
// than shared, so a field-specific `description` can sit on the same union.

export const GitCredentialsSchema = Type.Object(
  {
    // Deliberately plain Type.String(), not minLength: 1 - the current,
    // documented, BDD-covered behavior only checks typeof "string" here,
    // an empty-string username/token passes shape validation (the
    // downstream clone fails on its own if they're actually wrong).
    username: Type.String({ description: "Git HTTPS username." }),
    token: Type.String({
      description: "Git HTTPS token/password. Always HTTPS-shaped - see Credential handling docs for SSH's own server-side-only path.",
    }),
  },
  { additionalProperties: true, description: "Per-request git credentials for the clone. Both fields required together." },
);

export const RegistryCredentialsSchema = Type.Object(
  {
    // Unlike gitCredentials, every registryCredentials field must be a real
    // non-empty string - all three are required together once the object
    // is present at all.
    registry: Type.String({ minLength: 1, description: "Non-empty. The registry these credentials authenticate against." }),
    username: Type.String({ minLength: 1, description: "Non-empty." }),
    password: Type.String({ minLength: 1, description: "Non-empty." }),
  },
  {
    additionalProperties: true,
    description:
      "Per-request registry push credentials. All three fields required together. Omit entirely to rely on the server's own ambient registryAuth for the target registry instead.",
  },
);

export const ImageTargetSchema = Type.Object(
  {
    registry: Type.Optional(
      Type.Union([Type.Null(), Type.String({ minLength: 1, pattern: IMAGE_REGISTRY_PATTERN })], {
        description:
          "Wins over any server-side registry mapping rule. A registry host with optional port and namespace path (`ghcr.io/org`, `registry.local:5000`) - no `http://`/`https://` scheme.",
      }),
    ),
    name: Type.Optional(
      Type.Union([Type.Null(), Type.String({ minLength: 1, pattern: IMAGE_NAME_PATTERN })], {
        description:
          "A valid OCI repository name (lower-case `[a-z0-9]` components joined by `.`, `_`, `__` or `-`, optionally `/`-separated). Defaults to the repository path's last segment, with a trailing .git stripped, lower-cased and with any other character replaced by `-`.",
      }),
    ),
    tag: Type.Optional(
      Type.Union([Type.Null(), Type.String({ minLength: 1, pattern: IMAGE_TAG_PATTERN })], {
        description: 'A valid OCI tag (up to 128 of `[A-Za-z0-9_.-]`, not starting with `.` or `-`). Defaults to "sha-<short HEAD sha>".',
      }),
    ),
  },
  { additionalProperties: true },
);

export const BuildOptionsSchema = Type.Object(
  {
    noCache: Type.Optional(Type.Boolean({ description: 'Overrides the chart\'s build.noCache - passed as "--no-cache" when true.' })),
    cacheFrom: Type.Optional(
      Type.Union([Type.Null(), Type.String({ minLength: 1 })], {
        description:
          "Overrides the chart's build.cacheFrom. A plain image reference, or buildx `key=value` pairs whose `type` is `registry`, `gha` or `inline` - other cache types (`local`, `s3`, ...) are rejected with 400.",
      }),
    ),
    cacheTo: Type.Optional(
      Type.Union([Type.Null(), Type.String({ minLength: 1 })], {
        description: "Overrides the chart's build.cacheTo. Same rules as `cacheFrom`.",
      }),
    ),
    mode: Type.Optional(
      Type.Union([Type.Literal("auto"), Type.Literal("never")], { description: "Overrides the chart's build.mode." }),
    ),
  },
  { additionalProperties: true },
);

export const BuildRequestSchema = Type.Object(
  {
    repository: Type.String({
      minLength: 1,
      description:
        "`https://`, `ssh://`, or git's own SCP-style `[user@]host:path` shorthand. Any other scheme is rejected with 400 (`git://` and `http://` only when the server enables `allowInsecureGitProtocols`), and so are credentials in the URL (`https://user:token@...`) - use `gitCredentials`.",
    }),
    branch: Type.Optional(
      Type.Union([Type.Null(), Type.String({ minLength: 1 })], {
        description: "Branch (or tag) to build. Omitted or null: the repository's default branch. Non-empty if given.",
      }),
    ),
    image: Type.Optional(Type.Union([Type.Null(), ImageTargetSchema])),
    gitCredentials: Type.Optional(GitCredentialsSchema),
    registryCredentials: Type.Optional(RegistryCredentialsSchema),
    platforms: Type.Optional(
      Type.Array(Type.String({ minLength: 1, pattern: PLATFORM_PATTERN }), {
        description:
          'Overrides the chart\'s build.platforms for this request, e.g. ["linux/amd64", "linux/arm64"]. Omitted or empty means today\'s behavior (no --platform flag).',
      }),
    ),
    buildOptions: Type.Optional(BuildOptionsSchema),
  },
  {
    description:
      "`image`/`gitCredentials`/`registryCredentials`/`buildOptions` may each be omitted entirely; once present, their own required sub-fields apply. Unknown top-level fields are tolerated, not rejected.",
    // Unknown top-level fields are tolerated, not rejected - see the
    // description above (rendered into the generated OpenAPI document).
    additionalProperties: true,
    // Real, working repo/registry references (not "example.com") - the
    // second shows registryCredentials explicitly, since a request that
    // omits it only pushes successfully when the server already has
    // ambient registryAuth configured for the target registry (see the
    // Helm chart reference) - most first-time callers hit exactly this.
    examples: [
      {
        repository: "https://github.com/deepspacecartel/devcontainer-builder-examples.git",
        branch: "node",
        image: { registry: "ghcr.io/deepspacecartel" },
      },
      {
        repository: "https://github.com/deepspacecartel/devcontainer-builder-examples.git",
        branch: "python",
        image: { registry: "docker.io/deepspacecartel" },
        registryCredentials: { registry: "docker.io/deepspacecartel", username: "svc-bot", password: "hunter2" },
      },
    ],
  },
);
export type BuildRequestBody = Static<typeof BuildRequestSchema>;

export const BuildResponseSchema = Type.Object(
  {
    image: Type.String({ description: "`<registry>/<name>:<tag>`, the same value pushed." }),
    registry: Type.String({ description: "Decomposed from `image` - kept separate since re-parsing it generically is ambiguous (registry ports, default-registry conventions, tag-vs-digest forms)." }),
    name: Type.String(),
    tag: Type.String(),
    branch: Type.String({ description: "The branch built - the requested one, or the repository's default branch when none was given." }),
    commit: Type.String({ description: "Full SHA of the commit the image was built from - check this out to get the working copy that matches the image." }),
    gitCloneLogId: Type.Optional(Type.String({ description: "Fetch the full `git clone` output via `GET /logs/{id}`." })),
    imageBuildLogId: Type.Optional(
      Type.String({ description: "Fetch the full `devcontainer build --push` output (and remote builder setup) via `GET /logs/{id}`." }),
    ),
  },
  { description: "The clone and build+push both succeeded." },
);

// Fastify lower-cases header names before schema validation, so these keys
// are already the form request.headers actually uses (registry-client.ts's
// readRegistryAuthHeaders reads them the same way). additionalProperties
// stays true - every other real HTTP header (host, user-agent, accept, ...)
// must still pass through unvalidated/undocumented.
export const RegistryAuthHeadersSchema = Type.Object(
  {
    "x-registry-username": Type.Optional(
      Type.String({
        description:
          "Together with X-Registry-Password, explicit credentials for this call. Falls back to the service's ambient DOCKER_CONFIG auth for `registry` when omitted.",
      }),
    ),
    "x-registry-password": Type.Optional(Type.String({ description: "See X-Registry-Username." })),
  },
  { additionalProperties: true },
);

export const ImageQuerySchema = Type.Object({
  registry: Type.String({ minLength: 1, description: "Non-empty." }),
  name: Type.String({ minLength: 1, description: "Non-empty." }),
  tag: Type.String({ minLength: 1, description: "Non-empty." }),
});
export type ImageQuery = Static<typeof ImageQuerySchema>;

export const ImageExistsResponseSchema = Type.Object({
  image: Type.String({ description: "`<registry>/<name>:<tag>`." }),
  exists: Type.Boolean({
    description: "true if the registry has a manifest for this reference; false if it returned 404 - a normal, successful answer, not an error.",
  }),
});

export const ImageDeleteResponseSchema = Type.Object({
  image: Type.String({ description: "`<registry>/<name>:<tag>`." }),
  deleted: Type.Boolean({
    description: "true if the manifest was deleted, or was already absent - either way the post-condition \"image is gone\" holds.",
  }),
  reason: Type.Optional(
    Type.String({
      description:
        'Present, e.g. "registry does not support manifest deletion", when the registry returned 405/400/501 to the delete attempt (deleted: false) - not all registries support this via the standard API (Docker Hub notably doesn\'t).',
    }),
  ),
});

export const DevcontainerQuerySchema = Type.Object({
  registry: Type.String({
    minLength: 1,
    description: "Non-empty. As `POST /build` returns it - a namespaced registry (`ghcr.io/deepspacecartel`) is fine.",
  }),
  name: Type.String({ minLength: 1, description: "Non-empty." }),
  tag: Type.String({ minLength: 1, description: "Non-empty." }),
  platform: Type.Optional(
    Type.String({
      pattern: "^[^/]+/[^/]+(/[^/]+)?$",
      description: "`os/arch[/variant]` to read from a multi-platform image. Defaults to `linux/amd64`; ignored for a single-platform image.",
    }),
  ),
});
export type DevcontainerQuery = Static<typeof DevcontainerQuerySchema>;

const LifecycleScriptSchema = Type.Union([Type.String(), Type.Null()]);

export const DevcontainerResponseSchema = Type.Object(
  {
    image: Type.String({ description: "`<registry>/<name>:<tag>`." }),
    digest: Type.Optional(Type.String({ description: "Digest of the (platform) manifest the label was read from." })),
    configuration: Type.Object(
      {
        remoteUser: Type.Optional(Type.String()),
        containerUser: Type.Optional(Type.String()),
        onCreateCommands: Type.Array(Type.Unknown()),
        updateContentCommands: Type.Array(Type.Unknown()),
        postCreateCommands: Type.Array(Type.Unknown()),
        postStartCommands: Type.Array(Type.Unknown()),
        postAttachCommands: Type.Array(Type.Unknown()),
        customizations: Type.Optional(Type.Record(Type.String(), Type.Array(Type.Unknown()))),
      },
      {
        additionalProperties: true,
        description:
          "The image's `devcontainer.metadata` label merged exactly as `@devcontainers/cli` merges it - the same shape as `mergedConfiguration` from `devcontainer read-configuration --include-merged-configuration`: devcontainer.json property names, with each lifecycle hook as a plural list (`postCreateCommands`) of every entry's command in run order, and `customizations` as a per-tool list of every entry's value, unmerged. Variables like `${containerWorkspaceFolder}` are not substituted. `workspaceFolder` is never part of the label.",
      },
    ),
    lifecycleScripts: Type.Object(
      {
        initializeCommand: LifecycleScriptSchema,
        onCreateCommand: LifecycleScriptSchema,
        updateContentCommand: LifecycleScriptSchema,
        postCreateCommand: LifecycleScriptSchema,
        postStartCommand: LifecycleScriptSchema,
        postAttachCommand: LifecycleScriptSchema,
      },
      {
        description:
          "Each hook's commands rendered as one POSIX `sh` script (`null` if no entry sets it), with the Dev Containers CLI's semantics: entries run in order (base image, Features, devcontainer.json), a string runs via `/bin/sh -c`, an array as argv without a shell, an object's named commands in parallel; the first failure stops the script with that exit code. `initializeCommand` (from devcontainer.json; it runs on the host in Dev Containers) is meant to run first. devcontainer.json variables are shell references (see `variables`), expanded when the script runs. The caller chooses cwd (the workspace folder), user, and when to run each hook.",
      },
    ),
    envScripts: Type.Object(
      {
        containerEnv: LifecycleScriptSchema,
        remoteEnv: LifecycleScriptSchema,
      },
      {
        description:
          "`containerEnv` (runArgs `-e` first) and `remoteEnv` as POSIX `sh` `export K=\"...\"` lines, `null` when empty. Source containerEnv, then remoteEnv, before starting anything: values like `${PATH}:/opt/bin` expand against the container's real environment, the order the CLI resolves them in.",
      },
    ),
    runtime: Type.Object(
      {
        remoteUser: Type.String({ description: "remoteUser, else containerUser, else the image's USER, else root." }),
        remoteUserUid: Type.Union([Type.Number(), Type.Null()], {
          description:
            "remoteUser's uid, gid and home in the image's /etc/passwd, recorded at build time (devcontainer-builder >= 0.3.0) - enough to run a pod as that user directly (runAsUser/runAsGroup/fsGroup). Null when unknown (older image, or no shell in it).",
        }),
        remoteUserGid: Type.Union([Type.Number(), Type.Null()]),
        remoteUserHome: Type.Union([Type.String(), Type.Null()]),
        containerUser: Type.Union([Type.String(), Type.Null()]),
        ports: Type.Array(
          Type.Object({
            port: Type.Number(),
            label: Type.Optional(Type.String()),
            protocol: Type.Optional(Type.String()),
            onAutoForward: Type.Optional(Type.String()),
          }),
          { description: "Numeric forwardPorts with their portsAttributes; `host:port` entries are dropped with a warning." },
        ),
        mounts: Type.Array(
          Type.Object({
            kind: Type.Union([Type.Literal("volume"), Type.Literal("tmpfs")]),
            source: Type.Optional(Type.String()),
            target: Type.String(),
            readOnly: Type.Boolean(),
          }),
          { description: "mounts plus runArgs --mount/-v/--tmpfs; bind mounts are dropped with a warning. `target` may contain workspace placeholders like ${containerWorkspaceFolder}." },
        ),
        capAdd: Type.Array(Type.String()),
        privileged: Type.Boolean(),
        init: Type.Boolean(),
        seccompUnconfined: Type.Boolean(),
        shmSizeBytes: Type.Union([Type.Number(), Type.Null()]),
        hostname: Type.Union([Type.String(), Type.Null()]),
        hostAliases: Type.Array(Type.Object({ ip: Type.String(), hostnames: Type.Array(Type.String()) })),
        resources: Type.Object({
          cpus: Type.Union([Type.Number(), Type.Null()]),
          memoryBytes: Type.Union([Type.Number(), Type.Null()]),
          storageBytes: Type.Union([Type.Number(), Type.Null()]),
          gpu: Type.Unknown(),
        }),
      },
      {
        description:
          "The merged configuration (plus the build's runArgs) translated into what a Kubernetes pod can express. Docker-only settings without a pod equivalent (--network, --device, bind mounts, ...) are dropped with a warning.",
      },
    ),
    variables: Type.Array(
      Type.Object({
        kind: Type.Union([Type.Literal("localEnv"), Type.Literal("containerEnv"), Type.Literal("context")]),
        name: Type.String(),
        default: Type.Optional(Type.String()),
        usedIn: Type.Array(Type.String()),
      }),
      {
        description:
          "Every devcontainer.json variable the image's labels use. Nothing is substituted here: in scripts, `${localEnv:X}` reads `$DEVCONTAINER_LOCALENV_X`, `${containerEnv:X}` reads `$X`, `${containerWorkspaceFolder}`/`${localWorkspaceFolder}` read `$DEVCONTAINER_WORKSPACE_FOLDER` (`…Basename` → `$DEVCONTAINER_WORKSPACE_FOLDER_BASENAME`), `${devcontainerId}` reads `$DEVCONTAINER_ID` - all set by the caller at runtime.",
      },
    ),
    vscode: Type.Object(
      {
        extensions: Type.Array(Type.String(), {
          description:
            "Every entry's `customizations.vscode.extensions`, in order, de-duplicated case-insensitively; `-publisher.name` removes one added by an earlier entry.",
        }),
        settings: Type.Record(Type.String(), Type.Unknown(), {
          description: "Every entry's `customizations.vscode.settings`, merged per key - the last entry wins.",
        }),
      },
      { description: "`customizations.vscode` merged the way VS Code's Dev Containers support does - the CLI itself leaves this to the tool." },
    ),
    warnings: Type.Array(Type.String(), { description: "Things in the label this response could not represent faithfully." }),
    metadata: Type.Array(Type.Record(Type.String(), Type.Unknown()), {
      description: "The raw `devcontainer.metadata` label entries, verbatim.",
    }),
  },
  {
    description: "The image's Dev Container metadata, read from its registry.",
    examples: [
      {
        image: "ghcr.io/deepspacecartel/devcontainer-builder-examples:sha-a1b2c3d",
        digest: "sha256:3f1c…",
        configuration: {
          init: false,
          privileged: false,
          remoteUser: "node",
          onCreateCommands: [],
          updateContentCommands: [],
          postCreateCommands: ["/usr/local/share/pull-git-lfs-artifacts.sh", "bash .devcontainer/postCreateCommand.sh"],
          postStartCommands: [],
          postAttachCommands: [],
          customizations: { vscode: [{ extensions: ["dbaeumer.vscode-eslint"] }, { extensions: ["hashicorp.terraform"] }] },
          remoteEnv: {},
          containerEnv: {},
          portsAttributes: {},
        },
        lifecycleScripts: {
          onCreateCommand: null,
          updateContentCommand: null,
          postCreateCommand:
            "#!/bin/sh\necho 'devcontainer: postCreateCommand from ghcr.io/devcontainers/features/git-lfs:1'\n/bin/sh -c '/usr/local/share/pull-git-lfs-artifacts.sh' || { dc_rc=$?; echo 'devcontainer: postCreateCommand from ghcr.io/devcontainers/features/git-lfs:1 failed with exit code '\"$dc_rc\" >&2; exit \"$dc_rc\"; }\n…",
          postStartCommand: null,
          postAttachCommand: null,
        },
        vscode: { extensions: ["dbaeumer.vscode-eslint", "hashicorp.terraform"], settings: {} },
        warnings: [],
        metadata: [
          { id: "ghcr.io/devcontainers/features/git-lfs:1", postCreateCommand: "/usr/local/share/pull-git-lfs-artifacts.sh" },
          { remoteUser: "node", postCreateCommand: "bash .devcontainer/postCreateCommand.sh" },
        ],
      },
    ],
  },
);

export const DevcontainerNotFoundResponseSchema = Type.Object(
  { error: Type.String() },
  { description: "The registry has no manifest for this `<name>:<tag>`." },
);

export const DevcontainerUnprocessableResponseSchema = Type.Object(
  { error: Type.String() },
  {
    description:
      "The image exists, but carries no usable `devcontainer.metadata` label (it wasn't built by the Dev Containers CLI, or the label is malformed), or it is a multi-platform image with no manifest for the requested `platform`.",
  },
);

// Shared by GET/DELETE /image's and GET /devcontainer's 502.
export const RegistryUpstreamErrorResponseSchema = Type.Object(
  { error: Type.String() },
  {
    description:
      "The registry was unreachable, the auth challenge/exchange failed, or it returned something other than a clean success/not-found response.",
  },
);

export const ErrorResponseSchema = Type.Object({
  error: Type.String({
    description:
      "A single static string regardless of which sub-field actually failed - kept that way deliberately rather than switching to AJV's own per-field validation-error format, since the exact string is already a stable, tested part of this contract. See each operation's own description for what specific strings mean.",
  }),
  logId: Type.Optional(
    Type.String({
      description:
        "Set when the failure happened during the git clone or the build+push subprocess - fetch its full captured output via `GET /logs/{id}`.",
    }),
  ),
});

export const LogContentResponseSchema = Type.String({
  description: "The captured output, as `text/plain; charset=utf-8`.",
});

export const NoContentResponseSchema = Type.Null({ description: "Deleted." });

export const BusyResponseSchema = Type.Object(
  { error: Type.String() },
  {
    description:
      "The server is already running its maximum number of concurrent builds (`build.maxConcurrent`). Retry after the `Retry-After` header's number of seconds.",
  },
);

// Matches command-log.ts's own id format exactly (kind-uuid) - validated
// here too (defense in depth, not a substitute) so a malformed id 400s
// instead of silently falling through to command-log.ts's own check and a
// generic 404.
export const LogIdParamSchema = Type.Object({
  id: Type.String({
    pattern: "^(git|docker)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    description: "A log id returned by `POST /build` (`gitCloneLogId`/`imageBuildLogId`, or `logId` on a failure response).",
  }),
});
export type LogIdParam = Static<typeof LogIdParamSchema>;

export const HealthStartupResponseSchema = Type.Object({
  status: Type.Literal("started"),
});

export const HealthLiveResponseSchema = Type.Object({
  status: Type.Literal("ok"),
});

export const HealthReadyResponseSchema = Type.Object({
  status: Type.Union([Type.Literal("ready"), Type.Literal("not ready")]),
  reason: Type.Optional(Type.String({ description: 'e.g. "BUILDKIT_ENDPOINT not configured", present only when status is "not ready".' })),
});

// gitCredentials entries are reduced to {host, kind} below - never the
// credential material itself (token/privateKey/pinnedHostKey).
// registryMappingRules are returned in full, since they were never
// sensitive to begin with.
export const ConfigGitCredentialSchema = Type.Object({
  host: Type.String(),
  kind: Type.Union([Type.Literal("https"), Type.Literal("ssh")]),
});

export const ConfigRegistryMappingRuleSchema = Type.Object({
  hostMatch: Type.Optional(Type.String()),
  pathPrefix: Type.Optional(Type.String()),
  registry: Type.String(),
});

export const ConfigRegistryAuthEntrySchema = Type.Object({
  registry: Type.String(),
});

export const ConfigResponseSchema = Type.Object(
  {
    buildkitConfigured: Type.Boolean({
      description: "A presence check (is BUILDKIT_ENDPOINT set), not a live connectivity probe against BuildKit itself.",
    }),
    buildxBuilderName: Type.String(),
    sshHostKeyPolicy: Type.Union([Type.Literal("tofu"), Type.Literal("pinned")]),
    defaultPlatforms: Type.Array(Type.String()),
    defaultBuildOptions: Type.Object({
      noCache: Type.Boolean(),
      cacheFrom: Type.Optional(Type.String()),
      cacheTo: Type.Optional(Type.String()),
      mode: Type.Union([Type.Literal("auto"), Type.Literal("never")]),
    }),
    gitCredentials: Type.Array(ConfigGitCredentialSchema, {
      description: "Never the credential material itself - just enough to answer \"which hosts does this instance already know about\".",
    }),
    registryMappingRules: Type.Array(ConfigRegistryMappingRuleSchema),
    insecureRegistries: Type.Array(Type.String(), {
      description: "Registry hosts this service's own registry calls (`/image`, `/devcontainer`) reach over plain HTTP instead of HTTPS.",
    }),
    allowInsecureGitProtocols: Type.Boolean({ description: "Whether `git://` and `http://` repository URLs are accepted." }),
    cloneTimeoutSeconds: Type.Number(),
    buildTimeoutSeconds: Type.Number(),
    maxConcurrentBuilds: Type.Number({ description: "0 means no limit." }),
    registryAuth: Type.Array(ConfigRegistryAuthEntrySchema, {
      description:
        "Registries this instance has ambient push credentials for (from the mounted Docker config, e.g. the chart's registryAuth.registries) - hostnames only, never the credential material. Empty when relying entirely on per-request registryCredentials instead.",
    }),
  },
  {
    description:
      "Read-only, non-sensitive view of the service's own loaded configuration - what devcontainer-builder was actually started with, useful for confirming a Helm upgrade or settings-file change actually took effect without shelling into the pod.",
    examples: [
      {
        buildkitConfigured: true,
        buildxBuilderName: "devcontainer-builder-remote",
        sshHostKeyPolicy: "tofu",
        defaultPlatforms: [],
        defaultBuildOptions: { noCache: false, mode: "auto" },
        gitCredentials: [{ host: "github.com", kind: "https" }],
        registryMappingRules: [{ registry: "ghcr.io/deepspacecartel" }],
        insecureRegistries: [],
        allowInsecureGitProtocols: false,
        cloneTimeoutSeconds: 600,
        buildTimeoutSeconds: 3600,
        maxConcurrentBuilds: 4,
        registryAuth: [{ registry: "ghcr.io" }],
      },
    ],
  },
);
