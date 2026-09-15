import { readFileSync } from "node:fs";
import { extname } from "node:path";
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
  service?: { port?: number };
  sshHostKeyPolicy?: string;
  gitCredentials?: { entries?: unknown[] };
  registryMapping?: { rules?: unknown[] };
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
    },
    strict: true,
  });
  return values;
}

export interface ServiceConfig {
  buildkitEndpoint?: string;
  port: number;
  buildxBuilderName: string;
  gitCredentials: GitCredentialEntry[];
  registryMappingRules: RegistryMappingRule[];
  sshHostKeyPolicy: SshHostKeyPolicy;
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
    gitCredentials: gitCredentialsPath
      ? loadArrayConfigFile(gitCredentialsPath, isGitCredentialEntry, "git credentials")
      : validateEntries(settings.gitCredentials?.entries ?? [], isGitCredentialEntry, "git credentials"),
    registryMappingRules: registryMappingPath
      ? loadArrayConfigFile(registryMappingPath, isRegistryMappingRule, "registry mapping")
      : validateEntries(settings.registryMapping?.rules ?? [], isRegistryMappingRule, "registry mapping"),
    sshHostKeyPolicy: loadSshHostKeyPolicy(cli["ssh-host-key-policy"] ?? process.env.SSH_HOST_KEY_POLICY ?? settings.sshHostKeyPolicy),
  };
}
