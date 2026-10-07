// Build orchestration pieces that don't need BuildKit: the once-only
// builder setup, clone arguments and default-branch resolution.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clonedBranch, devcontainerBuildArgs, gitCloneArgs, onceUntilFailure } from "./build.js";

const noBuildOptions = { platforms: [], noCache: false, cacheFrom: undefined, cacheTo: undefined, mode: undefined };

test("devcontainer build args: a root config keeps today's argv, no --config", () => {
  for (const configPath of [".devcontainer/devcontainer.json", ".devcontainer.json"]) {
    assert.deepEqual(devcontainerBuildArgs("/w/repo", configPath, "r/x:t", noBuildOptions), [
      "build",
      "--workspace-folder",
      "/w/repo",
      "--image-name",
      "r/x:t",
      "--push",
    ]);
  }
});

test("devcontainer build args: a sub-folder config is passed with --config", () => {
  assert.deepEqual(
    devcontainerBuildArgs("/w/repo", ".devcontainer/backend/devcontainer.json", "r/x-backend:t", {
      ...noBuildOptions,
      platforms: ["linux/amd64", "linux/arm64"],
      noCache: true,
      mode: "never",
    }),
    [
      "build",
      "--workspace-folder",
      "/w/repo",
      "--config",
      "/w/repo/.devcontainer/backend/devcontainer.json",
      "--image-name",
      "r/x-backend:t",
      "--push",
      "--platform",
      "linux/amd64,linux/arm64",
      "--no-cache",
      "--buildkit",
      "never",
    ],
  );
});

test("onceUntilFailure shares one in-flight attempt and remembers success", async () => {
  let calls = 0;
  let release!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve));
  const setup = onceUntilFailure(async (label: string) => {
    calls++;
    await gate;
    return label;
  });
  const both = Promise.all([setup("first"), setup("second")]);
  release();
  assert.deepEqual(await both, ["first", "first"]);
  assert.equal(await setup("third"), "first");
  assert.equal(calls, 1);
});

test("onceUntilFailure forgets a failure so the next caller retries", async () => {
  let calls = 0;
  const setup = onceUntilFailure(async () => {
    calls++;
    if (calls === 1) throw new Error("buildx create failed");
    return "ok";
  });
  await assert.rejects(setup(), /buildx create failed/);
  assert.equal(await setup(), "ok");
  assert.equal(calls, 2);
});

test("clone args: --branch only when asked, and -- before the URL", () => {
  assert.deepEqual(gitCloneArgs("release", "https://h/r.git", "/w/repo"), [
    "clone",
    "--branch",
    "release",
    "--single-branch",
    "--depth",
    "1",
    "--",
    "https://h/r.git",
    "/w/repo",
  ]);
  assert.deepEqual(gitCloneArgs(undefined, "-upload-pack=x", "/w/repo"), [
    "clone",
    "--single-branch",
    "--depth",
    "1",
    "--",
    "-upload-pack=x",
    "/w/repo",
  ]);
  assert.deepEqual(gitCloneArgs(null, "u", "d"), gitCloneArgs(undefined, "u", "d"));
});

test("without a requested branch, the clone's own (default) branch is reported", async () => {
  const dir = mkdtempSync(join(tmpdir(), "dcb-branch-"));
  const git = (...args: string[]) => execFileSync("git", args, { cwd: dir, stdio: "ignore" });
  git("init", "--initial-branch=trunk");
  git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "--allow-empty", "-m", "init");
  assert.equal(await clonedBranch(undefined, dir), "trunk");
  assert.equal(await clonedBranch("v1.0.0", dir), "v1.0.0");
});
