import { execFile } from "node:child_process";
import * as vscode from "vscode";
import {
  CoderApi,
  CoderApiError,
  cliLogin,
  desktopUri,
  findExisting,
  parseLsRemote,
  phase,
  trimUrl,
  workspaceName,
  type CoderLogin,
  type Template,
  type Workspace,
} from "./clone";

const TOKEN_SECRET = "devcontainerBuilder.coderToken";
const URL_KEY = "devcontainerBuilder.coderUrl";
const CODER_EXTENSION = "coder.coder-remote";

// "Coder: Clone Repository in Workspace…" - repository → branch → an
// existing workspace on it, or a new one from the template → VS Code
// Desktop opened on the cloned folder. The repository picker is VS Code's
// own (Git: Clone's, as Dev Containers' Clone Repository in Container
// Volume uses): GitHub repositories you can see, recent ones, or a URL.
export async function cloneInWorkspace(context: vscode.ExtensionContext, log: vscode.LogOutputChannel): Promise<void> {
  const api = await connect(context);
  if (!api) return;

  const source = await pickRemoteSource();
  if (!source) return;
  const repo = source.url;
  const branch = source.branch ?? (await pickBranch(repo));
  if (!branch) return;

  const workspaces = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: "Looking for your workspaces on this repository…" },
    () => api.myWorkspaces(),
  );
  const existing = await findExisting(api, repo, branch, workspaces);
  let target: Workspace | undefined;
  if (existing.length > 0) {
    const pick = await vscode.window.showQuickPick(
      [
        ...existing.map((w) => ({ label: `$(vm) Open ${w.name}`, description: w.latest_build.status, workspace: w as Workspace | undefined })),
        { label: "$(add) Create Another Workspace", description: undefined, workspace: undefined },
      ],
      { title: `You already have a workspace on ${branch}` },
    );
    if (!pick) return;
    target = pick.workspace;
  }

  if (!target) {
    const template = await pickTemplate(api);
    if (!template) return;
    if (!(await linkExternalAuth(api, template, log))) return;
    const name = workspaceName(repo, branch, new Set(workspaces.map((w) => w.name)));
    log.info(`Creating ${name} from ${template.name}: ${repo} (${branch})`);
    target = await api.createWorkspace(template.id, name, [
      { name: "repository", value: repo },
      { name: "branch", value: branch },
    ]);
  } else if (target.latest_build.transition !== "start" && ["stopped", "failed", "canceled"].includes(target.latest_build.status)) {
    log.info(`Starting ${target.name}`);
    await api.startWorkspace(target.id);
  }

  const ready = await waitUntilReady(api, target, log);
  if (ready) await openInDesktop(api.login, ready);
}

async function connect(context: vscode.ExtensionContext): Promise<CoderApi | undefined> {
  const configured = vscode.workspace.getConfiguration("devcontainerBuilder").get<string>("coderUrl");
  const candidates: (CoderLogin | undefined)[] = [];
  const storedUrl = configured || context.globalState.get<string>(URL_KEY);
  const storedToken = await context.secrets.get(TOKEN_SECRET);
  if (storedUrl && storedToken) candidates.push({ url: trimUrl(storedUrl), token: storedToken });
  const cli = await cliLogin();
  if (cli && (!configured || trimUrl(configured) === cli.url)) candidates.push(cli);

  for (const login of candidates) {
    const api = new CoderApi(login!);
    try {
      await api.me();
      return api;
    } catch (e) {
      if (!(e instanceof CoderApiError && e.status === 401)) throw e;
    }
  }

  // Log in like the Coder extension and CLI: the deployment's /cli-auth
  // page shows a session token to paste.
  const url = await vscode.window.showInputBox({
    title: "Coder deployment",
    prompt: "Your Coder URL",
    value: storedUrl ?? "https://",
    ignoreFocusOut: true,
    validateInput: (v) => (/^https?:\/\/[^/]+/.test(v.trim()) ? undefined : "An http(s):// URL"),
  });
  if (!url) return undefined;
  await vscode.env.openExternal(vscode.Uri.parse(`${trimUrl(url)}/cli-auth`));
  const token = await vscode.window.showInputBox({
    title: "Coder session token",
    prompt: `Paste the session token from ${trimUrl(url)}/cli-auth`,
    password: true,
    ignoreFocusOut: true,
  });
  if (!token) return undefined;
  const api = new CoderApi({ url: trimUrl(url), token: token.trim() });
  await api.me();
  await context.globalState.update(URL_KEY, trimUrl(url));
  await context.secrets.store(TOKEN_SECRET, token.trim());
  return api;
}

// A quick pick that also takes whatever is typed: recent repositories as
// items, the typed value on top.
async function pickOrType(title: string, placeholder: string, items: string[], value = ""): Promise<string | undefined> {
  const qp = vscode.window.createQuickPick();
  qp.title = title;
  qp.placeholder = placeholder;
  qp.ignoreFocusOut = true;
  qp.value = value;
  const base = items.map((label) => ({ label }));
  const refresh = () => {
    const typed = qp.value.trim();
    qp.items = typed && !items.includes(typed) ? [{ label: typed, description: "(typed)" }, ...base] : base;
  };
  refresh();
  qp.onDidChangeValue(refresh);
  return new Promise((resolve) => {
    qp.onDidAccept(() => {
      resolve(qp.selectedItems[0]?.label ?? (qp.value.trim() || undefined));
      qp.hide();
    });
    qp.onDidHide(() => {
      resolve(undefined);
      qp.dispose();
    });
    qp.show();
  });
}

// git-base's pickRemoteSource, through its command so it works from any
// extension host: a typed URL comes back as a string; a provider's
// repository (e.g. GitHub, with VS Code's GitHub sign-in) as {url, branch}.
async function pickRemoteSource(): Promise<{ url: string; branch?: string } | undefined> {
  const options = {
    title: "Clone Repository in Coder Workspace",
    urlLabel: "Clone from URL",
    showRecentSources: true,
    branch: true,
  };
  let picked: string | { url: string; branch?: string } | undefined;
  try {
    picked = await vscode.commands.executeCommand("git-base.api.getRemoteSources", options);
  } catch {
    // No git-base (e.g. git disabled): a plain URL box.
    const url = await vscode.window.showInputBox({ title: options.title, prompt: "Repository URL (https://…, git@host:path)", ignoreFocusOut: true });
    return url?.trim() ? { url: url.trim() } : undefined;
  }
  if (!picked) return undefined;
  return typeof picked === "string" ? { url: picked } : picked;
}

async function pickBranch(repo: string): Promise<string | undefined> {
  const branches = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: "Listing branches…" },
    () =>
      new Promise<string[]>((resolve) =>
        execFile(
          "git",
          ["ls-remote", "--symref", repo, "HEAD", "refs/heads/*"],
          { timeout: 30_000, env: { ...process.env, GIT_TERMINAL_PROMPT: "0" } },
          (error, stdout) => resolve(error ? [] : parseLsRemote(stdout)),
        ),
      ),
  );
  // Private repositories without local credentials list nothing: type it.
  return pickOrType("Branch", branches.length ? "The default branch is first" : "Branch name", branches, branches.length ? "" : "main");
}

async function pickTemplate(api: CoderApi): Promise<Template | undefined> {
  const templates = await api.repositoryTemplates();
  const preferred = vscode.workspace.getConfiguration("devcontainerBuilder").get<string>("template");
  const match = templates.find((t) => t.name === preferred);
  if (match) return match;
  if (templates.length === 0) {
    vscode.window.showErrorMessage(`No template on ${api.login.url} asks for a repository and a branch (devcontainer-builder's Coder template).`);
    return undefined;
  }
  if (templates.length === 1) return templates[0];
  return (
    await vscode.window.showQuickPick(
      templates.map((t) => ({ label: t.display_name || t.name, description: t.name, detail: t.description, template: t })),
      { title: "Coder template" },
    )
  )?.template;
}

// Coder won't create a workspace while an account the template needs (its
// coder_external_auth, e.g. GitHub for private repositories) isn't linked:
// open Coder's link page and wait for it, rather than fail on create.
async function linkExternalAuth(api: CoderApi, template: Template, log: vscode.LogOutputChannel): Promise<boolean> {
  let unlinked = await api.unlinkedExternalAuth(template);
  for (const auth of unlinked) {
    const choice = await vscode.window.showInformationMessage(
      `${template.display_name || template.name} needs your ${auth.display_name} account linked in Coder (for the repository's clone and image build).`,
      { modal: true },
      `Link ${auth.display_name}`,
    );
    if (!choice) return false;
    await vscode.env.openExternal(vscode.Uri.parse(auth.authenticate_url));
  }
  if (unlinked.length === 0) return true;
  return vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: "Waiting for the account link in your browser…", cancellable: true },
    async (_progress, cancel) => {
      const deadline = Date.now() + 10 * 60_000;
      while (unlinked.length > 0) {
        if (cancel.isCancellationRequested || Date.now() > deadline) return false;
        await new Promise((r) => setTimeout(r, 3000));
        unlinked = await api.unlinkedExternalAuth(template);
      }
      log.info(`External auth linked for ${template.name}`);
      return true;
    },
  );
}

async function waitUntilReady(api: CoderApi, w: Workspace, log: vscode.LogOutputChannel): Promise<Workspace | undefined> {
  const dashboard = `${api.login.url}/@${w.owner_name}/${w.name}`;
  const result = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: w.name, cancellable: true },
    async (progress, cancel) => {
      let last = "";
      for (;;) {
        if (cancel.isCancellationRequested) return undefined;
        const current = await api.workspace(w.id);
        const p = phase(current);
        if (p.kind === "ready" || p.kind === "failed") return { workspace: current, phase: p };
        if (p.message !== last) {
          progress.report({ message: p.message });
          log.info(`${w.name}: ${p.message}`);
          last = p.message;
        }
        await new Promise((r) => setTimeout(r, 3000));
      }
    },
  );
  if (!result) return undefined;
  if (result.phase.kind === "ready") return result.workspace;

  const message = result.phase.kind === "failed" ? result.phase.message : "";
  log.error(`${w.name}: ${message}`);
  const choice = await vscode.window.showErrorMessage(`Workspace ${w.name} didn't start: ${message}`, "Show Build Log", "Open in Dashboard");
  if (choice === "Show Build Log") {
    log.info(await api.buildLog(result.workspace.latest_build.id));
    log.show();
  } else if (choice === "Open in Dashboard") {
    await vscode.env.openExternal(vscode.Uri.parse(dashboard));
  }
  return undefined;
}

// Opens the workspace in VS Code Desktop through the Coder extension,
// installing it first if needed.
async function openInDesktop(login: CoderLogin, w: Workspace): Promise<void> {
  if (!vscode.extensions.getExtension(CODER_EXTENSION)) {
    const install = await vscode.window.showInformationMessage(
      `Workspace ${w.name} is ready. Opening it needs the Coder extension (${CODER_EXTENSION}).`,
      "Install and Open",
    );
    if (install !== "Install and Open") return;
    await vscode.commands.executeCommand("workbench.extensions.installExtension", CODER_EXTENSION);
  }
  await vscode.env.openExternal(vscode.Uri.parse(desktopUri(w, login), true));
}
