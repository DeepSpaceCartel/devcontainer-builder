// Build orchestration pieces that don't need BuildKit: the once-only
// builder setup, clone arguments and default-branch resolution.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clonedBranch, gitCloneArgs, onceUntilFailure } from "./build.js";

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
