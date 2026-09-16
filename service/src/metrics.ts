import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

// One private registry (not the global default) so this module's own
// import doesn't silently register metrics into whatever else might import
// prom-client - GET /metrics below is the only thing that reads it.
export const registry = new Registry();
collectDefaultMetrics({ register: registry });

export const buildsTotal = new Counter({
  name: "devcontainer_builder_builds_total",
  help: "Total POST /build requests, by outcome.",
  labelNames: ["status"] as const,
  registers: [registry],
});

export const buildDurationSeconds = new Histogram({
  name: "devcontainer_builder_build_duration_seconds",
  help: "POST /build request duration in seconds, by outcome.",
  labelNames: ["status"] as const,
  // A real build is a clone + image build + push, not a cheap request -
  // buckets skew toward minutes, not the sub-second defaults prom-client
  // would otherwise use.
  buckets: [1, 5, 15, 30, 60, 120, 300, 600, 1200],
  registers: [registry],
});

export const imageChecksTotal = new Counter({
  name: "devcontainer_builder_image_checks_total",
  help: "Total GET /image requests, by outcome (exists/absent/error).",
  labelNames: ["result"] as const,
  registers: [registry],
});

export const imageDeletesTotal = new Counter({
  name: "devcontainer_builder_image_deletes_total",
  help: "Total DELETE /image requests, by outcome.",
  labelNames: ["result"] as const,
  registers: [registry],
});
