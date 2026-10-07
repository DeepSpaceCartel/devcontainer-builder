// Finding every devcontainer.json in a clone, and turning it into the
// response's images list (ADR-0016) - plain temp directories, no git.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { BuildRequestError } from "./errors.js";
import { discoverConfigs, instanceIdFor, instanceImageName, isRootConfigPath, selectInstances } from "./config-discovery.js";

test("root config paths are the two the CLI finds without --config", () => {
  assert.ok(isRootConfigPath(".devcontainer/devcontainer.json"));
  assert.ok(isRootConfigPath(".devcontainer.json"));
  assert.ok(!isRootConfigPath(".devcontainer/main/devcontainer.json"));
});

function repoWith(...paths: string[]): string {
  const dir = mkdtempSync(join(tmpdir(), "config-discovery-"));
  for (const path of paths) {
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), '{ "image": "mcr.microsoft.com/devcontainers/base:alpine-3.20" }\n');
  }
  return dir;
}

test("discovery: a root .devcontainer.json alone is main", async () => {
  assert.deepEqual(await discoverConfigs(repoWith(".devcontainer.json")), [{ id: "main", configPath: ".devcontainer.json" }]);
});

test("discovery: .devcontainer/devcontainer.json alone is main", async () => {
  assert.deepEqual(await discoverConfigs(repoWith(".devcontainer/devcontainer.json")), [
    { id: "main", configPath: ".devcontainer/devcontainer.json" },
  ]);
});

test("discovery: .devcontainer/devcontainer.json wins over .devcontainer.json, as in the CLI", async () => {
  assert.deepEqual(await discoverConfigs(repoWith(".devcontainer.json", ".devcontainer/devcontainer.json")), [
    { id: "main", configPath: ".devcontainer/devcontainer.json" },
  ]);
});

test("discovery: no config anywhere is an empty list", async () => {
  assert.deepEqual(await discoverConfigs(repoWith("README.md")), []);
  assert.deepEqual(await discoverConfigs(repoWith(".devcontainer/Dockerfile")), []);
});

test("discovery: sub-folders only, sorted by id, no main", async () => {
  assert.deepEqual(
    await discoverConfigs(repoWith(".devcontainer/frontend/devcontainer.json", ".devcontainer/backend/devcontainer.json")),
    [
      { id: "backend", configPath: ".devcontainer/backend/devcontainer.json" },
      { id: "frontend", configPath: ".devcontainer/frontend/devcontainer.json" },
    ],
  );
});

test("discovery: root config first, then the sub-folders", async () => {
  assert.deepEqual(
    await discoverConfigs(repoWith(".devcontainer/zeta/devcontainer.json", ".devcontainer.json", ".devcontainer/alpha/devcontainer.json")),
    [
      { id: "main", configPath: ".devcontainer.json" },
      { id: "alpha", configPath: ".devcontainer/alpha/devcontainer.json" },
      { id: "zeta", configPath: ".devcontainer/zeta/devcontainer.json" },
    ],
  );
});

test("discovery: only one level deep, only devcontainer.json, and folders without one are skipped", async () => {
  assert.deepEqual(
    await discoverConfigs(
      repoWith(
        ".devcontainer/a/b/devcontainer.json",
        ".devcontainer/c/.devcontainer.json",
        ".devcontainer/d/Dockerfile",
        ".devcontainer/e/devcontainer.json",
      ),
    ),
    [{ id: "e", configPath: ".devcontainer/e/devcontainer.json" }],
  );
});

test("discovery: symlinked sub-folders and files are ignored", async () => {
  const outside = repoWith("elsewhere/devcontainer.json");
  const dir = repoWith(".devcontainer/real/devcontainer.json");
  symlinkSync(join(outside, "elsewhere"), join(dir, ".devcontainer", "linked"));
  mkdirSync(join(dir, ".devcontainer", "filelink"));
  symlinkSync(join(outside, "elsewhere", "devcontainer.json"), join(dir, ".devcontainer", "filelink", "devcontainer.json"));
  assert.deepEqual(await discoverConfigs(dir), [{ id: "real", configPath: ".devcontainer/real/devcontainer.json" }]);
});

test("instance ids: lower-cased, [a-z0-9-] only, no leading/trailing dashes", () => {
  assert.equal(instanceIdFor("backend"), "backend");
  assert.equal(instanceIdFor("Back_End"), "back-end");
  assert.equal(instanceIdFor("node.js 22"), "node-js-22");
  assert.equal(instanceIdFor(".hidden_"), "hidden");
  assert.equal(instanceIdFor("___"), "");
});

test("discovery: two folders with the same id are a 400 naming both", async () => {
  await assert.rejects(
    discoverConfigs(repoWith(".devcontainer/Back_End/devcontainer.json", ".devcontainer/back-end/devcontainer.json")),
    (err: Error) =>
      err instanceof BuildRequestError &&
      /"back-end"/.test(err.message) &&
      err.message.includes(".devcontainer/Back_End/devcontainer.json") &&
      err.message.includes(".devcontainer/back-end/devcontainer.json"),
  );
});

test("discovery: a folder named main collides with the root config", async () => {
  await assert.rejects(
    discoverConfigs(repoWith(".devcontainer.json", ".devcontainer/Main/devcontainer.json")),
    (err: Error) => err instanceof BuildRequestError && /"main" \(\.devcontainer\.json, \.devcontainer\/Main\/devcontainer\.json\)/.test(err.message),
  );
});

test("discovery: a folder named main without a root config is just main", async () => {
  assert.deepEqual(await discoverConfigs(repoWith(".devcontainer/main/devcontainer.json")), [
    { id: "main", configPath: ".devcontainer/main/devcontainer.json" },
  ]);
});

test("discovery: a folder name with no usable characters is a 400", async () => {
  await assert.rejects(
    discoverConfigs(repoWith(".devcontainer/___/devcontainer.json")),
    (err: Error) => err instanceof BuildRequestError && err.message.includes(".devcontainer/___"),
  );
});

const items = [
  { id: "main", configPath: ".devcontainer/devcontainer.json" },
  { id: "backend", configPath: ".devcontainer/backend/devcontainer.json" },
  { id: "frontend", configPath: ".devcontainer/frontend/devcontainer.json" },
];

test("instances filter: omitted or null selects everything", () => {
  assert.deepEqual(selectInstances(items, undefined), items);
  assert.deepEqual(selectInstances(items, null), items);
});

test("instances filter: keeps discovery order, ignores duplicates", () => {
  assert.deepEqual(
    selectInstances(items, ["frontend", "main", "frontend"]).map((i) => i.id),
    ["main", "frontend"],
  );
});

test("instances filter: an unknown id is a 400 listing the valid ones", () => {
  assert.throws(
    () => selectInstances(items, ["backend", "nope"]),
    (err: Error) =>
      err instanceof BuildRequestError && err.message === 'unknown instance id(s) "nope" - this repository has: "main", "backend", "frontend"',
  );
});

test("image names: main keeps the name, other items get -<id>", () => {
  assert.equal(instanceImageName("my-repo", "main"), "my-repo");
  assert.equal(instanceImageName("my-repo", "backend"), "my-repo-backend");
  assert.equal(instanceImageName("team/custom", "back-end"), "team/custom-back-end");
});
