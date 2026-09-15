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
import { NodeSDK } from "@opentelemetry/sdk-node";
import { getNodeAutoInstrumentations } from "@opentelemetry/auto-instrumentations-node";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { ATTR_SERVICE_NAME } from "@opentelemetry/semantic-conventions";

const endpoint = process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT ?? process.env.OTEL_EXPORTER_OTLP_ENDPOINT;

if (endpoint) {
  const sdk = new NodeSDK({
    resource: resourceFromAttributes({
      [ATTR_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME ?? "devcontainer-builder",
    }),
    traceExporter: new OTLPTraceExporter(),
    instrumentations: [getNodeAutoInstrumentations()],
  });

  sdk.start();

  process.on("SIGTERM", () => {
    void sdk.shutdown();
  });
}
