import { createRequire } from "node:module";
import pino, { type DestinationStream } from "pino";
import type { FastifyBaseLogger } from "fastify";
import { serviceConfig } from "./config.js";

const require = createRequire(import.meta.url);
const packageVersion: string = require("../package.json").version;

// A standalone Pino instance, not Fastify's inline `logger:` options object
// (server.ts used to pass one directly) - a shared instance guarantees every
// log line gets identical base fields/redaction/formatting whether it's
// logged inside a request (via Fastify's `loggerInstance` option, see
// server.ts) or not, and lets a test build one against an in-memory
// `destination` instead of real stdout. Typed as the narrower
// FastifyBaseLogger (not pino's own richer Logger type) - Fastify's
// `loggerInstance` option's generic inference otherwise overfits onto
// pino's exact type and picks the wrong internal FastifyInstance overload.
export function createLogger(destination?: DestinationStream): FastifyBaseLogger {
  return pino(
    {
      // pino's own default is a numeric level (30, 50, ...) - a literal
      // label ("info", "error", ...) is what makes these JSON lines
      // directly filterable in Loki without a lookup table. Kept under the
      // key `level` (not renamed to `severity`, despite that being the
      // more OTel-Logs-flavored name) because Loki's `detected_level`
      // heuristic already recognizes this exact field name and the
      // deployed "Logs Overview" Grafana dashboard already relies on it -
      // renaming it would be a real regression for no functional gain.
      formatters: { level: (label) => ({ level: label }) },
      // Baked in once here, not repeated at every call site. "service.name"
      // deliberately mirrors app.kubernetes.io/name (see the Helm chart's
      // unconditional SERVICE_NAME env var), so it always matches the `app`
      // Loki label Alloy already promotes for this same pod.
      base: {
        "service.name": serviceConfig.serviceName,
        "service.version": packageVersion,
        "deployment.environment.name": serviceConfig.environment,
      },
      // Literal "timestamp" key in ISO-8601, matching the dotted-field
      // naming used everywhere else in this contract (http.*, error.*, ...)
      // - pino's own default is epoch-ms under a "time" key.
      timestamp: () => `,"timestamp":"${new Date().toISOString()}"`,
      // Renamed from pino's default "msg" to match "message" elsewhere.
      messageKey: "message",
      // Defense-in-depth, not a fix for a real leak today - ADR-0002's
      // readRegistryAuthHeaders (server.ts) already keeps these out of
      // anything that reaches request.log. Forecloses a future accidental
      // `logger.info({ headers: request.headers })` from ever printing a
      // registry credential or bearer token.
      redact: {
        paths: [
          'req.headers["x-registry-username"]',
          'req.headers["x-registry-password"]',
          "req.headers.authorization",
          "*.headers.authorization",
        ],
        censor: "[redacted]",
      },
    },
    destination,
  );
}

export const logger = createLogger();
