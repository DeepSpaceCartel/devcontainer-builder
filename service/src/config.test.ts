// Fast tests for the fallback image setting (ADR-0013): its precedence
// and the config it stands in for.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadServiceConfig } from "./config.js";
import { fallbackConfig } from "./build.js";
import { tracingServiceName } from "./tracing.js";

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

const HARDENING_ENV = {
  ALLOW_INSECURE_GIT_PROTOCOLS: undefined,
  CLONE_TIMEOUT_SECONDS: undefined,
  BUILD_TIMEOUT_SECONDS: undefined,
  MAX_CONCURRENT_BUILDS: undefined,
  SERVICE_CONFIG_PATH: undefined,
};

test("hardening settings default to safe values", () => {
  withEnv(HARDENING_ENV, () => {
    const config = loadServiceConfig([]);
    assert.equal(config.allowInsecureGitProtocols, false);
    assert.equal(config.cloneTimeoutSeconds, 600);
    assert.equal(config.buildTimeoutSeconds, 3600);
    assert.equal(config.maxConcurrentBuilds, 4);
  });
});

test("hardening settings: flag > env > settings file", () => {
  const dir = mkdtempSync(join(tmpdir(), "dcb-config-"));
  const settings = join(dir, "settings.yaml");
  writeFileSync(settings, "git:\n  allowInsecureProtocols: true\nbuild:\n  cloneTimeoutSeconds: 60\n  timeoutSeconds: 120\n  maxConcurrent: 0\n");
  withEnv({ ...HARDENING_ENV, SERVICE_CONFIG_PATH: settings }, () => {
    const fromFile = loadServiceConfig([]);
    assert.equal(fromFile.allowInsecureGitProtocols, true);
    assert.equal(fromFile.cloneTimeoutSeconds, 60);
    assert.equal(fromFile.buildTimeoutSeconds, 120);
    assert.equal(fromFile.maxConcurrentBuilds, 0);
    withEnv({ ALLOW_INSECURE_GIT_PROTOCOLS: "false", CLONE_TIMEOUT_SECONDS: "30", BUILD_TIMEOUT_SECONDS: "90", MAX_CONCURRENT_BUILDS: "2" }, () => {
      const fromEnv = loadServiceConfig([]);
      assert.equal(fromEnv.allowInsecureGitProtocols, false);
      assert.equal(fromEnv.cloneTimeoutSeconds, 30);
      assert.equal(fromEnv.buildTimeoutSeconds, 90);
      assert.equal(fromEnv.maxConcurrentBuilds, 2);
      const fromFlags = loadServiceConfig([
        "--allow-insecure-git-protocols",
        "--clone-timeout",
        "5",
        "--build-timeout",
        "6",
        "--max-concurrent-builds",
        "7",
      ]);
      assert.equal(fromFlags.allowInsecureGitProtocols, true);
      assert.equal(fromFlags.cloneTimeoutSeconds, 5);
      assert.equal(fromFlags.buildTimeoutSeconds, 6);
      assert.equal(fromFlags.maxConcurrentBuilds, 7);
    });
  });
});

test("invalid hardening settings fail at startup", () => {
  withEnv({ ...HARDENING_ENV, CLONE_TIMEOUT_SECONDS: "0" }, () => {
    assert.throws(() => loadServiceConfig([]), /CLONE_TIMEOUT_SECONDS must be a positive integer/);
  });
  withEnv({ ...HARDENING_ENV, MAX_CONCURRENT_BUILDS: "-1" }, () => {
    assert.throws(() => loadServiceConfig([]), /MAX_CONCURRENT_BUILDS must be a non-negative integer/);
  });
  withEnv({ ...HARDENING_ENV, ALLOW_INSECURE_GIT_PROTOCOLS: "yes" }, () => {
    assert.throws(() => loadServiceConfig([]), /ALLOW_INSECURE_GIT_PROTOCOLS must be "true" or "false"/);
  });
  const dir = mkdtempSync(join(tmpdir(), "dcb-config-"));
  const settings = join(dir, "settings.json");
  writeFileSync(settings, JSON.stringify({ git: { allowInsecureProtocols: "true" } }));
  withEnv({ ...HARDENING_ENV, SERVICE_CONFIG_PATH: settings }, () => {
    assert.throws(() => loadServiceConfig([]), /git\.allowInsecureProtocols" must be a boolean/);
  });
});

test("traces default to the logs' SERVICE_NAME unless OTEL_SERVICE_NAME is set", () => {
  assert.equal(tracingServiceName({}), "devcontainer-builder");
  assert.equal(tracingServiceName({ SERVICE_NAME: "dcb" }), "dcb");
  assert.equal(tracingServiceName({ SERVICE_NAME: "dcb", OTEL_SERVICE_NAME: "otel-dcb" }), "otel-dcb");
});
