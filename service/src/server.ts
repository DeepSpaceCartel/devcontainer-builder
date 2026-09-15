import { createRequire } from "node:module";
import Fastify, { type FastifyError, type FastifyInstance } from "fastify";
import fastifySwagger from "@fastify/swagger";
import fastifySwaggerUi from "@fastify/swagger-ui";
import { TypeBoxTypeProvider } from "@fastify/type-provider-typebox";
import { buildDevcontainer, isReady, BuildRequestError } from "./build.js";
import { manifestExists, deleteManifest, type RegistryAuthOverride } from "./registry-client.js";
import {
  BuildRequestSchema,
  BuildResponseSchema,
  ErrorResponseSchema,
  HealthLiveResponseSchema,
  HealthReadyResponseSchema,
  ImageDeleteResponseSchema,
  ImageExistsResponseSchema,
  ImageQuerySchema,
  type BuildRequestBody,
  type ImageQuery,
} from "./schemas.js";

// Explicit per-call registry credentials for /image, mirroring
// registryCredentials on /build - deliberately headers, not query params,
// so they never land in access logs (same ADR-0002 rationale as the
// scratch-file pattern used elsewhere for credentials). Falls back to the
// service's ambient DOCKER_CONFIG auth (see registry-client.ts) when absent.
function readRegistryAuthHeaders(headers: Record<string, unknown>): RegistryAuthOverride | undefined {
  const username = headers["x-registry-username"];
  const password = headers["x-registry-password"];
  if (typeof username === "string" && typeof password === "string" && username.length > 0 && password.length > 0) {
    return { username, password };
  }
  return undefined;
}

const BUILD_REQUEST_SHAPE_ERROR =
  "missing or invalid fields: repository (required); branch, image.{registry,name,tag}, " +
  "gitCredentials.{username,token}, registryCredentials.{registry,username,password}, " +
  "platforms, buildOptions.{noCache,cacheFrom,cacheTo,mode} (all optional)";

const IMAGE_QUERY_SHAPE_ERROR = "missing or invalid query parameters: registry, name, tag (all required)";

const require = createRequire(import.meta.url);
const packageVersion: string = require("../package.json").version;

// Builds and fully configures the app (routes, schemas, swagger) without
// binding a port - kept separate from actually listening so this is
// injectable/testable (fastify.inject()) and so index.ts, the real
// entrypoint, controls exactly when the process starts accepting traffic.
export async function buildApp(): Promise<FastifyInstance> {
  // coerceTypes is Fastify's own AJV default (on, for query-string-style
  // stringly-typed inputs) - off here because it silently coerces an empty
  // string into `null` for any property whose schema allows a null branch
  // (a documented AJV quirk, not specific to this schema), which would
  // undermine the null-means-absent/""-is-rejected distinction
  // OptionalNonEmptyString exists to enforce. The original hand-written
  // validator never coerced types either, so this keeps that behavior.
  const app = Fastify({ logger: true, ajv: { customOptions: { coerceTypes: false } } }).withTypeProvider<TypeBoxTypeProvider>();

  await app.register(fastifySwagger, {
    openapi: {
      info: {
        title: "devcontainer-builder",
        description:
          "Builds a container image from a git repository's .devcontainer.json using a remote BuildKit builder, and pushes it to a registry.",
        version: packageVersion,
      },
    },
  });
  await app.register(fastifySwaggerUi, { routePrefix: "/documentation" });

  // Every documented 400 body in docs/reference/API.md is a single static
  // string regardless of which sub-field actually failed - matches
  // isValidBuildRequest's historical behavior and the request_validation.feature
  // BDD suite's exact-string assertions. attachValidation: true keeps
  // TypeBox/AJV as the real, generated-OpenAPI-backing validator without
  // handing back AJV's own per-field error format on failure.
  app.setErrorHandler((error: FastifyError, request, reply) => {
    if (error.code === "FST_ERR_CTP_INVALID_JSON_BODY" || error.code === "FST_ERR_CTP_EMPTY_JSON_BODY") {
      reply.code(400).send({ error: "invalid JSON body" });
      return;
    }
    request.log.error(error);
    reply.code(500).send({ error: error.message });
  });

  app.get("/health/live", { schema: { response: { 200: HealthLiveResponseSchema } } }, async () => {
    return { status: "ok" as const };
  });

  app.get(
    "/health/ready",
    { schema: { response: { 200: HealthReadyResponseSchema, 503: HealthReadyResponseSchema } } },
    async (request, reply) => {
      const readiness = isReady();
      if (readiness.ready) {
        return { status: "ready" as const };
      }
      request.log.error(`readiness check failed: ${readiness.reason}`);
      reply.code(503);
      return { status: "not ready" as const, reason: readiness.reason };
    },
  );

  app.post<{ Body: BuildRequestBody }>(
    "/build",
    {
      schema: {
        body: BuildRequestSchema,
        response: { 200: BuildResponseSchema, 400: ErrorResponseSchema, 500: ErrorResponseSchema },
      },
      attachValidation: true,
    },
    async (request, reply) => {
      if (request.validationError) {
        reply.code(400);
        return { error: BUILD_REQUEST_SHAPE_ERROR };
      }

      try {
        return await buildDevcontainer(request.body);
      } catch (err) {
        if (err instanceof BuildRequestError) {
          reply.code(400);
          return { error: err.message };
        }
        reply.code(500);
        return { error: err instanceof Error ? err.message : "build failed" };
      }
    },
  );

  app.get<{ Querystring: ImageQuery }>(
    "/image",
    {
      schema: {
        querystring: ImageQuerySchema,
        response: { 200: ImageExistsResponseSchema, 400: ErrorResponseSchema, 502: ErrorResponseSchema },
      },
      attachValidation: true,
    },
    async (request, reply) => {
      if (request.validationError) {
        reply.code(400);
        return { error: IMAGE_QUERY_SHAPE_ERROR };
      }

      const { registry, name, tag } = request.query;
      const auth = readRegistryAuthHeaders(request.headers);

      try {
        const { exists } = await manifestExists(registry, name, tag, auth);
        return { image: `${registry}/${name}:${tag}`, exists };
      } catch (err) {
        reply.code(502);
        return { error: err instanceof Error ? err.message : "registry request failed" };
      }
    },
  );

  app.delete<{ Querystring: ImageQuery }>(
    "/image",
    {
      schema: {
        querystring: ImageQuerySchema,
        response: { 200: ImageDeleteResponseSchema, 400: ErrorResponseSchema, 502: ErrorResponseSchema },
      },
      attachValidation: true,
    },
    async (request, reply) => {
      if (request.validationError) {
        reply.code(400);
        return { error: IMAGE_QUERY_SHAPE_ERROR };
      }

      const { registry, name, tag } = request.query;
      const auth = readRegistryAuthHeaders(request.headers);

      try {
        const result = await deleteManifest(registry, name, tag, auth);
        return { image: `${registry}/${name}:${tag}`, ...result };
      } catch (err) {
        reply.code(502);
        return { error: err instanceof Error ? err.message : "registry request failed" };
      }
    },
  );

  app.setNotFoundHandler((_request, reply) => {
    reply.code(404).send({ error: "not found" });
  });

  return app;
}
