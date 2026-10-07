// command-log.ts: capture, per-kind rotation, and the id check that keeps
// a client-supplied id from becoming an arbitrary path. Runs in the
// private TMPDIR testing/setup.ts gives this process, so rotation here
// can't prune another test file's logs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { serviceConfig } from "./config.js";
import { closeCommandLog, deleteCommandLog, openCommandLog, readCommandLog, type CommandLogKind } from "./command-log.js";

const logsDir = () => join(tmpdir(), "devcontainer-builder-logs");

async function writeLog(kind: CommandLogKind, text: string) {
  const log = await openCommandLog(kind);
  log.stream.write(text);
  await closeCommandLog(log);
  return log;
}

test("a log reads back exactly what was written, until deleted", async () => {
  const log = await writeLog("git", "line 1\nline 2\n");
  assert.match(log.id, /^git-[0-9a-f-]{36}$/);
  assert.equal((await readCommandLog(log.id))?.toString(), "line 1\nline 2\n");
  assert.equal(await deleteCommandLog(log.id), true);
  assert.equal(await readCommandLog(log.id), undefined);
  assert.equal(await deleteCommandLog(log.id), false);
});

test("ids that aren't <kind>-<uuid> are never turned into paths", async () => {
  // A real file the traversal would otherwise reach.
  writeFileSync(join(tmpdir(), "secret.log"), "nope");
  for (const id of [
    "../secret",
    "git-../../secret",
    "GIT-00000000-0000-0000-0000-000000000000",
    "x-00000000-0000-0000-0000-000000000000",
    "",
  ]) {
    assert.equal(await readCommandLog(id), undefined, id);
    assert.equal(await deleteCommandLog(id), false, id);
  }
  assert.ok(existsSync(join(tmpdir(), "secret.log")));
});

test("rotation keeps the newest commandLogRetention logs per kind, independently", async () => {
  const saved = serviceConfig.commandLogRetention;
  serviceConfig.commandLogRetention = 100;
  try {
    const old = [];
    for (let i = 0; i < 3; i++) old.push(await writeLog("docker", `docker ${i}\n`));
    const git = await writeLog("git", "git\n");
    // Distinct, ascending mtimes in the past - not left to the filesystem's
    // timestamp granularity.
    old.forEach((log, i) => {
      const t = new Date(Date.UTC(2020, 0, 1 + i));
      utimesSync(join(logsDir(), `${log.id}.log`), t, t);
    });
    const gitTime = new Date(Date.UTC(2019, 0, 1));
    utimesSync(join(logsDir(), `${git.id}.log`), gitTime, gitTime);

    serviceConfig.commandLogRetention = 2;
    const newest = await writeLog("docker", "newest\n");

    assert.equal(await readCommandLog(old[0].id), undefined);
    assert.equal(await readCommandLog(old[1].id), undefined);
    assert.equal((await readCommandLog(old[2].id))?.toString(), "docker 2\n");
    assert.equal((await readCommandLog(newest.id))?.toString(), "newest\n");
    // The oldest file overall is a git log - untouched by a docker rotation.
    assert.equal((await readCommandLog(git.id))?.toString(), "git\n");
  } finally {
    serviceConfig.commandLogRetention = saved;
  }
});
