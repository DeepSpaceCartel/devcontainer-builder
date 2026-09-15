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
  // Unknown top-level fields are tolerated, not rejected - see
  // docs/reference/API.md's POST /build section.
  { additionalProperties: true },
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

export const HealthLiveResponseSchema = Type.Object({
  status: Type.Literal("ok"),
});

export const HealthReadyResponseSchema = Type.Object({
  status: Type.Union([Type.Literal("ready"), Type.Literal("not ready")]),
  reason: Type.Optional(Type.String()),
});
