import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

// Registry auth has no structured representation anywhere in this service
// (see ADR-0007) - it only ever exists as a docker-config-JSON file on disk,
// keyed by the exact registry string an operator/caller used when it was
// written (build.ts's withRegistryAuthEnv does the same exact-string match).
// This reads that same ambient file back out for the new /image endpoints,
// which need real credentials to call the registry directly instead of
// just handing DOCKER_CONFIG to a subprocess.
export async function readAmbientDockerAuth(registry: string): Promise<{ username: string; password: string } | undefined> {
  const dockerConfigDir = process.env.DOCKER_CONFIG ?? join(homedir(), ".docker");
  const configPath = join(dockerConfigDir, "config.json");

  let raw: string;
  try {
    raw = await readFile(configPath, "utf8");
  } catch {
    return undefined;
  }

  let config: { auths?: Record<string, { auth?: string }> };
  try {
    config = JSON.parse(raw);
  } catch {
    return undefined;
  }

  const entry = config.auths?.[registry];
  if (!entry?.auth) return undefined;

  const decoded = Buffer.from(entry.auth, "base64").toString("utf8");
  const separatorIndex = decoded.indexOf(":");
  if (separatorIndex === -1) return undefined;

  return { username: decoded.slice(0, separatorIndex), password: decoded.slice(separatorIndex + 1) };
}
