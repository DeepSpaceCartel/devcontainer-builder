// POST /build request rejection, the build concurrency limit, registry
// scheme handling and the OpenAPI document - through the real Fastify app
// (inject, no port), with no cluster, registry or BuildKit involved: every
// request here is refused before anything is cloned, or (the concurrency
// test) clones from a local socket that never answers.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Socket } from "node:net";
import { once } from "node:events";
import type { FastifyInstance } from "fastify";
import { buildApp } from "./server.js";
import { serviceConfig } from "./config.js";
import { openCommandLog, closeCommandLog } from "./command-log.js";

let appPromise: Promise<FastifyInstance> | undefined;
function app(): Promise<FastifyInstance> {
  appPromise ??= buildApp();
  return appPromise;
}
after(async () => {
  if (appPromise) await (await appPromise).close();
});

async function postBuild(body: unknown) {
  const res = await (await app()).inject({ method: "POST", url: "/build", payload: body as object });
  return { status: res.statusCode, body: res.json() as { error?: string }, headers: res.headers };
}

const SHAPE_ERROR_PREFIX = "missing or invalid fields:";

test("a repository URL with credentials is a 400 that doesn't echo them", async () => {
  const res = await postBuild({ repository: "https://svc:ghp_secret@github.com/org/repo.git", image: { registry: "ghcr.io/org" } });
  assert.equal(res.status, 400);
  assert.match(res.body.error!, /gitCredentials/);
  assert.ok(!JSON.stringify(res.body).includes("ghp_secret"));
});

test("file:// and (without the opt-in) git:// and http:// repositories are a 400", async () => {
  for (const repository of ["file:///etc/some-repo.git", "git://git.example/org/repo.git", "http://git.example/org/repo.git"]) {
    const res = await postBuild({ repository });
    assert.equal(res.status, 400, repository);
    assert.match(res.body.error!, /is not allowed/);
  }
});

test("invalid image fields and platforms fail shape validation", async () => {
  for (const extra of [
    { image: { name: "MyRepo" } },
    { image: { registry: "http://registry.local:5000" } },
    { image: { tag: "-bad" } },
    { platforms: ["linux/amd64 --push"] },
    { platforms: ["linux/amd64,linux/arm64"] },
  ]) {
    const res = await postBuild({ repository: "https://github.com/org/repo.git", ...extra });
    assert.equal(res.status, 400, JSON.stringify(extra));
    assert.ok(res.body.error!.startsWith(SHAPE_ERROR_PREFIX), JSON.stringify(extra));
  }
});

test("a local (or other non-allowlisted) cache backend is a 400", async () => {
  const res = await postBuild({ repository: "https://github.com/org/repo.git", buildOptions: { cacheTo: "type=local,dest=/home/builder" } });
  assert.equal(res.status, 400);
  assert.equal(res.body.error, 'buildOptions.cacheTo: cache type "local" is not allowed (allowed: registry, gha, inline)');
});

test("a repository path with no usable image name and no image.name is a 400", async () => {
  const res = await postBuild({ repository: "https://github.com/org/___.git" });
  assert.equal(res.status, 400);
  assert.match(res.body.error!, /provide image\.name/);
});

test("past maxConcurrentBuilds, POST /build is a 429 with Retry-After", async () => {
  const saved = { max: serviceConfig.maxConcurrentBuilds, insecure: serviceConfig.allowInsecureGitProtocols };
  serviceConfig.maxConcurrentBuilds = 1;
  serviceConfig.allowInsecureGitProtocols = true;

  // A "git server" that accepts the connection and never answers, so the
  // first build sits in its clone until the socket is closed.
  const sockets: Socket[] = [];
  const stalled = createServer((socket) => sockets.push(socket));
  stalled.listen(0, "127.0.0.1");
  await once(stalled, "listening");
  const { port } = stalled.address() as { port: number };
  const connected = once(stalled, "connection");

  try {
    const first = postBuild({ repository: `git://127.0.0.1:${port}/org/repo.git`, image: { registry: "registry.local:5000" } });
    await connected;

    const second = await postBuild({ repository: "https://github.com/org/repo.git" });
    assert.equal(second.status, 429);
    assert.equal(second.headers["retry-after"], "30");

    for (const socket of sockets) socket.destroy();
    const firstRes = await first;
    assert.equal(firstRes.status, 500);
    // Usually "exited with code 128"; under load git can still be writing
    // its request when the socket is destroyed and die of SIGPIPE instead.
    assert.match(
      firstRes.body.error!,
      /^git clone --single-branch --depth 1 -- git:\/\/127\.0\.0\.1:\d+\/org\/repo\.git .* (exited with code \d+|was killed by SIG[A-Z]+)$/,
    );
  } finally {
    serviceConfig.maxConcurrentBuilds = saved.max;
    serviceConfig.allowInsecureGitProtocols = saved.insecure;
    stalled.close();
  }
});

test("an http:// registry not listed in insecureRegistries is a 400 on the registry endpoints", async () => {
  const instance = await app();
  for (const [method, url] of [
    ["GET", "/image?registry=http://ghcr.io/org&name=app&tag=v1"],
    ["DELETE", "/image?registry=http://ghcr.io/org&name=app&tag=v1"],
    ["GET", "/devcontainer?registry=http://ghcr.io/org&name=app&tag=v1"],
  ] as const) {
    const res = await instance.inject({ method, url });
    assert.equal(res.statusCode, 400, `${method} ${url}`);
    assert.match(res.json().error, /not in insecureRegistries/);
  }
});

test("GET /logs/{id} returns the captured text as text/plain; DELETE is a 204", async () => {
  const log = await openCommandLog("git");
  log.stream.write("Cloning into 'repo'...\n");
  await closeCommandLog(log);
  const res = await (await app()).inject({ method: "GET", url: `/logs/${log.id}` });
  assert.equal(res.statusCode, 200);
  assert.match(String(res.headers["content-type"]), /^text\/plain/);
  assert.equal(res.body, "Cloning into 'repo'...\n");
  const del = await (await app()).inject({ method: "DELETE", url: `/logs/${log.id}` });
  assert.equal(del.statusCode, 204);
});

test("the OpenAPI document covers the logs bodies, the 429 and the resolved branch", async () => {
  const doc = (await (await app()).inject({ method: "GET", url: "/documentation/json" })).json();
  assert.ok(doc.paths["/logs/{id}"].get.responses["200"].content["text/plain"]);
  assert.ok(doc.paths["/logs/{id}"].delete.responses["204"]);
  const build = doc.paths["/build"].post;
  assert.ok(build.responses["429"]);
  const ok = build.responses["200"].content["application/json"].schema;
  assert.ok(ok.required.includes("branch"));
  const image = build.requestBody.content["application/json"].schema.properties.image;
  assert.ok(JSON.stringify(image).includes("pattern"));
});
