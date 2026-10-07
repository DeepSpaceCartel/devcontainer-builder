import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { coderUrl, NotLoggedIn, requestRebuild, sessionToken, settingsUrl } from "./coder";

const ws = { url: "https://coder.example.com", id: "ws-1", name: "dev", owner: "alice", rebuild: 2 };

function fakeFetch(responses: Record<string, [number, unknown]>, calls: { url: string; init?: RequestInit }[]) {
  return (async (url: string, init?: RequestInit) => {
    calls.push({ url, init });
    const key = `${init?.method ?? "GET"} ${url.replace(ws.url, "")}`;
    const [status, body] = responses[key] ?? [404, { message: `no fake for ${key}` }];
    return new Response(JSON.stringify(body), { status });
  }) as typeof fetch;
}

test("requestRebuild starts a build with rebuild = current + 1", async () => {
  const calls: { url: string; init?: RequestInit }[] = [];
  const next = await requestRebuild(
    ws,
    "tok",
    fakeFetch(
      {
        "GET /api/v2/workspaces/ws-1": [200, { latest_build: { id: "b-9" } }],
        "GET /api/v2/workspacebuilds/b-9/parameters": [200, [{ name: "rebuild", value: "4" }, { name: "branch", value: "main" }]],
        "POST /api/v2/workspaces/ws-1/builds": [201, { build_number: 10 }],
      },
      calls,
    ),
  );
  assert.equal(next, 5);
  const post = calls.at(-1)!;
  assert.deepEqual(JSON.parse(String(post.init?.body)), { transition: "start", rich_parameter_values: [{ name: "rebuild", value: "5" }] });
  assert.equal((post.init?.headers as Record<string, string>)["Coder-Session-Token"], "tok");
});

test("requestRebuild: 401 means log in again; other errors carry Coder's message", async () => {
  await assert.rejects(requestRebuild(ws, "tok", fakeFetch({ "GET /api/v2/workspaces/ws-1": [401, {}] }, [])), NotLoggedIn);
  await assert.rejects(
    requestRebuild(
      ws,
      "tok",
      fakeFetch(
        {
          "GET /api/v2/workspaces/ws-1": [200, { latest_build: { id: "b-9" } }],
          "GET /api/v2/workspacebuilds/b-9/parameters": [200, []],
          "POST /api/v2/workspaces/ws-1/builds": [409, { message: "Build already in progress." }],
        },
        [],
      ),
    ),
    /409: Build already in progress/,
  );
});

test("session token and URL from coder login's config, env first", async () => {
  const home = mkdtempSync(join(tmpdir(), "dc-coder-"));
  assert.equal(await sessionToken({}, home), undefined);
  assert.equal(await coderUrl({ CODER_AGENT_URL: "https://agent.example.com/" }, home), "https://agent.example.com");
  const dir = join(home, ".config", "coderv2");
  require("node:fs").mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "session"), "abc\n");
  writeFileSync(join(dir, "url"), "https://coder.example.com/\n");
  assert.equal(await sessionToken({}, home), "abc");
  assert.equal(await sessionToken({ CODER_SESSION_TOKEN: "env" }, home), "env");
  assert.equal(await coderUrl({ CODER_AGENT_URL: "https://agent.example.com/" }, home), "https://coder.example.com");
});

test("settingsUrl", () => {
  assert.equal(settingsUrl(ws), "https://coder.example.com/@alice/dev/settings/parameters");
});
