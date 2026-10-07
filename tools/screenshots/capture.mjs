// Captures the docs' screenshots (docs/assets/screenshots/) from a real
// Coder deployment running devcontainer-builder's template. See README.md.
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const env = (name, fallback) => {
  const value = process.env[name] ?? fallback;
  if (value === undefined) throw new Error(`${name} is required (see tools/screenshots/README.md)`);
  return value;
};
const CODER_URL = env("CODER_URL").replace(/\/+$/, "");
const TOKEN = env("CODER_SESSION_TOKEN");
const TEMPLATE = env("TEMPLATE", "kubernetes-devcontainer");
const REPO = env("FIXTURE_REPO", "https://github.com/DeepSpaceCartel/devcontainer-builder-examples.git");
const BRANCH = env("FIXTURE_BRANCH", "docs-demo");
const NO_CONFIG_BRANCH = env("NO_CONFIG_BRANCH", "missing-devcontainer-json");
const OUT = resolve(env("OUT", join(dirname(fileURLToPath(import.meta.url)), "../../docs/assets/screenshots")));
// "secret=shown,..." - text replaced on every captured page (e.g. your email).
const REDACT = (process.env.REDACT ?? "").split(",").filter(Boolean).map((p) => p.split("="));
const KEEP = process.env.KEEP_WORKSPACES === "1";
const VIEWPORT = { width: 1280, height: 800 };

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

// --- Coder API -------------------------------------------------------------
async function api(path, init = {}) {
  const res = await fetch(`${CODER_URL}/api/v2${path}`, {
    ...init,
    headers: { "Coder-Session-Token": TOKEN, "Content-Type": "application/json" },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${init.method ?? "GET"} ${path}: ${res.status} ${body.message ?? ""} ${body.detail ?? ""}`);
  return body;
}

async function workspace(name, branch) {
  const me = await api("/users/me");
  const find = async () => (await api(`/workspaces?q=owner:me name:${name}`)).workspaces.find((w) => w.name === name);
  let existing = await find();
  // A previous run's workspace still being deleted: wait it out.
  for (let i = 0; existing?.latest_build.transition === "delete" && i < 60; i++) {
    await new Promise((r) => setTimeout(r, 5000));
    existing = await find();
  }
  if (existing) return { ws: existing, owner: me.username, created: false };
  const template = (await api("/templates")).find((t) => t.name === TEMPLATE);
  if (!template) throw new Error(`no template ${TEMPLATE}`);
  log(`creating ${name} (${REPO} ${branch})`);
  const ws = await api("/users/me/workspaces", {
    method: "POST",
    body: JSON.stringify({
      name,
      template_id: template.id,
      rich_parameter_values: [
        { name: "repository", value: REPO },
        { name: "branch", value: branch },
      ],
    }),
  });
  return { ws, owner: me.username, created: true };
}

async function waitReady(id) {
  for (let i = 0; i < 120; i++) {
    const w = await api(`/workspaces/${id}`);
    const b = w.latest_build;
    if (b.job.status === "failed") throw new Error(`build failed: ${b.job.error}`);
    const agents = b.resources.flatMap((r) => r.agents ?? []);
    if (b.job.status === "succeeded" && agents.length && agents.every((a) => a.lifecycle_state === "ready")) return w;
    await new Promise((r) => setTimeout(r, 5000));
  }
  throw new Error("workspace not ready after 10 minutes");
}

// --- git (the fixture branch) ---------------------------------------------
function git(cwd, ...args) {
  const helper = process.env.GIT_CREDENTIAL_HELPER;
  const auth = helper ? ["-c", "credential.helper=", "-c", `credential.helper=${helper}`] : [];
  return execFileSync("git", [...auth, ...args], { cwd, encoding: "utf8", env: { ...process.env, GIT_ASKPASS: "", GIT_TERMINAL_PROMPT: "0" } }).trim();
}

// --- browser helpers -------------------------------------------------------
async function tidyCoderPage(page) {
  await page.evaluate((redact) => {
    // The admin-only deployment stats bar at the bottom.
    for (const el of document.querySelectorAll("body *")) {
      if (el.childElementCount === 0 && (el.textContent ?? "").trim() === "Transmission") {
        let node = el;
        while (node && node !== document.body && !["fixed", "sticky"].includes(getComputedStyle(node).position)) node = node.parentElement;
        if (node && node !== document.body) node.style.display = "none";
      }
    }
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      for (const [from, to] of redact) if (n.nodeValue.includes(from)) n.nodeValue = n.nodeValue.split(from).join(to);
    }
    for (const input of document.querySelectorAll("input")) {
      for (const [from, to] of redact) if (input.value.includes(from)) input.value = input.value.split(from).join(to);
    }
  }, REDACT);
}

async function shot(page, file, options = {}) {
  await tidyCoderPage(page);
  await page.screenshot({ path: join(OUT, file), ...options });
  log(`wrote ${file}`);
}

async function command(page, title) {
  await page.keyboard.press("F1");
  await page.locator(".quick-input-widget input").fill(`>${title}`);
  await page.locator(".quick-input-list .monaco-list-row").first().waitFor();
  await page.keyboard.press("Enter");
}

async function openVSCode(ctx, owner, name) {
  const page = await ctx.newPage();
  await page.setViewportSize(VIEWPORT);
  await page.goto(`${CODER_URL}/@${owner}/${name}/apps/vscode-web/`, { waitUntil: "domcontentloaded", timeout: 120000 });
  await page.locator(".monaco-workbench").waitFor({ timeout: 120000 });
  await page.waitForTimeout(5000);
  // Trust the folder, as a user does on first open - VS Code doesn't run
  // the extension in Restricted Mode.
  if (await page.getByText("Restricted Mode").first().isVisible().catch(() => false)) {
    await command(page, "Workspaces: Manage Workspace Trust");
    await page.getByRole("button", { name: /^Trust( Folder)?$/ }).first().click();
    await page.waitForTimeout(1500);
    await page.keyboard.press("Escape");
  }
  await page.waitForTimeout(3000);
  await command(page, "View: Close All Editors");
  await page.waitForTimeout(500);
  // The Chat view in the secondary side bar, if VS Code opened it.
  await command(page, "View: Toggle Secondary Side Bar Visibility").catch(() => {});
  await page.waitForTimeout(1000);
  if (await page.locator(".part.auxiliarybar").isVisible().catch(() => false)) await command(page, "View: Toggle Secondary Side Bar Visibility");
  await page.waitForTimeout(2000);
  return page;
}

const statusItem = (page, text) => page.locator(".statusbar-item", { hasText: text }).first();
const toast = (page, text) => page.locator(".notification-toast", { hasText: text }).first();

// --- scenes ----------------------------------------------------------------
async function main() {
  mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: VIEWPORT, colorScheme: "light" });
  await ctx.addCookies([{ name: "coder_session_token", value: TOKEN, url: CODER_URL }]);
  const cleanup = [];
  const clone = mkdtempSync(join(tmpdir(), "dcb-screenshots-"));
  let originalSha;

  try {
    // 1. The create page, filled in.
    const create = await ctx.newPage();
    const q = new URLSearchParams({ mode: "form", "param.repository": REPO, "param.branch": BRANCH, name: "my-app" });
    await create.goto(`${CODER_URL}/templates/coder/${TEMPLATE}/workspace?${q}`, { waitUntil: "domcontentloaded" });
    await create.getByText("Git repository").first().waitFor({ timeout: 60000 });
    await create.waitForTimeout(2000);
    await create.getByText("Parameters", { exact: true }).first().evaluate((el) => el.scrollIntoView({ block: "start" }));
    await shot(create, "coder-create-workspace.png");
    await create.close();

    // 2. A workspace on the fixture branch: its page in the dashboard.
    const demo = await workspace("docs-demo", BRANCH);
    if (demo.created && !KEEP) cleanup.push(demo.ws.id);
    const ready = await waitReady(demo.ws.id);
    const dash = await ctx.newPage();
    await dash.goto(`${CODER_URL}/@${demo.owner}/${ready.name}`, { waitUntil: "domcontentloaded" });
    await dash.getByText("VS Code Desktop").first().waitFor({ timeout: 60000 });
    await dash.waitForTimeout(3000);
    await shot(dash, "coder-workspace-page.png");
    await dash.close();

    // 3. VS Code in the browser, up to date.
    const vscode = await openVSCode(ctx, demo.owner, ready.name);
    await command(vscode, "Dev Container: Check for Rebuild");
    await vscode.waitForTimeout(8000);
    await command(vscode, "Notifications: Clear All Notifications");
    await command(vscode, "Go to File...");
    await vscode.keyboard.type(".devcontainer/devcontainer.json");
    await vscode.waitForTimeout(1500);
    await vscode.keyboard.press("Enter");
    await vscode.waitForTimeout(2000);
    await statusItem(vscode, /\b[0-9a-f]{7}\s*$/).hover({ timeout: 90000 });
    await vscode.waitForTimeout(1500);
    await shot(vscode, "vscode-up-to-date.png");

    // 4. A local, unpushed change to the configuration.
    await vscode.locator(".monaco-editor .view-lines").first().click();
    await vscode.keyboard.press("Control+End");
    await vscode.keyboard.press("Enter");
    await vscode.keyboard.type("// added in the workspace");
    await vscode.keyboard.press("Control+S");
    await statusItem(vscode, "Push Dev Container changes").waitFor({ timeout: 60000 });
    await toast(vscode, "aren't on origin").waitFor({ timeout: 30000 }).catch(() => {});
    await vscode.waitForTimeout(1500);
    await shot(vscode, "vscode-push-changes.png");
    for (let i = 0; i < 20; i++) await vscode.keyboard.press("Control+Z");
    await vscode.keyboard.press("Control+S");
    await command(vscode, "Notifications: Clear All Notifications");
    await vscode.waitForTimeout(5000);

    // 5. A configuration change pushed to the branch: Rebuild available.
    git(clone, "clone", "-q", "--branch", BRANCH, REPO, ".");
    originalSha = git(clone, "rev-parse", "HEAD");
    const file = join(clone, ".devcontainer/devcontainer.json");
    const config = JSON.parse(readFileSync(file, "utf8"));
    config.features = { "ghcr.io/devcontainers/features/github-cli:1": {} };
    writeFileSync(file, JSON.stringify(config, null, 2) + "\n");
    git(clone, "-c", "user.name=docs", "-c", "user.email=docs@example.com", "commit", "-qam", "Add the GitHub CLI Feature");
    git(clone, "push", "-q", "origin", BRANCH);
    await command(vscode, "Dev Container: Check for Rebuild");
    await toast(vscode, "Rebuild the workspace?").waitFor({ timeout: 120000 });
    await vscode.waitForTimeout(1500);
    await shot(vscode, "vscode-rebuild-available.png");
    await vscode.close();

    // 6. A repository without a configuration.
    const bare = await workspace("docs-no-config", NO_CONFIG_BRANCH);
    if (bare.created && !KEEP) cleanup.push(bare.ws.id);
    const bareReady = await waitReady(bare.ws.id);
    const bareCode = await openVSCode(ctx, bare.owner, bareReady.name);
    await statusItem(bareCode, "Add Dev Container config").waitFor({ timeout: 120000 });
    // The prompt shows once per window, possibly during the setup above:
    // reload for a fresh one.
    await Promise.all([bareCode.waitForNavigation({ timeout: 120000 }), command(bareCode, "Developer: Reload Window")]);
    await bareCode.locator(".monaco-workbench").waitFor({ timeout: 120000 });
    await statusItem(bareCode, "Add Dev Container config").waitFor({ timeout: 120000 });
    await toast(bareCode, "no devcontainer.json").waitFor({ timeout: 120000 });
    await bareCode.waitForTimeout(1000);
    await shot(bareCode, "vscode-add-config.png");
    await bareCode.close();
  } catch (e) {
    for (const p of ctx.pages()) await p.screenshot({ path: join(OUT, `_failed-${ctx.pages().indexOf(p)}.png`) }).catch(() => {});
    throw e;
  } finally {
    if (originalSha) {
      git(clone, "push", "-q", "--force", "origin", `${originalSha}:refs/heads/${BRANCH}`);
      log(`reset ${BRANCH} to ${originalSha.slice(0, 7)}`);
    }
    rmSync(clone, { recursive: true, force: true });
    for (const id of cleanup) {
      await api(`/workspaces/${id}/builds`, { method: "POST", body: JSON.stringify({ transition: "delete" }) }).catch((e) => log(e.message));
      log(`deleting workspace ${id}`);
    }
    await browser.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
