import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, beforeEach, test } from "node:test";
import { checkStatus } from "./status";

// A bare "origin", a clone like the template's (branch at the image's
// commit), and a second clone standing in for someone pushing.
const root = mkdtempSync(join(tmpdir(), "dc-rebuild-"));
after(() => rmSync(root, { recursive: true, force: true }));
let n = 0;
let origin: string, workspace: string, other: string;

const run = (cwd: string, ...args: string[]) =>
  execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
  }).trim();
const write = (dir: string, file: string, text: string) => {
  mkdirSync(dirname(join(dir, file)), { recursive: true });
  writeFileSync(join(dir, file), text);
};
const commitAll = (dir: string, msg: string) => {
  run(dir, "add", "-A");
  run(dir, "commit", "-q", "-m", msg);
  return run(dir, "rev-parse", "HEAD");
};
const push = (dir: string, files: Record<string, string>) => {
  for (const [f, t] of Object.entries(files)) write(dir, f, t);
  const sha = commitAll(dir, "change");
  run(dir, "push", "-q", "origin", "main");
  return sha;
};

let imageCommit: string;
beforeEach(() => {
  const dir = join(root, String(n++));
  origin = join(dir, "origin.git");
  other = join(dir, "other");
  workspace = join(dir, "workspace");
  mkdirSync(dir);
  run(dir, "init", "-q", "--bare", "-b", "main", origin);
  run(dir, "clone", "-q", origin, other);
  run(other, "checkout", "-q", "-b", "main");
  imageCommit = push(other, {
    ".devcontainer/devcontainer.json": `{ "build": { "dockerfile": "../docker/Dockerfile", "context": "../docker" } }`,
    "docker/Dockerfile": "FROM alpine\n",
    "src/app.ts": "1\n",
  });
  run(dir, "clone", "-q", "-b", "main", origin, workspace);
});

const ws = () => ({ folder: workspace, imageCommit, branch: "main" });

test("up to date when nothing changed", async () => {
  const s = await checkStatus(ws(), { fetch: true });
  assert.equal(s.kind, "up-to-date");
  assert.deepEqual(s.paths, [".devcontainer", ".devcontainer.json", "docker", "docker/Dockerfile"]);
});

test("changes outside the rebuild paths don't count", async () => {
  push(other, { "src/app.ts": "2\n" });
  assert.equal((await checkStatus(ws(), { fetch: true })).kind, "up-to-date");
});

test("a pushed change in the build context needs a rebuild, once fetched", async () => {
  const sha = push(other, { "docker/Dockerfile": "FROM alpine:3\n" });
  assert.equal((await checkStatus(ws(), { fetch: false })).kind, "up-to-date");
  const s = await checkStatus(ws(), { fetch: true });
  assert.equal(s.kind, "rebuild-available");
  assert.equal(s.originCommit, sha);
  assert.deepEqual(s.changed, ["docker/Dockerfile"]);
});

test("a pushed change to devcontainer.json needs a rebuild", async () => {
  push(other, { ".devcontainer/devcontainer.json": `{ "image": "alpine" }` });
  const s = await checkStatus(ws(), { fetch: true });
  assert.equal(s.kind, "rebuild-available");
  assert.deepEqual(s.changed, [".devcontainer/devcontainer.json"]);
});

test("a context moved to the repo root makes every pushed change count", async () => {
  push(other, { ".devcontainer/devcontainer.json": `{ "build": { "dockerfile": "Dockerfile", "context": ".." } }` });
  const s = await checkStatus(ws(), { fetch: true });
  assert.deepEqual(s.paths, ["."]);
});

test("uncommitted and unpushed local changes ask to push first", async () => {
  write(workspace, ".devcontainer/devcontainer.json", `{ "image": "alpine" }`);
  let s = await checkStatus(ws(), { fetch: true });
  assert.equal(s.kind, "unpushed");
  assert.deepEqual(s.local, [".devcontainer/devcontainer.json"]);

  commitAll(workspace, "local");
  write(workspace, ".devcontainer/new-feature/install.sh", "true\n");
  s = await checkStatus(ws(), { fetch: true });
  assert.equal(s.kind, "unpushed");
  assert.deepEqual(s.local, [".devcontainer/devcontainer.json", ".devcontainer/new-feature/install.sh"]);

  write(workspace, "src/app.ts", "local\n");
  run(workspace, "add", "-A");
  run(workspace, "commit", "-q", "-m", "more");
  run(workspace, "push", "-q", "origin", "main");
  s = await checkStatus(ws(), { fetch: true });
  assert.equal(s.kind, "rebuild-available");
  assert.deepEqual(s.local, []);
});

test("an image commit missing locally is fetched", async () => {
  const sha = push(other, { "docker/Dockerfile": "FROM alpine:3\n" });
  const s = await checkStatus({ ...ws(), imageCommit: sha }, { fetch: true });
  assert.equal(s.kind, "up-to-date");
  assert.equal(s.imageCommit, sha);
});

test("unknown without the env, or when origin is unreachable", async () => {
  assert.equal((await checkStatus({ ...ws(), imageCommit: "" }, { fetch: true })).kind, "unknown");
  run(workspace, "remote", "set-url", "origin", join(root, "missing.git"));
  const s = await checkStatus(ws(), { fetch: true });
  assert.equal(s.kind, "unknown");
  assert.match(s.reason ?? "", /git fetch/);
});
