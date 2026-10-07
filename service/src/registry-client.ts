import { serviceConfig } from "./config.js";
import { readAmbientDockerAuth } from "./docker-config.js";

export interface RegistryAuthOverride {
  username: string;
  password: string;
}

// Thrown when the registry itself can't be reached, doesn't speak the
// distribution protocol we expect, or returns something we can't make
// sense of - maps to 502 in server.ts, distinct from a 400 (bad request
// shape) or a plain "not found" (which is a normal, successful answer for
// these endpoints, not an error).
export class RegistryUpstreamError extends Error {}

// The image exists, but is a multi-platform index with no entry for the
// requested platform - maps to 422 in server.ts (the caller asked for
// something this image genuinely doesn't have, not a registry failure).
export class PlatformNotFoundError extends Error {}

const MANIFEST_ACCEPT = [
  "application/vnd.oci.image.manifest.v1+json",
  "application/vnd.oci.image.index.v1+json",
  "application/vnd.docker.distribution.manifest.v2+json",
  "application/vnd.docker.distribution.manifest.list.v2+json",
].join(", ");

const CONFIG_ACCEPT = ["application/vnd.oci.image.config.v1+json", "application/vnd.docker.container.image.v1+json", "*/*"].join(", ");

// Manifests and image configs are small JSON documents (a few KiB); anything
// near this is not something we should be buffering into memory.
const MAX_JSON_BYTES = 4 * 1024 * 1024;

// `registry` as callers pass it (and as POST /build returns it) may carry a
// namespace path - `ghcr.io/deepspacecartel` - that belongs to the
// repository, not the host: the distribution API lives at
// `https://ghcr.io/v2/deepspacecartel/<name>/...`. An explicit
// http:// / https:// prefix is still honored as-is; otherwise plain http is
// used only for hosts listed in serviceConfig.insecureRegistries.
interface RegistryTarget {
  baseUrl: string;
  host: string;
  repository: string;
}

// Docker Hub's well-known names aren't its API host - `docker.io` itself
// redirects to the marketing site. Same mapping the Docker CLI applies.
const API_HOST_ALIASES: Record<string, string> = { "docker.io": "registry-1.docker.io", "index.docker.io": "registry-1.docker.io" };

function resolveTarget(registry: string, name: string): RegistryTarget {
  let scheme: "http" | "https" | undefined;
  let rest = registry;
  const schemeMatch = /^(https?):\/\//.exec(rest);
  if (schemeMatch) {
    scheme = schemeMatch[1] as "http" | "https";
    rest = rest.slice(schemeMatch[0].length);
  }
  rest = rest.replace(/\/+$/, "");

  const slash = rest.indexOf("/");
  const host = slash === -1 ? rest : rest.slice(0, slash);
  const prefix = slash === -1 ? "" : rest.slice(slash + 1);

  scheme ??= serviceConfig.insecureRegistries.includes(host) ? "http" : "https";
  return { baseUrl: `${scheme}://${API_HOST_ALIASES[host] ?? host}`, host, repository: prefix ? `${prefix}/${name}` : name };
}

function manifestUrl(target: RegistryTarget, ref: string): string {
  return `${target.baseUrl}/v2/${target.repository}/manifests/${ref}`;
}

function blobUrl(target: RegistryTarget, digest: string): string {
  return `${target.baseUrl}/v2/${target.repository}/blobs/${digest}`;
}

interface BearerChallenge {
  realm: string;
  service?: string;
  scope?: string;
}

// Parses `WWW-Authenticate: Bearer realm="...",service="...",scope="..."`
// per the OCI distribution spec's token-auth challenge, e.g. RFC 6750 +
// docker/distribution's token extension. Returns undefined for any other
// auth scheme - Basic (a plain htpasswd-backed registry) is handled
// separately in RegistrySession.request.
function parseBearerChallenge(header: string): BearerChallenge | undefined {
  if (!/^bearer\s/i.test(header)) return undefined;

  const params: Record<string, string> = {};
  const re = /(\w+)="([^"]*)"/g;
  let match: RegExpExecArray | null;
  while ((match = re.exec(header)) !== null) {
    params[match[1]] = match[2];
  }
  if (!params.realm) return undefined;
  return { realm: params.realm, service: params.service, scope: params.scope };
}

// One logical lookup's worth of registry requests (e.g. index -> platform
// manifest -> config blob), sharing one Authorization header across them
// instead of repeating the challenge/exchange for every request. Each
// request is issued with the current header (if any); on a 401 with a Basic
// challenge and credentials available, it retries once with them as-is; on
// a 401 with a Bearer challenge,
// it exchanges for a fresh token (Basic-authenticating the token request
// itself if `auth` is given, else anonymously - many registries allow
// anonymous pull-scope tokens) and retries exactly once. A challenge this
// doesn't understand, or a token exchange failure, surfaces as-is rather
// than looping or guessing. Redirects (blob downloads are commonly a 307 to
// object storage) are followed by fetch's default, which drops the
// Authorization header on a cross-origin hop - what pre-signed URLs need.
class RegistrySession {
  private authorization?: string;

  constructor(private readonly auth?: RegistryAuthOverride) {}

  async request(method: string, url: string, accept: string = MANIFEST_ACCEPT): Promise<Response> {
    const initial = await this.send(method, url, accept);
    if (initial.status !== 401) return initial;

    const challengeHeader = initial.headers.get("www-authenticate");
    if (!challengeHeader) return initial;

    if (/^basic\b/i.test(challengeHeader)) {
      if (!this.auth) return initial;
      this.authorization = `Basic ${Buffer.from(`${this.auth.username}:${this.auth.password}`).toString("base64")}`;
      return this.send(method, url, accept);
    }

    const challenge = parseBearerChallenge(challengeHeader);
    if (!challenge) return initial;

    this.authorization = `Bearer ${await this.exchange(challenge)}`;
    return this.send(method, url, accept);
  }

  private send(method: string, url: string, accept: string): Promise<Response> {
    const headers: Record<string, string> = { Accept: accept };
    if (this.authorization) headers.Authorization = this.authorization;
    return fetch(url, { method, headers });
  }

  private async exchange(challenge: BearerChallenge): Promise<string> {
    const tokenUrl = new URL(challenge.realm);
    if (challenge.service) tokenUrl.searchParams.set("service", challenge.service);
    if (challenge.scope) tokenUrl.searchParams.set("scope", challenge.scope);

    const tokenHeaders: Record<string, string> = {};
    if (this.auth) {
      tokenHeaders.Authorization = `Basic ${Buffer.from(`${this.auth.username}:${this.auth.password}`).toString("base64")}`;
    }

    const tokenRes = await fetch(tokenUrl, { headers: tokenHeaders });
    if (!tokenRes.ok) {
      throw new RegistryUpstreamError(`registry auth token request to ${challenge.realm} failed with status ${tokenRes.status}`);
    }

    const tokenBody = (await tokenRes.json()) as { token?: string; access_token?: string };
    const token = tokenBody.token ?? tokenBody.access_token;
    if (!token) {
      throw new RegistryUpstreamError(`registry auth token response from ${challenge.realm} did not include a token`);
    }
    return token;
  }
}

// Ambient credentials are keyed by whatever string the operator wrote into
// the Docker config - usually the bare host (`ghcr.io`), even when callers
// pass a namespaced registry (`ghcr.io/deepspacecartel`). Exact match first
// (same as build.ts's own push-credential lookup), then the host alone.
async function resolveAuth(
  registry: string,
  target: RegistryTarget,
  override?: RegistryAuthOverride,
): Promise<RegistryAuthOverride | undefined> {
  if (override) return override;
  return (await readAmbientDockerAuth(registry)) ?? (target.host !== registry ? await readAmbientDockerAuth(target.host) : undefined);
}

async function requestOrUpstreamError(session: RegistrySession, registry: string, method: string, url: string, accept?: string) {
  try {
    return await session.request(method, url, accept);
  } catch (err) {
    if (err instanceof RegistryUpstreamError) throw err;
    throw new RegistryUpstreamError(`failed to reach registry ${registry}: ${err instanceof Error ? err.message : err}`);
  }
}

async function readJson(res: Response, registry: string, what: string): Promise<Record<string, unknown>> {
  const declared = Number(res.headers.get("content-length") ?? "0");
  if (declared > MAX_JSON_BYTES) {
    throw new RegistryUpstreamError(`${what} from registry ${registry} is ${declared} bytes, over the ${MAX_JSON_BYTES} byte limit`);
  }
  const text = await res.text();
  if (text.length > MAX_JSON_BYTES) {
    throw new RegistryUpstreamError(`${what} from registry ${registry} is over the ${MAX_JSON_BYTES} byte limit`);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new RegistryUpstreamError(`${what} from registry ${registry} is not valid JSON`);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new RegistryUpstreamError(`${what} from registry ${registry} is not a JSON object`);
  }
  return parsed as Record<string, unknown>;
}

export async function manifestExists(
  registry: string,
  name: string,
  tag: string,
  override?: RegistryAuthOverride,
): Promise<{ exists: boolean; digest?: string }> {
  const target = resolveTarget(registry, name);
  const session = new RegistrySession(await resolveAuth(registry, target, override));
  return manifestExistsWith(session, target, registry, name, tag);
}

async function manifestExistsWith(
  session: RegistrySession,
  target: RegistryTarget,
  registry: string,
  name: string,
  tag: string,
): Promise<{ exists: boolean; digest?: string }> {
  const res = await requestOrUpstreamError(session, registry, "GET", manifestUrl(target, tag));

  if (res.status === 404) return { exists: false };
  if (res.status === 200) {
    return { exists: true, digest: res.headers.get("docker-content-digest") ?? undefined };
  }
  throw new RegistryUpstreamError(`unexpected response from registry ${registry} checking ${name}:${tag}: ${res.status}`);
}

export async function deleteManifest(
  registry: string,
  name: string,
  tag: string,
  override?: RegistryAuthOverride,
): Promise<{ deleted: boolean; reason?: string }> {
  const target = resolveTarget(registry, name);
  const session = new RegistrySession(await resolveAuth(registry, target, override));

  const { exists, digest } = await manifestExistsWith(session, target, registry, name, tag);
  if (!exists) return { deleted: true, reason: "already absent" };
  if (!digest) {
    throw new RegistryUpstreamError(`registry ${registry} did not return a manifest digest for ${name}:${tag}, cannot delete`);
  }

  const res = await requestOrUpstreamError(session, registry, "DELETE", manifestUrl(target, digest));

  if (res.status === 200 || res.status === 202 || res.status === 204) return { deleted: true };
  if (res.status === 404) return { deleted: true, reason: "already absent" };
  if (res.status === 405 || res.status === 400 || res.status === 501) {
    return { deleted: false, reason: "registry does not support manifest deletion" };
  }
  throw new RegistryUpstreamError(`unexpected response from registry ${registry} deleting ${name}:${tag}: ${res.status}`);
}

interface ManifestDescriptor {
  digest?: unknown;
  platform?: { os?: unknown; architecture?: unknown; variant?: unknown };
}

function describePlatform(p: ManifestDescriptor["platform"]): string {
  return [p?.os, p?.architecture, p?.variant].filter((v) => typeof v === "string" && v).join("/");
}

// `platform` is `os/arch[/variant]`; an omitted variant matches any.
// Attestation entries (`unknown/unknown`) never match a real platform.
function matchesPlatform(p: ManifestDescriptor["platform"], platform: string): boolean {
  const [os, architecture, variant] = platform.split("/");
  return p?.os === os && p?.architecture === architecture && (variant === undefined || p?.variant === variant);
}

export type ImageConfigLookup = { found: false } | { found: true; digest?: string; labels: Record<string, string> };

// Reads an image's config (for its labels) straight from the registry:
// manifest by tag -> if it's a multi-platform index, the entry for
// `platform` -> that manifest's config blob. `found: false` means the tag
// doesn't exist (a normal answer, like GET /image's `exists: false`).
export async function readImageConfig(
  registry: string,
  name: string,
  tag: string,
  platform: string,
  override?: RegistryAuthOverride,
): Promise<ImageConfigLookup> {
  const target = resolveTarget(registry, name);
  const session = new RegistrySession(await resolveAuth(registry, target, override));

  let res = await requestOrUpstreamError(session, registry, "GET", manifestUrl(target, tag));
  if (res.status === 404) return { found: false };
  if (res.status !== 200) {
    throw new RegistryUpstreamError(`unexpected response from registry ${registry} reading ${name}:${tag}: ${res.status}`);
  }
  let digest = res.headers.get("docker-content-digest") ?? undefined;
  let manifest = await readJson(res, registry, `manifest for ${name}:${tag}`);

  if (Array.isArray(manifest.manifests)) {
    const entries = manifest.manifests as ManifestDescriptor[];
    const entry = entries.find((m) => matchesPlatform(m.platform, platform));
    if (!entry || typeof entry.digest !== "string") {
      const available = entries
        .map((m) => describePlatform(m.platform))
        .filter((p) => p && p !== "unknown/unknown")
        .join(", ");
      throw new PlatformNotFoundError(`${name}:${tag} has no manifest for platform ${platform} (available: ${available || "none"})`);
    }
    digest = entry.digest;
    res = await requestOrUpstreamError(session, registry, "GET", manifestUrl(target, entry.digest));
    if (res.status !== 200) {
      throw new RegistryUpstreamError(`unexpected response from registry ${registry} reading ${name}@${entry.digest}: ${res.status}`);
    }
    manifest = await readJson(res, registry, `manifest for ${name}@${entry.digest}`);
  }

  const configDigest = (manifest.config as { digest?: unknown } | undefined)?.digest;
  if (typeof configDigest !== "string") {
    throw new RegistryUpstreamError(`manifest for ${name}:${tag} from registry ${registry} has no config digest`);
  }

  const blobRes = await requestOrUpstreamError(session, registry, "GET", blobUrl(target, configDigest), CONFIG_ACCEPT);
  if (blobRes.status !== 200) {
    throw new RegistryUpstreamError(`unexpected response from registry ${registry} reading config ${configDigest}: ${blobRes.status}`);
  }
  const imageConfig = await readJson(blobRes, registry, `image config ${configDigest}`);
  const rawLabels = (imageConfig.config as { Labels?: unknown } | undefined)?.Labels;

  const labels: Record<string, string> = {};
  if (typeof rawLabels === "object" && rawLabels !== null) {
    for (const [key, value] of Object.entries(rawLabels)) {
      if (typeof value === "string") labels[key] = value;
    }
  }
  return { found: true, digest, labels };
}
