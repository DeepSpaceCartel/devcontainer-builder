// OpenTelemetry bootstrap - must be the very first thing index.ts imports,
// before fastify/node:http or anything else, since auto-instrumentation
// works by monkey-patching those modules at require/import time; importing
// this after them would silently instrument nothing.
//
// Entirely opt-in: only starts if OTEL_EXPORTER_OTLP_ENDPOINT (or the
// traces-specific OTEL_EXPORTER_OTLP_TRACES_ENDPOINT) is set - the same
// standard env vars any OTel SDK reads, not an app-specific flag, so this
// composes with however the rest of your cluster already configures
// OTel exporters (e.g. pointing at a Tempo/OTel Collector endpoint).
import { createRequire, register } from "node:module";
import { NodeSDK } from "@opentelemetry/sdk-node";
import { getNodeAutoInstrumentations } from "@opentelemetry/auto-instrumentations-node";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION, ATTR_DEPLOYMENT_ENVIRONMENT_NAME } from "@opentelemetry/semantic-conventions";

const require = createRequire(import.meta.url);
const packageVersion: string = require("../package.json").version;

const endpoint = process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT ?? process.env.OTEL_EXPORTER_OTLP_ENDPOINT;

if (endpoint) {
  // This project is "type": "module" - auto-instrumentation's own
  // require() hook alone (installed by `instrumentations` below) only
  // catches actual `require()` calls, not this app's own ESM `import`
  // statements (fastify, pino, undici all get `import`ed, not
  // `require`d, from server.ts/logger.ts/registry-client.ts). Verified by
  // running this locally with OTEL_LOG_LEVEL=debug: the require hook logs
  // "Applying instrumentation patch... module: 'pino'", but trace.id/
  // span.id never actually appeared on a request's log lines until this
  // registration was added. `register()` installs @opentelemetry/
  // instrumentation's companion ESM loader hook (import-in-the-middle),
  // which is what actually lets getNodeAutoInstrumentations() patch
  // modules loaded via `import` - must happen before fastify/pino/undici
  // are ever imported, i.e. before the later `await import("./server.js")`
  // in index.ts.
  register("@opentelemetry/instrumentation/hook.mjs", import.meta.url);

  const sdk = new NodeSDK({
    resource: resourceFromAttributes({
      [ATTR_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME ?? "devcontainer-builder",
      [ATTR_SERVICE_VERSION]: packageVersion,
      // Read directly from the env var, not config.ts's ServiceConfig -
      // this module runs (and must finish starting instrumentation)
      // before config.ts's loadServiceConfig ever runs, so it can't import
      // serviceConfig without forcing that load earlier than intended.
      // logger.ts's ServiceConfig.environment reads the identical env var
      // independently, the same accepted duplication config.ts's own
      // sentryDsn-vs-OTel comment already documents.
      [ATTR_DEPLOYMENT_ENVIRONMENT_NAME]: process.env.DEPLOYMENT_ENVIRONMENT ?? "development",
    }),
    traceExporter: new OTLPTraceExporter(),
    instrumentations: [
      // getNodeAutoInstrumentations() already bundles and enables
      // @opentelemetry/instrumentation-pino by default, which already
      // injects trace/span context into every Pino log line emitted during
      // an active span - just under its own default snake_case keys
      // (trace_id/span_id). Overriding logKeys here is the entire
      // trace/log correlation mechanism this app needs: no mixin, no extra
      // dependency, just renaming the injected keys to match the
      // dot-notation naming (trace.id/span.id) the rest of this app's
      // structured-logging fields use (http.route, error.type, ...).
      getNodeAutoInstrumentations({
        "@opentelemetry/instrumentation-pino": {
          logKeys: { traceId: "trace.id", spanId: "span.id", traceFlags: "trace.flags" },
        },
      }),
    ],
  });

  sdk.start();

  process.on("SIGTERM", () => {
    void sdk.shutdown();
  });
}
