import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { CoderApiError, coderRequest, isTransient } from "./http";

export { CoderApiError, CoderUnreachable } from "./http";

// "Clone Repository in Coder Workspace…": the Coder side of Dev Containers'
// "Clone Repository in Container Volume…". Everything here is plain
// node, so it's testable without VS Code.

export interface CoderLogin {
  url: string;
  token: string;
}

// Where the Coder CLI keeps `coder login`'s url/session on this machine.
export function coderConfigDir(platform = process.platform, env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  if (env.CODER_CONFIG_DIR) return env.CODER_CONFIG_DIR;
  if (platform === "darwin") return join(home, "Library", "Application Support", "coderv2");
  if (platform === "win32") return join(env.APPDATA ?? join(home, "AppData", "Roaming"), "coderv2");
  return join(env.XDG_CONFIG_HOME ?? join(home, ".config"), "coderv2");
}

export async function cliLogin(dir = coderConfigDir()): Promise<CoderLogin | undefined> {
  try {
    const [url, token] = await Promise.all(["url", "session"].map((f) => readFile(join(dir, f), "utf8")));
    return url.trim() && token.trim() ? { url: trimUrl(url), token: token.trim() } : undefined;
  } catch {
    return undefined;
  }
}

export function trimUrl(url: string): string {
  return url.trim().replace(/\/+$/, "");
}

// The same repository however it's written: scheme, user, `.git`, a
// trailing slash and case don't matter; SCP-style becomes host/path.
export function normalizeRepo(url: string): string {
  let s = url.trim();
  const scp = /^[^@/]+@([^:/]+):(.+)$/.exec(s);
  if (scp) s = `${scp[1]}/${scp[2]}`;
  else s = s.replace(/^[a-z+]+:\/\//i, "").replace(/^[^@/]+@/, "");
  return s.replace(/:\d+\//, "/").replace(/\/+$/, "").replace(/\.git$/i, "").toLowerCase();
}

// A Coder workspace name for <repo>-<branch>: letters, digits and single
// hyphens, at most 32 characters, and not one that's taken. A long name
// shortens the repository part first, so the branch stays readable.
export function workspaceName(repo: string, branch: string, taken: Set<string>): string {
  const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  const trim = (s: string, n: number) => s.slice(0, n).replace(/-+$/, "");
  const base = slug(normalizeRepo(repo).split("/").pop() ?? "") || "workspace";
  const b = trim(slug(branch), 15);
  let name = `${base}-${b}`.length <= 32 || !b ? trim(`${base}-${b}`, 32) : `${trim(base, 32 - 1 - b.length)}-${b}`;
  name = name.replace(/-+$/, "") || "workspace";
  if (!taken.has(name)) return name;
  for (let i = 2; ; i++) {
    const suffix = `-${i}`;
    const candidate = name.slice(0, 32 - suffix.length).replace(/-+$/, "") + suffix;
    if (!taken.has(candidate)) return candidate;
  }
}

// `git ls-remote --symref <url> HEAD 'refs/heads/*'`: the default branch
// first, then the rest.
export function parseLsRemote(output: string): string[] {
  let head: string | undefined;
  const branches: string[] = [];
  for (const line of output.split("\n")) {
    const symref = /^ref: refs\/heads\/(\S+)\s+HEAD$/.exec(line.trim());
    if (symref) head = symref[1];
    const branch = /^[0-9a-f]+\s+refs\/heads\/(\S+)$/.exec(line.trim());
    if (branch) branches.push(branch[1]);
  }
  const rest = branches.filter((b) => b !== head).sort();
  return head ? [head, ...rest] : rest;
}

export interface Parameter {
  name: string;
  value: string;
}

export interface Template {
  id: string;
  name: string;
  display_name?: string;
  description?: string;
  active_version_id: string;
}

export interface Workspace {
  id: string;
  name: string;
  owner_name: string;
  template_name: string;
  latest_build: {
    id: string;
    status: string;
    transition: string;
    job: { status: string; error?: string };
    resources?: {
      agents?: {
        name: string;
        status: string;
        lifecycle_state: string;
        apps?: { slug: string; external?: boolean; url?: string }[];
      }[];
    }[];
  };
}

// A git account the template needs linked before a workspace can be
// created (its `coder_external_auth`, e.g. GitHub for private repositories).
export interface ExternalAuth {
  id: string;
  display_name: string;
  authenticated: boolean;
  authenticate_url: string;
}

export class CoderApi {
  constructor(
    readonly login: CoderLogin,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  private call<T>(path: string, init?: RequestInit): Promise<T> {
    return coderRequest<T>(this.fetchImpl, this.login.url, this.login.token, path, init);
  }

  me() {
    return this.call<{ username: string }>("/users/me");
  }

  // Templates a repository can be cloned into: those asking for a
  // `repository` and a `branch` (devcontainer-builder's Coder template).
  async repositoryTemplates(): Promise<Template[]> {
    const templates = await this.call<Template[]>("/templates");
    const usable = await Promise.all(
      templates.map(async (t) => {
        const params = await this.call<{ name: string }[]>(`/templateversions/${t.active_version_id}/rich-parameters`).catch(() => []);
        const names = new Set(params.map((p) => p.name));
        return names.has("repository") && names.has("branch") ? t : undefined;
      }),
    );
    return usable.filter((t): t is Template => t !== undefined);
  }

  // The template's required accounts that aren't linked yet.
  async unlinkedExternalAuth(template: Template): Promise<ExternalAuth[]> {
    const auths = await this.call<ExternalAuth[]>(`/templateversions/${template.active_version_id}/external-auth`);
    return auths.filter((a) => !a.authenticated);
  }

  async myWorkspaces(): Promise<Workspace[]> {
    return (await this.call<{ workspaces: Workspace[] }>("/workspaces?q=owner:me")).workspaces;
  }

  buildParameters(buildId: string) {
    return this.call<Parameter[]>(`/workspacebuilds/${buildId}/parameters`);
  }

  workspace(id: string) {
    return this.call<Workspace>(`/workspaces/${id}`);
  }

  startWorkspace(id: string) {
    return this.call<unknown>(`/workspaces/${id}/builds`, { method: "POST", body: JSON.stringify({ transition: "start" }) });
  }

  // Every other parameter takes the template's default.
  createWorkspace(templateId: string, name: string, parameters: Parameter[]) {
    return this.call<Workspace>("/users/me/workspaces", {
      method: "POST",
      body: JSON.stringify({ template_id: templateId, name, rich_parameter_values: parameters }),
    });
  }

  async buildLog(buildId: string): Promise<string> {
    const logs = await this.call<{ stage: string; output: string }[]>(`/workspacebuilds/${buildId}/logs`);
    return logs.map((l) => `[${l.stage}] ${l.output}`).join("\n");
  }
}

// My workspaces already on this repository and branch.
export async function findExisting(api: CoderApi, repo: string, branch: string, workspaces: Workspace[]): Promise<Workspace[]> {
  const wanted = normalizeRepo(repo);
  const matches = await Promise.all(
    workspaces.map(async (w) => {
      const params = await api.buildParameters(w.latest_build.id).catch(() => [] as Parameter[]);
      const value = (name: string) => params.find((p) => p.name === name)?.value;
      const r = value("repository");
      return r !== undefined && normalizeRepo(r) === wanted && value("branch") === branch ? w : undefined;
    }),
  );
  return matches.filter((w): w is Workspace => w !== undefined);
}

// `stalled`: not failed yet, but it will be if it stays like this (an
// agent that timed out connecting or disconnected can still come back).
export type Phase =
  | { kind: "building" | "starting" | "scripts"; message: string; stalled?: string }
  | { kind: "ready" }
  | { kind: "failed"; message: string };

// Where a workspace is on its way to usable.
export function phase(w: Workspace): Phase {
  const b = w.latest_build;
  if (b.job.status === "failed" || b.job.status === "canceled") return { kind: "failed", message: b.job.error || `The build ${b.job.status}.` };
  if (b.transition !== "start") return { kind: "failed", message: `The workspace is ${b.status}.` };
  if (b.job.status !== "succeeded") return { kind: "building", message: "Building the image and the workspace…" };
  const agents = (b.resources ?? []).flatMap((r) => r.agents ?? []);
  const stuck = agents.find((a) => a.status === "timeout" || a.status === "disconnected");
  if (stuck) {
    const what = stuck.status === "timeout" ? "didn't connect" : "disconnected";
    return { kind: "starting", message: `Waiting for the workspace's agent (it ${what})…`, stalled: `The workspace's agent ${stuck.name} ${what}` };
  }
  if (agents.length === 0 || agents.some((a) => a.status !== "connected")) return { kind: "starting", message: "Starting the workspace…" };
  if (agents.some((a) => a.lifecycle_state === "start_error" || a.lifecycle_state === "start_timeout")) {
    return { kind: "failed", message: "A startup script failed - see the workspace's startup logs." };
  }
  if (agents.some((a) => a.lifecycle_state !== "ready")) return { kind: "scripts", message: "Cloning and running the Dev Container hooks…" };
  return { kind: "ready" };
}

// The workspace's VS Code Desktop app (the vscode-desktop module):
// vscode://coder.coder-remote/open?…&folder=<workspaceFolder>, with the
// session token the dashboard would fill in. Without the app, the same URI
// without a folder.
export function desktopUri(w: Workspace, login: CoderLogin): string {
  const apps = (w.latest_build.resources ?? []).flatMap((r) => r.agents ?? []).flatMap((a) => a.apps ?? []);
  const app = apps.find((a) => a.external && a.url?.startsWith("vscode://coder.coder-remote/"));
  if (app?.url) return app.url.replace("$SESSION_TOKEN", encodeURIComponent(login.token));
  const q = new URLSearchParams({ owner: w.owner_name, workspace: w.name, url: login.url, token: login.token });
  return `vscode://coder.coder-remote/open?${q}`;
}

// A repository URL with credentials in it (https://user:token@host/…) would
// be logged and saved as a workspace parameter that anyone who can read the
// workspace sees. Private repositories use the linked git account instead.
export function repoUrlProblem(url: string): string | undefined {
  const s = url.trim();
  const withScheme = /^([a-z][a-z0-9+.-]*):\/\/([^/?#]*)/i.exec(s);
  let credentials: boolean;
  if (withScheme) {
    const at = withScheme[2].lastIndexOf("@");
    const userinfo = at < 0 ? undefined : withScheme[2].slice(0, at);
    // ssh://git@host is a user name, not a secret; on http(s) a user name
    // alone is often a token.
    credentials = userinfo !== undefined && (userinfo.includes(":") || /^https?$/i.test(withScheme[1]));
  } else {
    // SCP-style user:password@host:path.
    credentials = /^[^@/:]*:[^@/]*@[^:/]+:/.test(s);
  }
  if (!credentials) return undefined;
  return "The repository URL has credentials in it. Use it without them (e.g. https://github.com/owner/repo): workspaces clone private repositories with your git account linked in Coder, and the URL is saved as a workspace parameter.";
}

// What to do with an existing workspace before waiting for it: wait for a
// start that's under way, let a stop or cancel finish first, or start it
// (stopped, or a failed or canceled build - the dashboard's Retry).
export type ExistingStep = "wait" | "settle" | "start" | "deleted";

export function existingStep(w: Workspace): ExistingStep {
  const { transition, status } = w.latest_build;
  if (transition === "delete" || status === "deleting" || status === "deleted") return "deleted";
  if (status === "canceling") return "settle";
  if (["pending", "starting", "stopping"].includes(status)) return transition === "start" ? "wait" : "settle";
  if (status === "running") return transition === "start" ? "wait" : "start";
  return "start";
}

export interface WaitOptions {
  pollMs?: number;
  // How long an agent may stay timed out or disconnected.
  stallGraceMs?: number;
  // Then the caller decides: keep waiting, or look in the dashboard.
  deadlineMs?: number;
  // Consecutive network errors or 5xx before giving up.
  maxTransientErrors?: number;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  cancelled?: () => boolean;
  onPhase?: (p: Phase) => void;
  onRetry?: (e: Error, attempt: number) => void;
}

export type WaitResult =
  | { kind: "ready"; workspace: Workspace }
  | { kind: "failed"; workspace: Workspace; message: string }
  | { kind: "deadline"; workspace?: Workspace }
  | { kind: "cancelled" };

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

// Follows a workspace until it's ready, failed, or the deadline passes.
// Transient errors are retried with backoff; anything else is thrown.
export async function pollUntilReady(get: () => Promise<Workspace>, o: WaitOptions = {}): Promise<WaitResult> {
  const pollMs = o.pollMs ?? 3000;
  const stallGraceMs = o.stallGraceMs ?? 3 * 60_000;
  const deadlineMs = o.deadlineMs ?? 20 * 60_000;
  const maxTransientErrors = o.maxTransientErrors ?? 5;
  const now = o.now ?? Date.now;
  const wait = o.sleep ?? sleep;
  const start = now();
  let stalledSince: number | undefined;
  let errors = 0;
  let last: Workspace | undefined;
  for (;;) {
    if (o.cancelled?.()) return { kind: "cancelled" };
    if (now() - start >= deadlineMs) return { kind: "deadline", workspace: last };
    let current: Workspace;
    try {
      current = await get();
      errors = 0;
    } catch (e) {
      if (!isTransient(e) || ++errors > maxTransientErrors) throw e;
      o.onRetry?.(e as Error, errors);
      await wait(Math.min(pollMs * 2 ** errors, 30_000));
      continue;
    }
    last = current;
    const p = phase(current);
    if (p.kind === "ready") return { kind: "ready", workspace: current };
    if (p.kind === "failed") return { kind: "failed", workspace: current, message: p.message };
    if (p.stalled) {
      stalledSince ??= now();
      if (now() - stalledSince >= stallGraceMs) {
        return { kind: "failed", workspace: current, message: `${p.stalled} for ${Math.round(stallGraceMs / 60_000)} minutes - see its logs in the dashboard.` };
      }
    } else {
      stalledSince = undefined;
    }
    o.onPhase?.(p);
    await wait(pollMs);
  }
}

// Logging in. Stored tokens are kept per deployment, so a token is only
// ever sent to the Coder it was issued by.
export const TOKEN_SECRET = "devcontainerBuilder.coderToken";

export function origin(url: string): string | undefined {
  try {
    const u = new URL(url.trim());
    return /^https?:$/.test(u.protocol) ? u.origin : undefined;
  } catch {
    return undefined;
  }
}

export function tokenSecretKey(url: string): string | undefined {
  const o = origin(url);
  return o && `${TOKEN_SECRET}:${o}`;
}

// The parts of VS Code's SecretStorage used here.
export interface Secrets {
  get(key: string): PromiseLike<string | undefined>;
  store(key: string, value: string): PromiseLike<void>;
  delete(key: string): PromiseLike<void>;
}

// 0.5.0 stored one token for whichever URL was last typed: keep it for
// that URL only.
export async function migrateLegacyToken(secrets: Secrets, storedUrl: string | undefined): Promise<void> {
  const legacy = await secrets.get(TOKEN_SECRET);
  if (legacy === undefined) return;
  const key = storedUrl && tokenSecretKey(storedUrl);
  if (key && (await secrets.get(key)) === undefined) await secrets.store(key, legacy);
  await secrets.delete(TOKEN_SECRET);
}

export interface LoginCandidate {
  login: CoderLogin;
  source: "stored" | "cli";
}

// The configured deployment (else the last one logged in to) with its own
// stored token, then the Coder CLI's session if it's for that deployment.
export async function loginCandidates(
  secrets: Secrets,
  configured: string | undefined,
  storedUrl: string | undefined,
  cli: CoderLogin | undefined,
): Promise<LoginCandidate[]> {
  const candidates: LoginCandidate[] = [];
  const url = configured || storedUrl;
  const key = url && tokenSecretKey(url);
  const token = key ? await secrets.get(key) : undefined;
  if (url && token) candidates.push({ login: { url: trimUrl(url), token }, source: "stored" });
  if (cli && (!configured || origin(configured) === origin(cli.url))) candidates.push({ login: cli, source: "cli" });
  return candidates;
}

// The first candidate Coder accepts. A rejected stored token is deleted;
// an unreachable deployment moves on to the next, and is reported.
export async function firstWorkingLogin(
  candidates: LoginCandidate[],
  secrets: Secrets,
  makeApi: (login: CoderLogin) => CoderApi = (login) => new CoderApi(login),
): Promise<{ api?: CoderApi; problems: string[] }> {
  const problems: string[] = [];
  for (const c of candidates) {
    const api = makeApi(c.login);
    try {
      await api.me();
      return { api, problems };
    } catch (e) {
      if (e instanceof CoderApiError && e.status === 401) {
        const key = tokenSecretKey(c.login.url);
        if (c.source === "stored" && key) await secrets.delete(key);
        problems.push(`The ${c.source === "cli" ? "Coder CLI's" : "stored"} session for ${c.login.url} has expired.`);
      } else if (isTransient(e)) {
        problems.push((e as Error).message);
      } else {
        throw e;
      }
    }
  }
  return { problems };
}
