import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

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

export class CoderApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

export class CoderApi {
  constructor(
    readonly login: CoderLogin,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  private async call<T>(path: string, init?: RequestInit): Promise<T> {
    const res = await this.fetchImpl(`${this.login.url}/api/v2${path}`, {
      ...init,
      headers: { "Coder-Session-Token": this.login.token, "Content-Type": "application/json", Accept: "application/json" },
    });
    const body: any = await res.json().catch(() => ({}));
    if (!res.ok) {
      const detail = [body.message, body.detail, ...(body.validations ?? []).map((v: any) => `${v.field}: ${v.detail}`)];
      throw new CoderApiError(`Coder API ${res.status}: ${detail.filter(Boolean).join(" - ") || res.statusText}`, res.status);
    }
    return body as T;
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

export type Phase = { kind: "building" | "starting" | "scripts"; message: string } | { kind: "ready" } | { kind: "failed"; message: string };

// Where a workspace is on its way to usable.
export function phase(w: Workspace): Phase {
  const b = w.latest_build;
  if (b.job.status === "failed" || b.job.status === "canceled") return { kind: "failed", message: b.job.error || `The build ${b.job.status}.` };
  if (b.transition !== "start") return { kind: "failed", message: `The workspace is ${b.status}.` };
  if (b.job.status !== "succeeded") return { kind: "building", message: "Building the image and the workspace…" };
  const agents = (b.resources ?? []).flatMap((r) => r.agents ?? []);
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
