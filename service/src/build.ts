import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile, chmod, cp, readFile } from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import type { BuildRequest, BuildResponse, RegistryCredentials } from "./types.js";
import { loadServiceConfig, type GitCredentialEntry, type RegistryMappingRule, type SshHostKeyPolicy } from "./config.js";

export const serviceConfig = loadServiceConfig();

// Thrown for user-fixable request problems discovered mid-build (can't be
// caught by server.ts's up-front shape validation alone, e.g. no registry
// resolves for a repository) - server.ts maps this to 400, everything else
// to 500.
export class BuildRequestError extends Error {}

export function isReady(): { ready: boolean; reason?: string } {
  if (!serviceConfig.buildkitEndpoint) {
    return { ready: false, reason: "BUILDKIT_ENDPOINT not configured" };
  }
  return { ready: true };
}

function run(cmd: string, args: string[], env: NodeJS.ProcessEnv = process.env): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: "inherit", env });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`${cmd} ${args.join(" ")} exited with code ${code}`));
      }
    });
  });
}

function runCapture(
  cmd: string,
  args: string[],
  opts: { cwd?: string; env?: NodeJS.ProcessEnv } = {},
): Promise<{ stdout: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "inherit"], cwd: opts.cwd, env: opts.env ?? process.env });
    let stdout = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve({ stdout: stdout.trim() });
      } else {
        reject(new Error(`${cmd} ${args.join(" ")} exited with code ${code}`));
      }
    });
  });
}

// `docker buildx create --driver remote` talks straight to the remote
// BuildKit daemon over TCP - no local dockerd is needed. `--use` makes it
// the active builder so plain `docker build` (which the devcontainer CLI
// shells out to) is transparently routed through it. `env` lets a caller
// point this at a scratch DOCKER_CONFIG (see withRegistryAuthEnv) while
// still finding the builder state copied into that scratch dir.
async function ensureRemoteBuilder(env: NodeJS.ProcessEnv = process.env): Promise<void> {
  if (!serviceConfig.buildkitEndpoint) {
    throw new Error("BUILDKIT_ENDPOINT is not configured");
  }

  try {
    await run("docker", ["buildx", "inspect", serviceConfig.buildxBuilderName], env);
  } catch {
    await run(
      "docker",
      ["buildx", "create", "--name", serviceConfig.buildxBuilderName, "--driver", "remote", serviceConfig.buildkitEndpoint],
      env,
    );
  }

  await run("docker", ["buildx", "use", serviceConfig.buildxBuilderName], env);
}

// Git credentials go into a scratch `.netrc` (never argv or the remote URL)
// so they never show up in `ps` output or shell history/logs.
async function withNetrcEnv<T>(
  hostname: string,
  username: string,
  password: string,
  fn: (env: NodeJS.ProcessEnv) => Promise<T>,
): Promise<T> {
  const scratchHome = await mkdtemp(join(tmpdir(), "git-creds-"));
  const netrcPath = join(scratchHome, ".netrc");
  await writeFile(netrcPath, `machine ${hostname}\nlogin ${username}\npassword ${password}\n`);
  await chmod(netrcPath, 0o600);

  try {
    return await fn({ ...process.env, HOME: scratchHome, GIT_TERMINAL_PROMPT: "0" });
  } finally {
    await rm(scratchHome, { recursive: true, force: true });
  }
}

// SSH private key + known_hosts go into a scratch dir (never argv or the
// remote URL either), same rationale as withNetrcEnv. known_hosts content
// depends on the deployment-wide host-key policy: "tofu" scans the host at
// clone time (trust-on-first-use), "pinned" uses the operator-supplied key
// for this host and fails closed if none was configured.
async function withSshKeyEnv<T>(
  host: string,
  entry: Extract<GitCredentialEntry, { kind: "ssh" }>,
  hostKeyPolicy: SshHostKeyPolicy,
  fn: (env: NodeJS.ProcessEnv) => Promise<T>,
): Promise<T> {
  if (hostKeyPolicy === "pinned" && !entry.pinnedHostKey) {
    throw new BuildRequestError(`SSH host key policy is "pinned" but no pinned key configured for host ${host}`);
  }

  const scratchDir = await mkdtemp(join(tmpdir(), "git-ssh-"));
  const keyPath = join(scratchDir, "id");
  const knownHostsPath = join(scratchDir, "known_hosts");

  try {
    await writeFile(keyPath, entry.privateKey.endsWith("\n") ? entry.privateKey : `${entry.privateKey}\n`);
    await chmod(keyPath, 0o600);

    if (hostKeyPolicy === "pinned") {
      await writeFile(knownHostsPath, `${entry.pinnedHostKey!.trim()}\n`);
    } else {
      const scan = await runCapture("ssh-keyscan", ["-H", host]);
      await writeFile(knownHostsPath, `${scan.stdout}\n`);
    }
    await chmod(knownHostsPath, 0o600);

    const gitSshCommand = `ssh -i ${keyPath} -o UserKnownHostsFile=${knownHostsPath} -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o BatchMode=yes`;

    return await fn({ ...process.env, GIT_SSH_COMMAND: gitSshCommand, GIT_TERMINAL_PROMPT: "0" });
  } finally {
    await rm(scratchDir, { recursive: true, force: true });
  }
}

// Per-request registry push credentials get a scratch DOCKER_CONFIG, seeded
// from the ambient one (config.json *and* buildx/ builder state) before
// merging in the override entry - seeding from ambient means
// ensureRemoteBuilder still finds the already-created "remote" builder
// under the scratch dir instead of recreating it on every such request.
async function withRegistryAuthEnv<T>(
  creds: RegistryCredentials,
  fn: (env: NodeJS.ProcessEnv) => Promise<T>,
): Promise<T> {
  const ambientDockerConfig = process.env.DOCKER_CONFIG ?? join(homedir(), ".docker");
  const scratchDir = await mkdtemp(join(tmpdir(), "docker-config-"));

  try {
    try {
      await cp(ambientDockerConfig, scratchDir, { recursive: true });
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
    }

    const configPath = join(scratchDir, "config.json");
    let config: { auths?: Record<string, { auth: string }> } = {};
    try {
      config = JSON.parse(await readFile(configPath, "utf8"));
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
    }

    config.auths = { ...config.auths, [creds.registry]: { auth: Buffer.from(`${creds.username}:${creds.password}`).toString("base64") } };

    await writeFile(configPath, JSON.stringify(config));
    await chmod(configPath, 0o600);

    return await fn({ ...process.env, DOCKER_CONFIG: scratchDir });
  } finally {
    await rm(scratchDir, { recursive: true, force: true });
  }
}

interface ParsedGitUrl {
  host: string;
  path: string;
}

const SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
const SCP_RE = /^(?:[^@/]+@)?([^:/]+):(?!\/\/)(.+)$/;

// Accepts `https://host/path`, `ssh://[user@]host[:port]/path`, and git's
// own SCP-style shorthand `[user@]host:path` - the third form is not a
// valid `URL` and previously crashed `new URL(repository)` unconditionally.
function parseGitUrl(repository: string): ParsedGitUrl {
  if (SCHEME_RE.test(repository)) {
    const url = new URL(repository);
    return { host: url.hostname, path: url.pathname.replace(/^\//, "") };
  }

  const match = SCP_RE.exec(repository);
  if (match) {
    return { host: match[1], path: match[2] };
  }

  throw new BuildRequestError(`unable to parse git repository URL: ${repository}`);
}

type GitCredentialKind = "https" | "ssh" | "none";

function toCloneUrl(repository: string, parsed: ParsedGitUrl, kind: GitCredentialKind): string {
  switch (kind) {
    case "none":
      return repository;
    case "https":
      return `https://${parsed.host}/${parsed.path}`;
    case "ssh":
      return `ssh://git@${parsed.host}/${parsed.path}`;
  }
}

type ResolvedGitCredential =
  | { kind: "none" }
  | { kind: "https"; username: string; token: string }
  | { kind: "ssh"; entry: Extract<GitCredentialEntry, { kind: "ssh" }> };

// Request-level gitCredentials (always HTTPS/token-shaped) take priority;
// otherwise fall back to the server's own config, keyed by host, which may
// be HTTPS- or SSH-keyed. Whichever resolves determines the clone URL's
// protocol via toCloneUrl - this is what lets a caller pass an HTTPS URL
// for a host the server only has an SSH credential for, and vice versa.
function resolveGitCredential(host: string, req: BuildRequest): ResolvedGitCredential {
  if (req.gitCredentials) {
    return { kind: "https", username: req.gitCredentials.username, token: req.gitCredentials.token };
  }

  const entry = serviceConfig.gitCredentials.find((e) => e.host === host);
  if (!entry) return { kind: "none" };
  if (entry.kind === "https") return { kind: "https", username: entry.username, token: entry.token };
  return { kind: "ssh", entry };
}

function resolveRegistry(parsed: ParsedGitUrl, rules: RegistryMappingRule[]): string | undefined {
  for (const rule of rules) {
    if (rule.hostMatch && rule.hostMatch !== parsed.host) continue;
    if (rule.pathPrefix && !parsed.path.startsWith(rule.pathPrefix)) continue;
    return rule.registry;
  }
  return undefined;
}

function deriveImageName(path: string): string {
  const segments = path.replace(/\.git$/, "").split("/").filter(Boolean);
  return segments[segments.length - 1] ?? path;
}

export async function buildDevcontainer(req: BuildRequest): Promise<BuildResponse> {
  const branch = req.branch ?? "main";
  const parsed = parseGitUrl(req.repository);
  const gitCredential = resolveGitCredential(parsed.host, req);
  const cloneUrl = toCloneUrl(req.repository, parsed, gitCredential.kind);

  const workDir = await mkdtemp(join(tmpdir(), "devcontainer-build-"));
  const repoDir = join(workDir, "repo");

  try {
    const cloneArgs = ["clone", "--branch", branch, "--single-branch", "--depth", "1", cloneUrl, repoDir];

    if (gitCredential.kind === "https") {
      await withNetrcEnv(parsed.host, gitCredential.username, gitCredential.token, (env) =>
        run("git", cloneArgs, env),
      );
    } else if (gitCredential.kind === "ssh") {
      await withSshKeyEnv(parsed.host, gitCredential.entry, serviceConfig.sshHostKeyPolicy, (env) =>
        run("git", cloneArgs, env),
      );
    } else {
      // GIT_TERMINAL_PROMPT=0 only suppresses git's own (HTTPS-style)
      // credential prompts - it does nothing for the `ssh` subprocess git
      // spawns underneath for an ssh://SCP-style URL with no credential
      // configured. Without BatchMode=yes, an unrecognized host or a
      // rejected identity lets ssh fall through to an interactive host-key
      // confirmation or password prompt - invisible in automated testing
      // (no TTY attached, so ssh just fails immediately instead), but a
      // real hang risk for a backend service if one ever is attached.
      await run("git", cloneArgs, {
        ...process.env,
        GIT_TERMINAL_PROMPT: "0",
        GIT_SSH_COMMAND: "ssh -o BatchMode=yes",
      });
    }

    const { stdout: headSha } = await runCapture("git", ["rev-parse", "HEAD"], { cwd: repoDir });

    const name = req.image?.name ?? deriveImageName(parsed.path);
    const tag = req.image?.tag ?? `sha-${headSha.slice(0, 7)}`;
    const registry = req.image?.registry ?? resolveRegistry(parsed, serviceConfig.registryMappingRules);
    if (!registry) {
      throw new BuildRequestError(
        `no registry resolved for repository ${req.repository}: provide image.registry or configure a matching registry mapping rule`,
      );
    }
    const image = `${registry}/${name}:${tag}`;

    const platforms = req.platforms ?? serviceConfig.defaultPlatforms;
    const noCache = req.buildOptions?.noCache ?? serviceConfig.defaultBuildOptions.noCache;
    const cacheFrom = req.buildOptions?.cacheFrom ?? serviceConfig.defaultBuildOptions.cacheFrom;
    const cacheTo = req.buildOptions?.cacheTo ?? serviceConfig.defaultBuildOptions.cacheTo;
    const mode = req.buildOptions?.mode ?? serviceConfig.defaultBuildOptions.mode;

    const runBuild = async (env: NodeJS.ProcessEnv) => {
      await ensureRemoteBuilder(env);
      const args = ["build", "--workspace-folder", repoDir, "--image-name", image, "--push"];
      if (platforms.length > 0) args.push("--platform", platforms.join(","));
      if (noCache) args.push("--no-cache");
      if (cacheFrom) args.push("--cache-from", cacheFrom);
      if (cacheTo) args.push("--cache-to", cacheTo);
      if (mode) args.push("--buildkit", mode);
      await run("devcontainer", args, env);
    };

    if (req.registryCredentials) {
      await withRegistryAuthEnv(req.registryCredentials, runBuild);
    } else {
      await runBuild(process.env);
    }

    return { image, registry, name, tag };
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
}
