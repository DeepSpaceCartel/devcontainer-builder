// devcontainer.json variables (`${localEnv:X}`, `${containerEnv:X}`,
// `${containerWorkspaceFolder}`, ...) - detected and rewritten, never
// substituted. The CLI substitutes them at `devcontainer up` time from the
// host's environment and the running container; this service has neither,
// and GET /devcontainer stays a pure function of the image (ADR-0012). So
// each reference becomes a shell variable reference the workspace fills in
// at runtime - `${containerEnv:PATH}` becomes `${PATH}`, read from the
// container's real environment, `${localEnv:TOKEN}` becomes
// `${DEVCONTAINER_LOCALENV_TOKEN}`, set from what the user provides.
//
// Parsing follows the CLI's own (src/spec-common/variableSubstitution.ts,
// checked against the 0.89.0 bundle): `${name}` or `${name:arg1:arg2...}`,
// split on `:`; localEnv/env/containerEnv take a variable name and an
// optional default (the first argument after it); anything else is left
// exactly as written.

export const LOCAL_ENV_PREFIX = "DEVCONTAINER_LOCALENV_";
export const WORKSPACE_FOLDER_VAR = "DEVCONTAINER_WORKSPACE_FOLDER";
export const WORKSPACE_FOLDER_BASENAME_VAR = "DEVCONTAINER_WORKSPACE_FOLDER_BASENAME";
export const DEVCONTAINER_ID_VAR = "DEVCONTAINER_ID";

export type VariableKind = "localEnv" | "containerEnv" | "context";

export interface DetectedVariable {
  kind: VariableKind;
  name: string;
  default?: string;
  usedIn: string[];
}

// A reference resolved to the shell variable that will hold its value at
// runtime, with the devcontainer.json default (if any) as the shell default.
interface ShellReference {
  kind: VariableKind;
  name: string;
  shellName: string;
  default?: string;
}

const REFERENCE_PATTERN = /\$\{(.*?)\}/g;
const SHELL_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;

const CONTEXT_VARIABLES: Record<string, string> = {
  localWorkspaceFolder: WORKSPACE_FOLDER_VAR,
  containerWorkspaceFolder: WORKSPACE_FOLDER_VAR,
  localWorkspaceFolderBasename: WORKSPACE_FOLDER_BASENAME_VAR,
  containerWorkspaceFolderBasename: WORKSPACE_FOLDER_BASENAME_VAR,
  devcontainerId: DEVCONTAINER_ID_VAR,
};

// Parses the inside of one `${...}`; undefined for anything the CLI itself
// wouldn't substitute (left verbatim, like the CLI does).
function parseReference(inner: string): ShellReference | undefined {
  const [name, ...args] = inner.split(":");
  if (Object.hasOwn(CONTEXT_VARIABLES, name)) {
    return { kind: "context", name, shellName: CONTEXT_VARIABLES[name] };
  }
  if ((name === "localEnv" || name === "env" || name === "containerEnv") && args.length > 0 && SHELL_NAME.test(args[0])) {
    const kind: VariableKind = name === "containerEnv" ? "containerEnv" : "localEnv";
    const shellName = kind === "localEnv" ? `${LOCAL_ENV_PREFIX}${args[0]}` : args[0];
    return { kind, name: args[0], shellName, default: args.length > 1 ? args[1] : undefined };
  }
  return undefined;
}

export type Segment = { literal: string } | { reference: ShellReference };

// Splits a string into literal text and variable references.
export function segments(value: string): Segment[] {
  const out: Segment[] = [];
  let last = 0;
  for (const match of value.matchAll(REFERENCE_PATTERN)) {
    const reference = parseReference(match[1]);
    if (!reference) continue;
    if (match.index! > last) out.push({ literal: value.slice(last, match.index) });
    out.push({ reference });
    last = match.index! + match[0].length;
  }
  if (last < value.length) out.push({ literal: value.slice(last) });
  return out;
}

export function hasReferences(value: string): boolean {
  return segments(value).some((s) => "reference" in s);
}

// `${NAME}` / `${NAME:-default}` - the default is shell-escaped for use
// inside a parameter expansion that itself sits in double quotes.
function shellExpansion(reference: ShellReference): string {
  if (reference.default === undefined) return `\${${reference.shellName}}`;
  return `\${${reference.shellName}:-${escapeDoubleQuoted(reference.default)}}`;
}

function escapeDoubleQuoted(value: string): string {
  return value.replace(/[\\"$`]/g, (c) => `\\${c}`);
}

// For a string that will itself be run by `sh -c` (a string-form lifecycle
// command): references become `${NAME}` in place, everything else is left
// for that shell to interpret, as the CLI's substituted string would be.
export function rewriteForShellString(value: string): string {
  return segments(value)
    .map((s) => ("literal" in s ? s.literal : shellExpansion(s.reference)))
    .join("");
}

// One shell *word* whose literal parts can't be reinterpreted - for argv
// elements and env values. Literal text is double-quote-escaped and the
// references expand inside the same double quotes.
export function shellWord(value: string): string {
  return `"${segments(value)
    .map((s) => ("literal" in s ? escapeDoubleQuoted(s.literal) : shellExpansion(s.reference)))
    .join("")}"`;
}

// Walks any JSON value, recording each variable reference against the path
// it appears at (e.g. `remoteEnv.GITHUB_TOKEN`, `postCreateCommand[1]`).
export function detectVariables(sources: { path: string; value: unknown }[]): DetectedVariable[] {
  const found = new Map<string, DetectedVariable>();

  const visit = (path: string, value: unknown) => {
    if (typeof value === "string") {
      for (const s of segments(value)) {
        if (!("reference" in s)) continue;
        const key = `${s.reference.kind}:${s.reference.name}`;
        const existing = found.get(key);
        if (existing) {
          if (!existing.usedIn.includes(path)) existing.usedIn.push(path);
          if (existing.default === undefined && s.reference.default !== undefined) existing.default = s.reference.default;
        } else {
          found.set(key, {
            kind: s.reference.kind,
            name: s.reference.name,
            ...(s.reference.default !== undefined ? { default: s.reference.default } : {}),
            usedIn: [path],
          });
        }
      }
    } else if (Array.isArray(value)) {
      value.forEach((v, i) => visit(`${path}[${i}]`, v));
    } else if (typeof value === "object" && value !== null) {
      for (const [k, v] of Object.entries(value)) visit(path ? `${path}.${k}` : k, v);
    }
  };

  for (const source of sources) visit(source.path, source.value);
  return [...found.values()];
}
