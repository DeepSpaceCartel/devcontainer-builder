import { mkdtemp, mkdir, rm, writeFile, chmod, cp, readFile } from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { trace, SpanStatusCode } from "@opentelemetry/api";
import type { BuildRequest, BuildResponse, RegistryCredentials } from "./types.js";
import { serviceConfig, type GitCredentialEntry, type RegistryMappingRule, type SshHostKeyPolicy } from "./config.js";
import { logger } from "./logger.js";
import { openCommandLog, closeCommandLog, type CommandLogKind } from "./command-log.js";
import { CONFIG_LABEL, METADATA_LABEL, configLabelValue, parsePasswdEntry, remoteUserFor } from "./devcontainer-metadata.js";
import { readImageConfig } from "./registry-client.js";
import { BuildRequestError } from "./errors.js";
import { checkRepositoryUrl, gitAllowProtocol, redactUrlCredentials, type ParsedGitUrl } from "./git-url.js";
import { checkCacheOption, deriveImageName } from "./image-ref.js";
import { phaseTimeout, run, runCapture } from "./process.js";

export { BuildRequestError };

export function fallbackConfig(image: string): string {
  return JSON.stringify({ image }, null, 2) + "\n";
}

async function readFirstExisting(paths: string[]): Promise<string | undefined> {
  for (const path of paths) {
    try {
      return await readFile(path, "utf8");
    } catch {
      // try the next location
    }
  }
  return undefined;
}

// git clone and `devcontainer build --push` are both plain child_process
// subprocesses (see `run`/`runCapture` below) - OTel's auto-instrumentation
// only patches library calls (http/undici/fs/dns/...), never arbitrary
// subprocesses, so without this they're invisible inside a trace: the
// whole buildDevcontainer call shows as one flat span under the HTTP
// server span auto-instrumentation already provides. This wraps a phase
// in its own child span so it shows up nested under that request's trace.
const tracer = trace.getTracer("devcontainer-builder");

async function withSpan<T>(name: string, attributes: Record<string, string | number>, fn: () => Promise<T>): Promise<T> {
  return tracer.startActiveSpan(name, { attributes }, async (span) => {
    try {
      const result = await fn();
      span.setStatus({ code: SpanStatusCode.OK });
      return result;
    } catch (err) {
      span.recordException(err instanceof Error ? err : String(err));
      span.setStatus({ code: SpanStatusCode.ERROR, message: err instanceof Error ? err.message : String(err) });
      throw err;
    } finally {
      span.end();
    }
  });
}

// git clone / devcontainer build --push's own stdout+stderr used to be
// inherited straight onto this process's stdout (see `run` below before
// this change), interleaving raw text into the middle of the JSON log
// stream Pino writes everything else as. This captures that output into
// its own file (rotated per `serviceConfig.commandLogRetention`, see
// command-log.ts) instead, and reports only a small JSON breadcrumb - the
// file's id, fetchable via GET /logs/:id - through the normal structured
// logger. Not `request.log` (build.ts has no request context) - a plain
// `logger` call still gets trace.id/span.id injected automatically here
// because it runs inside the active span `fn` was called from.
async function withCommandLog<T>(
  kind: CommandLogKind,
  event: string,
  fn: (logStream: NodeJS.WritableStream) => Promise<T>,
): Promise<{ result: T; logId: string }> {
  const log = await openCommandLog(kind);
  try {
    const result = await fn(log.stream);
    return { result, logId: log.id };
  } catch (err) {
    (err as Error & { logId?: string }).logId = log.id;
    throw err;
  } finally {
    await closeCommandLog(log);
    logger.info({ event, "log.id": log.id });
  }
}

export function isReady(): { ready: boolean; reason?: string } {
  if (!serviceConfig.buildkitEndpoint) {
    return { ready: false, reason: "BUILDKIT_ENDPOINT not configured" };
  }
  return { ready: true };
}

// Runs `fn` at most once at a time and remembers its success: concurrent
// callers share the one in-flight attempt (made with the first caller's
// arguments), later callers get the settled result, and a failure is
// forgotten so the next caller retries.
export function onceUntilFailure<A extends unknown[], T>(fn: (...args: A) => Promise<T>): (...args: A) => Promise<T> {
  let pending: Promise<T> | undefined;
  return (...args) => {
    pending ??= fn(...args).catch((err) => {
      pending = undefined;
      throw err;
    });
    return pending;
  };
}

// `docker buildx create --driver remote` talks straight to the remote
// BuildKit daemon over TCP - no local dockerd is needed. Created once per
// process in the ambient DOCKER_CONFIG and serialized - two concurrent
// first builds used to both run `buildx create`, and one of them failed.
// Builds select it per child process via BUILDX_BUILDER (see builderEnv)
// instead of `buildx use`, which rewrote shared state on every request.
// withRegistryAuthEnv's scratch DOCKER_CONFIG copies the ambient one, so
// it finds the builder there too. Setup output lands in the log of the
// build that triggered it.
const ensureRemoteBuilder = onceUntilFailure(async (logStream: NodeJS.WritableStream, signal: AbortSignal) => {
  const endpoint = serviceConfig.buildkitEndpoint;
  if (!endpoint) {
    throw new Error("BUILDKIT_ENDPOINT is not configured");
  }
  try {
    await run("docker", ["buildx", "inspect", serviceConfig.buildxBuilderName], { logStream, signal });
  } catch {
    await run("docker", ["buildx", "create", "--name", serviceConfig.buildxBuilderName, "--driver", "remote", endpoint], {
      logStream,
      signal,
    });
  }
});

function builderEnv(env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return { ...env, BUILDX_BUILDER: serviceConfig.buildxBuilderName };
}

// The environment every git child process starts from: never prompt (a
// backend service has nobody to answer), and only the protocols a
// repository URL may use (GIT_ALLOW_PROTOCOL) - git then refuses others
// even when a redirect or remote config points elsewhere.
function gitBaseEnv(): NodeJS.ProcessEnv {
  return {
    ...process.env,
    GIT_TERMINAL_PROMPT: "0",
    GIT_ALLOW_PROTOCOL: gitAllowProtocol(serviceConfig.allowInsecureGitProtocols),
  };
}

// Git credentials go into a scratch `.netrc` (never argv or the remote URL)
// so they never show up in `ps` output or shell history/logs.
async function withNetrcEnv<T>(
  hostname: string,
  username: string,
  password: string,
  baseEnv: NodeJS.ProcessEnv,
  fn: (env: NodeJS.ProcessEnv) => Promise<T>,
): Promise<T> {
  const scratchHome = await mkdtemp(join(tmpdir(), "git-creds-"));
  const netrcPath = join(scratchHome, ".netrc");
  await writeFile(netrcPath, `machine ${hostname}\nlogin ${username}\npassword ${password}\n`);
  await chmod(netrcPath, 0o600);

  try {
    return await fn({ ...baseEnv, HOME: scratchHome });
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
  baseEnv: NodeJS.ProcessEnv,
  signal: AbortSignal,
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
      const scan = await runCapture("ssh-keyscan", ["-H", "--", host], { signal });
      await writeFile(knownHostsPath, `${scan.stdout}\n`);
    }
    await chmod(knownHostsPath, 0o600);

    const gitSshCommand = `ssh -i ${keyPath} -o UserKnownHostsFile=${knownHostsPath} -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o BatchMode=yes`;

    return await fn({ ...baseEnv, GIT_SSH_COMMAND: gitSshCommand });
  } finally {
    await rm(scratchDir, { recursive: true, force: true });
  }
}

// Per-request registry push credentials get a scratch DOCKER_CONFIG, seeded
// from the ambient one (config.json *and* buildx/ builder state) before
// merging in the override entry - seeding from ambient means BUILDX_BUILDER
// still names a builder that exists under the scratch dir (ensureRemoteBuilder
// creates it in the ambient one before this copy is made).
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

// No --branch when none was asked for: git then checks out the remote's
// own default branch (its HEAD), whatever that's called. `--` keeps a URL
// starting with "-" from being read as an option.
export function gitCloneArgs(branch: string | null | undefined, cloneUrl: string, dir: string): string[] {
  const branchArgs = branch ? ["--branch", branch] : [];
  return ["clone", ...branchArgs, "--single-branch", "--depth", "1", "--", cloneUrl, dir];
}

// The branch a clone made by gitCloneArgs checked out: the one asked for
// (which may also be a tag, leaving HEAD detached), else the remote's
// default branch, which is then the clone's current branch.
export async function clonedBranch(
  requested: string | null | undefined,
  repoDir: string,
  opts: { logStream?: NodeJS.WritableStream; signal?: AbortSignal } = {},
): Promise<string> {
  if (requested) return requested;
  return (await runCapture("git", ["symbolic-ref", "--short", "HEAD"], { cwd: repoDir, ...opts })).stdout;
}

// Everything about a request that can be rejected without touching the
// network or disk - checked before any clone starts, so a bad request is
// a 400 rather than a failure halfway through.
function checkBuildRequest(req: BuildRequest): ParsedGitUrl {
  const parsed = checkRepositoryUrl(req.repository, serviceConfig.allowInsecureGitProtocols);
  if (req.buildOptions?.cacheFrom) checkCacheOption("buildOptions.cacheFrom", req.buildOptions.cacheFrom);
  if (req.buildOptions?.cacheTo) checkCacheOption("buildOptions.cacheTo", req.buildOptions.cacheTo);
  return parsed;
}

export async function buildDevcontainer(req: BuildRequest): Promise<BuildResponse> {
  const parsed = checkBuildRequest(req);
  const name = req.image?.name ?? deriveImageName(parsed.path);
  const gitCredential = resolveGitCredential(parsed.host, req);
  const cloneUrl = toCloneUrl(req.repository, parsed, gitCredential.kind);
  // Redacted although checkBuildRequest already refuses URLs with
  // credentials in them - defense in depth for every log/span/error below.
  const repositoryForLogs = redactUrlCredentials(req.repository);

  const workDir = await mkdtemp(join(tmpdir(), "devcontainer-build-"));
  const repoDir = join(workDir, "repo");

  try {
    const cloneArgs = gitCloneArgs(req.branch, cloneUrl, repoDir);
    const cloneSpanAttributes: Record<string, string> = { "git.repository.url": repositoryForLogs };
    if (req.branch) cloneSpanAttributes["git.branch"] = req.branch;

    const cloneTimeout = phaseTimeout("git clone", serviceConfig.cloneTimeoutSeconds);
    const {
      result: { headSha, branch },
      logId: gitCloneLogId,
    } = await withSpan("git.clone", cloneSpanAttributes, () =>
      withCommandLog("git", "git.clone.output_captured", async (logStream) => {
        const { signal } = cloneTimeout;
        if (gitCredential.kind === "https") {
          await withNetrcEnv(parsed.host, gitCredential.username, gitCredential.token, gitBaseEnv(), (env) =>
            run("git", cloneArgs, { env, logStream, signal }),
          );
        } else if (gitCredential.kind === "ssh") {
          await withSshKeyEnv(parsed.host, gitCredential.entry, serviceConfig.sshHostKeyPolicy, gitBaseEnv(), signal, (env) =>
            run("git", cloneArgs, { env, logStream, signal }),
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
          await run("git", cloneArgs, { env: { ...gitBaseEnv(), GIT_SSH_COMMAND: "ssh -o BatchMode=yes" }, logStream, signal });
        }

        const { stdout: sha } = await runCapture("git", ["rev-parse", "HEAD"], { cwd: repoDir, logStream, signal });
        // The branch actually cloned: the one asked for, else the remote's
        // default branch, which a --branch-less clone checks out.
        return { headSha: sha, branch: await clonedBranch(req.branch, repoDir, { logStream, signal }) };
      }),
    ).finally(cloneTimeout.dispose);

    const tag = req.image?.tag ?? `sha-${headSha.slice(0, 7)}`;
    const registry = req.image?.registry ?? resolveRegistry(parsed, serviceConfig.registryMappingRules);
    if (!registry) {
      throw new BuildRequestError(
        `no registry resolved for repository ${repositoryForLogs}: provide image.registry or configure a matching registry mapping rule`,
      );
    }
    const image = `${registry}/${name}:${tag}`;

    const platforms = req.platforms ?? serviceConfig.defaultPlatforms;
    const noCache = req.buildOptions?.noCache ?? serviceConfig.defaultBuildOptions.noCache;
    const cacheFrom = req.buildOptions?.cacheFrom ?? serviceConfig.defaultBuildOptions.cacheFrom;
    const cacheTo = req.buildOptions?.cacheTo ?? serviceConfig.defaultBuildOptions.cacheTo;
    const mode = req.buildOptions?.mode ?? serviceConfig.defaultBuildOptions.mode;

    // devcontainer.json properties the CLI's own devcontainer.metadata label
    // leaves out (workspaceFolder, runArgs, initializeCommand), recorded in
    // the image too - see CONFIG_LABEL / ADR-0012. Same discovery order as
    // the CLI; an unparseable file gets no label (the CLI reports the real
    // error itself). Added by a second, layer-less build on top of the
    // pushed image rather than `devcontainer build --label`: the CLI only
    // forwards --label on its image+Features path, never for a
    // build.dockerfile config (checked in 0.89.0).
    let configText = await readFirstExisting([
      join(repoDir, ".devcontainer", "devcontainer.json"),
      join(repoDir, ".devcontainer.json"),
    ]);
    // No devcontainer.json at all: build the configured fallback image
    // instead of failing (ADR-0013), from a config written into this
    // scratch clone only - the repository never sees it, so a workspace
    // can tell the image came from the fallback and offer to add one.
    if (configText === undefined && serviceConfig.fallbackImage) {
      configText = fallbackConfig(serviceConfig.fallbackImage);
      await mkdir(join(repoDir, ".devcontainer"), { recursive: true });
      await writeFile(join(repoDir, ".devcontainer", "devcontainer.json"), configText);
      logger.info({ event: "build.config.fallback", "git.repository.url": repositoryForLogs, "container.image.name": serviceConfig.fallbackImage });
    }
    const configLabel = configText !== undefined ? configLabelValue(configText) : undefined;

    // The remote user's uid/gid/home, read from the pushed image's own
    // /etc/passwd by a throwaway BuildKit stage (`getent`, else a grep for
    // images without it) and exported as a single file - no layers come
    // back to this service. Recorded in the config label so a pod can run
    // as that user from the start (ADR-0012). Best effort: an image without
    // a shell, or a user missing from /etc/passwd, just gets no account.
    const probeRemoteUserAccount = async (env: NodeJS.ProcessEnv, logStream: NodeJS.WritableStream, signal: AbortSignal) => {
      try {
        const platform = platforms[0] ?? "linux/amd64";
        const auth = req.registryCredentials ? { username: req.registryCredentials.username, password: req.registryCredentials.password } : undefined;
        const pushed = await readImageConfig(registry, name, tag, platform, auth);
        const metadata = pushed.found ? pushed.labels[METADATA_LABEL] : undefined;
        if (!pushed.found || metadata === undefined) return {};
        const user = remoteUserFor(metadata, pushed.user);

        const probeDir = join(workDir, "user-probe");
        const outDir = join(probeDir, "out");
        await mkdir(outDir, { recursive: true });
        await writeFile(
          join(probeDir, "Dockerfile"),
          [
            `FROM ${image} AS probe`,
            `ARG DEVCONTAINER_USER`,
            `RUN (getent passwd "$DEVCONTAINER_USER" || grep -E "^$DEVCONTAINER_USER:|^[^:]*:[^:]*:$DEVCONTAINER_USER:" /etc/passwd) | head -n 1 > /devcontainer-user`,
            `FROM scratch`,
            `COPY --from=probe /devcontainer-user /`,
            ``,
          ].join("\n"),
        );
        const probeArgs = ["buildx", "build", "--build-arg", `DEVCONTAINER_USER=${user}`, "--platform", platform];
        probeArgs.push("--output", `type=local,dest=${outDir}`, probeDir);
        await run("docker", probeArgs, { env, logStream, signal });
        const account = parsePasswdEntry(await readFile(join(outDir, "devcontainer-user"), "utf8"));
        return account ? { remoteUserAccount: account } : {};
      } catch (err) {
        logStream.write(`remote user probe failed, continuing without it: ${err instanceof Error ? err.message : err}\n`);
        return {};
      }
    };

    const runBuild = async (baseEnv: NodeJS.ProcessEnv, logStream: NodeJS.WritableStream, signal: AbortSignal) => {
      const env = builderEnv(baseEnv);
      const args = ["build", "--workspace-folder", repoDir, "--image-name", image, "--push"];
      if (platforms.length > 0) args.push("--platform", platforms.join(","));
      if (noCache) args.push("--no-cache");
      if (cacheFrom) args.push("--cache-from", cacheFrom);
      if (cacheTo) args.push("--cache-to", cacheTo);
      if (mode) args.push("--buildkit", mode);
      await run("devcontainer", args, { env, logStream, signal });

      if (configLabel !== undefined) {
        const label = { ...JSON.parse(configLabel), ...(await probeRemoteUserAccount(env, logStream, signal)) };
        const labelDir = join(workDir, "config-label");
        await mkdir(labelDir, { recursive: true });
        await writeFile(join(labelDir, "Dockerfile"), `FROM ${image}\n`);
        const labelArgs = ["buildx", "build", "--push", "--label", `${CONFIG_LABEL}=${JSON.stringify(label)}`, "-t", image];
        if (platforms.length > 0) labelArgs.push("--platform", platforms.join(","));
        labelArgs.push(labelDir);
        await run("docker", labelArgs, { env, logStream, signal });
      }
    };

    const buildTimeout = phaseTimeout("image build and push", serviceConfig.buildTimeoutSeconds);
    const { logId: imageBuildLogId } = await withSpan(
      "image.build_push",
      { "image.registry": registry, "image.name": name, "image.tag": tag },
      () =>
        withCommandLog("docker", "image.build_push.output_captured", async (logStream) => {
          const { signal } = buildTimeout;
          // Before withRegistryAuthEnv copies the ambient DOCKER_CONFIG, so
          // the copy already has the builder in it.
          await ensureRemoteBuilder(logStream, signal);
          logStream.write(`using remote buildx builder ${serviceConfig.buildxBuilderName}\n`);
          await (req.registryCredentials
            ? withRegistryAuthEnv(req.registryCredentials, (env) => runBuild(env, logStream, signal))
            : runBuild(process.env, logStream, signal));
        }),
    ).finally(buildTimeout.dispose);

    return { image, registry, name, tag, branch, commit: headSha.trim(), gitCloneLogId, imageBuildLogId };
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
}
