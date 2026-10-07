// Registry scheme policy and request timeouts, against local sockets only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { once } from "node:events";
import { serviceConfig } from "./config.js";
import { InvalidRegistryError, manifestExists, registryRequestLimits, RegistryUpstreamError, resolveTarget } from "./registry-client.js";

test("an http:// registry is refused unless its host is in insecureRegistries", () => {
  assert.throws(() => resolveTarget("http://ghcr.io/org", "app"), InvalidRegistryError);
  const saved = serviceConfig.insecureRegistries;
  serviceConfig.insecureRegistries = ["registry.local:5000"];
  try {
    assert.equal(resolveTarget("http://registry.local:5000/team", "app").baseUrl, "http://registry.local:5000");
    assert.equal(resolveTarget("registry.local:5000", "app").baseUrl, "http://registry.local:5000");
  } finally {
    serviceConfig.insecureRegistries = saved;
  }
});

test("https:// and bare registries resolve to https", () => {
  assert.deepEqual(resolveTarget("https://ghcr.io/org", "app"), { baseUrl: "https://ghcr.io", host: "ghcr.io", repository: "org/app" });
  assert.equal(resolveTarget("docker.io/library", "node").baseUrl, "https://registry-1.docker.io");
});

test("a registry that never answers fails with a timeout instead of hanging", async () => {
  const stalled = createServer(() => {
    // accept, never respond
  });
  stalled.listen(0, "127.0.0.1");
  await once(stalled, "listening");
  const { port } = stalled.address() as { port: number };
  const host = `127.0.0.1:${port}`;
  const saved = { insecure: serviceConfig.insecureRegistries, timeout: registryRequestLimits.timeoutMs };
  serviceConfig.insecureRegistries = [host];
  registryRequestLimits.timeoutMs = 200;
  try {
    await assert.rejects(manifestExists(host, "app", "v1", { username: "u", password: "p" }), (err: Error) => {
      assert.ok(err instanceof RegistryUpstreamError);
      assert.match(err.message, /timeout/i);
      return true;
    });
  } finally {
    serviceConfig.insecureRegistries = saved.insecure;
    registryRequestLimits.timeoutMs = saved.timeout;
    stalled.closeAllConnections();
    stalled.close();
  }
});
