// Fast tests for the fallback image setting (ADR-0013): its precedence
// and the config it stands in for.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadServiceConfig } from "./config.js";
import { fallbackConfig } from "./build.js";

function withEnv<T>(env: Record<string, string | undefined>, fn: () => T): T {
  const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
  Object.assign(process.env, env);
  for (const [k, v] of Object.entries(env)) if (v === undefined) delete process.env[k];
  try {
    return fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
}

test("fallbackImage is unset by default, so a repo without config still fails", () => {
  withEnv({ FALLBACK_IMAGE: undefined, SERVICE_CONFIG_PATH: undefined }, () => {
    assert.equal(loadServiceConfig([]).fallbackImage, undefined);
  });
});

test("fallbackImage: flag > env > settings file; empty means unset", () => {
  const dir = mkdtempSync(join(tmpdir(), "dcb-config-"));
  const settings = join(dir, "settings.json");
  writeFileSync(settings, JSON.stringify({ build: { fallbackImage: "from-settings" } }));
  withEnv({ FALLBACK_IMAGE: undefined, SERVICE_CONFIG_PATH: settings }, () => {
    assert.equal(loadServiceConfig([]).fallbackImage, "from-settings");
    withEnv({ FALLBACK_IMAGE: "from-env" }, () => {
      assert.equal(loadServiceConfig([]).fallbackImage, "from-env");
      assert.equal(loadServiceConfig(["--fallback-image", "from-flag"]).fallbackImage, "from-flag");
    });
    withEnv({ FALLBACK_IMAGE: "" }, () => assert.equal(loadServiceConfig([]).fallbackImage, undefined));
  });
  writeFileSync(settings, JSON.stringify({ build: { fallbackImage: 1 } }));
  withEnv({ FALLBACK_IMAGE: undefined, SERVICE_CONFIG_PATH: settings }, () => {
    assert.throws(() => loadServiceConfig([]), /build\.fallbackImage" must be a string/);
  });
});

test("the fallback config is just the image", () => {
  assert.deepEqual(JSON.parse(fallbackConfig("mcr.microsoft.com/devcontainers/base:ubuntu")), {
    image: "mcr.microsoft.com/devcontainers/base:ubuntu",
  });
});
