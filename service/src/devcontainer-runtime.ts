// Translates the merged Dev Container configuration (plus the build-time
// config label's runArgs) into what a Kubernetes pod can actually express -
// the `runtime` block of GET /devcontainer, see ADR-0012. Docker-only
// concepts with no pod equivalent (bind mounts, --network, --device, ...)
// are dropped with a warning, never silently.

import { hasReferences, shellWord } from "./devcontainer-variables.js";

export interface PortSpec {
  port: number;
  label?: string;
  protocol?: string;
  onAutoForward?: string;
}

export interface MountSpec {
  kind: "volume" | "tmpfs";
  source?: string;
  target: string;
  readOnly: boolean;
}

export interface HostAlias {
  ip: string;
  hostnames: string[];
}

export interface Runtime {
  remoteUser: string;
  containerUser: string | null;
  ports: PortSpec[];
  mounts: MountSpec[];
  capAdd: string[];
  privileged: boolean;
  init: boolean;
  seccompUnconfined: boolean;
  shmSizeBytes: number | null;
  hostname: string | null;
  hostAliases: HostAlias[];
  resources: { cpus: number | null; memoryBytes: number | null; storageBytes: number | null; gpu: unknown };
}

type Config = Record<string, unknown>;

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Docker-style sizes: "1g", "512m", "64MiB", "1073741824".
export function parseByteSize(value: string): number | null {
  const match = /^(\d+(?:\.\d+)?)\s*([kmgt]?)(i?b)?$/i.exec(value.trim());
  if (!match) return null;
  const units: Record<string, number> = { "": 1, k: 2 ** 10, m: 2 ** 20, g: 2 ** 30, t: 2 ** 40 };
  return Math.round(parseFloat(match[1]) * units[match[2].toLowerCase()]);
}

// `type=volume,source=x,target=/y,readonly` (the --mount / devcontainer.json
// string form) or the object form.
function parseMount(mount: unknown, origin: string, warnings: string[]): MountSpec | undefined {
  let fields: Record<string, string>;
  if (typeof mount === "string") {
    fields = {};
    for (const part of mount.split(",")) {
      const [key, ...rest] = part.split("=");
      const k = { src: "source", destination: "target", dst: "target", ro: "readonly" }[key] ?? key;
      fields[k] = rest.length ? rest.join("=") : "true";
    }
  } else if (isPlainObject(mount)) {
    fields = Object.fromEntries(Object.entries(mount).map(([k, v]) => [k, String(v)]));
  } else {
    warnings.push(`${origin}: unsupported mount ${JSON.stringify(mount)} - dropped`);
    return undefined;
  }

  const type = fields.type ?? "volume";
  const readOnly = fields.readonly === "true" || fields.readonly === "1";
  if (!fields.target) {
    warnings.push(`${origin}: mount without a target - dropped`);
    return undefined;
  }
  if (type === "volume") return { kind: "volume", source: fields.source, target: fields.target, readOnly };
  if (type === "tmpfs") return { kind: "tmpfs", target: fields.target, readOnly };
  warnings.push(`${origin}: ${type} mount of ${fields.source ?? "?"} at ${fields.target} has no host to mount from in a pod - dropped`);
  return undefined;
}

// `-v source:target[:ro]` - a named volume when source isn't a path.
function parseVolumeFlag(value: string, warnings: string[]): MountSpec | undefined {
  const [source, target, options] = value.split(":");
  if (!target) {
    return { kind: "volume", source: undefined, target: source, readOnly: false };
  }
  if (source.startsWith("/") || source.startsWith(".") || source.startsWith("~") || source.startsWith("$")) {
    warnings.push(`runArgs: bind mount -v ${value} has no host to mount from in a pod - dropped`);
    return undefined;
  }
  return { kind: "volume", source, target, readOnly: (options ?? "").split(",").includes("ro") };
}

export interface ParsedRunArgs {
  capAdd: string[];
  privileged: boolean;
  init: boolean;
  securityOpt: string[];
  shmSizeBytes: number | null;
  env: [string, string][];
  cpus: number | null;
  memoryBytes: number | null;
  hostname: string | null;
  hostAliases: HostAlias[];
  mounts: MountSpec[];
}

// The supported subset of `docker run` flags; everything else is a warning.
// Accepts `--flag=value` and `--flag value`.
export function parseRunArgs(runArgs: unknown, warnings: string[]): ParsedRunArgs {
  const parsed: ParsedRunArgs = {
    capAdd: [],
    privileged: false,
    init: false,
    securityOpt: [],
    shmSizeBytes: null,
    env: [],
    cpus: null,
    memoryBytes: null,
    hostname: null,
    hostAliases: [],
    mounts: [],
  };
  if (!Array.isArray(runArgs)) return parsed;
  const args = runArgs.filter((a): a is string => typeof a === "string");

  const withValue = new Set([
    "--cap-add", "--security-opt", "--shm-size", "-e", "--env", "--cpus", "-m", "--memory",
    "--hostname", "-h", "--add-host", "--mount", "-v", "--volume", "--tmpfs",
  ]);
  for (let i = 0; i < args.length; i++) {
    let flag = args[i];
    let value: string | undefined;
    const eq = flag.indexOf("=");
    if (flag.startsWith("--") && eq !== -1) {
      value = flag.slice(eq + 1);
      flag = flag.slice(0, eq);
    } else if (withValue.has(flag)) {
      value = args[++i];
    }

    switch (flag) {
      case "--cap-add":
        if (value) parsed.capAdd.push(value.toUpperCase().replace(/^CAP_/, ""));
        break;
      case "--privileged":
        parsed.privileged = value === undefined || value === "true";
        break;
      case "--init":
        parsed.init = value === undefined || value === "true";
        break;
      case "--security-opt":
        if (value) parsed.securityOpt.push(value);
        break;
      case "--shm-size": {
        const size = value ? parseByteSize(value) : null;
        if (size === null) warnings.push(`runArgs: unparseable --shm-size ${value}`);
        else parsed.shmSizeBytes = size;
        break;
      }
      case "-e":
      case "--env":
        if (value) {
          const sep = value.indexOf("=");
          if (sep > 0) parsed.env.push([value.slice(0, sep), value.slice(sep + 1)]);
          else warnings.push(`runArgs: ${flag} ${value} passes a host variable through - there is no host; ignored`);
        }
        break;
      case "--cpus": {
        const cpus = value ? parseFloat(value) : NaN;
        if (Number.isFinite(cpus)) parsed.cpus = cpus;
        else warnings.push(`runArgs: unparseable --cpus ${value}`);
        break;
      }
      case "-m":
      case "--memory": {
        const size = value ? parseByteSize(value) : null;
        if (size === null) warnings.push(`runArgs: unparseable --memory ${value}`);
        else parsed.memoryBytes = size;
        break;
      }
      case "-h":
      case "--hostname":
        if (value) parsed.hostname = value;
        break;
      case "--add-host": {
        // docker: host:ip (ip may itself contain ':' for IPv6)
        const sep = value ? value.search(/[:=]/) : -1;
        if (value && sep > 0) parsed.hostAliases.push({ ip: value.slice(sep + 1), hostnames: [value.slice(0, sep)] });
        else warnings.push(`runArgs: unparseable --add-host ${value}`);
        break;
      }
      case "--mount": {
        const mount = value ? parseMount(value, "runArgs --mount", warnings) : undefined;
        if (mount) parsed.mounts.push(mount);
        break;
      }
      case "-v":
      case "--volume": {
        const mount = value ? parseVolumeFlag(value, warnings) : undefined;
        if (mount) parsed.mounts.push(mount);
        break;
      }
      case "--tmpfs":
        if (value) parsed.mounts.push({ kind: "tmpfs", target: value.split(":")[0], readOnly: false });
        break;
      default:
        warnings.push(`runArgs: ${args[i]}${value !== undefined && !args[i].includes("=") ? ` ${value}` : ""} has no Kubernetes equivalent - ignored`);
    }
  }
  return parsed;
}

function portsFrom(configuration: Config, warnings: string[]): PortSpec[] {
  const forwardPorts = Array.isArray(configuration.forwardPorts) ? configuration.forwardPorts : [];
  const attributes = isPlainObject(configuration.portsAttributes) ? configuration.portsAttributes : {};
  const ports: PortSpec[] = [];
  for (const entry of forwardPorts) {
    if (typeof entry !== "number") {
      warnings.push(`forwardPorts "${entry}" points at another container (e.g. a Docker Compose service) - dropped`);
      continue;
    }
    const attr = isPlainObject(attributes[String(entry)]) ? (attributes[String(entry)] as Record<string, unknown>) : {};
    ports.push({
      port: entry,
      ...(typeof attr.label === "string" ? { label: attr.label } : {}),
      ...(typeof attr.protocol === "string" ? { protocol: attr.protocol } : {}),
      ...(typeof attr.onAutoForward === "string" ? { onAutoForward: attr.onAutoForward } : {}),
    });
  }
  return ports;
}

// The user tools and hooks run as: remoteUser, else containerUser, else the
// image's own USER (name part of "user[:group]"), else root - the CLI's
// own fallback order.
export function resolveRemoteUser(configuration: Config, imageUser: string | undefined, warnings: string[]): string {
  const fromImage = imageUser ? imageUser.split(":")[0] : undefined;
  const user =
    (typeof configuration.remoteUser === "string" && configuration.remoteUser) ||
    (typeof configuration.containerUser === "string" && configuration.containerUser) ||
    fromImage ||
    "root";
  if (/^\d+$/.test(user)) {
    warnings.push(`remote user is the numeric uid ${user} - the workspace needs a user name to find its home directory`);
  }
  return user;
}

export function buildRuntime(configuration: Config, runArgs: ParsedRunArgs, imageUser: string | undefined, warnings: string[]): Runtime {
  const mounts: MountSpec[] = [];
  const configMounts = Array.isArray(configuration.mounts) ? configuration.mounts : [];
  for (const mount of configMounts) {
    const parsed = parseMount(mount, "mounts", warnings);
    if (parsed) mounts.push(parsed);
  }
  mounts.push(...runArgs.mounts);

  const securityOpt = [...(Array.isArray(configuration.securityOpt) ? configuration.securityOpt : []), ...runArgs.securityOpt].filter(
    (o): o is string => typeof o === "string",
  );
  let seccompUnconfined = false;
  for (const opt of securityOpt) {
    if (/^seccomp[=:]unconfined$/.test(opt)) seccompUnconfined = true;
    else warnings.push(`securityOpt ${opt} has no Kubernetes equivalent here - ignored`);
  }

  const hostRequirements = isPlainObject(configuration.hostRequirements) ? configuration.hostRequirements : {};
  const number = (v: unknown) => (typeof v === "number" ? v : typeof v === "string" && /^\d+$/.test(v) ? parseInt(v, 10) : null);

  for (const field of ["hostname"] as const) {
    if (runArgs[field] && hasReferences(runArgs[field]!)) {
      warnings.push(`runArgs --${field} uses a variable - the template must substitute workspace placeholders itself`);
    }
  }

  const capAdd = [...new Set([...(Array.isArray(configuration.capAdd) ? configuration.capAdd : []), ...runArgs.capAdd])].filter(
    (c): c is string => typeof c === "string",
  );

  return {
    remoteUser: resolveRemoteUser(configuration, imageUser, warnings),
    containerUser: (typeof configuration.containerUser === "string" && configuration.containerUser) || (imageUser ? imageUser.split(":")[0] : null),
    ports: portsFrom(configuration, warnings),
    mounts,
    capAdd,
    privileged: configuration.privileged === true || runArgs.privileged,
    init: configuration.init === true || runArgs.init,
    seccompUnconfined,
    shmSizeBytes: runArgs.shmSizeBytes,
    hostname: runArgs.hostname,
    hostAliases: runArgs.hostAliases,
    resources: {
      cpus: runArgs.cpus ?? number(hostRequirements.cpus),
      memoryBytes: runArgs.memoryBytes ?? number(hostRequirements.memory),
      storageBytes: number(hostRequirements.storage),
      gpu: hostRequirements.gpu ?? null,
    },
  };
}

// `export K="..."` lines, values rewritten so variable references expand
// against the environment at the time the script is sourced - containerEnv
// first (runArgs -e, then the merged containerEnv), then remoteEnv, the
// order the CLI resolves them in.
export function renderEnvScript(pairs: [string, unknown][], warnings: string[], origin: string): string | null {
  const lines: string[] = [];
  for (const [key, value] of pairs) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      warnings.push(`${origin} ${key} is not a valid environment variable name - skipped`);
      continue;
    }
    if (value === null || value === undefined) continue;
    lines.push(`export ${key}=${shellWord(String(value))}`);
  }
  return lines.length ? `${lines.join("\n")}\n` : null;
}
