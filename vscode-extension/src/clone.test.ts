import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { CoderApi, cliLogin, coderConfigDir, desktopUri, findExisting, normalizeRepo, parseLsRemote, phase, workspaceName, type Workspace } from "./clone";

test("normalizeRepo: the same repository however it's written", () => {
  const forms = [
    "https://github.com/DeepSpaceCartel/make",
    "https://github.com/DeepSpaceCartel/make.git",
    "https://user@github.com/deepspacecartel/make/",
    "git@github.com:DeepSpaceCartel/make.git",
    "ssh://git@github.com:22/DeepSpaceCartel/make",
  ];
  for (const f of forms) assert.equal(normalizeRepo(f), "github.com/deepspacecartel/make", f);
  assert.notEqual(normalizeRepo("https://github.com/a/make"), normalizeRepo("https://github.com/b/make"));
});

test("workspaceName: <repo>-<branch>, Coder-safe, unique", () => {
  assert.equal(workspaceName("https://github.com/DeepSpaceCartel/make", "master", new Set()), "make-master");
  assert.equal(workspaceName("git@github.com:o/My_Repo.git", "feat/Some Thing", new Set()), "my-repo-feat-some-thing");
  assert.equal(workspaceName("https://x/o/make", "master", new Set(["make-master", "make-master-2"])), "make-master-3");
  assert.equal(workspaceName("https://github.com/o/devcontainer-builder-examples", "main", new Set()), "devcontainer-builder-exampl-main");
  assert.equal(
    workspaceName("https://github.com/o/devcontainer-builder-examples", "runtime-and-env", new Set()),
    "devcontainer-bui-runtime-and-env",
  );
  const long = workspaceName("https://x/o/" + "a".repeat(40), "main", new Set());
  assert.ok(long.length <= 32 && /^[a-z0-9]+(-[a-z0-9]+)*$/.test(long), long);
  const taken = workspaceName("https://x/o/" + "a".repeat(40), "main", new Set([long]));
  assert.ok(taken.length <= 32 && taken.endsWith("-2"), taken);
});

test("parseLsRemote: the default branch first", () => {
  const out = [
    "ref: refs/heads/master\tHEAD",
    "c63a5bc6a2881d515bb3020ed477fcba08fb2f3d\tHEAD",
    "1111111111111111111111111111111111111111\trefs/heads/feature/x",
    "c63a5bc6a2881d515bb3020ed477fcba08fb2f3d\trefs/heads/master",
    "2222222222222222222222222222222222222222\trefs/heads/dev",
  ].join("\n");
  assert.deepEqual(parseLsRemote(out), ["master", "dev", "feature/x"]);
  assert.deepEqual(parseLsRemote(""), []);
});

test("coderConfigDir per platform, and cliLogin", async () => {
  assert.equal(coderConfigDir("linux", {}, "/h"), "/h/.config/coderv2");
  assert.equal(coderConfigDir("darwin", {}, "/h"), "/h/Library/Application Support/coderv2");
  assert.equal(coderConfigDir("win32", { APPDATA: "C:\\A" }, "/h"), join("C:\\A", "coderv2"));
  assert.equal(coderConfigDir("linux", { CODER_CONFIG_DIR: "/c" }, "/h"), "/c");
  const dir = mkdtempSync(join(tmpdir(), "dc-clone-"));
  assert.equal(await cliLogin(dir), undefined);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "url"), "https://coder.example.com/\n");
  writeFileSync(join(dir, "session"), "tok\n");
  assert.deepEqual(await cliLogin(dir), { url: "https://coder.example.com", token: "tok" });
});

const ws = (over: any = {}): Workspace => ({
  id: "w1",
  name: "make-master",
  owner_name: "alice",
  template_name: "t",
  latest_build: {
    id: "b1",
    status: "running",
    transition: "start",
    job: { status: "succeeded" },
    resources: [{ agents: [{ name: "main", status: "connected", lifecycle_state: "ready", apps: [] }] }],
    ...over,
  },
});

test("phase follows a workspace from building to ready or failed", () => {
  assert.equal(phase(ws({ job: { status: "running" } })).kind, "building");
  assert.equal(phase(ws({ resources: [{ agents: [{ name: "main", status: "connecting", lifecycle_state: "created" }] }] })).kind, "starting");
  assert.equal(phase(ws({ resources: [{ agents: [{ name: "main", status: "connected", lifecycle_state: "starting" }] }] })).kind, "scripts");
  assert.equal(phase(ws()).kind, "ready");
  assert.deepEqual(phase(ws({ job: { status: "failed", error: "boom" } })), { kind: "failed", message: "boom" });
  assert.equal(phase(ws({ resources: [{ agents: [{ name: "main", status: "connected", lifecycle_state: "start_error" }] }] })).kind, "failed");
});

test("desktopUri: the vscode-desktop app with the token filled in, else a bare open URI", () => {
  const login = { url: "https://coder.example.com", token: "t/k" };
  const app = {
    slug: "vscode",
    external: true,
    url: "vscode://coder.coder-remote/open?owner=alice&workspace=make-master&folder=/workspaces/make&url=https://coder.example.com&token=$SESSION_TOKEN",
  };
  const withApp = ws({ resources: [{ agents: [{ name: "main", status: "connected", lifecycle_state: "ready", apps: [app] }] }] });
  assert.equal(desktopUri(withApp, login), app.url.replace("$SESSION_TOKEN", "t%2Fk"));
  const bare = new URL(desktopUri(ws(), login));
  assert.equal(bare.searchParams.get("workspace"), "make-master");
  assert.equal(bare.searchParams.get("token"), "t/k");
});

test("API: templates asking for repository and branch; existing workspaces on the same repo and branch", async () => {
  const responses: Record<string, unknown> = {
    "GET /templates": [
      { id: "t1", name: "devcontainer", active_version_id: "v1" },
      { id: "t2", name: "plain", active_version_id: "v2" },
    ],
    "GET /templateversions/v1/rich-parameters": [{ name: "repository" }, { name: "branch" }, { name: "rebuild" }],
    "GET /templateversions/v2/rich-parameters": [{ name: "cpu" }],
    "GET /templateversions/v1/external-auth": [
      { id: "github", display_name: "GitHub", authenticated: false, authenticate_url: "https://c/external-auth/github" },
      { id: "gitlab", display_name: "GitLab", authenticated: true, authenticate_url: "https://c/external-auth/gitlab" },
    ],
    "GET /workspacebuilds/b1/parameters": [
      { name: "repository", value: "git@github.com:DeepSpaceCartel/make.git" },
      { name: "branch", value: "master" },
    ],
    "GET /workspacebuilds/b2/parameters": [
      { name: "repository", value: "https://github.com/DeepSpaceCartel/make" },
      { name: "branch", value: "dev" },
    ],
  };
  const calls: string[] = [];
  const fake = (async (url: string, init?: RequestInit) => {
    const key = `${init?.method ?? "GET"} ${url.replace("https://c/api/v2", "")}`;
    calls.push(key);
    if (key === "POST /users/me/workspaces") return new Response(JSON.stringify({ ...ws(), body: JSON.parse(String(init?.body)) }), { status: 201 });
    return key in responses ? new Response(JSON.stringify(responses[key])) : new Response("{}", { status: 404 });
  }) as typeof fetch;
  const api = new CoderApi({ url: "https://c", token: "t" }, fake);

  const [template] = await api.repositoryTemplates();
  assert.equal(template.name, "devcontainer");
  assert.deepEqual((await api.unlinkedExternalAuth(template)).map((a) => a.id), ["github"]);
  const mine = [ws(), { ...ws(), id: "w2", name: "make-dev", latest_build: { ...ws().latest_build, id: "b2" } }];
  const found = await findExisting(api, "https://github.com/deepspacecartel/make.git", "master", mine);
  assert.deepEqual(found.map((w) => w.name), ["make-master"]);

  const created: any = await api.createWorkspace("t1", "make-master-2", [{ name: "repository", value: "r" }, { name: "branch", value: "b" }]);
  assert.deepEqual(created.body, { template_id: "t1", name: "make-master-2", rich_parameter_values: [{ name: "repository", value: "r" }, { name: "branch", value: "b" }] });
});
