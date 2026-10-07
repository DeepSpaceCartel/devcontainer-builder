// registry-client.ts's auth negotiation and response handling against the
// fake registry (testing/fake-registry.ts): ambient Docker-config
// credentials, the bearer token exchange's edge cases, challenges it
// doesn't understand, and oversized/odd bodies.
import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { serviceConfig } from "./config.js";
import { deleteManifest, manifestExists, readImageConfig, RegistryUpstreamError, resolveTarget } from "./registry-client.js";
import { FakeRegistry, startFakeRegistry } from "./testing/fake-registry.js";

let registry: FakeRegistry;
const savedInsecure = serviceConfig.insecureRegistries;
const savedDockerConfig = process.env.DOCKER_CONFIG;

before(async () => {
  registry = await startFakeRegistry();
  serviceConfig.insecureRegistries = [registry.host];
  registry.addImage("team/app", "v1", { labels: { a: "1", notAString: 2 as unknown as string }, user: "dev" });
});
after(async () => {
  serviceConfig.insecureRegistries = savedInsecure;
  if (savedDockerConfig === undefined) delete process.env.DOCKER_CONFIG;
  else process.env.DOCKER_CONFIG = savedDockerConfig;
  await registry.stop();
});
beforeEach(() => {
  registry.auth = { kind: "none" };
  registry.override = undefined;
  registry.requests.length = 0;
  process.env.DOCKER_CONFIG = mkdtempSync(join(tmpdir(), "dcb-docker-"));
});

function writeDockerConfig(auths: Record<string, string>): void {
  const entries = Object.fromEntries(Object.entries(auths).map(([k, v]) => [k, { auth: Buffer.from(v).toString("base64") }]));
  writeFileSync(join(process.env.DOCKER_CONFIG!, "config.json"), JSON.stringify({ auths: entries }));
}

test("ambient credentials: an exact registry match is used", async () => {
  registry.auth = { kind: "basic", username: "ops", password: "ambient" };
  writeDockerConfig({ [`${registry.host}/team`]: "ops:ambient" });
  const { exists, digest } = await manifestExists(`${registry.host}/team`, "app", "v1");
  assert.equal(exists, true);
  assert.match(digest!, /^sha256:[0-9a-f]{64}$/);
  assert.equal(registry.requests.at(-1)!.authorization, `Basic ${Buffer.from("ops:ambient").toString("base64")}`);
});

test("ambient credentials: a namespaced registry falls back to the bare host's entry", async () => {
  registry.auth = { kind: "bearer", username: "ops", password: "ambient" };
  writeDockerConfig({ [registry.host]: "ops:ambient" });
  assert.equal((await manifestExists(`${registry.host}/team`, "app", "v1")).exists, true);
});

test("explicit credentials win over ambient ones", async () => {
  registry.auth = { kind: "basic", username: "caller", password: "explicit" };
  writeDockerConfig({ [registry.host]: "ops:ambient" });
  assert.equal((await manifestExists(`${registry.host}/team`, "app", "v1", { username: "caller", password: "explicit" })).exists, true);
  await assert.rejects(manifestExists(`${registry.host}/team`, "app", "v1"), /401/);
});

test("bearer: anonymous token exchange when no credentials exist", async () => {
  registry.auth = { kind: "bearer" };
  const lookup = await readImageConfig(`${registry.host}/team`, "app", "v1", "linux/amd64");
  assert.deepEqual(lookup.found && { labels: lookup.labels, user: lookup.user }, { labels: { a: "1" }, user: "dev" });
  const token = registry.requests.find((r) => r.path.startsWith("/token"))!;
  assert.equal(token.authorization, undefined);
  // One exchange per session, reused for the manifest and the config blob.
  assert.equal(registry.requests.filter((r) => r.path.startsWith("/token")).length, 1);
});

test("bearer: access_token is accepted in place of token; no token at all is an upstream error", async () => {
  registry.auth = { kind: "bearer" };
  registry.override = (req) =>
    req.url!.startsWith("/token") ? { status: 200, body: JSON.stringify({ access_token: "fake-registry-token" }) } : undefined;
  assert.equal((await manifestExists(`${registry.host}/team`, "app", "v1")).exists, true);

  registry.override = (req) => (req.url!.startsWith("/token") ? { status: 200, body: "{}" } : undefined);
  await assert.rejects(manifestExists(`${registry.host}/team`, "app", "v1"), (err: Error) => {
    assert.ok(err instanceof RegistryUpstreamError);
    assert.match(err.message, /did not include a token/);
    return true;
  });
});

test("a challenge the client doesn't understand surfaces as the 401 itself", async () => {
  for (const header of ['Digest realm="x"', 'Bearer service="no-realm"', ""]) {
    registry.override = (req) =>
      req.url!.startsWith("/v2/")
        ? { status: 401, headers: header ? { "www-authenticate": header } : ({} as Record<string, string>) }
        : undefined;
    await assert.rejects(manifestExists(`${registry.host}/team`, "app", "v1"), /checking app:v1: 401/, header);
    assert.equal(registry.requests.filter((r) => r.path.startsWith("/token")).length, 0);
  }
});

test("Basic challenge without any credentials doesn't retry", async () => {
  registry.auth = { kind: "basic", username: "u", password: "p" };
  await assert.rejects(manifestExists(`${registry.host}/team`, "app", "v1"), /401/);
  assert.equal(registry.requests.length, 1);
});

test("a body declaring more than 4 MiB is refused before it is read", async () => {
  registry.override = (req) =>
    req.url!.includes("/manifests/") ? { status: 200, body: "{}", headers: { "content-length": String(5 * 1024 * 1024) } } : undefined;
  await assert.rejects(readImageConfig(`${registry.host}/team`, "app", "v1", "linux/amd64"), /over the 4194304 byte limit/);
});

test("an index whose entries can't be fetched is an upstream error; one with no platforms says none", async () => {
  const index = registry.addIndex("team/idx", "v1", { "linux/amd64": {} });
  registry.override = (req) => (req.url!.includes("/manifests/sha256:") && !req.url!.endsWith(index) ? { status: 500 } : undefined);
  await assert.rejects(readImageConfig(`${registry.host}/team`, "idx", "v1", "linux/amd64"), /reading idx@sha256:[0-9a-f]+: 500/);

  registry.override = undefined;
  registry.putManifest("team/empty", { schemaVersion: 2, manifests: [] }, "application/vnd.oci.image.index.v1+json", "v1");
  await assert.rejects(readImageConfig(`${registry.host}/team`, "empty", "v1", "linux/amd64"), /\(available: none\)/);
});

test("deleteManifest reports an already-absent tag without issuing a DELETE", async () => {
  assert.deepEqual(await deleteManifest(`${registry.host}/team`, "never", "v1"), { deleted: true, reason: "already absent" });
  assert.equal(registry.requests.filter((r) => r.method === "DELETE").length, 0);
});

test("resolveTarget: trailing slashes, index.docker.io and an https:// override of an insecure host", () => {
  assert.deepEqual(resolveTarget("ghcr.io/org/", "app"), { baseUrl: "https://ghcr.io", host: "ghcr.io", repository: "org/app" });
  assert.equal(resolveTarget("index.docker.io", "node").baseUrl, "https://registry-1.docker.io");
  assert.equal(resolveTarget(`https://${registry.host}/team`, "app").baseUrl, `https://${registry.host}`);
  assert.equal(resolveTarget("a.example/b/c", "app").repository, "b/c/app");
});
