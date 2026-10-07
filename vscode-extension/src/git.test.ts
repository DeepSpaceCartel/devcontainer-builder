import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { git, GitError } from "./git";

const dir = mkdtempSync(join(tmpdir(), "dc-git-"));
execFileSync("git", ["init", "-q", dir]);
after(() => rmSync(dir, { recursive: true, force: true }));

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

test("a timeout kills git and what it started", { skip: process.platform === "win32" }, async () => {
  const pidFile = join(dir, "pid");
  // A git alias runs a shell, which starts a child of its own - like
  // git-remote-https or an askpass helper.
  const started = Date.now();
  await assert.rejects(git(dir, ["-c", `alias.slow=!sh -c 'echo $$ > ${pidFile}; sleep 30'`, "slow"], { timeoutMs: 500 }), (e: Error) => e instanceof GitError && /git slow: timed out/.test(e.message));
  assert.ok(Date.now() - started < 5000);
  const pid = Number(readFileSync(pidFile, "utf8"));
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(alive(pid), false, "the grandchild was left running");
});

test("askpass: false empties GIT_ASKPASS and SSH_ASKPASS", async () => {
  const saved = process.env.GIT_ASKPASS;
  process.env.GIT_ASKPASS = "/bin/false";
  try {
    const show = ["-c", `alias.askpassenv=!echo "[$GIT_ASKPASS][$SSH_ASKPASS]"`, "askpassenv"];
    assert.equal((await git(dir, show)).trim().startsWith("[/bin/false]"), true);
    assert.equal((await git(dir, show, { askpass: false })).trim(), "[][]");
  } finally {
    if (saved === undefined) delete process.env.GIT_ASKPASS;
    else process.env.GIT_ASKPASS = saved;
  }
});
