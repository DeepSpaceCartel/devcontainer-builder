import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { coderConfigDir } from "./clone";
import { CoderApiError, coderRequest } from "./http";

// The template's parameter that rebuilds the image when increased.
export const REBUILD_PARAMETER = "rebuild";

export interface CoderWorkspace {
  url: string;
  id: string;
  name: string;
  owner: string;
  // The parameter's value when this workspace was built.
  rebuild: number;
}

export function settingsUrl(ws: CoderWorkspace): string {
  return `${ws.url}/@${ws.owner}/${ws.name}/settings/parameters`;
}

export class NotLoggedIn extends Error {}

// The session `coder login` stores in the workspace. Without one there's no
// way to start a build from here: the agent's own token can't.
export async function sessionToken(env: NodeJS.ProcessEnv = process.env, home = homedir(), platform = process.platform): Promise<string | undefined> {
  if (env.CODER_SESSION_TOKEN) return env.CODER_SESSION_TOKEN.trim();
  const dir = coderConfigDir(platform, env, home);
  try {
    return (await readFile(join(dir, "session"), "utf8")).trim() || undefined;
  } catch {
    return undefined;
  }
}

// The deployment's URL: the one `coder login` used, else the agent's (which
// may be an internal address on some deployments).
export async function coderUrl(env: NodeJS.ProcessEnv = process.env, home = homedir(), platform = process.platform): Promise<string | undefined> {
  const dir = coderConfigDir(platform, env, home);
  let url = env.CODER_URL;
  if (!url) {
    try {
      url = (await readFile(join(dir, "url"), "utf8")).trim();
    } catch {
      // Not logged in.
    }
  }
  url ||= env.CODER_AGENT_URL;
  return url ? url.replace(/\/+$/, "") : undefined;
}

// Increases the Rebuild parameter by starting a new build of the running
// workspace. The Coder API, not the CLI: `coder restart/start --parameter`
// keep an existing workspace's value (Coder v2.37), and `coder update` does
// nothing on an up-to-date workspace. Other parameters keep their values.
export async function requestRebuild(ws: CoderWorkspace, token: string, fetchImpl: typeof fetch = fetch): Promise<number> {
  const api = async (path: string, init?: RequestInit): Promise<any> => {
    try {
      return await coderRequest(fetchImpl, ws.url, token, path, init);
    } catch (e) {
      if (e instanceof CoderApiError && e.status === 401) throw new NotLoggedIn("The Coder session has expired.");
      throw e;
    }
  };

  // The current value, in case it moved since this workspace started (e.g.
  // set in the dashboard while a build is still pending).
  const workspace = await api(`/workspaces/${ws.id}`);
  const parameters: { name: string; value: string }[] = await api(`/workspacebuilds/${workspace.latest_build.id}/parameters`);
  const current = Number(parameters.find((p) => p.name === REBUILD_PARAMETER)?.value ?? ws.rebuild);
  const next = Math.max(Number.isFinite(current) ? current : 0, ws.rebuild) + 1;

  await api(`/workspaces/${ws.id}/builds`, {
    method: "POST",
    body: JSON.stringify({ transition: "start", rich_parameter_values: [{ name: REBUILD_PARAMETER, value: String(next) }] }),
  });
  return next;
}
