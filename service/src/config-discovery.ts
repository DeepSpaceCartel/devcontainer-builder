import { lstat, readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { BuildRequestError } from "./errors.js";

// Every devcontainer.json a cloned repository has, as the list of images one
// `POST /build` produces (ADR-0016). The containers.dev spec allows three
// locations: `.devcontainer/devcontainer.json`, `.devcontainer.json`, and
// `.devcontainer/<folder>/devcontainer.json`. The first two are "the" root
// config - at most one counts, `.devcontainer/devcontainer.json` first, the
// Dev Containers CLI's own order - and become the `main` item. Each
// sub-folder config is an item of its own, its id derived from the folder.

export const MAIN_INSTANCE_ID = "main";

export interface DiscoveredConfig {
  /** `main` for the root config, else the sanitized folder name. */
  id: string;
  /** Repository-relative, `/`-separated. */
  configPath: string;
}

const ROOT_CONFIG_PATHS = [".devcontainer/devcontainer.json", ".devcontainer.json"];

// Whether the Dev Containers CLI finds this config on its own (without
// `--config`).
export function isRootConfigPath(configPath: string): boolean {
  return ROOT_CONFIG_PATHS.includes(configPath);
}

// A folder name as an item id: lower-cased, anything outside [a-z0-9-] → `-`,
// leading/trailing dashes dropped. The id ends up in an image name
// (`<name>-<id>`, where a trailing dash isn't valid OCI) and, in the Coder
// template, in Kubernetes object names and the agent name (DNS labels,
// which must start and end alphanumeric). Empty when nothing usable is left.
export function instanceIdFor(folder: string): string {
  return folder
    .toLowerCase()
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/^-+|-+$/g, "");
}

async function isFile(path: string, followSymlinks: boolean): Promise<boolean> {
  try {
    return (await (followSymlinks ? stat(path) : lstat(path))).isFile();
  } catch {
    return false;
  }
}

// Root configs are read the way the CLI reads them (symlinks followed, as
// before). Sub-folders are enumerated without following symlinks - a
// symlinked folder or file in an untrusted clone could otherwise point the
// build at something outside the repository.
export async function discoverConfigs(repoDir: string): Promise<DiscoveredConfig[]> {
  const items: DiscoveredConfig[] = [];
  for (const configPath of ROOT_CONFIG_PATHS) {
    if (await isFile(join(repoDir, configPath), true)) {
      items.push({ id: MAIN_INSTANCE_ID, configPath });
      break;
    }
  }

  let entries: import("node:fs").Dirent[] = [];
  try {
    entries = await readdir(join(repoDir, ".devcontainer"), { withFileTypes: true });
  } catch {
    // no .devcontainer directory (or it's a file): no sub-folder configs
  }

  const folders: { folder: string; id: string; configPath: string }[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const configPath = `.devcontainer/${entry.name}/devcontainer.json`;
    if (!(await isFile(join(repoDir, configPath), false))) continue;
    folders.push({ folder: entry.name, id: instanceIdFor(entry.name), configPath });
  }

  const unusable = folders.filter((f) => f.id === "");
  if (unusable.length > 0) {
    throw new BuildRequestError(
      `devcontainer.json sub-folder name(s) leave no usable id (need at least one of [a-z0-9]): ${unusable.map((f) => `.devcontainer/${f.folder}`).join(", ")}`,
    );
  }

  const byId = new Map<string, string[]>();
  if (items.length > 0) byId.set(MAIN_INSTANCE_ID, [items[0]!.configPath]);
  for (const f of folders) byId.set(f.id, [...(byId.get(f.id) ?? []), f.configPath]);
  const collisions = [...byId].filter(([, paths]) => paths.length > 1);
  if (collisions.length > 0) {
    throw new BuildRequestError(
      `devcontainer.json locations map to the same instance id: ${collisions.map(([id, paths]) => `"${id}" (${paths.join(", ")})`).join("; ")} - rename a folder`,
    );
  }

  folders.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return [...items, ...folders.map(({ id, configPath }) => ({ id, configPath }))];
}

// The items a request asked for, in discovery order. No filter (or null):
// all of them.
export function selectInstances(items: DiscoveredConfig[], filter: string[] | null | undefined): DiscoveredConfig[] {
  if (filter === undefined || filter === null) return items;
  const valid = new Set(items.map((i) => i.id));
  const unknown = [...new Set(filter)].filter((id) => !valid.has(id));
  if (unknown.length > 0) {
    throw new BuildRequestError(
      `unknown instance id(s) ${unknown.map((id) => `"${id}"`).join(", ")} - this repository has: ${items.map((i) => `"${i.id}"`).join(", ")}`,
    );
  }
  const wanted = new Set(filter);
  return items.filter((i) => wanted.has(i.id));
}

// `main` keeps the name a single-config repository always had; every other
// item gets `-<id>` appended, whether the name was derived or given.
export function instanceImageName(name: string, id: string): string {
  return id === MAIN_INSTANCE_ID ? name : `${name}-${id}`;
}
