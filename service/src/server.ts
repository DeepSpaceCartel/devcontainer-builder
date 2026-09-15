import { createServer, IncomingMessage, ServerResponse } from "node:http";
import { buildDevcontainer, isReady, serviceConfig, BuildRequestError } from "./build.js";
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

  return true;
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

  if (req.method !== "POST" || req.url !== "/build") {
    sendJson(res, 404, { error: "not found" });
    return;
  }

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
        "gitCredentials.{username,token}, registryCredentials.{registry,username,password} (all optional)",
    });
    return;
  }

  try {
    const image = await buildDevcontainer(payload);
    sendJson(res, 200, { image });
  } catch (err) {
    if (err instanceof BuildRequestError) {
      sendJson(res, 400, { error: err.message });
    } else {
      sendJson(res, 500, { error: err instanceof Error ? err.message : "build failed" });
    }
  }
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
