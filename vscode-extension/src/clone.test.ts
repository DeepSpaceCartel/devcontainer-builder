import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  CoderApi,
  CoderApiError,
  CoderUnreachable,
  TOKEN_SECRET,
  cliLogin,
  coderConfigDir,
  desktopUri,
  existingStep,
  findExisting,
  firstWorkingLogin,
  loginCandidates,
  migrateLegacyToken,
  normalizeRepo,
  parseLsRemote,
  phase,
  pollUntilReady,
  repoUrlProblem,
  tokenSecretKey,
  workspaceName,
  type CoderLogin,
  type Secrets,
  type Workspace,
} from "./clone";
import { coderRequest } from "./http";

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
  assert.equal(coderConfigDir("linux", { XDG_CONFIG_HOME: "/x" }, "/h"), "/x/coderv2");
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

const agent = (status: string, lifecycle_state = "created") => ({ resources: [{ agents: [{ name: "main", status, lifecycle_state }] }] });

test("phase: an agent that timed out or disconnected is stalled, not failed yet", () => {
  for (const status of ["timeout", "disconnected"]) {
    const p = phase(ws(agent(status)));
    assert.equal(p.kind, "starting", status);
    assert.ok(p.kind === "starting" && p.stalled?.includes("main"), status);
  }
  const connecting = phase(ws(agent("connecting")));
  assert.ok(connecting.kind === "starting" && connecting.stalled === undefined);
});

// A fake clock: sleep moves time on.
function clock() {
  let t = 0;
  return { now: () => t, sleep: async (ms: number) => void (t += ms) };
}

test("pollUntilReady: a stalled agent fails after the grace period; a recovered one doesn't", async () => {
  const stalled = await pollUntilReady(async () => ws(agent("timeout")), { ...clock(), stallGraceMs: 60_000 });
  assert.equal(stalled.kind, "failed");
  assert.match(stalled.kind === "failed" ? stalled.message : "", /agent main didn't connect/);

  const states = [agent("timeout"), agent("timeout"), agent("connected", "ready")];
  const recovered = await pollUntilReady(async () => ws(states.shift()), { ...clock(), stallGraceMs: 60_000 });
  assert.equal(recovered.kind, "ready");
});

test("pollUntilReady: transient errors are retried, others thrown; the deadline ends the wait", async () => {
  let calls = 0;
  const flaky = async () => {
    calls++;
    if (calls === 1) throw new CoderUnreachable("Couldn't reach Coder");
    if (calls === 2) throw new CoderApiError("Coder API 502: bad gateway", 502);
    return ws();
  };
  const retries: number[] = [];
  assert.equal((await pollUntilReady(flaky, { ...clock(), onRetry: (_e, n) => retries.push(n) })).kind, "ready");
  assert.deepEqual(retries, [1, 2]);

  const down = async (): Promise<Workspace> => {
    throw new CoderUnreachable("down");
  };
  await assert.rejects(pollUntilReady(down, { ...clock(), maxTransientErrors: 3 }), /down/);
  const forbidden = async (): Promise<Workspace> => {
    throw new CoderApiError("Coder API 403: forbidden", 403);
  };
  await assert.rejects(pollUntilReady(forbidden, clock()), /403/);

  const building = await pollUntilReady(async () => ws({ job: { status: "running" } }), { ...clock(), deadlineMs: 60_000 });
  assert.equal(building.kind, "deadline");
  assert.equal((await pollUntilReady(async () => ws(), { cancelled: () => true })).kind, "cancelled");
});

test("existingStep: wait for a start, let a stop finish, start a stopped or failed one", () => {
  const b = (transition: string, status: string) => ws({ transition, status });
  assert.equal(existingStep(b("start", "running")), "wait");
  assert.equal(existingStep(b("start", "starting")), "wait");
  assert.equal(existingStep(b("start", "pending")), "wait");
  assert.equal(existingStep(b("stop", "stopping")), "settle");
  assert.equal(existingStep(b("stop", "pending")), "settle");
  assert.equal(existingStep(b("start", "canceling")), "settle");
  assert.equal(existingStep(b("stop", "stopped")), "start");
  assert.equal(existingStep(b("start", "failed")), "start");
  assert.equal(existingStep(b("stop", "failed")), "start");
  assert.equal(existingStep(b("start", "canceled")), "start");
  assert.equal(existingStep(b("delete", "deleting")), "deleted");
});

test("repoUrlProblem: credentials in a repository URL are refused", () => {
  for (const ok of [
    "https://github.com/o/r",
    "https://github.com/o/r.git",
    "git@github.com:o/r.git",
    "ssh://git@github.com/o/r",
    "https://example.com/path@with-at/r",
  ]) {
    assert.equal(repoUrlProblem(ok), undefined, ok);
  }
  for (const bad of ["https://user:ghp_secret@github.com/o/r", "https://ghp_secret@github.com/o/r", "http://u:p@host/r", "ssh://git:pw@host/r", "user:pw@host:o/r"]) {
    assert.match(repoUrlProblem(bad) ?? "", /credentials/, bad);
  }
});

function memorySecrets(initial: Record<string, string> = {}) {
  const data = new Map(Object.entries(initial));
  const secrets: Secrets = {
    get: async (k) => data.get(k),
    store: async (k, v) => void data.set(k, v),
    delete: async (k) => void data.delete(k),
  };
  return { data, secrets };
}

test("stored tokens are kept per deployment; the old unkeyed one moves to its URL", async () => {
  assert.equal(tokenSecretKey("https://coder.example.com/"), `${TOKEN_SECRET}:https://coder.example.com`);
  assert.equal(tokenSecretKey("https://coder.example.com:8443/x"), `${TOKEN_SECRET}:https://coder.example.com:8443`);
  assert.equal(tokenSecretKey("file:///etc/passwd"), undefined);

  const { data, secrets } = memorySecrets({ [TOKEN_SECRET]: "old" });
  await migrateLegacyToken(secrets, "https://a.example.com");
  assert.deepEqual([...data], [[`${TOKEN_SECRET}:https://a.example.com`, "old"]]);
  // Without the URL it was stored with, it's dropped rather than guessed.
  const orphan = memorySecrets({ [TOKEN_SECRET]: "old" });
  await migrateLegacyToken(orphan.secrets, undefined);
  assert.equal(orphan.data.size, 0);
});

test("loginCandidates: a token is only used with the URL it was stored for", async () => {
  const { secrets } = memorySecrets({ [`${TOKEN_SECRET}:https://a.example.com`]: "tok-a" });
  const cli: CoderLogin = { url: "https://a.example.com", token: "cli-a" };

  // A configured URL elsewhere gets neither A's stored token nor A's CLI session.
  assert.deepEqual(await loginCandidates(secrets, "https://evil.example.com", "https://a.example.com", cli), []);
  // The configured URL with its own token, then the CLI's session for it.
  assert.deepEqual(await loginCandidates(secrets, "https://a.example.com/", undefined, cli), [
    { login: { url: "https://a.example.com", token: "tok-a" }, source: "stored" },
    { login: cli, source: "cli" },
  ]);
  // Nothing configured: the last URL logged in to, and any CLI session.
  const other: CoderLogin = { url: "https://b.example.com", token: "cli-b" };
  assert.deepEqual(
    (await loginCandidates(secrets, undefined, "https://a.example.com", other)).map((c) => c.login.token),
    ["tok-a", "cli-b"],
  );
});

test("firstWorkingLogin: a rejected stored token is deleted; an unreachable deployment falls through", async () => {
  const key = `${TOKEN_SECRET}:https://a.example.com`;
  const { data, secrets } = memorySecrets({ [key]: "stale" });
  const answers: Record<string, () => Error | undefined> = {
    stale: () => new CoderApiError("Coder API 401: unauthorized", 401),
    offline: () => new CoderUnreachable("Couldn't reach Coder at https://a.example.com: ECONNREFUSED"),
    good: () => undefined,
    weird: () => new CoderApiError("Coder API 400: bad", 400),
  };
  const makeApi = (login: CoderLogin) =>
    ({
      login,
      me: async () => {
        const e = answers[login.token]();
        if (e) throw e;
        return { username: "alice" };
      },
    }) as unknown as CoderApi;
  const stored = { login: { url: "https://a.example.com", token: "stale" }, source: "stored" as const };
  const cliGood = { login: { url: "https://a.example.com", token: "good" }, source: "cli" as const };

  const r1 = await firstWorkingLogin([stored, cliGood], secrets, makeApi);
  assert.equal(r1.api?.login.token, "good");
  assert.equal(data.has(key), false, "the rejected token is deleted");

  const offline = { login: { url: "https://a.example.com", token: "offline" }, source: "stored" as const };
  const r2 = await firstWorkingLogin([offline, cliGood], secrets, makeApi);
  assert.equal(r2.api?.login.token, "good");
  assert.match(r2.problems[0], /ECONNREFUSED/);

  const r3 = await firstWorkingLogin([offline], secrets, makeApi);
  assert.equal(r3.api, undefined);
  await assert.rejects(firstWorkingLogin([{ login: { url: "https://a.example.com", token: "weird" }, source: "cli" }], secrets, makeApi), /400/);
});

test("API calls time out instead of hanging", async () => {
  const hang = ((_url: string, init?: RequestInit) =>
    new Promise((_resolve, reject) => init?.signal?.addEventListener("abort", () => reject(init.signal!.reason)))) as typeof fetch;
  // AbortSignal.timeout's timer doesn't keep the event loop alive; VS Code's does.
  const alive = setTimeout(() => undefined, 5000);
  await assert.rejects(coderRequest(hang, "https://c", "t", "/users/me", undefined, 50), (e: Error) => e instanceof CoderUnreachable && /didn't answer within/.test(e.message));
  clearTimeout(alive);
  const refused = (async () => {
    throw Object.assign(new TypeError("fetch failed"), { cause: { message: "connect ECONNREFUSED" } });
  }) as typeof fetch;
  await assert.rejects(new CoderApi({ url: "https://c", token: "t" }, refused).me(), /Couldn't reach Coder at https:\/\/c: connect ECONNREFUSED/);
});
