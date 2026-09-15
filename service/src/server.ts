import { createRequire } from "node:module";
import Fastify, { type FastifyError, type FastifyInstance } from "fastify";
import fastifySwagger from "@fastify/swagger";
import fastifySwaggerUi from "@fastify/swagger-ui";
import { TypeBoxTypeProvider } from "@fastify/type-provider-typebox";
import * as Sentry from "@sentry/node";
import { buildDevcontainer, isReady, serviceConfig, BuildRequestError } from "./build.js";
import { manifestExists, deleteManifest, type RegistryAuthOverride } from "./registry-client.js";
import { registry as metricsRegistry, buildsTotal, buildDurationSeconds, imageChecksTotal, imageDeletesTotal } from "./metrics.js";
import {
  BuildRequestSchema,
  BuildResponseSchema,
  ConfigResponseSchema,
  ErrorResponseSchema,
  HealthLiveResponseSchema,
  HealthReadyResponseSchema,
  HealthStartupResponseSchema,
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

const TAGS = {
  build: "Building devcontainers",
  images: "Images",
  health: "Health (Kubernetes probes)",
  config: "Configuration (read-only)",
} as const;

const require = createRequire(import.meta.url);
const packageVersion: string = require("../package.json").version;

// No-op unless Sentry is actually configured (serviceConfig.sentryDsn) -
// every call site below stays a plain, unconditional call either way.
function captureIfEnabled(err: unknown): void {
  if (serviceConfig.sentryDsn) {
    Sentry.captureException(err);
  }
}

// Builds and fully configures the app (routes, schemas, swagger) without
// binding a port - kept separate from actually listening so this is
// injectable/testable (fastify.inject()) and so index.ts, the real
// entrypoint, controls exactly when the process starts accepting traffic.
export async function buildApp(): Promise<FastifyInstance> {
  if (serviceConfig.sentryDsn) {
    Sentry.init({
      dsn: serviceConfig.sentryDsn,
      integrations: [Sentry.fastifyIntegration()],
      // GlitchTip (Sentry-protocol-compatible) doesn't speak every modern
      // Sentry-SDK feature - tracesSampleRate/profiling are deliberately
      // left off rather than assumed supported; OpenTelemetry (tracing.ts)
      // already covers distributed tracing for a Tempo-style backend.
    });
  }

  // coerceTypes is Fastify's own AJV default (on, for query-string-style
  // stringly-typed inputs) - off here because it silently coerces an empty
  // string into `null` for any property whose schema allows a null branch
  // (a documented AJV quirk, not specific to this schema), which would
  // undermine the null-means-absent/""-is-rejected distinction
  // OptionalNonEmptyString exists to enforce. The original hand-written
  // validator never coerced types either, so this keeps that behavior.
  const app = Fastify({
    logger: {
      // pino's own default is a numeric level (30, 50, ...) - a literal
      // label ("info", "error", ...) is what makes these JSON lines
      // directly readable/filterable in Loki or any other log sink without
      // a lookup table.
      formatters: { level: (label) => ({ level: label }) },
    },
    ajv: { customOptions: { coerceTypes: false } },
  }).withTypeProvider<TypeBoxTypeProvider>();

  if (serviceConfig.sentryDsn) {
    Sentry.setupFastifyErrorHandler(app);
  }

  await app.register(fastifySwagger, {
    openapi: {
      // 3.1, not @fastify/swagger's default 3.0.x - 3.1 is a strict JSON
      // Schema 2020-12 superset, so TypeBox's own `examples` (plural, a
      // real JSON Schema keyword) survives the transform intact instead of
      // being silently dropped the way it is under 3.0 (which only
      // supports a single `example`).
      openapi: "3.1.0",
      info: {
        title: "devcontainer-builder",
        description:
          "Builds a container image from a git repository's .devcontainer.json using a remote BuildKit builder, and pushes it to a registry.",
        version: packageVersion,
      },
      tags: [
        { name: TAGS.build, description: "Turn a git repository into a real, pushed image." },
        { name: TAGS.images, description: "Check or best-effort delete a previously-built image." },
        { name: TAGS.health, description: "Kubernetes-style startup/liveness/readiness probes." },
        { name: TAGS.config, description: "Non-sensitive view of the service's own loaded configuration." },
      ],
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
    captureIfEnabled(error);
    reply.code(500).send({ error: error.message });
  });

  app.get(
    "/health/startup",
    { schema: { tags: [TAGS.health], response: { 200: HealthStartupResponseSchema } } },
    async () => {
      // Distinct route from /health/live, even though the check is
      // identical today (200 once the process can answer HTTP at all) -
      // this service has no separate async startup phase (config loading
      // is synchronous, before the server ever starts listening), so
      // there's nothing more to distinguish yet. Kept separate anyway so a
      // Kubernetes startupProbe (generous failureThreshold, to tolerate a
      // slow scheduling/image pull) can be tuned independently of
      // livenessProbe (tight, once actually started) - see the Helm
      // chart - and so any future real async startup work has a route to
      // grow into without overloading /health/live's meaning.
      return { status: "started" as const };
    },
  );

  app.get(
    "/health/live",
    { schema: { tags: [TAGS.health], response: { 200: HealthLiveResponseSchema } } },
    async () => {
      return { status: "ok" as const };
    },
  );

  app.get(
    "/health/ready",
    { schema: { tags: [TAGS.health], response: { 200: HealthReadyResponseSchema, 503: HealthReadyResponseSchema } } },
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

  app.get("/config", { schema: { tags: [TAGS.config], response: { 200: ConfigResponseSchema } } }, async () => {
    return {
      buildkitConfigured: Boolean(serviceConfig.buildkitEndpoint),
      buildxBuilderName: serviceConfig.buildxBuilderName,
      sshHostKeyPolicy: serviceConfig.sshHostKeyPolicy,
      defaultPlatforms: serviceConfig.defaultPlatforms,
      defaultBuildOptions: serviceConfig.defaultBuildOptions,
      // Never the credential material itself (token/privateKey/pinnedHostKey) -
      // just enough to answer "which hosts/registries does this instance
      // already know about", the whole point of this endpoint.
      gitCredentials: serviceConfig.gitCredentials.map((entry) => ({ host: entry.host, kind: entry.kind })),
      registryMappingRules: serviceConfig.registryMappingRules,
    };
  });

  app.get("/metrics", { schema: { tags: [TAGS.health], hide: true } }, async (_request, reply) => {
    reply.header("Content-Type", metricsRegistry.contentType);
    return metricsRegistry.metrics();
  });

  app.post<{ Body: BuildRequestBody }>(
    "/build",
    {
      schema: {
        tags: [TAGS.build],
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

      const stopTimer = buildDurationSeconds.startTimer();
      try {
        const result = await buildDevcontainer(request.body);
        buildsTotal.inc({ status: "success" });
        stopTimer({ status: "success" });
        return result;
      } catch (err) {
        if (err instanceof BuildRequestError) {
          buildsTotal.inc({ status: "invalid_request" });
          stopTimer({ status: "invalid_request" });
          reply.code(400);
          return { error: err.message };
        }
        buildsTotal.inc({ status: "failure" });
        stopTimer({ status: "failure" });
        captureIfEnabled(err);
        reply.code(500);
        return { error: err instanceof Error ? err.message : "build failed" };
      }
    },
  );

  app.get<{ Querystring: ImageQuery }>(
    "/image",
    {
      schema: {
        tags: [TAGS.images],
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
        imageChecksTotal.inc({ result: exists ? "exists" : "absent" });
        return { image: `${registry}/${name}:${tag}`, exists };
      } catch (err) {
        imageChecksTotal.inc({ result: "error" });
        captureIfEnabled(err);
        reply.code(502);
        return { error: err instanceof Error ? err.message : "registry request failed" };
      }
    },
  );

  app.delete<{ Querystring: ImageQuery }>(
    "/image",
    {
      schema: {
        tags: [TAGS.images],
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
        imageDeletesTotal.inc({ result: result.deleted ? "deleted" : "unsupported" });
        return { image: `${registry}/${name}:${tag}`, ...result };
      } catch (err) {
        imageDeletesTotal.inc({ result: "error" });
        captureIfEnabled(err);
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
