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

import { parse as parseJsonc, type ParseError } from "jsonc-parser";
import { buildRuntime, parseRunArgs, renderEnvScript, type Runtime } from "./devcontainer-runtime.js";
import { detectVariables, hasReferences, rewriteForShellString, shellWord, type DetectedVariable } from "./devcontainer-variables.js";

export const METADATA_LABEL = "devcontainer.metadata";

// Written by POST /build (service >= 0.3.0) next to the CLI's own label:
// devcontainer.json properties the CLI never copies into the image because
// it re-reads them from the repo when *creating* a container - which a
// workspace planned from the image alone can't do. See ADR-0012.
export const CONFIG_LABEL = "com.deepspacecartel.devcontainer-builder.config";
const CONFIG_LABEL_PROPERTIES = ["workspaceFolder", "runArgs", "initializeCommand"] as const;

// The config label's value for a repo's devcontainer.json text (JSONC):
// just the properties above, raw - variables are rewritten on read, like
// everything else. undefined if the file doesn't parse as an object.
export function configLabelValue(devcontainerJson: string): string | undefined {
  const errors: ParseError[] = [];
  const parsed = parseJsonc(devcontainerJson, errors, { allowTrailingComma: true });
  if (errors.length || typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return undefined;
  const picked: Record<string, unknown> = {};
  for (const key of CONFIG_LABEL_PROPERTIES) {
    if (parsed[key] !== undefined) picked[key] = parsed[key];
  }
  return JSON.stringify(picked);
}

function parseConfigLabel(raw: string | undefined, warnings: string[]): Record<string, unknown> | undefined {
  if (raw === undefined) {
    warnings.push(
      `no ${CONFIG_LABEL} label (image built before devcontainer-builder 0.3.0) - workspaceFolder, runArgs and initializeCommand are unknown; rebuild the image to include them`,
    );
    return undefined;
  }
  try {
    const parsed = JSON.parse(raw);
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) return parsed;
  } catch {
    // fall through
  }
  warnings.push(`${CONFIG_LABEL} label is not a JSON object - ignored`);
  return undefined;
}

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
// for an empty one (the CLI skips those too). devcontainer.json variables
// become shell variable references, expanded when the script runs: inside
// the `sh -c` string for the string form, as double-quoted words (literal
// text escaped) for the argv form - which otherwise never sees a shell.
function commandLine(command: unknown): string | undefined {
  if (typeof command === "string") return command.trim() ? `/bin/sh -c ${shQuote(rewriteForShellString(command))}` : undefined;
  if (isArgv(command)) {
    return command.length ? command.map((arg) => (hasReferences(arg) ? shellWord(arg) : shQuote(arg))).join(" ") : undefined;
  }
  return undefined;
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

export type ScriptHook = LifecycleHook | "initializeCommand";

export interface DevcontainerMetadata {
  configuration: Record<string, unknown>;
  lifecycleScripts: Record<ScriptHook, string | null>;
  envScripts: { containerEnv: string | null; remoteEnv: string | null };
  runtime: Runtime;
  variables: DetectedVariable[];
  vscode: { extensions: string[]; settings: Record<string, unknown> };
  warnings: string[];
  metadata: Entry[];
}

// The default the Dev Containers CLI uses when devcontainer.json sets none.
const DEFAULT_WORKSPACE_FOLDER = "/workspaces/${localWorkspaceFolderBasename}";

export function buildDevcontainerMetadata(
  label: string,
  options: { configLabel?: string; imageUser?: string } = {},
): DevcontainerMetadata {
  const { entries, raw } = parseMetadataLabel(label);
  const warnings: string[] = [];
  const config = parseConfigLabel(options.configLabel, warnings) ?? {};

  const lifecycleScripts = {} as Record<ScriptHook, string | null>;
  // initializeCommand only ever comes from devcontainer.json itself (it
  // runs on the host in Dev Containers); here it's the first hook to run.
  const initialize = renderLifecycleScript("initializeCommand" as LifecycleHook, [{ initializeCommand: config.initializeCommand }]);
  lifecycleScripts.initializeCommand = initialize.script;
  warnings.push(...initialize.warnings);
  for (const hook of LIFECYCLE_HOOKS) {
    const rendered = renderLifecycleScript(hook, entries);
    lifecycleScripts[hook] = rendered.script;
    warnings.push(...rendered.warnings);
  }

  const configuration: Record<string, unknown> = {
    ...mergeConfiguration(entries),
    workspaceFolder: typeof config.workspaceFolder === "string" ? config.workspaceFolder : DEFAULT_WORKSPACE_FOLDER,
    ...(config.runArgs !== undefined ? { runArgs: config.runArgs } : {}),
    ...(config.initializeCommand !== undefined ? { initializeCommand: config.initializeCommand } : {}),
  };

  const runArgs = parseRunArgs(config.runArgs, warnings);
  const runtime = buildRuntime(configuration, runArgs, options.imageUser, warnings);

  const containerEnv: [string, unknown][] = [
    ...runArgs.env,
    ...Object.entries((configuration.containerEnv as Record<string, unknown> | undefined) ?? {}),
  ];
  const remoteEnv = Object.entries((configuration.remoteEnv as Record<string, unknown> | undefined) ?? {});

  return {
    configuration,
    lifecycleScripts,
    envScripts: {
      containerEnv: renderEnvScript(containerEnv, warnings, "containerEnv"),
      remoteEnv: renderEnvScript(remoteEnv, warnings, "remoteEnv"),
    },
    runtime,
    variables: detectVariables([
      ...raw.map((entry, i) => ({ path: `metadata[${i}]`, value: entry })),
      { path: "config", value: config },
    ]).map((v) => ({ ...v, usedIn: v.usedIn.map(friendlyPath(raw)) })),
    vscode: mergeVscode(entries),
    warnings,
    metadata: raw,
  };
}

// `metadata[3].remoteEnv.TOKEN` -> `remoteEnv.TOKEN (devcontainer.json)` /
// `(ghcr.io/devcontainers/features/node:1)` - where a person would look.
function friendlyPath(raw: Entry[]): (path: string) => string {
  return (path) => {
    const config = /^config\.(.*)$/.exec(path);
    if (config) return `${config[1]} (devcontainer.json)`;
    const match = /^metadata\[(\d+)\]\.(.*)$/.exec(path);
    if (!match) return path;
    const entry = raw[parseInt(match[1], 10)];
    const origin = typeof entry?.id === "string" ? entry.id : "devcontainer.json";
    return `${match[2]} (${origin})`;
  };
}
