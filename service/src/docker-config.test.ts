// readAmbientDockerAuth: the ambient Docker config.json the /image and
// /devcontainer endpoints read registry credentials from.
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readAmbientDockerAuth } from "./docker-config.js";

const saved = { DOCKER_CONFIG: process.env.DOCKER_CONFIG, HOME: process.env.HOME };
afterEach(() => {
  for (const [k, v] of Object.entries(saved))
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
});

function dockerConfigDir(content?: string): string {
  const dir = mkdtempSync(join(tmpdir(), "dcb-docker-config-"));
  if (content !== undefined) writeFileSync(join(dir, "config.json"), content);
  return dir;
}

const b64 = (s: string) => Buffer.from(s).toString("base64");

test("decodes user:password for the exact registry key; a password may contain colons", async () => {
  process.env.DOCKER_CONFIG = dockerConfigDir(
    JSON.stringify({ auths: { "ghcr.io": { auth: b64("bot:pa:ss") }, "ghcr.io/org": { auth: b64("org:x") } } }),
  );
  assert.deepEqual(await readAmbientDockerAuth("ghcr.io"), { username: "bot", password: "pa:ss" });
  assert.deepEqual(await readAmbientDockerAuth("ghcr.io/org"), { username: "org", password: "x" });
  assert.equal(await readAmbientDockerAuth("docker.io"), undefined);
});

test("without DOCKER_CONFIG, falls back to $HOME/.docker/config.json", async () => {
  delete process.env.DOCKER_CONFIG;
  const home = mkdtempSync(join(tmpdir(), "dcb-home-"));
  const docker = join(home, ".docker");
  mkdirSync(docker);
  writeFileSync(join(docker, "config.json"), JSON.stringify({ auths: { "quay.io": { auth: b64("q:p") } } }));
  process.env.HOME = home;
  assert.deepEqual(await readAmbientDockerAuth("quay.io"), { username: "q", password: "p" });
});

test("a missing, unparsable or incomplete config is simply no credentials", async () => {
  for (const content of [
    undefined,
    "{not json",
    "{}",
    JSON.stringify({ auths: { "ghcr.io": {} } }),
    JSON.stringify({ auths: { "ghcr.io": { auth: b64("no-separator") } } }),
  ]) {
    process.env.DOCKER_CONFIG = dockerConfigDir(content);
    assert.equal(await readAmbientDockerAuth("ghcr.io"), undefined, String(content));
  }
});
