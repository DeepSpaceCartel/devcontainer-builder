import { createRequire } from "node:module";
import Fastify, { LogController, type FastifyError, type FastifyInstance } from "fastify";
import fastifySwagger from "@fastify/swagger";
import fastifySwaggerUi from "@fastify/swagger-ui";
import { SWAGGER_UI_CUSTOM_CSS } from "./swagger-ui-theme.js";
import { TypeBoxTypeProvider } from "@fastify/type-provider-typebox";
import * as Sentry from "@sentry/node";
import { buildDevcontainer, isReady, BuildRequestError } from "./build.js";
import { serviceConfig } from "./config.js";
import { manifestExists, deleteManifest, type RegistryAuthOverride } from "./registry-client.js";
import { readCommandLog, deleteCommandLog } from "./command-log.js";
import { registry as metricsRegistry, buildsTotal, buildDurationSeconds, imageChecksTotal, imageDeletesTotal } from "./metrics.js";
import { logger } from "./logger.js";
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
  LogIdParamSchema,
  RegistryAuthHeadersSchema,
  RegistryUpstreamErrorResponseSchema,
  type BuildRequestBody,
  type ImageQuery,
  type LogIdParam,
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

const LOG_ID_SHAPE_ERROR = "id must look like a log id returned by POST /build (git-<uuid> or docker-<uuid>)";

const TAGS = {
  build: "Dev Containers",
  images: "Images",
  health: "Health",
  config: "Configuration",
  logs: "Logs",
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

// Shared shape for the "error.*" fields every `.failed` event below logs -
// `err` is `unknown` at every catch site (no type narrowing until here), so
// this is the one place that decides what a non-Error thrown value renders
// as instead of repeating the same ternary at each call site.
// build.ts's withCommandLog attaches this to an error thrown mid-clone or
// mid-build+push, pointing at the captured output file for that phase.
function logIdOf(err: unknown): string | undefined {
  return err instanceof Error ? (err as Error & { logId?: string }).logId : undefined;
}

function errorFields(err: unknown): { "error.type": string; "error.message": string; "error.stacktrace"?: string } {
  if (err instanceof Error) {
    return { "error.type": err.constructor.name, "error.message": err.message, "error.stacktrace": err.stack };
  }
  return { "error.type": "UnknownError", "error.message": String(err) };
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
    // A standalone instance (logger.ts), not an inline options object -
    // every log line gets identical base fields/redaction whether it's
    // logged inside a request or not (see logger.ts's own header comment).
    loggerInstance: logger,
    // Fastify's own default per-request access log lines log the raw
    // request.url, querystring and all - exactly the anti-pattern this
    // service's structured-logging contract exists to avoid (a registry
    // name/image tag is domain data, not an opaque path segment, and a
    // future route's query string could carry something actually
    // sensitive). The onResponse hook below replaces it with one explicit
    // http.request.completed event per request, keyed on the matched
    // route *template* (never the querystring) via request.routeOptions.
    // logController (not the deprecated top-level disableRequestLogging,
    // removed in fastify@6) wants a real LogController instance, not a
    // plain options object - fastify exports the concrete class itself,
    // so this just constructs the real default controller with the one
    // option we actually want to change.
    logController: new LogController({ disableRequestLogging: true }),
    ajv: { customOptions: { coerceTypes: false } },
  }).withTypeProvider<TypeBoxTypeProvider>();

  if (serviceConfig.sentryDsn) {
    Sentry.setupFastifyErrorHandler(app);
  }

  app.addHook("onResponse", async (request, reply) => {
    request.log.info({
      event: "http.request.completed",
      "http.request.method": request.method,
      "http.route": request.routeOptions?.url ?? request.url,
      "http.response.status_code": reply.statusCode,
      "http.response.duration_ms": reply.elapsedTime,
    });
  });

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
        description: [
          "Builds a container image from a git repository's .devcontainer.json using a remote BuildKit builder, and pushes it to a registry.",
          "",
          "No authentication of its own - the service is meant to sit behind cluster-internal networking (see the Helm chart's `Service`).",
          "Every response is `application/json` except `GET /metrics` (`text/plain`). Any other method/path returns `404 {\"error\":\"not found\"}`.",
        ].join("\n"),
        version: packageVersion,
      },
      tags: [
        { name: TAGS.build, description: "Turn a git repository into a real, pushed image." },
        { name: TAGS.images, description: "Check or best-effort delete a previously-built image." },
        { name: TAGS.health, description: "Kubernetes-style startup/liveness/readiness probes." },
        { name: TAGS.config, description: "Non-sensitive view of the service's own loaded configuration." },
        { name: TAGS.logs, description: "Captured git clone / devcontainer build --push output, keyed by the id POST /build returns." },
      ],
    },
  });
  await app.register(fastifySwaggerUi, {
    routePrefix: "/documentation",
    // See swagger-ui-theme.ts's own header comment.
    theme: { css: [{ filename: "custom.css", content: SWAGGER_UI_CUSTOM_CSS }] },
  });

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
    request.log.error({ event: "http.request.error", ...errorFields(error) });
    captureIfEnabled(error);
    reply.code(500).send({ error: error.message });
  });

  app.get(
    "/health/startup",
    {
      schema: {
        tags: [TAGS.health],
        description:
          "Kubernetes `startupProbe`. Always `200 {\"status\":\"started\"}` once the process is listening - checks nothing beyond that. A distinct route from `GET /health/live` even though the check is identical today (this service has no separate async startup phase), so a `startupProbe` (a generous total budget, to tolerate slow pod scheduling/image pulls) can be tuned independently of `livenessProbe` (tight, once actually started).",
        response: { 200: HealthStartupResponseSchema },
      },
    },
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
    {
      schema: {
        tags: [TAGS.health],
        description: 'Liveness probe. Always `200 {"status":"ok"}` once the process is listening - checks nothing beyond that.',
        response: { 200: HealthLiveResponseSchema },
      },
    },
    async () => {
      return { status: "ok" as const };
    },
  );

  app.get(
    "/health/ready",
    {
      schema: {
        tags: [TAGS.health],
        description: "Readiness probe. `200` when `BUILDKIT_ENDPOINT` is configured, `503` when it isn't.",
        response: { 200: HealthReadyResponseSchema, 503: HealthReadyResponseSchema },
      },
    },
    async (request, reply) => {
      const readiness = isReady();
      if (readiness.ready) {
        return { status: "ready" as const };
      }
      request.log.error({ event: "health.ready.failed", reason: readiness.reason });
      reply.code(503);
      return { status: "not ready" as const, reason: readiness.reason };
    },
  );

  app.get("/config", { schema: { tags: [TAGS.config], response: { 200: ConfigResponseSchema } } }, async () => {
    // ConfigResponseSchema's own top-level `description`/`examples` carry
    // the human-readable contract for this route (rendered into the
    // generated OpenAPI document) - not repeated here.
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
      registryAuth: serviceConfig.registryAuthRegistries.map((registry) => ({ registry })),
    };
  });

  app.get(
    "/metrics",
    {
      schema: {
        tags: [TAGS.health],
        description: [
          "Prometheus text-format metrics (`Content-Type: text/plain`), for a `ServiceMonitor`/node-exporter-style scrape.",
          "Node.js process/runtime defaults (`prom-client`'s `collectDefaultMetrics`) plus:",
          "",
          "- **`devcontainer_builder_builds_total`** (counter, label `status`: `success`|`failure`|`invalid_request`) - every `POST /build` attempt.",
          "- **`devcontainer_builder_build_duration_seconds`** (histogram, label `status`) - real build wall-clock time, bucketed toward minutes (not the sub-second defaults), since a build is a clone + image build + push.",
          "- **`devcontainer_builder_image_checks_total`** (counter, label `result`: `exists`|`absent`|`error`) - every `GET /image` call.",
          "- **`devcontainer_builder_image_deletes_total`** (counter, label `result`: `deleted`|`unsupported`|`error`) - every `DELETE /image` call.",
        ].join("\n"),
      },
    },
    async (_request, reply) => {
      reply.header("Content-Type", metricsRegistry.contentType);
      return metricsRegistry.metrics();
    },
  );

  app.post<{ Body: BuildRequestBody }>(
    "/build",
    {
      schema: {
        tags: [TAGS.build],
        description: [
          "`400` always means the *request itself* was unusable - nothing was ever attempted, or a required piece of configuration to even attempt it (a registry, a host key pin) was missing:",
          "",
          '- `{"error": "invalid JSON body"}` - the request body isn\'t valid JSON at all.',
          `- \`{"error": "${BUILD_REQUEST_SHAPE_ERROR}"}\` - the parsed body isn't a JSON object, or fails the shape check.`,
          '- `{"error": "unable to parse git repository URL: <repository>"}` - `repository` doesn\'t match any accepted URL form.',
          '- `{"error": "no registry resolved for repository <repository>: provide image.registry or configure a matching registry mapping rule"}` - no `image.registry` given and no registry mapping rule matched.',
          '- `{"error": "SSH host key policy is \\"pinned\\" but no pinned key configured for host <host>"}` - the resolved SSH credential has no `pinnedHostKey` under `sshHostKeyPolicy: pinned`.',
          "",
          '`500` always means a real external command was actually run and failed - the request was well-formed, but cloning or building it didn\'t work: `{"error": "<command> <args...> exited with code <n>", "logId": "<id>"}`. The body is the real command and exit code, not the real error text (a registry\'s real 401 body, git\'s real "Permission denied") - fetch that via `GET /logs/{logId}` (also returned on success, as `gitCloneLogId`/`imageBuildLogId`).',
        ].join("\n"),
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

      request.log.info({
        event: "build.started",
        repository: request.body.repository,
        branch: request.body.branch,
        "image.registry": request.body.image?.registry,
        "image.name": request.body.image?.name,
        "image.tag": request.body.image?.tag,
      });

      const stopTimer = buildDurationSeconds.startTimer();
      try {
        const result = await buildDevcontainer(request.body);
        buildsTotal.inc({ status: "success" });
        stopTimer({ status: "success" });
        request.log.info({
          event: "build.completed",
          "image.registry": result.registry,
          "image.name": result.name,
          "image.tag": result.tag,
        });
        return result;
      } catch (err) {
        const logId = logIdOf(err);
        if (err instanceof BuildRequestError) {
          buildsTotal.inc({ status: "invalid_request" });
          stopTimer({ status: "invalid_request" });
          request.log.warn({ event: "build.failed", "log.id": logId, ...errorFields(err) });
          reply.code(400);
          return { error: err.message, logId };
        }
        buildsTotal.inc({ status: "failure" });
        stopTimer({ status: "failure" });
        request.log.error({ event: "build.failed", "log.id": logId, ...errorFields(err) });
        captureIfEnabled(err);
        reply.code(500);
        return { error: err instanceof Error ? err.message : "build failed", logId };
      }
    },
  );

  app.get<{ Querystring: ImageQuery }>(
    "/image",
    {
      schema: {
        tags: [TAGS.images],
        description:
          "Checks whether a previously-built image still exists in its registry, by talking to the registry's own HTTP API V2 directly (bearer-token challenge/exchange, then a manifest lookup).",
        querystring: ImageQuerySchema,
        headers: RegistryAuthHeadersSchema,
        response: { 200: ImageExistsResponseSchema, 400: ErrorResponseSchema, 502: RegistryUpstreamErrorResponseSchema },
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

      request.log.info({ event: "image.lookup.started", "image.registry": registry, "image.name": name, "image.tag": tag });

      try {
        const { exists } = await manifestExists(registry, name, tag, auth);
        imageChecksTotal.inc({ result: exists ? "exists" : "absent" });
        request.log.info({ event: "image.lookup.completed", "image.registry": registry, "image.name": name, "image.tag": tag, exists });
        return { image: `${registry}/${name}:${tag}`, exists };
      } catch (err) {
        imageChecksTotal.inc({ result: "error" });
        request.log.error({
          event: "image.lookup.failed",
          "image.registry": registry,
          "image.name": name,
          "image.tag": tag,
          ...errorFields(err),
        });
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
        description:
          "Best-effort deletion of a previously-built image's manifest. Not all registries support this via the standard API (Docker Hub notably doesn't) - see [0008](https://github.com/DeepSpaceCartel/devcontainer-builder/blob/main/docs/decisions/0008-image-existence-and-deletion-endpoints.md) for why that's treated as a normal outcome, not an error.",
        querystring: ImageQuerySchema,
        headers: RegistryAuthHeadersSchema,
        response: { 200: ImageDeleteResponseSchema, 400: ErrorResponseSchema, 502: RegistryUpstreamErrorResponseSchema },
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

      request.log.info({ event: "image.delete.started", "image.registry": registry, "image.name": name, "image.tag": tag });

      try {
        const result = await deleteManifest(registry, name, tag, auth);
        imageDeletesTotal.inc({ result: result.deleted ? "deleted" : "unsupported" });
        request.log.info({
          event: "image.delete.completed",
          "image.registry": registry,
          "image.name": name,
          "image.tag": tag,
          ...result,
        });
        return { image: `${registry}/${name}:${tag}`, ...result };
      } catch (err) {
        imageDeletesTotal.inc({ result: "error" });
        request.log.error({
          event: "image.delete.failed",
          "image.registry": registry,
          "image.name": name,
          "image.tag": tag,
          ...errorFields(err),
        });
        captureIfEnabled(err);
        reply.code(502);
        return { error: err instanceof Error ? err.message : "registry request failed" };
      }
    },
  );

  app.get<{ Params: LogIdParam }>(
    "/logs/:id",
    {
      schema: {
        tags: [TAGS.logs],
        description: [
          "Full captured stdout+stderr of one `git clone` or one `devcontainer build --push` (including remote builder setup) - the id comes from `POST /build`'s response (`gitCloneLogId`/`imageBuildLogId` on success, `logId` on a 500).",
          "",
          "Not persisted beyond this pod's own lifetime (backed by the same ephemeral scratch space as an in-progress build, not a volume) and rotated: only the most recent `commandLogRetention` (default 10) files are kept per kind (`git`/`docker`) - an id from an old build may already be gone.",
        ].join("\n"),
        params: LogIdParamSchema,
        response: { 400: ErrorResponseSchema, 404: ErrorResponseSchema },
      },
      attachValidation: true,
    },
    async (request, reply) => {
      if (request.validationError) {
        reply.code(400);
        return { error: LOG_ID_SHAPE_ERROR };
      }

      const { id } = request.params;
      request.log.info({ event: "logs.read.started", "log.id": id });

      const content = await readCommandLog(id);
      if (!content) {
        request.log.warn({ event: "logs.read.failed", "log.id": id, reason: "not found" });
        reply.code(404);
        return { error: "log not found" };
      }

      request.log.info({ event: "logs.read.completed", "log.id": id });
      reply.header("Content-Type", "text/plain; charset=utf-8");
      return content;
    },
  );

  app.delete<{ Params: LogIdParam }>(
    "/logs/:id",
    {
      schema: {
        tags: [TAGS.logs],
        description: "Deletes one captured command-output log ahead of its normal rotation. Idempotent - deleting an already-gone id also 404s.",
        params: LogIdParamSchema,
        response: { 400: ErrorResponseSchema, 404: ErrorResponseSchema },
      },
      attachValidation: true,
    },
    async (request, reply) => {
      if (request.validationError) {
        reply.code(400);
        return { error: LOG_ID_SHAPE_ERROR };
      }

      const { id } = request.params;
      request.log.info({ event: "logs.delete.started", "log.id": id });

      const deleted = await deleteCommandLog(id);
      if (!deleted) {
        request.log.warn({ event: "logs.delete.failed", "log.id": id, reason: "not found" });
        reply.code(404);
        return { error: "log not found" };
      }

      request.log.info({ event: "logs.delete.completed", "log.id": id });
      reply.code(204);
    },
  );

  app.setNotFoundHandler((_request, reply) => {
    reply.code(404).send({ error: "not found" });
  });

  return app;
}
