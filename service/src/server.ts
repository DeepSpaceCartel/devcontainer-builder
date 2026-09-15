import { createServer, IncomingMessage, ServerResponse } from "node:http";
import { buildDevcontainer, isReady, serviceConfig, BuildRequestError } from "./build.js";
import { manifestExists, deleteManifest, RegistryUpstreamError, type RegistryAuthOverride } from "./registry-client.js";
import type { BuildRequest } from "./types.js";

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function isNonEmptyStringIfPresent(value: unknown): boolean {
  return value === undefined || value === null || (typeof value === "string" && value.length > 0);
}

function isValidBuildRequest(value: unknown): value is BuildRequest {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;

  if (typeof v.repository !== "string" || v.repository.length === 0) return false;
  if (!isNonEmptyStringIfPresent(v.branch)) return false;

  if (v.image !== undefined && v.image !== null) {
    if (typeof v.image !== "object") return false;
    const image = v.image as Record<string, unknown>;
    if (!isNonEmptyStringIfPresent(image.registry)) return false;
    if (!isNonEmptyStringIfPresent(image.name)) return false;
    if (!isNonEmptyStringIfPresent(image.tag)) return false;
  }

  if (v.gitCredentials !== undefined) {
    if (typeof v.gitCredentials !== "object" || v.gitCredentials === null) return false;
    const creds = v.gitCredentials as Record<string, unknown>;
    if (typeof creds.username !== "string" || typeof creds.token !== "string") return false;
  }

  if (v.registryCredentials !== undefined) {
    if (typeof v.registryCredentials !== "object" || v.registryCredentials === null) return false;
    const creds = v.registryCredentials as Record<string, unknown>;
    if (typeof creds.registry !== "string" || creds.registry.length === 0) return false;
    if (typeof creds.username !== "string" || creds.username.length === 0) return false;
    if (typeof creds.password !== "string" || creds.password.length === 0) return false;
  }

  if (v.platforms !== undefined) {
    if (!Array.isArray(v.platforms)) return false;
    if (!v.platforms.every((p) => typeof p === "string" && p.length > 0)) return false;
  }

  if (v.buildOptions !== undefined) {
    if (typeof v.buildOptions !== "object" || v.buildOptions === null) return false;
    const opts = v.buildOptions as Record<string, unknown>;
    if (opts.noCache !== undefined && typeof opts.noCache !== "boolean") return false;
    if (!isNonEmptyStringIfPresent(opts.cacheFrom)) return false;
    if (!isNonEmptyStringIfPresent(opts.cacheTo)) return false;
    if (opts.mode !== undefined && opts.mode !== "auto" && opts.mode !== "never") return false;
  }

  return true;
}

interface ImageQuery {
  registry: string;
  name: string;
  tag: string;
}

function parseImageQuery(url: URL): ImageQuery | undefined {
  const registry = url.searchParams.get("registry");
  const name = url.searchParams.get("name");
  const tag = url.searchParams.get("tag");
  if (!registry || !name || !tag) return undefined;
  return { registry, name, tag };
}

// Explicit per-call registry credentials for /image, mirroring
// registryCredentials on /build - deliberately headers, not query params,
// so they never land in access logs (same ADR-0002 rationale as the
// scratch-file pattern used elsewhere for credentials). Falls back to the
// service's ambient DOCKER_CONFIG auth (see registry-client.ts) when absent.
function readRegistryAuthHeaders(req: IncomingMessage): RegistryAuthOverride | undefined {
  const username = req.headers["x-registry-username"];
  const password = req.headers["x-registry-password"];
  if (typeof username === "string" && typeof password === "string" && username.length > 0 && password.length > 0) {
    return { username, password };
  }
  return undefined;
}

const server = createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health/live") {
    sendJson(res, 200, { status: "ok" });
    return;
  }

  if (req.method === "GET" && req.url === "/health/ready") {
    const readiness = isReady();
    if (readiness.ready) {
      sendJson(res, 200, { status: "ready" });
    } else {
      console.error(`readiness check failed: ${readiness.reason}`);
      sendJson(res, 503, { status: "not ready", reason: readiness.reason });
    }
    return;
  }

  const url = new URL(req.url ?? "/", "http://internal");

  if (req.method === "POST" && url.pathname === "/build") {
    let payload: unknown;
    try {
      payload = JSON.parse(await readBody(req));
    } catch {
      sendJson(res, 400, { error: "invalid JSON body" });
      return;
    }

    if (!isValidBuildRequest(payload)) {
      sendJson(res, 400, {
        error:
          "missing or invalid fields: repository (required); branch, image.{registry,name,tag}, " +
          "gitCredentials.{username,token}, registryCredentials.{registry,username,password}, " +
          "platforms, buildOptions.{noCache,cacheFrom,cacheTo,mode} (all optional)",
      });
      return;
    }

    try {
      const result = await buildDevcontainer(payload);
      sendJson(res, 200, result);
    } catch (err) {
      if (err instanceof BuildRequestError) {
        sendJson(res, 400, { error: err.message });
      } else {
        sendJson(res, 500, { error: err instanceof Error ? err.message : "build failed" });
      }
    }
    return;
  }

  if ((req.method === "GET" || req.method === "DELETE") && url.pathname === "/image") {
    const query = parseImageQuery(url);
    if (!query) {
      sendJson(res, 400, { error: "missing or invalid query parameters: registry, name, tag (all required)" });
      return;
    }

    const auth = readRegistryAuthHeaders(req);

    try {
      if (req.method === "GET") {
        const { exists } = await manifestExists(query.registry, query.name, query.tag, auth);
        sendJson(res, 200, { image: `${query.registry}/${query.name}:${query.tag}`, exists });
      } else {
        const result = await deleteManifest(query.registry, query.name, query.tag, auth);
        sendJson(res, 200, { image: `${query.registry}/${query.name}:${query.tag}`, ...result });
      }
    } catch (err) {
      if (err instanceof RegistryUpstreamError) {
        sendJson(res, 502, { error: err.message });
      } else {
        sendJson(res, 502, { error: err instanceof Error ? err.message : "registry request failed" });
      }
    }
    return;
  }

  sendJson(res, 404, { error: "not found" });
});

server.listen(serviceConfig.port, () => {
  console.log(`devcontainer-builder listening on :${serviceConfig.port}`);
});

// Running as PID 1 in the container (no init process) means the kernel's
// default disposition for signals doesn't apply - an unhandled SIGTERM is
// silently ignored rather than terminating the process, so a pod would
// otherwise sit through its full terminationGracePeriodSeconds (30s
// default) on every rollout/scale-down before kubelet resorts to SIGKILL.
process.on("SIGTERM", () => process.exit(0));
