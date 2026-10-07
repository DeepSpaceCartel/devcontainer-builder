// loadServiceConfig's file-based sources: the unified settings file (every
// field, and its per-field type checks), the dedicated git-credentials and
// registry-mapping files, and the ambient Docker config /config reports.
// The cluster suite (service_settings_file.feature,
// service_startup_configuration.feature) proves the same through a real
// crash-looping pod; this proves each rule in milliseconds.
import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadServiceConfig } from "./config.js";

// Every env var loadServiceConfig reads, cleared so the host's own
// environment can't leak into these tests.
const CONFIG_ENV = [
  "SERVICE_CONFIG_PATH",
  "BUILDKIT_ENDPOINT",
  "PORT",
  "BUILDX_BUILDER_NAME",
  "BUILD_PLATFORMS",
  "BUILD_NO_CACHE",
  "BUILD_CACHE_FROM",
  "BUILD_CACHE_TO",
  "BUILDKIT_MODE",
  "FALLBACK_IMAGE",
  "INSECURE_REGISTRIES",
  "GIT_CREDENTIALS_CONFIG_PATH",
  "REGISTRY_MAPPING_CONFIG_PATH",
  "SSH_HOST_KEY_POLICY",
  "SENTRY_DSN",
  "SERVICE_NAME",
  "DEPLOYMENT_ENVIRONMENT",
  "COMMAND_LOG_RETENTION",
  "ALLOW_INSECURE_GIT_PROTOCOLS",
  "CLONE_TIMEOUT_SECONDS",
  "BUILD_TIMEOUT_SECONDS",
  "MAX_CONCURRENT_BUILDS",
];

function withEnv<T>(env: Record<string, string | undefined>, fn: () => T): T {
  const all = { ...Object.fromEntries(CONFIG_ENV.map((k) => [k, undefined])), DOCKER_CONFIG: emptyDir(), ...env };
  const saved = Object.fromEntries(Object.keys(all).map((k) => [k, process.env[k]]));
  for (const [k, v] of Object.entries(all))
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  try {
    return fn();
  } finally {
    for (const [k, v] of Object.entries(saved))
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
  }
}

function emptyDir(): string {
  return mkdtempSync(join(tmpdir(), "dcb-config-files-"));
}

function file(name: string, content: unknown): string {
  const path = join(emptyDir(), name);
  writeFileSync(path, typeof content === "string" ? content : JSON.stringify(content));
  return path;
}

// Skipped-entry warnings go to console.error; keep them out of the report
// and make them assertable.
function captureConsoleError<T>(fn: () => T): { result: T; messages: string[] } {
  const spy = mock.method(console, "error", () => {});
  try {
    const result = fn();
    return { result, messages: spy.mock.calls.map((c) => String(c.arguments[0])) };
  } finally {
    spy.mock.restore();
  }
}

test("defaults with no configuration at all", () => {
  withEnv({}, () => {
    const config = loadServiceConfig([]);
    assert.equal(config.buildkitEndpoint, undefined);
    assert.equal(config.port, 8080);
    assert.equal(config.buildxBuilderName, "devcontainer-builder-remote");
    assert.equal(config.sshHostKeyPolicy, "tofu");
    assert.deepEqual(config.defaultPlatforms, []);
    assert.deepEqual(config.defaultBuildOptions, { noCache: false, cacheFrom: undefined, cacheTo: undefined, mode: "auto" });
    assert.deepEqual(config.gitCredentials, []);
    assert.deepEqual(config.registryMappingRules, []);
    assert.deepEqual(config.insecureRegistries, []);
    assert.deepEqual(config.registryAuthRegistries, []);
    assert.equal(config.serviceName, "devcontainer-builder");
    assert.equal(config.environment, "development");
    assert.equal(config.commandLogRetention, 10);
  });
});

test("a YAML settings file sets every field it mirrors from values.yaml", () => {
  const settings = file(
    "settings.yml",
    [
      "buildkit: { endpoint: tcp://buildkitd:1234 }",
      "build:",
      "  platforms: [linux/amd64, linux/arm64]",
      "  noCache: true",
      "  cacheFrom: type=registry,ref=ghcr.io/org/cache",
      "  cacheTo: type=inline",
      "  mode: never",
      "service: { port: 9090 }",
      "sshHostKeyPolicy: pinned",
      "insecureRegistries: [registry.local:5000]",
      "gitCredentials:",
      "  entries:",
      "    - { host: github.com, kind: https, username: bot, token: t }",
      "    - { host: git.example, kind: ssh, privateKey: k, pinnedHostKey: 'git.example ssh-ed25519 AAAA' }",
      "registryMapping:",
      "  rules: [{ hostMatch: github.com, pathPrefix: org/, registry: ghcr.io/org }]",
      "sentry: { dsn: https://key@sentry.example/1 }",
      "observability: { serviceName: dcb, environment: staging }",
      "logs: { retention: 3 }",
      "image: { repository: ignored }",
    ].join("\n"),
  );
  withEnv({ SERVICE_CONFIG_PATH: settings }, () => {
    const config = loadServiceConfig([]);
    assert.equal(config.buildkitEndpoint, "tcp://buildkitd:1234");
    assert.deepEqual(config.defaultPlatforms, ["linux/amd64", "linux/arm64"]);
    assert.deepEqual(config.defaultBuildOptions, {
      noCache: true,
      cacheFrom: "type=registry,ref=ghcr.io/org/cache",
      cacheTo: "type=inline",
      mode: "never",
    });
    assert.equal(config.port, 9090);
    assert.equal(config.sshHostKeyPolicy, "pinned");
    assert.deepEqual(config.insecureRegistries, ["registry.local:5000"]);
    assert.equal(config.gitCredentials.length, 2);
    assert.deepEqual(config.registryMappingRules, [{ hostMatch: "github.com", pathPrefix: "org/", registry: "ghcr.io/org" }]);
    assert.equal(config.sentryDsn, "https://key@sentry.example/1");
    assert.equal(config.serviceName, "dcb");
    assert.equal(config.environment, "staging");
    assert.equal(config.commandLogRetention, 3);
  });
});

test("env vars and flags override the settings file", () => {
  const settings = file("settings.json", { buildkit: { endpoint: "from-file" }, build: { platforms: ["linux/amd64"], noCache: false } });
  withEnv(
    {
      SERVICE_CONFIG_PATH: settings,
      BUILDKIT_ENDPOINT: "from-env",
      BUILD_PLATFORMS: " linux/arm64 , ,linux/amd64",
      BUILD_NO_CACHE: "true",
    },
    () => {
      const fromEnv = loadServiceConfig([]);
      assert.equal(fromEnv.buildkitEndpoint, "from-env");
      assert.deepEqual(fromEnv.defaultPlatforms, ["linux/arm64", "linux/amd64"]);
      assert.equal(fromEnv.defaultBuildOptions.noCache, true);
      const fromFlags = loadServiceConfig([
        "--buildkit-endpoint",
        "from-flag",
        "--insecure-registries",
        "a:1,b:2",
        "--port",
        "1234",
        "--ssh-host-key-policy",
        "pinned",
      ]);
      assert.equal(fromFlags.buildkitEndpoint, "from-flag");
      assert.deepEqual(fromFlags.insecureRegistries, ["a:1", "b:2"]);
      assert.equal(fromFlags.port, 1234);
      assert.equal(fromFlags.sshHostKeyPolicy, "pinned");
    },
  );
  // --settings itself beats SERVICE_CONFIG_PATH.
  const other = file("other.json", { buildkit: { endpoint: "from-flag-file" } });
  withEnv({ SERVICE_CONFIG_PATH: settings }, () =>
    assert.equal(loadServiceConfig(["--settings", other]).buildkitEndpoint, "from-flag-file"),
  );
});

test("each settings-file field is type-checked with a message naming it", () => {
  const cases: Array<[unknown, RegExp]> = [
    [[], /must be a JSON\/YAML object/],
    [{ buildkit: "x" }, /"buildkit" must be an object/],
    [{ buildkit: { endpoint: 1 } }, /"buildkit\.endpoint" must be a string/],
    [{ build: [] }, /"build" must be an object/],
    [{ build: { platforms: "linux/amd64" } }, /"build\.platforms" must be an array of strings/],
    [{ build: { noCache: "yes" } }, /"build\.noCache" must be a boolean/],
    [{ build: { cacheFrom: 1 } }, /"build\.cacheFrom" must be a string/],
    [{ build: { cacheTo: 1 } }, /"build\.cacheTo" must be a string/],
    [{ build: { mode: "sometimes" } }, /"build\.mode" must be "auto" or "never"/],
    [{ build: { timeoutSeconds: "60" } }, /"build\.timeoutSeconds" must be a number/],
    [{ build: { timeoutSeconds: 1.5 } }, /build\.timeoutSeconds must be a positive integer/],
    [{ git: 1 }, /"git" must be an object/],
    [{ service: 1 }, /"service" must be an object/],
    [{ service: { port: "80" } }, /"service\.port" must be a number/],
    [{ sshHostKeyPolicy: 1 }, /"sshHostKeyPolicy" must be a string/],
    [{ sshHostKeyPolicy: "strict" }, /SSH_HOST_KEY_POLICY must be "tofu" or "pinned"/],
    [{ insecureRegistries: [1] }, /"insecureRegistries" must be an array of strings/],
    [{ gitCredentials: [] }, /"gitCredentials" must be an object/],
    [{ gitCredentials: { entries: {} } }, /"gitCredentials\.entries" must be an array/],
    [{ registryMapping: 1 }, /"registryMapping" must be an object/],
    [{ registryMapping: { rules: "x" } }, /"registryMapping\.rules" must be an array/],
    [{ sentry: 1 }, /"sentry" must be an object/],
    [{ sentry: { dsn: 1 } }, /"sentry\.dsn" must be a string/],
    [{ observability: 1 }, /"observability" must be an object/],
    [{ observability: { serviceName: 1 } }, /"observability\.serviceName" must be a string/],
    [{ observability: { environment: 1 } }, /"observability\.environment" must be a string/],
    [{ logs: 1 }, /"logs" must be an object/],
    [{ logs: { retention: "5" } }, /"logs\.retention" must be a number/],
    [{ logs: { retention: 0 } }, /logs\.retention must be a positive integer/],
  ];
  for (const [content, expected] of cases) {
    withEnv({ SERVICE_CONFIG_PATH: file("settings.json", content) }, () => {
      assert.throws(() => loadServiceConfig([]), expected, JSON.stringify(content));
    });
  }
});

test("unreadable, unparsable or wrongly named settings files fail at startup", () => {
  withEnv({ SERVICE_CONFIG_PATH: join(emptyDir(), "missing.json") }, () => {
    assert.throws(() => loadServiceConfig([]), /failed to read settings config at .*missing\.json/);
  });
  withEnv({ SERVICE_CONFIG_PATH: file("settings.json", "{oops") }, () => {
    assert.throws(() => loadServiceConfig([]), /failed to parse settings config/);
  });
  withEnv({ SERVICE_CONFIG_PATH: file("settings.toml", "a = 1") }, () => {
    assert.throws(() => loadServiceConfig([]), /must end in \.json, \.yaml, or \.yml/);
  });
});

test("invalid env values and unknown flags fail at startup", () => {
  withEnv({ BUILDKIT_MODE: "sometimes" }, () => assert.throws(() => loadServiceConfig([]), /buildkit mode must be "auto" or "never"/));
  withEnv({ BUILD_NO_CACHE: "1" }, () => assert.throws(() => loadServiceConfig([]), /BUILD_NO_CACHE must be "true" or "false"/));
  withEnv({ COMMAND_LOG_RETENTION: "lots" }, () =>
    assert.throws(() => loadServiceConfig([]), /COMMAND_LOG_RETENTION must be a positive integer/),
  );
  withEnv({}, () => assert.throws(() => loadServiceConfig(["--no-such-flag"]), /Unknown option '--no-such-flag'/));
});

test("dedicated git-credentials and registry-mapping files: invalid entries are skipped, not fatal", () => {
  const credentials = file(
    "creds.yaml",
    [
      "- { host: github.com, kind: https, username: bot, token: t }",
      "- { host: '', kind: https, username: u, token: t }",
      "- { host: git.example, kind: ssh, privateKey: '' }",
      "- { host: git.example, kind: ssh, privateKey: k, pinnedHostKey: 1 }",
      "- { host: git.example, kind: ftp }",
      "- not-an-object",
      "- { host: gitlab.com, kind: ssh, privateKey: k }",
    ].join("\n"),
  );
  const mapping = file("rules.json", [
    { registry: "ghcr.io/org" },
    { registry: "" },
    { registry: "x", hostMatch: 1 },
    { registry: "x", pathPrefix: 1 },
    null,
  ]);
  withEnv({ GIT_CREDENTIALS_CONFIG_PATH: credentials, REGISTRY_MAPPING_CONFIG_PATH: mapping }, () => {
    const { result, messages } = captureConsoleError(() => loadServiceConfig([]));
    assert.deepEqual(
      result.gitCredentials.map((c) => c.host),
      ["github.com", "gitlab.com"],
    );
    assert.deepEqual(result.registryMappingRules, [{ registry: "ghcr.io/org" }]);
    assert.equal(messages.filter((m) => m.startsWith("skipping invalid git credentials")).length, 5);
    assert.equal(messages.filter((m) => m.startsWith("skipping invalid registry mapping")).length, 4);
  });
  // The dedicated file wins over the settings file's entries.
  const settings = file("settings.json", {
    gitCredentials: { entries: [{ host: "settings.example", kind: "https", username: "u", token: "t" }] },
  });
  withEnv({ SERVICE_CONFIG_PATH: settings }, () => {
    assert.deepEqual(
      loadServiceConfig([]).gitCredentials.map((c) => c.host),
      ["settings.example"],
    );
    const flagFile = file("creds.json", [{ host: "flag.example", kind: "https", username: "u", token: "t" }]);
    assert.deepEqual(
      loadServiceConfig(["--git-credentials-config-path", flagFile]).gitCredentials.map((c) => c.host),
      ["flag.example"],
    );
  });
  withEnv({ REGISTRY_MAPPING_CONFIG_PATH: file("rules.json", { registry: "x" }) }, () => {
    assert.throws(() => loadServiceConfig([]), /registry mapping config at .* must be a JSON array/);
  });
});

test("registryAuthRegistries lists the ambient Docker config's hosts, and nothing when it's unusable", () => {
  const dir = emptyDir();
  writeFileSync(join(dir, "config.json"), JSON.stringify({ auths: { "ghcr.io": { auth: "eDp5" }, "registry.local:5000": {} } }));
  withEnv({ DOCKER_CONFIG: dir }, () => assert.deepEqual(loadServiceConfig([]).registryAuthRegistries, ["ghcr.io", "registry.local:5000"]));
  const broken = emptyDir();
  writeFileSync(join(broken, "config.json"), "{nope");
  withEnv({ DOCKER_CONFIG: broken }, () => assert.deepEqual(loadServiceConfig([]).registryAuthRegistries, []));
});
