import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { extname, join } from "node:path";
import { parseArgs } from "node:util";
import { parse as parseYaml } from "yaml";

export type GitCredentialEntry =
  | { host: string; kind: "https"; username: string; token: string }
  | { host: string; kind: "ssh"; privateKey: string; pinnedHostKey?: string };

export interface RegistryMappingRule {
  hostMatch?: string;
  pathPrefix?: string;
  registry: string;
}

export type SshHostKeyPolicy = "tofu" | "pinned";

function isGitCredentialEntry(value: unknown): value is GitCredentialEntry {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  if (typeof v.host !== "string" || v.host.length === 0) return false;

  if (v.kind === "https") {
    return typeof v.username === "string" && typeof v.token === "string";
  }
  if (v.kind === "ssh") {
    if (typeof v.privateKey !== "string" || v.privateKey.length === 0) return false;
    return v.pinnedHostKey === undefined || typeof v.pinnedHostKey === "string";
  }
  return false;
}

function isRegistryMappingRule(value: unknown): value is RegistryMappingRule {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  if (typeof v.registry !== "string" || v.registry.length === 0) return false;
  if (v.hostMatch !== undefined && typeof v.hostMatch !== "string") return false;
  if (v.pathPrefix !== undefined && typeof v.pathPrefix !== "string") return false;
  return true;
}

// Reads a file as JSON or YAML, picked by extension rather than sniffed -
// valid JSON is valid YAML (YAML 1.2 spec), so `parseYaml` alone could
// handle both, but a wrong/typo'd extension should fail with a clear
// message naming the accepted extensions rather than being silently
// accepted or misparsed.
function readStructuredFile(path: string, label: string): unknown {
  const ext = extname(path);

  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (err) {
    throw new Error(`failed to read ${label} config at ${path}: ${err instanceof Error ? err.message : err}`);
  }

  try {
    if (ext === ".json") return JSON.parse(raw);
    if (ext === ".yaml" || ext === ".yml") return parseYaml(raw);
    throw new Error(`must end in .json, .yaml, or .yml`);
  } catch (err) {
    throw new Error(`failed to parse ${label} config at ${path}: ${err instanceof Error ? err.message : err}`);
  }
}

// One bad *entry* inside an otherwise-valid array is logged and skipped
// rather than taking down the whole service, mirroring how a single bad
// BuildRequest field doesn't crash the process either. Shared by both the
// dedicated array-file loader and the unified settings file below, since
// both end up with "an array of entries that need this same validation."
function validateEntries<T>(items: unknown[], isValidEntry: (value: unknown) => value is T, label: string): T[] {
  const entries: T[] = [];
  for (const [index, item] of items.entries()) {
    if (isValidEntry(item)) {
      entries.push(item);
    } else {
      console.error(`skipping invalid ${label} config entry at index ${index}`);
    }
  }
  return entries;
}

// Reads an operator-authored JSON/YAML array from disk (Helm-mounted
// Secret or ConfigMap). A missing/unset path is a supported "feature not
// configured" state -> empty list. An unreadable/malformed *file* fails
// fast (crash at startup, same as a bad BUILDKIT_ENDPOINT would surface
// immediately) since this is deployment-time misconfiguration, not
// per-request input.
function loadArrayConfigFile<T>(
  path: string | undefined,
  isValidEntry: (value: unknown) => value is T,
  label: string,
): T[] {
  if (!path) return [];

  const parsed = readStructuredFile(path, label);
  if (!Array.isArray(parsed)) {
    throw new Error(`${label} config at ${path} must be a JSON array`);
  }
  return validateEntries(parsed, isValidEntry, label);
}

function loadSshHostKeyPolicy(raw: string | undefined): SshHostKeyPolicy {
  if (raw === "pinned") return "pinned";
  if (raw !== undefined && raw !== "tofu") {
    throw new Error(`SSH_HOST_KEY_POLICY must be "tofu" or "pinned", got ${JSON.stringify(raw)}`);
  }
  return "tofu";
}

// The settings file's shape deliberately mirrors
// charts/devcontainer-builder/values.yaml's own keys and nesting
// (buildkit.endpoint, service.port, gitCredentials.entries,
// registryMapping.rules, top-level sshHostKeyPolicy) rather than a flat,
// invented shape - an operator who knows the chart's values.yaml
// recognizes this file immediately, and a future chart change could
// render a subset of values.yaml straight into it. values.yaml's other
// sections (image, resources, registryAuth, ...) have no runtime-config
// meaning here and are simply ignored if present.
interface RawSettingsFile {
  buildkit?: { endpoint?: string };
  build?: {
    platforms?: string[];
    noCache?: boolean;
    cacheFrom?: string;
    cacheTo?: string;
    mode?: string;
    fallbackImage?: string;
    cloneTimeoutSeconds?: number;
    timeoutSeconds?: number;
    maxConcurrent?: number;
  };
  git?: { allowInsecureProtocols?: boolean };
  service?: { port?: number };
  sshHostKeyPolicy?: string;
  insecureRegistries?: string[];
  gitCredentials?: { entries?: unknown[] };
  registryMapping?: { rules?: unknown[] };
  sentry?: { dsn?: string };
  observability?: { serviceName?: string; environment?: string };
  logs?: { retention?: number };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function loadSettingsFile(path: string | undefined): RawSettingsFile {
  if (!path) return {};

  const parsed = readStructuredFile(path, "settings");
  if (!isPlainObject(parsed)) {
    throw new Error(`settings file at ${path} must be a JSON/YAML object`);
  }

  const settings: RawSettingsFile = {};

  if (parsed.buildkit !== undefined) {
    if (!isPlainObject(parsed.buildkit)) throw new Error(`settings file field "buildkit" must be an object`);
    if (parsed.buildkit.endpoint !== undefined) {
      if (typeof parsed.buildkit.endpoint !== "string") {
        throw new Error(`settings file field "buildkit.endpoint" must be a string`);
      }
      settings.buildkit = { endpoint: parsed.buildkit.endpoint };
    }
  }

  if (parsed.build !== undefined) {
    if (!isPlainObject(parsed.build)) throw new Error(`settings file field "build" must be an object`);
    const build: RawSettingsFile["build"] = {};
    if (parsed.build.platforms !== undefined) {
      if (!Array.isArray(parsed.build.platforms) || !parsed.build.platforms.every((p) => typeof p === "string")) {
        throw new Error(`settings file field "build.platforms" must be an array of strings`);
      }
      build.platforms = parsed.build.platforms as string[];
    }
    if (parsed.build.noCache !== undefined) {
      if (typeof parsed.build.noCache !== "boolean") {
        throw new Error(`settings file field "build.noCache" must be a boolean`);
      }
      build.noCache = parsed.build.noCache;
    }
    if (parsed.build.cacheFrom !== undefined) {
      if (typeof parsed.build.cacheFrom !== "string") {
        throw new Error(`settings file field "build.cacheFrom" must be a string`);
      }
      build.cacheFrom = parsed.build.cacheFrom;
    }
    if (parsed.build.cacheTo !== undefined) {
      if (typeof parsed.build.cacheTo !== "string") {
        throw new Error(`settings file field "build.cacheTo" must be a string`);
      }
      build.cacheTo = parsed.build.cacheTo;
    }
    if (parsed.build.mode !== undefined) {
      if (parsed.build.mode !== "auto" && parsed.build.mode !== "never") {
        throw new Error(`settings file field "build.mode" must be "auto" or "never"`);
      }
      build.mode = parsed.build.mode;
    }
    if (parsed.build.fallbackImage !== undefined) {
      if (typeof parsed.build.fallbackImage !== "string") {
        throw new Error(`settings file field "build.fallbackImage" must be a string`);
      }
      build.fallbackImage = parsed.build.fallbackImage;
    }
    for (const key of ["cloneTimeoutSeconds", "timeoutSeconds", "maxConcurrent"] as const) {
      if (parsed.build[key] !== undefined) {
        if (typeof parsed.build[key] !== "number") {
          throw new Error(`settings file field "build.${key}" must be a number`);
        }
        build[key] = parsed.build[key];
      }
    }
    settings.build = build;
  }

  if (parsed.git !== undefined) {
    if (!isPlainObject(parsed.git)) throw new Error(`settings file field "git" must be an object`);
    if (parsed.git.allowInsecureProtocols !== undefined) {
      if (typeof parsed.git.allowInsecureProtocols !== "boolean") {
        throw new Error(`settings file field "git.allowInsecureProtocols" must be a boolean`);
      }
      settings.git = { allowInsecureProtocols: parsed.git.allowInsecureProtocols };
    }
  }

  if (parsed.service !== undefined) {
    if (!isPlainObject(parsed.service)) throw new Error(`settings file field "service" must be an object`);
    if (parsed.service.port !== undefined) {
      if (typeof parsed.service.port !== "number") {
        throw new Error(`settings file field "service.port" must be a number`);
      }
      settings.service = { port: parsed.service.port };
    }
  }

  if (parsed.sshHostKeyPolicy !== undefined) {
    if (typeof parsed.sshHostKeyPolicy !== "string") {
      throw new Error(`settings file field "sshHostKeyPolicy" must be a string`);
    }
    settings.sshHostKeyPolicy = parsed.sshHostKeyPolicy;
  }

  if (parsed.insecureRegistries !== undefined) {
    if (!Array.isArray(parsed.insecureRegistries) || !parsed.insecureRegistries.every((r) => typeof r === "string")) {
      throw new Error(`settings file field "insecureRegistries" must be an array of strings`);
    }
    settings.insecureRegistries = parsed.insecureRegistries as string[];
  }

  if (parsed.gitCredentials !== undefined) {
    if (!isPlainObject(parsed.gitCredentials)) throw new Error(`settings file field "gitCredentials" must be an object`);
    if (parsed.gitCredentials.entries !== undefined) {
      if (!Array.isArray(parsed.gitCredentials.entries)) {
        throw new Error(`settings file field "gitCredentials.entries" must be an array`);
      }
      settings.gitCredentials = { entries: parsed.gitCredentials.entries };
    }
  }

  if (parsed.registryMapping !== undefined) {
    if (!isPlainObject(parsed.registryMapping)) throw new Error(`settings file field "registryMapping" must be an object`);
    if (parsed.registryMapping.rules !== undefined) {
      if (!Array.isArray(parsed.registryMapping.rules)) {
        throw new Error(`settings file field "registryMapping.rules" must be an array`);
      }
      settings.registryMapping = { rules: parsed.registryMapping.rules };
    }
  }

  if (parsed.sentry !== undefined) {
    if (!isPlainObject(parsed.sentry)) throw new Error(`settings file field "sentry" must be an object`);
    if (parsed.sentry.dsn !== undefined) {
      if (typeof parsed.sentry.dsn !== "string") {
        throw new Error(`settings file field "sentry.dsn" must be a string`);
      }
      settings.sentry = { dsn: parsed.sentry.dsn };
    }
  }

  if (parsed.observability !== undefined) {
    if (!isPlainObject(parsed.observability)) throw new Error(`settings file field "observability" must be an object`);
    const observability: RawSettingsFile["observability"] = {};
    if (parsed.observability.serviceName !== undefined) {
      if (typeof parsed.observability.serviceName !== "string") {
        throw new Error(`settings file field "observability.serviceName" must be a string`);
      }
      observability.serviceName = parsed.observability.serviceName;
    }
    if (parsed.observability.environment !== undefined) {
      if (typeof parsed.observability.environment !== "string") {
        throw new Error(`settings file field "observability.environment" must be a string`);
      }
      observability.environment = parsed.observability.environment;
    }
    settings.observability = observability;
  }

  if (parsed.logs !== undefined) {
    if (!isPlainObject(parsed.logs)) throw new Error(`settings file field "logs" must be an object`);
    if (parsed.logs.retention !== undefined) {
      if (typeof parsed.logs.retention !== "number") {
        throw new Error(`settings file field "logs.retention" must be a number`);
      }
      settings.logs = { retention: parsed.logs.retention };
    }
  }

  return settings;
}

// CLI flags are the most explicit, closest-to-invocation config source,
// so they take precedence over both env vars and the settings file (see
// loadServiceConfig below). `strict: true` throws clearly on a typo'd
// flag, consistent with every other startup misconfiguration in this
// file failing loudly rather than being silently ignored. Structured
// list data (gitCredentials/registryMappingRules) has no flag of its
// own, same limitation as env vars - only a *path* to a file can be
// given.
function loadCliOptions(argv: string[]) {
  const { values } = parseArgs({
    args: argv,
    options: {
      settings: { type: "string" },
      "buildkit-endpoint": { type: "string" },
      port: { type: "string" },
      "buildx-builder-name": { type: "string" },
      "ssh-host-key-policy": { type: "string" },
      "git-credentials-config-path": { type: "string" },
      "registry-mapping-config-path": { type: "string" },
      "build-platforms": { type: "string" },
      "insecure-registries": { type: "string" },
      "build-no-cache": { type: "boolean" },
      "build-cache-from": { type: "string" },
      "build-cache-to": { type: "string" },
      "buildkit-mode": { type: "string" },
      "fallback-image": { type: "string" },
      "sentry-dsn": { type: "string" },
      "service-name": { type: "string" },
      environment: { type: "string" },
      "command-log-retention": { type: "string" },
      "allow-insecure-git-protocols": { type: "boolean" },
      "clone-timeout": { type: "string" },
      "build-timeout": { type: "string" },
      "max-concurrent-builds": { type: "string" },
    },
    strict: true,
  });
  return values;
}

function parsePositiveInteger(name: string, raw: string | number | undefined): number | undefined {
  if (raw === undefined) return undefined;
  const value = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer, got ${JSON.stringify(raw)}`);
  }
  return value;
}

// Like parsePositiveInteger, but 0 is allowed (meaning "no limit").
function parseNonNegativeInteger(name: string, raw: string | number | undefined): number | undefined {
  if (raw === undefined) return undefined;
  const value = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`${name} must be a non-negative integer, got ${JSON.stringify(raw)}`);
  }
  return value;
}

export interface DefaultBuildOptions {
  noCache: boolean;
  cacheFrom?: string;
  cacheTo?: string;
  mode: "auto" | "never";
}

export interface ServiceConfig {
  buildkitEndpoint?: string;
  port: number;
  buildxBuilderName: string;
  gitCredentials: GitCredentialEntry[];
  registryMappingRules: RegistryMappingRule[];
  sshHostKeyPolicy: SshHostKeyPolicy;
  defaultPlatforms: string[];
  defaultBuildOptions: DefaultBuildOptions;
  // Registry hosts (exactly as given in a request's `registry`, minus any
  // path) this service's own registry HTTP calls (GET/DELETE /image, GET
  // /devcontainer - not the build itself, which BuildKit's own config
  // governs) reach over plain http:// instead of https://. Explicit opt-in
  // only, never an automatic https->http fallback, so credentials can't be
  // downgraded to cleartext by a network failure.
  insecureRegistries: string[];
  // The image a repository without any devcontainer.json is built from,
  // as if it had `{"image": fallbackImage}` (ADR-0013). Unset: such a
  // build fails, as the Dev Containers CLI does.
  fallbackImage?: string;
  // Sentry/GlitchTip DSN - error tracking is entirely opt-in, off unless
  // set. OpenTelemetry tracing is deliberately not a field here - it's
  // bootstrapped from the standard OTEL_EXPORTER_OTLP_ENDPOINT env var
  // before this config even loads (see tracing.ts), the same way any
  // OTel-instrumented app is configured, not through an app-specific flag.
  sentryDsn?: string;
  // "service.name"/"deployment.environment.name" on every structured log
  // line (logger.ts). serviceVersion has no field here - it's always this
  // build's own package.json version, never a value an operator would
  // choose to override. environment is also read directly from
  // DEPLOYMENT_ENVIRONMENT by tracing.ts (which runs before this config
  // loads) - an accepted, explicit duplication of one env var across two
  // independent read sites, the same shape as the sentryDsn/OTel split
  // above.
  serviceName: string;
  environment: string;
  // How many captured command-output log files (see command-log.ts) to
  // keep per kind ("git"/"docker") before the oldest are pruned - two
  // independent buckets, not a combined cap.
  commandLogRetention: number;
  // Registries this instance has ambient push credentials for, from the
  // mounted Docker config (see loadRegistryAuthRegistries) - hostnames
  // only, never read for any other purpose than reporting via GET /config.
  registryAuthRegistries: string[];
  // Accept git:// and http:// repository URLs (unauthenticated,
  // unencrypted). Off by default - meant for test git servers.
  allowInsecureGitProtocols: boolean;
  // Per-phase wall-clock limits; the phase's child processes are killed
  // when one is exceeded. cloneTimeoutSeconds covers the clone,
  // buildTimeoutSeconds the whole build+push (builder setup included).
  cloneTimeoutSeconds: number;
  buildTimeoutSeconds: number;
  // Builds running at once before POST /build answers 429. 0 = no limit.
  maxConcurrentBuilds: number;
}

function parseCommaList(raw: string | undefined): string[] | undefined {
  if (raw === undefined) return undefined;
  return raw
    .split(",")
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
}

function parseBooleanEnv(name: string, raw: string | undefined): boolean | undefined {
  if (raw === undefined) return undefined;
  if (raw === "true") return true;
  if (raw === "false") return false;
  throw new Error(`${name} must be "true" or "false", got ${JSON.stringify(raw)}`);
}

// Reads the same file the Docker/buildx CLI subprocess itself reads for
// push credentials - this service never parsed it before, so /config had
// no way to report whether ambient registryAuth (as opposed to a per-request
// registryCredentials) actually loaded, short of shelling into the pod to
// decode the Secret directly. Resolved the same way the real Docker CLI
// does ($DOCKER_CONFIG/config.json, else $HOME/.docker/config.json).
// Missing or unparsable -> no registries, not a startup error: ambient
// registry auth is entirely optional. Read once at startup like every
// other ServiceConfig field - accurate to reality, since the chart mounts
// this via subPath, which Kubernetes doesn't live-update on Secret change
// anyway.
function loadRegistryAuthRegistries(): string[] {
  const dir = process.env.DOCKER_CONFIG ?? join(homedir(), ".docker");
  let raw: string;
  try {
    raw = readFileSync(join(dir, "config.json"), "utf8");
  } catch {
    return [];
  }
  try {
    const parsed = JSON.parse(raw) as { auths?: Record<string, unknown> };
    return Object.keys(parsed.auths ?? {});
  } catch {
    return [];
  }
}

function loadBuildkitMode(raw: string | undefined): "auto" | "never" {
  if (raw === undefined) return "auto";
  if (raw === "auto" || raw === "never") return raw;
  throw new Error(`buildkit mode must be "auto" or "never", got ${JSON.stringify(raw)}`);
}

// Precedence at every field: CLI flag > env var > settings file > default.
// An unset settings file (the common case) makes every field resolve
// exactly as before this feature existed - purely additive.
export function loadServiceConfig(argv: string[] = process.argv.slice(2)): ServiceConfig {
  const cli = loadCliOptions(argv);
  const settings = loadSettingsFile(cli.settings ?? process.env.SERVICE_CONFIG_PATH);

  const gitCredentialsPath = cli["git-credentials-config-path"] ?? process.env.GIT_CREDENTIALS_CONFIG_PATH;
  const registryMappingPath = cli["registry-mapping-config-path"] ?? process.env.REGISTRY_MAPPING_CONFIG_PATH;

  return {
    buildkitEndpoint: cli["buildkit-endpoint"] ?? process.env.BUILDKIT_ENDPOINT ?? settings.buildkit?.endpoint,
    port: Number(cli.port ?? process.env.PORT ?? settings.service?.port ?? 8080),
    buildxBuilderName: cli["buildx-builder-name"] ?? process.env.BUILDX_BUILDER_NAME ?? "devcontainer-builder-remote",
    defaultPlatforms:
      parseCommaList(cli["build-platforms"]) ?? parseCommaList(process.env.BUILD_PLATFORMS) ?? settings.build?.platforms ?? [],
    defaultBuildOptions: {
      noCache:
        cli["build-no-cache"] ?? parseBooleanEnv("BUILD_NO_CACHE", process.env.BUILD_NO_CACHE) ?? settings.build?.noCache ?? false,
      cacheFrom: cli["build-cache-from"] ?? process.env.BUILD_CACHE_FROM ?? settings.build?.cacheFrom,
      cacheTo: cli["build-cache-to"] ?? process.env.BUILD_CACHE_TO ?? settings.build?.cacheTo,
      mode: loadBuildkitMode(cli["buildkit-mode"] ?? process.env.BUILDKIT_MODE ?? settings.build?.mode),
    },
    fallbackImage: (cli["fallback-image"] ?? process.env.FALLBACK_IMAGE ?? settings.build?.fallbackImage) || undefined,
    insecureRegistries:
      parseCommaList(cli["insecure-registries"]) ??
      parseCommaList(process.env.INSECURE_REGISTRIES) ??
      settings.insecureRegistries ??
      [],
    gitCredentials: gitCredentialsPath
      ? loadArrayConfigFile(gitCredentialsPath, isGitCredentialEntry, "git credentials")
      : validateEntries(settings.gitCredentials?.entries ?? [], isGitCredentialEntry, "git credentials"),
    registryMappingRules: registryMappingPath
      ? loadArrayConfigFile(registryMappingPath, isRegistryMappingRule, "registry mapping")
      : validateEntries(settings.registryMapping?.rules ?? [], isRegistryMappingRule, "registry mapping"),
    sshHostKeyPolicy: loadSshHostKeyPolicy(cli["ssh-host-key-policy"] ?? process.env.SSH_HOST_KEY_POLICY ?? settings.sshHostKeyPolicy),
    sentryDsn: cli["sentry-dsn"] ?? process.env.SENTRY_DSN ?? settings.sentry?.dsn,
    serviceName: cli["service-name"] ?? process.env.SERVICE_NAME ?? settings.observability?.serviceName ?? "devcontainer-builder",
    environment: cli.environment ?? process.env.DEPLOYMENT_ENVIRONMENT ?? settings.observability?.environment ?? "development",
    commandLogRetention:
      parsePositiveInteger("COMMAND_LOG_RETENTION", cli["command-log-retention"] ?? process.env.COMMAND_LOG_RETENTION) ??
      parsePositiveInteger("logs.retention", settings.logs?.retention) ??
      10,
    registryAuthRegistries: loadRegistryAuthRegistries(),
    allowInsecureGitProtocols:
      cli["allow-insecure-git-protocols"] ??
      parseBooleanEnv("ALLOW_INSECURE_GIT_PROTOCOLS", process.env.ALLOW_INSECURE_GIT_PROTOCOLS) ??
      settings.git?.allowInsecureProtocols ??
      false,
    cloneTimeoutSeconds:
      parsePositiveInteger("CLONE_TIMEOUT_SECONDS", cli["clone-timeout"] ?? process.env.CLONE_TIMEOUT_SECONDS) ??
      parsePositiveInteger("build.cloneTimeoutSeconds", settings.build?.cloneTimeoutSeconds) ??
      600,
    buildTimeoutSeconds:
      parsePositiveInteger("BUILD_TIMEOUT_SECONDS", cli["build-timeout"] ?? process.env.BUILD_TIMEOUT_SECONDS) ??
      parsePositiveInteger("build.timeoutSeconds", settings.build?.timeoutSeconds) ??
      3600,
    maxConcurrentBuilds:
      parseNonNegativeInteger("MAX_CONCURRENT_BUILDS", cli["max-concurrent-builds"] ?? process.env.MAX_CONCURRENT_BUILDS) ??
      parseNonNegativeInteger("build.maxConcurrent", settings.build?.maxConcurrent) ??
      4,
  };
}

// Single shared instance - config.ts has no dependency of its own, so
// every other module (build.ts, logger.ts, server.ts, index.ts) can import
// this without risking a load-order cycle (this used to live in build.ts,
// which broke the moment logger.ts needed to import both `serviceConfig`
// and, separately, build.ts needed to import logger.ts's `logger`).
export const serviceConfig = loadServiceConfig();
