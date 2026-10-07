// Reads the `devcontainer.metadata` image label that `devcontainer build`
// writes (a JSON array: base-image entries, then one per Feature in install
// order, then devcontainer.json's own entry last) and merges it the way
// @devcontainers/cli itself does. `mergeConfiguration` below is a direct
// port of the CLI's own `mergeConfiguration` (src/spec-node/imageMetadata.ts,
// checked against the 0.89.0 bundle) so `configuration` in GET
// /devcontainer has exactly the CLI's `mergedConfiguration` shape - see
// ADR-0011. `vscode` and `lifecycleScripts` are this service's own
// additions on top, for callers (a Coder template) that can't easily merge
// editor customizations or run the CLI's command semantics themselves.

export const METADATA_LABEL = "devcontainer.metadata";

export const LIFECYCLE_HOOKS = [
  "onCreateCommand",
  "updateContentCommand",
  "postCreateCommand",
  "postStartCommand",
  "postAttachCommand",
] as const;
export type LifecycleHook = (typeof LIFECYCLE_HOOKS)[number];

type Entry = Record<string, unknown>;
// A lifecycle command as devcontainer.json allows it: a shell string, an
// argv array, or an object of named string/array commands run in parallel.
type LifecycleCommand = string | string[] | Record<string, string | string[]>;

export class InvalidMetadataLabelError extends Error {}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Same acceptance rule as the CLI: a JSON array, or a single object (which
// the spec allows "to make adoption easier for other tools").
export function parseMetadataLabel(raw: string): { entries: Entry[]; raw: Entry[] } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new InvalidMetadataLabelError(`${METADATA_LABEL} label is not valid JSON: ${err instanceof Error ? err.message : err}`);
  }
  const rawEntries = Array.isArray(parsed) ? parsed.filter(isPlainObject) : isPlainObject(parsed) ? [parsed] : undefined;
  if (rawEntries) return { entries: rawEntries.map(migrateLegacyVscodeProperties), raw: rawEntries };
  throw new InvalidMetadataLabelError(`${METADATA_LABEL} label must be a JSON array or object`);
}

// The CLI's own legacy migration: top-level `extensions`/`settings` (pre
// `customizations`) move into `customizations.vscode`.
function migrateLegacyVscodeProperties(entry: Entry): Entry {
  if (entry.extensions === undefined && entry.settings === undefined) return entry;
  const migrated: Entry = { ...entry };
  const customizations: Record<string, unknown> = isPlainObject(migrated.customizations) ? { ...migrated.customizations } : {};
  const vscode: Record<string, unknown> = isPlainObject(customizations.vscode) ? { ...customizations.vscode } : {};
  if (Array.isArray(migrated.extensions)) {
    vscode.extensions = [...(Array.isArray(vscode.extensions) ? vscode.extensions : []), ...migrated.extensions];
  }
  if (isPlainObject(migrated.settings)) {
    vscode.settings = { ...migrated.settings, ...(isPlainObject(vscode.settings) ? vscode.settings : {}) };
  }
  delete migrated.extensions;
  delete migrated.settings;
  customizations.vscode = vscode;
  migrated.customizations = customizations;
  return migrated;
}

function lastSet(entries: Entry[], key: string): unknown {
  for (let i = entries.length - 1; i >= 0; i--) {
    if (entries[i][key]) return entries[i][key];
  }
  return undefined;
}

function lastBoolean(entries: Entry[], key: string): boolean | undefined {
  for (let i = entries.length - 1; i >= 0; i--) {
    const value = entries[i][key];
    if (typeof value === "boolean") return value;
  }
  return undefined;
}

function unionOrUndefined(entries: Entry[], key: string): unknown[] | undefined {
  const all = new Set<unknown>();
  for (const entry of entries) {
    const value = entry[key];
    if (Array.isArray(value)) value.forEach((v) => all.add(v));
    else if (value) all.add(value);
  }
  return all.size ? [...all] : undefined;
}

function collect(entries: Entry[], key: string): unknown[] {
  return entries.map((e) => e[key]).filter((v) => !!v);
}

function assignAll(entries: Entry[], key: string): Record<string, unknown> {
  return Object.assign({}, ...entries.map((e) => (isPlainObject(e[key]) ? e[key] : {})));
}

const MOUNT_KEY_ALIASES: Record<string, string> = { src: "source", destination: "target", dst: "target" };

function mountTarget(mount: unknown): unknown {
  if (typeof mount === "string") {
    const fields: Record<string, string> = {};
    for (const part of mount.split(",")) {
      const [key, value] = part.split("=");
      fields[MOUNT_KEY_ALIASES[key] ?? key] = value;
    }
    return fields.target;
  }
  return isPlainObject(mount) ? mount.target : undefined;
}

// Later mounts win per target, keeping the original order of survivors.
function mergeMounts(entries: Entry[]): unknown[] | undefined {
  const all = entries.flatMap((e) => (Array.isArray(e.mounts) ? e.mounts : []));
  const seen = new Set<unknown>();
  const kept = all
    .slice()
    .reverse()
    .filter((m) => {
      const target = mountTarget(m);
      if (seen.has(target)) return false;
      seen.add(target);
      return true;
    })
    .reverse();
  return kept.length ? kept : undefined;
}

function mergeForwardPorts(entries: Entry[]): unknown[] | undefined {
  const normalized = entries
    .flatMap((e) => (Array.isArray(e.forwardPorts) ? e.forwardPorts : []))
    .map((p) => (typeof p === "number" ? `localhost:${p}` : p));
  const ports = [...new Set(normalized)].map((p) => (typeof p === "string" && /localhost:\d+/.test(p) ? parseInt(p.substring(10), 10) : p));
  return ports.length ? ports : undefined;
}

function parseSize(value: unknown): number {
  const match = typeof value === "string" ? /^(\d+)([tgmk]b)?$/.exec(value) : null;
  if (!match) return 0;
  const units: Record<string, number> = { t: 2 ** 40, g: 2 ** 30, m: 2 ** 20, k: 2 ** 10 };
  return parseInt(match[1], 10) * ((match[2] && units[match[2][0]]) || 1);
}

function mergeGpu(a: unknown, b: unknown): unknown {
  if (a === undefined || a === false) return b;
  if (b === undefined || b === false) return a;
  if (a === "optional" && b === "optional") return "optional";
  const left = isPlainObject(a) ? a : {};
  const right = isPlainObject(b) ? b : {};
  const cores = Math.max(Number(left.cores) || 0, Number(right.cores) || 0);
  const memory = Math.max(parseSize(left.memory ?? "0"), parseSize(right.memory ?? "0"));
  return { cores: cores || undefined, memory: memory ? `${memory}` : undefined };
}

function mergeHostRequirements(entries: Entry[]): Record<string, unknown> | undefined {
  const reqs = entries.map((e) => (isPlainObject(e.hostRequirements) ? e.hostRequirements : {}));
  const cpus = Math.max(0, ...reqs.map((r) => Number(r.cpus) || 0));
  const memory = Math.max(0, ...reqs.map((r) => parseSize(r.memory ?? "0")));
  const storage = Math.max(0, ...reqs.map((r) => parseSize(r.storage ?? "0")));
  const gpu = reqs.map((r) => r.gpu).reduce(mergeGpu, undefined);
  if (!cpus && !memory && !storage && !gpu) return undefined;
  return { cpus, memory: memory ? `${memory}` : undefined, storage: storage ? `${storage}` : undefined, gpu };
}

// Port of the CLI's mergeConfiguration(config, imageMetadata), with no
// separate devcontainer.json `config` - the label's own last entry already
// is devcontainer.json's contribution. Fields the CLI leaves `undefined`
// stay absent from the JSON response, same as the CLI's own output.
export function mergeConfiguration(entries: Entry[]): Record<string, unknown> {
  const customizations: Record<string, unknown[]> = {};
  for (const entry of entries) {
    if (!isPlainObject(entry.customizations)) continue;
    for (const [tool, value] of Object.entries(entry.customizations)) {
      (customizations[tool] ??= []).push(value);
    }
  }

  return {
    init: entries.some((e) => !!e.init),
    privileged: entries.some((e) => !!e.privileged),
    capAdd: unionOrUndefined(entries, "capAdd"),
    securityOpt: unionOrUndefined(entries, "securityOpt"),
    entrypoints: (() => {
      const all = collect(entries, "entrypoint");
      return all.length ? all : undefined;
    })(),
    mounts: mergeMounts(entries),
    customizations: Object.keys(customizations).length ? customizations : undefined,
    onCreateCommands: collect(entries, "onCreateCommand"),
    updateContentCommands: collect(entries, "updateContentCommand"),
    postCreateCommands: collect(entries, "postCreateCommand"),
    postStartCommands: collect(entries, "postStartCommand"),
    postAttachCommands: collect(entries, "postAttachCommand"),
    waitFor: lastSet(entries, "waitFor"),
    remoteUser: lastSet(entries, "remoteUser"),
    containerUser: lastSet(entries, "containerUser"),
    userEnvProbe: lastSet(entries, "userEnvProbe"),
    remoteEnv: assignAll(entries, "remoteEnv"),
    containerEnv: assignAll(entries, "containerEnv"),
    overrideCommand: lastBoolean(entries, "overrideCommand"),
    portsAttributes: assignAll(entries, "portsAttributes"),
    otherPortsAttributes: lastSet(entries, "otherPortsAttributes"),
    forwardPorts: mergeForwardPorts(entries),
    shutdownAction: lastSet(entries, "shutdownAction"),
    updateRemoteUserUID: lastBoolean(entries, "updateRemoteUserUID"),
    hostRequirements: mergeHostRequirements(entries),
  };
}

// The CLI leaves merging `customizations.vscode` to the tool; this follows
// VS Code's own Dev Containers behavior. Extensions: union in entry order,
// matched case-insensitively (first spelling kept), `-publisher.name`
// removes one added by an earlier entry. Settings: per key, last entry wins.
export function mergeVscode(entries: Entry[]): { extensions: string[]; settings: Record<string, unknown> } {
  const extensions: string[] = [];
  const settings: Record<string, unknown> = {};

  for (const entry of entries) {
    const vscode = isPlainObject(entry.customizations) ? entry.customizations.vscode : undefined;
    if (!isPlainObject(vscode)) continue;

    if (Array.isArray(vscode.extensions)) {
      for (const id of vscode.extensions) {
        if (typeof id !== "string" || !id) continue;
        if (id.startsWith("-")) {
          const removed = id.slice(1).toLowerCase();
          const index = extensions.findIndex((e) => e.toLowerCase() === removed);
          if (index !== -1) extensions.splice(index, 1);
        } else if (!extensions.some((e) => e.toLowerCase() === id.toLowerCase())) {
          extensions.push(id);
        }
      }
    }
    if (isPlainObject(vscode.settings)) Object.assign(settings, vscode.settings);
  }

  return { extensions, settings };
}

// POSIX single-quoting: the whole word in '...', each embedded ' as '\''.
export function shQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function isArgv(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((v) => typeof v === "string");
}

// One runnable shell line for a single string/array command, or undefined
// for an empty one (the CLI skips those too).
function commandLine(command: unknown): string | undefined {
  if (typeof command === "string") return command.trim() ? `/bin/sh -c ${shQuote(command)}` : undefined;
  if (isArgv(command)) return command.length ? command.map(shQuote).join(" ") : undefined;
  return undefined;
}

// Matches the devcontainer.json variables the CLI would substitute; this
// service runs nothing and has no workspace, so they're left as-is.
const VARIABLE_PATTERN =
  /\$\{(?:(?:localEnv|containerEnv):[^}]*|localWorkspaceFolder|containerWorkspaceFolder|localWorkspaceFolderBasename|containerWorkspaceFolderBasename|devcontainerId)\}/;

function commandStrings(command: unknown): string[] {
  if (typeof command === "string") return [command];
  if (isArgv(command)) return command;
  if (isPlainObject(command)) return Object.values(command).flatMap(commandStrings);
  return [];
}

// Renders every entry's command for one hook into a single POSIX sh
// script with the CLI's own semantics: entries run in label order, a
// string runs via `/bin/sh -c`, an array runs as argv with no shell, an
// object runs its named commands in parallel and fails if any failed, and
// the first failure stops the script with that command's exit code (the
// CLI's "Skipping any further user-provided commands"). Returns null when
// no entry sets the hook. cwd, user, and running the hooks themselves in
// order are the caller's job.
export function renderLifecycleScript(hook: LifecycleHook, entries: Entry[]): { script: string | null; warnings: string[] } {
  const warnings: string[] = [];
  const blocks: string[] = [];
  let parallelGroup = 0;

  for (const entry of entries) {
    const command = entry[hook] as LifecycleCommand | undefined;
    if (!command) continue;
    const origin = typeof entry.id === "string" ? entry.id : "devcontainer.json";
    const label = `${hook} from ${origin}`;
    // `dc_rc` must already hold the failing exit code - capture it before
    // anything else (even the echo) overwrites `$?`.
    const fail = `echo ${shQuote(`devcontainer: ${label} failed with exit code `)}"$dc_rc" >&2; exit "$dc_rc"`;

    if (commandStrings(command).some((c) => VARIABLE_PATTERN.test(c))) {
      warnings.push(`${label} uses a devcontainer.json variable (e.g. \${containerWorkspaceFolder}), which is not substituted`);
    }

    const single = commandLine(command);
    if (single) {
      blocks.push([`echo ${shQuote(`devcontainer: ${label}`)}`, `${single} || { dc_rc=$?; ${fail}; }`].join("\n"));
      continue;
    }

    if (isPlainObject(command)) {
      const named = Object.entries(command)
        .map(([name, value]) => ({ name, line: commandLine(value) }))
        .filter((c): c is { name: string; line: string } => !!c.line);
      if (!named.length) continue;

      parallelGroup++;
      const pid = (i: number) => `dc_pid_${parallelGroup}_${i}`;
      const lines = [`echo ${shQuote(`devcontainer: ${label} (parallel: ${named.map((c) => c.name).join(", ")})`)}`];
      named.forEach((c, i) => lines.push(`${c.line} & ${pid(i)}=$!`));
      lines.push("dc_rc=0");
      named.forEach((_, i) => lines.push(`wait "$${pid(i)}" || dc_rc=$?`));
      lines.push(`[ "$dc_rc" -eq 0 ] || { ${fail}; }`);
      blocks.push(lines.join("\n"));
      continue;
    }

    warnings.push(`${label} has an unsupported command shape and was skipped`);
  }

  if (!blocks.length) return { script: null, warnings };
  return { script: `#!/bin/sh\n${blocks.join("\n")}\n`, warnings };
}

export interface DevcontainerMetadata {
  configuration: Record<string, unknown>;
  lifecycleScripts: Record<LifecycleHook, string | null>;
  vscode: { extensions: string[]; settings: Record<string, unknown> };
  warnings: string[];
  metadata: Entry[];
}

export function buildDevcontainerMetadata(label: string): DevcontainerMetadata {
  const { entries, raw } = parseMetadataLabel(label);
  const warnings: string[] = [];
  const lifecycleScripts = {} as Record<LifecycleHook, string | null>;
  for (const hook of LIFECYCLE_HOOKS) {
    const rendered = renderLifecycleScript(hook, entries);
    lifecycleScripts[hook] = rendered.script;
    warnings.push(...rendered.warnings);
  }
  return {
    configuration: mergeConfiguration(entries),
    lifecycleScripts,
    vscode: mergeVscode(entries),
    warnings,
    metadata: raw,
  };
}
