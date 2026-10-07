import { posix } from "node:path";
import { parseJsonc } from "./jsonc";

// Where devcontainer-builder looks for the config, in its order
// (service/src/build.ts).
export const CONFIG_FILES = [".devcontainer/devcontainer.json", ".devcontainer.json"];

const ALWAYS = [".devcontainer", ".devcontainer.json"];

// The repo paths whose changes make an image outdated: the Dev Container
// files, plus the Dockerfile and build context devcontainer.json points at
// (relative to devcontainer.json's folder). A context at or above the repo
// root means every change counts - returned as ".".
export function rebuildPaths(configFile: string, configText: string | undefined): string[] {
  const paths = new Set(ALWAYS);
  let config: any;
  try {
    config = configText === undefined ? undefined : parseJsonc(configText);
  } catch {
    // An unparsable config still has its own files watched.
  }
  const build = config && typeof config.build === "object" ? config.build : {};
  const dockerfile = build.dockerfile ?? config?.dockerFile;
  const context = build.context ?? config?.context ?? (dockerfile !== undefined ? "." : undefined);
  const dir = posix.dirname(configFile);
  for (const p of [dockerfile, context]) {
    if (typeof p !== "string") continue;
    const resolved = posix.normalize(posix.join(dir, p)).replace(/\/+$/, "");
    if (resolved === "." || resolved === "" || resolved === ".." || resolved.startsWith("../")) return ["."];
    paths.add(resolved);
  }
  return [...paths].sort();
}

// Several configs' paths (e.g. at the image's commit and at origin) as one
// git pathspec list.
export function unionPaths(...lists: string[][]): string[] {
  const all = new Set(lists.flat());
  return all.has(".") ? ["."] : [...all].sort();
}
