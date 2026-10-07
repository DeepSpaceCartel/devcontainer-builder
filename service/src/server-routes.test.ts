// Every route of buildApp() through Fastify's inject() - no port, no
// cluster: health probes, /config, /metrics, the 404 handler, POST /build's
// request rejection, /logs, and GET/DELETE /image and GET /devcontainer
// against a fake OCI registry on localhost (testing/fake-registry.ts).
// server.test.ts has the older POST /build validation and 429 cases.
import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import type { FastifyInstance } from "fastify";
import { buildApp } from "./server.js";
import { serviceConfig } from "./config.js";
import { openCommandLog, closeCommandLog } from "./command-log.js";
import { CONFIG_LABEL, METADATA_LABEL } from "./devcontainer-metadata.js";
import { FakeRegistry, startFakeRegistry } from "./testing/fake-registry.js";

let app: FastifyInstance;
let registry: FakeRegistry;
// The registry as callers pass it: host plus a namespace path.
let reg: string;
const savedInsecure = serviceConfig.insecureRegistries;

before(async () => {
  app = await buildApp();
  registry = await startFakeRegistry();
  reg = `${registry.host}/team`;
  serviceConfig.insecureRegistries = [registry.host];
});
after(async () => {
  serviceConfig.insecureRegistries = savedInsecure;
  await app.close();
  await registry.stop();
});
beforeEach(() => {
  registry.auth = { kind: "none" };
  registry.override = undefined;
  registry.deleteStatus = 202;
  registry.redirectBlobs = false;
  registry.requests.length = 0;
});

async function withConfig<T>(patch: Partial<typeof serviceConfig>, fn: () => Promise<T>): Promise<T> {
  const saved = Object.fromEntries(Object.keys(patch).map((k) => [k, serviceConfig[k as keyof typeof serviceConfig]]));
  Object.assign(serviceConfig, patch);
  try {
    return await fn();
  } finally {
    Object.assign(serviceConfig, saved);
  }
}

async function get(url: string, headers: Record<string, string> = {}) {
  const res = await app.inject({ method: "GET", url, headers });
  return { status: res.statusCode, json: () => res.json(), body: res.body, headers: res.headers };
}

const q = (name: string, tag: string, extra = "") => `registry=${encodeURIComponent(reg)}&name=${name}&tag=${tag}${extra}`;

// --- health, config, metrics, 404 ---------------------------------------

test("startup and liveness probes are always 200", async () => {
  assert.deepEqual((await get("/health/startup")).json(), { status: "started" });
  assert.deepEqual((await get("/health/live")).json(), { status: "ok" });
});

test("readiness is 503 without a BuildKit endpoint and 200 with one", async () => {
  await withConfig({ buildkitEndpoint: undefined }, async () => {
    const res = await get("/health/ready");
    assert.equal(res.status, 503);
    assert.deepEqual(res.json(), { status: "not ready", reason: "BUILDKIT_ENDPOINT not configured" });
  });
  await withConfig({ buildkitEndpoint: "tcp://buildkitd:1234" }, async () => {
    const res = await get("/health/ready");
    assert.equal(res.status, 200);
    assert.deepEqual(res.json(), { status: "ready" });
  });
});

test("GET /config reports settings but never a credential", async () => {
  await withConfig(
    {
      buildkitEndpoint: "tcp://buildkitd:1234",
      gitCredentials: [
        { host: "github.com", kind: "https", username: "bot", token: "ghp_never_shown" },
        { host: "git.example", kind: "ssh", privateKey: "-----BEGIN KEY never_shown" },
      ],
      registryAuthRegistries: ["ghcr.io"],
      maxConcurrentBuilds: 2,
    },
    async () => {
      const res = await get("/config");
      assert.equal(res.status, 200);
      const body = res.json();
      assert.equal(body.buildkitConfigured, true);
      assert.deepEqual(body.gitCredentials, [
        { host: "github.com", kind: "https" },
        { host: "git.example", kind: "ssh" },
      ]);
      assert.deepEqual(body.registryAuth, [{ registry: "ghcr.io" }]);
      assert.equal(body.maxConcurrentBuilds, 2);
      assert.deepEqual(body.insecureRegistries, [registry.host]);
      assert.ok(!res.body.includes("never_shown"));
      assert.ok(!res.body.includes("tcp://buildkitd"), "the endpoint itself is reported only as configured or not");
    },
  );
});

test("GET /metrics is Prometheus text with the service's own counters", async () => {
  registry.addImage("team/metrics-app", "v1");
  await get(`/image?${q("metrics-app", "v1")}`);
  const res = await get("/metrics");
  assert.equal(res.status, 200);
  assert.match(String(res.headers["content-type"]), /^text\/plain/);
  assert.match(res.body, /# TYPE devcontainer_builder_builds_total counter/);
  assert.match(res.body, /devcontainer_builder_image_checks_total\{result="exists"\} [1-9]/);
  assert.match(res.body, /process_cpu_user_seconds_total/);
});

test("an unknown route is a JSON 404", async () => {
  const res = await get("/nope");
  assert.equal(res.status, 404);
  assert.deepEqual(res.json(), { error: "not found" });
});

// --- POST /build rejections ------------------------------------------------

async function postBuild(payload: string | object, headers: Record<string, string> = { "content-type": "application/json" }) {
  const res = await app.inject({ method: "POST", url: "/build", payload, headers });
  return { status: res.statusCode, body: res.json() as { error: string; logId?: string } };
}

test("malformed or empty JSON is a 400 invalid JSON body", async () => {
  assert.deepEqual(await postBuild("{not json"), { status: 400, body: { error: "invalid JSON body" } });
  assert.deepEqual(await postBuild(""), { status: 400, body: { error: "invalid JSON body" } });
});

test("a body failing the shape check is a 400 naming the accepted fields", async () => {
  for (const payload of [
    {},
    [],
    { repository: "" },
    { repository: 42 },
    { repository: "https://x/y.git", gitCredentials: { username: "u" } },
  ]) {
    const res = await postBuild(payload);
    assert.equal(res.status, 400, JSON.stringify(payload));
    assert.match(res.body.error, /^missing or invalid fields: repository \(required\)/, JSON.stringify(payload));
  }
});

test("an unparseable repository URL is a 400 that doesn't echo credentials", async () => {
  const res = await postBuild({ repository: "not a url at all" });
  assert.equal(res.status, 400);
  assert.match(res.body.error, /^unable to parse git repository URL/);
});

test("repository userinfo: a token is refused on https and ssh, a bare ssh login is not", async () => {
  for (const repository of ["https://ghp_token@github.com/org/repo.git", "ssh://git:hunter2@git.example/org/repo.git"]) {
    const res = await postBuild({ repository });
    assert.equal(res.status, 400, repository);
    assert.match(res.body.error, /must not contain credentials/);
    assert.ok(!res.body.error.includes("ghp_token") && !res.body.error.includes("hunter2"));
  }
  // A bare ssh user passes URL checks; with no registry configured it fails
  // at the next, still pre-clone, check (pinned host key) - not on userinfo.
  await withConfig({ sshHostKeyPolicy: "pinned", gitCredentials: [{ host: "git.example", kind: "ssh", privateKey: "k" }] }, async () => {
    const res = await postBuild({ repository: "ssh://git@git.example/org/repo.git" });
    assert.equal(res.status, 400);
    assert.equal(res.body.error, 'SSH host key policy is "pinned" but no pinned key configured for host git.example');
  });
});

test("http:// and git:// repositories pass the scheme check once allowInsecureGitProtocols is on", async () => {
  // Still refused, but no longer for the scheme - for the userinfo.
  await withConfig({ allowInsecureGitProtocols: true }, async () => {
    const res = await postBuild({ repository: "http://u:p@git.local/org/repo.git" });
    assert.equal(res.status, 400);
    assert.match(res.body.error, /must not contain credentials/);
  });
});

test("cacheFrom is checked like cacheTo", async () => {
  const res = await postBuild({ repository: "https://github.com/org/repo.git", buildOptions: { cacheFrom: "type=local,src=/etc" } });
  assert.equal(res.status, 400);
  assert.equal(res.body.error, 'buildOptions.cacheFrom: cache type "local" is not allowed (allowed: registry, gha, inline)');
});

test("maxConcurrentBuilds: 0 means no limit, and a rejected request doesn't hold a slot", async () => {
  await withConfig({ maxConcurrentBuilds: 1 }, async () => {
    for (let i = 0; i < 3; i++) {
      // 400s, not 429s: each failed request released its slot.
      assert.equal((await postBuild({ repository: "file:///x" })).status, 400);
    }
  });
  await withConfig({ maxConcurrentBuilds: 0 }, async () => {
    assert.equal((await postBuild({ repository: "file:///x" })).status, 400);
  });
});

// --- /logs ---------------------------------------------------------------

test("/logs: a malformed id is a 400 on read and delete", async () => {
  for (const method of ["GET", "DELETE"] as const) {
    for (const id of ["nope", "git-not-a-uuid", "..%2F..%2Fetc%2Fpasswd", "other-00000000-0000-0000-0000-000000000000"]) {
      const res = await app.inject({ method, url: `/logs/${id}` });
      assert.equal(res.statusCode, 400, `${method} ${id}`);
      assert.match(res.json().error, /^id must look like a log id/);
    }
  }
});

test("/logs: an unknown id is a 404; a deleted one is gone", async () => {
  const unknown = "docker-00000000-0000-0000-0000-000000000000";
  assert.equal((await get(`/logs/${unknown}`)).status, 404);
  assert.equal((await app.inject({ method: "DELETE", url: `/logs/${unknown}` })).statusCode, 404);

  const log = await openCommandLog("docker");
  log.stream.write("#1 [internal] load build definition\n");
  await closeCommandLog(log);
  const read = await get(`/logs/${log.id}`);
  assert.equal(read.status, 200);
  assert.equal(read.headers["content-type"], "text/plain; charset=utf-8");
  assert.equal(read.body, "#1 [internal] load build definition\n");
  assert.equal((await app.inject({ method: "DELETE", url: `/logs/${log.id}` })).statusCode, 204);
  assert.equal((await get(`/logs/${log.id}`)).status, 404);
  assert.equal((await app.inject({ method: "DELETE", url: `/logs/${log.id}` })).statusCode, 404);
});

// --- GET/DELETE /image ------------------------------------------------------

test("GET /image: missing query parameters are a 400", async () => {
  for (const url of ["/image", `/image?registry=${reg}&name=app`, `/image?registry=${reg}&name=&tag=v1`]) {
    const res = await get(url);
    assert.equal(res.status, 400, url);
    assert.equal(res.json().error, "missing or invalid query parameters: registry, name, tag (all required)");
  }
});

test("GET /image: exists and absent, against an anonymous registry", async () => {
  registry.addImage("team/app", "v1");
  assert.deepEqual((await get(`/image?${q("app", "v1")}`)).json(), { image: `${reg}/app:v1`, exists: true });
  assert.deepEqual((await get(`/image?${q("app", "v2")}`)).json(), { image: `${reg}/app:v2`, exists: false });
  assert.equal(registry.requests[0].path, "/v2/team/app/manifests/v1");
  assert.match(registry.requests[0].accept!, /application\/vnd\.oci\.image\.index\.v1\+json/);
});

test("GET /image: X-Registry-Username/Password authenticate against a Basic-auth registry", async () => {
  registry.addImage("team/private", "v1");
  registry.auth = { kind: "basic", username: "alice", password: "s3cret" };

  // No credentials: the 401 is not a "doesn't exist" - it's an upstream error.
  const anonymous = await get(`/image?${q("private", "v1")}`);
  assert.equal(anonymous.status, 502);
  assert.match(anonymous.json().error, /unexpected response .* 401/);

  const wrong = await get(`/image?${q("private", "v1")}`, { "x-registry-username": "alice", "x-registry-password": "nope" });
  assert.equal(wrong.status, 502);

  const ok = await get(`/image?${q("private", "v1")}`, { "x-registry-username": "alice", "x-registry-password": "s3cret" });
  assert.deepEqual(ok.json(), { image: `${reg}/private:v1`, exists: true });
  // Only one of the pair is not a credential at all.
  assert.equal((await get(`/image?${q("private", "v1")}`, { "x-registry-username": "alice" })).status, 502);
});

test("GET /image: bearer challenge, token exchange with the caller's credentials, retry", async () => {
  registry.addImage("team/tokened", "v1");
  registry.auth = { kind: "bearer", username: "bob", password: "pw" };
  const res = await get(`/image?${q("tokened", "v1")}`, { "x-registry-username": "bob", "x-registry-password": "pw" });
  assert.deepEqual(res.json(), { image: `${reg}/tokened:v1`, exists: true });
  const token = registry.requests.find((r) => r.path.startsWith("/token"))!;
  assert.match(token.path, /service=fake-registry&scope=repository%3Ateam%2Ftokened%3Apull%2Cdelete/);
  assert.equal(token.authorization, `Basic ${Buffer.from("bob:pw").toString("base64")}`);
  assert.equal(registry.requests.at(-1)!.authorization, "Bearer fake-registry-token");

  const denied = await get(`/image?${q("tokened", "v1")}`, { "x-registry-username": "bob", "x-registry-password": "wrong" });
  assert.equal(denied.status, 502);
  assert.match(denied.json().error, /auth token request to .* failed with status 401/);
});

test("GET /image: a registry error or an unreachable registry is a 502", async () => {
  registry.override = () => ({ status: 500, body: "boom" });
  const res = await get(`/image?${q("app", "v1")}`);
  assert.equal(res.status, 502);
  assert.match(res.json().error, /unexpected response from registry .* checking app:v1: 500/);

  await withConfig({ insecureRegistries: ["127.0.0.1:1"] }, async () => {
    const down = await get(`/image?registry=127.0.0.1:1&name=app&tag=v1`);
    assert.equal(down.status, 502);
    assert.match(down.json().error, /^failed to reach registry 127\.0\.0\.1:1/);
  });
});

test("DELETE /image: deletes by digest, then reports already absent", async () => {
  const digest = registry.addImage("team/doomed", "v1");
  const res = await app.inject({ method: "DELETE", url: `/image?${q("doomed", "v1")}` });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json(), { image: `${reg}/doomed:v1`, deleted: true });
  assert.ok(registry.requests.some((r) => r.method === "DELETE" && r.path === `/v2/team/doomed/manifests/${digest}`));
  assert.equal(registry.hasManifest("team/doomed", "v1"), false);

  const again = await app.inject({ method: "DELETE", url: `/image?${q("doomed", "v1")}` });
  assert.deepEqual(again.json(), { image: `${reg}/doomed:v1`, deleted: true, reason: "already absent" });
});

test("DELETE /image: a registry without deletion support is a normal 200, not an error", async () => {
  registry.addImage("team/kept", "v1");
  for (const status of [405, 400, 501]) {
    registry.deleteStatus = status;
    const res = await app.inject({ method: "DELETE", url: `/image?${q("kept", "v1")}` });
    assert.equal(res.statusCode, 200, String(status));
    assert.deepEqual(res.json(), { image: `${reg}/kept:v1`, deleted: false, reason: "registry does not support manifest deletion" });
  }
  registry.deleteStatus = 404;
  assert.equal((await app.inject({ method: "DELETE", url: `/image?${q("kept", "v1")}` })).json().reason, "already absent");
});

test("DELETE /image: a 400 on bad query, 502 on a missing digest or an unexpected status", async () => {
  assert.equal((await app.inject({ method: "DELETE", url: "/image?name=x" })).statusCode, 400);

  registry.addImage("team/odd", "v1");
  registry.deleteStatus = 500;
  const failed = await app.inject({ method: "DELETE", url: `/image?${q("odd", "v1")}` });
  assert.equal(failed.statusCode, 502);
  assert.match(failed.json().error, /deleting odd:v1: 500/);

  registry.override = (req) => (req.method === "GET" ? { status: 200, body: "{}" } : undefined);
  const noDigest = await app.inject({ method: "DELETE", url: `/image?${q("odd", "v1")}` });
  assert.equal(noDigest.statusCode, 502);
  assert.match(noDigest.json().error, /did not return a manifest digest/);
});

// --- GET /devcontainer -----------------------------------------------------------

const METADATA = JSON.stringify([
  { id: "ghcr.io/devcontainers/features/node:1", onCreateCommand: "npm i -g pnpm" },
  { remoteUser: "vscode", postCreateCommand: "npm ci", customizations: { vscode: { extensions: ["dbaeumer.vscode-eslint"] } } },
]);
const CONFIG = JSON.stringify({ workspaceFolder: "/workspaces/app" });

test("GET /devcontainer: reads and merges the metadata label of a single-platform image", async () => {
  const digest = registry.addImage("team/dc", "v1", { labels: { [METADATA_LABEL]: METADATA, [CONFIG_LABEL]: CONFIG }, user: "root" });
  const res = await get(`/devcontainer?${q("dc", "v1")}`);
  assert.equal(res.status, 200, res.body);
  const body = res.json();
  assert.equal(body.image, `${reg}/dc:v1`);
  assert.equal(body.digest, digest);
  assert.equal(body.configuration.remoteUser, "vscode");
  assert.equal(body.metadata.length, 2);
  assert.match(body.lifecycleScripts.postCreateCommand, /npm ci/);
  assert.match(body.lifecycleScripts.onCreateCommand, /pnpm/);
  // The config blob was asked for as an image config, not a manifest.
  assert.match(registry.requests.find((r) => r.path.includes("/blobs/"))!.accept!, /application\/vnd\.oci\.image\.config\.v1\+json/);
});

test("GET /devcontainer: picks the requested platform out of an index (default linux/amd64)", async () => {
  registry.addIndex("team/multi", "v1", {
    "linux/amd64": { labels: { [METADATA_LABEL]: JSON.stringify([{ remoteUser: "amd" }]) } },
    "linux/arm64/v8": { labels: { [METADATA_LABEL]: JSON.stringify([{ remoteUser: "arm" }]) } },
  });
  assert.equal((await get(`/devcontainer?${q("multi", "v1")}`)).json().configuration.remoteUser, "amd");
  assert.equal((await get(`/devcontainer?${q("multi", "v1", "&platform=linux/arm64")}`)).json().configuration.remoteUser, "arm");
  assert.equal((await get(`/devcontainer?${q("multi", "v1", "&platform=linux/arm64/v8")}`)).json().configuration.remoteUser, "arm");

  const missing = await get(`/devcontainer?${q("multi", "v1", "&platform=linux/s390x")}`);
  assert.equal(missing.status, 422);
  assert.equal(missing.json().error, "multi:v1 has no manifest for platform linux/s390x (available: linux/amd64, linux/arm64/v8)");
});

test("GET /devcontainer: 404 for an absent tag, 422 for no or an invalid label", async () => {
  const absent = await get(`/devcontainer?${q("ghost", "v1")}`);
  assert.equal(absent.status, 404);
  assert.equal(absent.json().error, `no image ${reg}/ghost:v1 in the registry`);

  registry.addImage("team/plain", "v1", { labels: { "org.opencontainers.image.title": "plain" } });
  const plain = await get(`/devcontainer?${q("plain", "v1")}`);
  assert.equal(plain.status, 422);
  assert.match(plain.json().error, /has no devcontainer\.metadata label/);

  registry.addImage("team/broken", "v1", { labels: { [METADATA_LABEL]: "{not json" } });
  const broken = await get(`/devcontainer?${q("broken", "v1")}`);
  assert.equal(broken.status, 422);
  assert.match(broken.json().error, /label is not valid JSON/);
});

test("GET /devcontainer: blobs behind a redirect are followed", async () => {
  registry.addImage("team/redirected", "v1", { labels: { [METADATA_LABEL]: JSON.stringify([{ remoteUser: "r" }]) } });
  registry.redirectBlobs = true;
  const res = await get(`/devcontainer?${q("redirected", "v1")}`);
  assert.equal(res.status, 200, res.body);
  assert.ok(registry.requests.some((r) => r.path.startsWith("/redirected/")));
});

test("GET /devcontainer: bad query is a 400; an http:// registry not allowlisted is a 400", async () => {
  for (const url of ["/devcontainer?name=x&tag=y", `/devcontainer?${q("x", "y", "&platform=linux")}`]) {
    const res = await get(url);
    assert.equal(res.status, 400, url);
    assert.match(res.json().error, /^missing or invalid query parameters/);
  }
  await withConfig({ insecureRegistries: [] }, async () => {
    const res = await get(`/devcontainer?registry=http://${registry.host}&name=x&tag=y`);
    assert.equal(res.status, 400);
    assert.match(res.json().error, /not in insecureRegistries/);
  });
});

test("GET /devcontainer: malformed registry answers are 502s", async () => {
  registry.addImage("team/bad", "v1");
  const cases: Array<[(path: string) => { status: number; body?: string; headers?: Record<string, string> } | undefined, RegExp]> = [
    [
      (p) => (p.includes("/manifests/") ? { status: 200, body: "not json" } : undefined),
      /manifest for bad:v1 from registry .* is not valid JSON/,
    ],
    [(p) => (p.includes("/manifests/") ? { status: 200, body: "[1,2]" } : undefined), /is not a JSON object/],
    [(p) => (p.includes("/manifests/") ? { status: 200, body: "{}" } : undefined), /has no config digest/],
    [(p) => (p.includes("/manifests/") ? { status: 503 } : undefined), /reading bad:v1: 503/],
    [(p) => (p.includes("/blobs/") ? { status: 500 } : undefined), /reading config sha256:[0-9a-f]+: 500/],
  ];
  for (const [override, expected] of cases) {
    registry.override = (req) => override(req.url ?? "");
    const res = await get(`/devcontainer?${q("bad", "v1")}`);
    assert.equal(res.status, 502, String(expected));
    assert.match(res.json().error, expected);
  }
});
