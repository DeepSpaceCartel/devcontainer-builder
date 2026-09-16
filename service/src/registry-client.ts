import { readAmbientDockerAuth } from "./docker-config.js";

export interface RegistryAuthOverride {
  username: string;
  password: string;
}

// Thrown when the registry itself can't be reached, doesn't speak the
// distribution protocol we expect, or returns something we can't make
// sense of - maps to 502 in server.ts, distinct from a 400 (bad request
// shape) or a plain "not found" (which is a normal, successful answer for
// these two endpoints, not an error).
export class RegistryUpstreamError extends Error {}

const MANIFEST_ACCEPT = [
  "application/vnd.oci.image.manifest.v1+json",
  "application/vnd.oci.image.index.v1+json",
  "application/vnd.docker.distribution.manifest.v2+json",
  "application/vnd.docker.distribution.manifest.list.v2+json",
].join(", ");

function registryBaseUrl(registry: string): string {
  const base = registry.startsWith("http://") || registry.startsWith("https://") ? registry : `https://${registry}`;
  return base.replace(/\/$/, "");
}

function manifestUrl(registry: string, name: string, ref: string): string {
  return `${registryBaseUrl(registry)}/v2/${name}/manifests/${ref}`;
}

interface BearerChallenge {
  realm: string;
  service?: string;
  scope?: string;
}

// Parses `WWW-Authenticate: Bearer realm="...",service="...",scope="..."`
// per the OCI distribution spec's token-auth challenge, e.g. RFC 6750 +
// docker/distribution's token extension. Returns undefined for any other
// auth scheme (Basic, etc.) - not handled, no registry we target uses it
// for anonymous/service-account style pulls.
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

async function rawRequest(method: string, url: string, extraHeaders: Record<string, string>): Promise<Response> {
  return fetch(url, { method, headers: { Accept: MANIFEST_ACCEPT, ...extraHeaders } });
}

// Issues one request; on a 401 with a Bearer challenge, exchanges it for a
// token (Basic-authenticating the token request itself if `auth` is given,
// else anonymously - many registries allow anonymous pull-scope tokens) and
// retries exactly once with `Authorization: Bearer <token>`. A challenge
// this doesn't understand, or a token exchange failure, surfaces as-is
// rather than looping or guessing.
async function authorizedRequest(method: string, url: string, auth?: RegistryAuthOverride): Promise<Response> {
  const initial = await rawRequest(method, url, {});
  if (initial.status !== 401) return initial;

  const challengeHeader = initial.headers.get("www-authenticate");
  if (!challengeHeader) return initial;

  const challenge = parseBearerChallenge(challengeHeader);
  if (!challenge) return initial;

  const tokenUrl = new URL(challenge.realm);
  if (challenge.service) tokenUrl.searchParams.set("service", challenge.service);
  if (challenge.scope) tokenUrl.searchParams.set("scope", challenge.scope);

  const tokenHeaders: Record<string, string> = {};
  if (auth) {
    tokenHeaders.Authorization = `Basic ${Buffer.from(`${auth.username}:${auth.password}`).toString("base64")}`;
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

  return rawRequest(method, url, { Authorization: `Bearer ${token}` });
}

async function resolveAuth(registry: string, override?: RegistryAuthOverride): Promise<RegistryAuthOverride | undefined> {
  return override ?? (await readAmbientDockerAuth(registry));
}

export async function manifestExists(
  registry: string,
  name: string,
  tag: string,
  override?: RegistryAuthOverride,
): Promise<{ exists: boolean; digest?: string }> {
  const auth = await resolveAuth(registry, override);

  let res: Response;
  try {
    res = await authorizedRequest("GET", manifestUrl(registry, name, tag), auth);
  } catch (err) {
    throw new RegistryUpstreamError(`failed to reach registry ${registry}: ${err instanceof Error ? err.message : err}`);
  }

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
  const auth = await resolveAuth(registry, override);

  const { exists, digest } = await manifestExists(registry, name, tag, auth);
  if (!exists) return { deleted: true, reason: "already absent" };
  if (!digest) {
    throw new RegistryUpstreamError(`registry ${registry} did not return a manifest digest for ${name}:${tag}, cannot delete`);
  }

  let res: Response;
  try {
    res = await authorizedRequest("DELETE", manifestUrl(registry, name, digest), auth);
  } catch (err) {
    throw new RegistryUpstreamError(`failed to reach registry ${registry}: ${err instanceof Error ? err.message : err}`);
  }

  if (res.status === 200 || res.status === 202 || res.status === 204) return { deleted: true };
  if (res.status === 404) return { deleted: true, reason: "already absent" };
  if (res.status === 405 || res.status === 400 || res.status === 501) {
    return { deleted: false, reason: "registry does not support manifest deletion" };
  }
  throw new RegistryUpstreamError(`unexpected response from registry ${registry} deleting ${name}:${tag}: ${res.status}`);
}
