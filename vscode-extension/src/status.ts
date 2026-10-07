import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { git, gitOptional, lines } from "./git";
import { CONFIG_FILES, rebuildPaths, unionPaths } from "./paths";

export interface Workspace {
  folder: string;
  imageCommit: string;
  branch: string;
}

export type Kind = "up-to-date" | "rebuild-available" | "unpushed" | "no-config" | "unknown";

export interface Status {
  kind: Kind;
  branch: string;
  imageCommit?: string;
  originCommit?: string;
  // Rebuild paths changed between the image's commit and origin.
  changed: string[];
  // Rebuild paths changed here but not on origin: uncommitted, or in
  // commits that aren't pushed.
  local: string[];
  paths: string[];
  // Why it's unknown, or why rebuild-available has no changed files.
  reason?: string;
}

// Compares the commit the workspace's image was built from with
// origin/<branch>, over the paths that go into the image. A rebuild always
// builds origin/<branch>, so local changes only count once they're pushed.
export interface CheckOptions {
  // Fetch origin/<branch> first.
  fetch: boolean;
  // Let git ask for credentials through GIT_ASKPASS (default true). Off for
  // background checks once one has hung on it - see git().
  askpass?: boolean;
}

const SHA = /^[0-9a-f]{7,64}$/i;

export async function checkStatus(ws: Workspace, opts: CheckOptions): Promise<Status> {
  const base: Status = { kind: "unknown", branch: ws.branch, changed: [], local: [], paths: [] };
  if (!ws.imageCommit || !ws.branch) {
    return { ...base, reason: "The workspace's image commit or branch isn't known (DEVCONTAINER_IMAGE_COMMIT / DEVCONTAINER_BRANCH)." };
  }
  if (!SHA.test(ws.imageCommit)) return { ...base, reason: `DEVCONTAINER_IMAGE_COMMIT isn't a commit: ${ws.imageCommit}` };
  const remote = `refs/remotes/origin/${ws.branch}`;
  const net = { askpass: opts.askpass ?? true };
  // Paths from devcontainer.json are file names, never globs or pathspec
  // magic like :(top) or :!.
  const diff = (...args: string[]) => ["--literal-pathspecs", ...args];
  try {
    if (opts.fetch) await git(ws.folder, ["fetch", "--quiet", "--no-tags", "origin", `+refs/heads/${ws.branch}:${remote}`], net);
    const originCommit = (await git(ws.folder, ["rev-parse", "--verify", `${remote}^{commit}`])).trim();
    let imageCommit = await resolveCommit(ws.folder, ws.imageCommit);
    if (!imageCommit && (await gitOptional(ws.folder, ["fetch", "--quiet", "--no-tags", "origin", ws.imageCommit], net)) !== undefined) {
      imageCommit = await resolveCommit(ws.folder, ws.imageCommit);
    }
    // Not on origin any more (force-pushed away, or the branch was
    // recreated) - as long as origin itself answers: the branch fetch just
    // now says so, else ask it.
    if (!imageCommit && !opts.fetch) await git(ws.folder, ["ls-remote", "--quiet", "origin", `refs/heads/${ws.branch}`], net);

    const configs = [
      ...(imageCommit ? [await configAt(ws.folder, imageCommit)] : []),
      await configAt(ws.folder, originCommit),
      await configInWorkingTree(ws.folder),
    ];
    const paths = unionPaths(...configs.map((c) => c.paths));
    const changed = imageCommit ? lines(await git(ws.folder, diff("diff", "--name-only", imageCommit, originCommit, "--", ...paths))) : [];
    const uncommitted = [
      ...lines(await gitOptional(ws.folder, diff("diff", "--name-only", "HEAD", "--", ...paths))),
      ...lines(await git(ws.folder, diff("ls-files", "--others", "--exclude-standard", "--", ...paths))),
    ];
    const unpushed = lines(await gitOptional(ws.folder, diff("diff", "--name-only", `${originCommit}...HEAD`, "--", ...paths)));
    const local = [...new Set([...uncommitted, ...unpushed])].sort();

    if (!imageCommit) {
      return {
        kind: "rebuild-available",
        branch: ws.branch,
        imageCommit: ws.imageCommit,
        originCommit,
        changed,
        local,
        paths,
        reason: `The image's commit ${ws.imageCommit.slice(0, 7)} isn't on origin any more (force-pushed?), so what changed can't be listed. A rebuild builds origin/${ws.branch}.`,
      };
    }
    // No devcontainer.json anywhere: the image came from the service's
    // fallback (ADR-0013) - offer to add one.
    const noConfig = configs.every((c) => !c.found);
    const kind: Kind = changed.length > 0 ? "rebuild-available" : local.length > 0 ? "unpushed" : noConfig ? "no-config" : "up-to-date";
    return { kind, branch: ws.branch, imageCommit, originCommit, changed, local, paths };
  } catch (e) {
    return { ...base, imageCommit: ws.imageCommit, reason: (e as Error).message };
  }
}

async function resolveCommit(folder: string, sha: string): Promise<string | undefined> {
  return (await gitOptional(folder, ["rev-parse", "--verify", "--quiet", `${sha}^{commit}`]))?.trim() || undefined;
}

interface Config {
  found: boolean;
  paths: string[];
}

async function configAt(folder: string, commit: string): Promise<Config> {
  for (const file of CONFIG_FILES) {
    const text = await gitOptional(folder, ["show", `${commit}:${file}`]);
    if (text !== undefined) return { found: true, paths: rebuildPaths(file, text) };
  }
  return { found: false, paths: rebuildPaths(CONFIG_FILES[0], undefined) };
}

async function configInWorkingTree(folder: string): Promise<Config> {
  for (const file of CONFIG_FILES) {
    try {
      return { found: true, paths: rebuildPaths(file, await readFile(join(folder, file), "utf8")) };
    } catch {
      // Not this one.
    }
  }
  return { found: false, paths: rebuildPaths(CONFIG_FILES[0], undefined) };
}
