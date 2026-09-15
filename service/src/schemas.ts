import { Type, type Static } from "@sinclair/typebox";

// TypeBox schemas for every route this service exposes - the single source
// of truth for both real Fastify request validation and the OpenAPI
// document @fastify/swagger derives from these same route schemas (see
// server.ts). Every shape here mirrors docs/reference/API.md exactly;
// that page (not this file) is still where a human goes to read the
// contract, but this is now what actually enforces it.
//
// A few fields (image.{registry,name,tag}, branch, buildOptions.{cacheFrom,cacheTo})
// accept `null` as "not provided" but reject `""` - OptionalNonEmptyString
// below encodes that with a real anyOf, not a convention left to callers to
// notice.
const OptionalNonEmptyString = Type.Optional(Type.Union([Type.Null(), Type.String({ minLength: 1 })]));

export const GitCredentialsSchema = Type.Object(
  {
    // Deliberately plain Type.String(), not minLength: 1 - the current,
    // documented, BDD-covered behavior only checks typeof "string" here,
    // an empty-string username/token passes shape validation (the
    // downstream clone fails on its own if they're actually wrong).
    username: Type.String(),
    token: Type.String(),
  },
  { additionalProperties: true },
);

export const RegistryCredentialsSchema = Type.Object(
  {
    // Unlike gitCredentials, every registryCredentials field must be a real
    // non-empty string - all three are required together once the object
    // is present at all.
    registry: Type.String({ minLength: 1 }),
    username: Type.String({ minLength: 1 }),
    password: Type.String({ minLength: 1 }),
  },
  { additionalProperties: true },
);

export const ImageTargetSchema = Type.Object(
  {
    registry: OptionalNonEmptyString,
    name: OptionalNonEmptyString,
    tag: OptionalNonEmptyString,
  },
  { additionalProperties: true },
);

export const BuildOptionsSchema = Type.Object(
  {
    noCache: Type.Optional(Type.Boolean()),
    cacheFrom: OptionalNonEmptyString,
    cacheTo: OptionalNonEmptyString,
    mode: Type.Optional(Type.Union([Type.Literal("auto"), Type.Literal("never")])),
  },
  { additionalProperties: true },
);

export const BuildRequestSchema = Type.Object(
  {
    repository: Type.String({ minLength: 1 }),
    branch: OptionalNonEmptyString,
    image: Type.Optional(Type.Union([Type.Null(), ImageTargetSchema])),
    gitCredentials: Type.Optional(GitCredentialsSchema),
    registryCredentials: Type.Optional(RegistryCredentialsSchema),
    platforms: Type.Optional(Type.Array(Type.String({ minLength: 1 }))),
    buildOptions: Type.Optional(BuildOptionsSchema),
  },
  {
    // Unknown top-level fields are tolerated, not rejected - see
    // docs/reference/API.md's POST /build section.
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

export const BuildResponseSchema = Type.Object({
  image: Type.String(),
  registry: Type.String(),
  name: Type.String(),
  tag: Type.String(),
});

export const ImageQuerySchema = Type.Object({
  registry: Type.String({ minLength: 1 }),
  name: Type.String({ minLength: 1 }),
  tag: Type.String({ minLength: 1 }),
});
export type ImageQuery = Static<typeof ImageQuerySchema>;

export const ImageExistsResponseSchema = Type.Object({
  image: Type.String(),
  exists: Type.Boolean(),
});

export const ImageDeleteResponseSchema = Type.Object({
  image: Type.String(),
  deleted: Type.Boolean(),
  reason: Type.Optional(Type.String()),
});

export const ErrorResponseSchema = Type.Object({
  error: Type.String(),
});

export const HealthStartupResponseSchema = Type.Object({
  status: Type.Literal("started"),
});

export const HealthLiveResponseSchema = Type.Object({
  status: Type.Literal("ok"),
});

export const HealthReadyResponseSchema = Type.Object({
  status: Type.Union([Type.Literal("ready"), Type.Literal("not ready")]),
  reason: Type.Optional(Type.String()),
});

// Read-only, non-sensitive view of the service's own loaded ServiceConfig
// (src/config.ts) - never the credential material itself. gitCredentials
// entries are reduced to {host, kind}; registryMappingRules are already
// non-sensitive in full (no credentials live there).
export const ConfigGitCredentialSchema = Type.Object({
  host: Type.String(),
  kind: Type.Union([Type.Literal("https"), Type.Literal("ssh")]),
});

export const ConfigRegistryMappingRuleSchema = Type.Object({
  hostMatch: Type.Optional(Type.String()),
  pathPrefix: Type.Optional(Type.String()),
  registry: Type.String(),
});

export const ConfigResponseSchema = Type.Object({
  buildkitConfigured: Type.Boolean(),
  buildxBuilderName: Type.String(),
  sshHostKeyPolicy: Type.Union([Type.Literal("tofu"), Type.Literal("pinned")]),
  defaultPlatforms: Type.Array(Type.String()),
  defaultBuildOptions: Type.Object({
    noCache: Type.Boolean(),
    cacheFrom: Type.Optional(Type.String()),
    cacheTo: Type.Optional(Type.String()),
    mode: Type.Union([Type.Literal("auto"), Type.Literal("never")]),
  }),
  gitCredentials: Type.Array(ConfigGitCredentialSchema),
  registryMappingRules: Type.Array(ConfigRegistryMappingRuleSchema),
});
