import * as vscode from "vscode";
import { cloneInWorkspace } from "./cloneCommand";
import { coderUrl, NotLoggedIn, requestRebuild, sessionToken, settingsUrl, type CoderWorkspace } from "./coder";
import { decidePrompt, localKey, shortSha, type PromptMemory } from "./prompt";
import { checkStatus, type Status, type Workspace } from "./status";

const IGNORED_ORIGIN_KEY = "devcontainerBuilder.ignoredOrigin";
const ADD_CONFIG_DISMISSED_KEY = "devcontainerBuilder.addConfigDismissed";
// Dev Containers' "Add Dev Container Configuration Files…": templates,
// options and Features, in VS Code Desktop (the extension is UI-side).
const DEV_CONTAINERS_ADD_CONFIG = "remote-containers.createDevContainerFile";
const DEV_CONTAINERS_EXTENSION = "ms-vscode-remote.remote-containers";

// Env set by the Coder template (see templates/coder-kubernetes). Absent
// anywhere else - e.g. a local window, where only the clone command works.
function workspaceFromEnv(): Workspace | undefined {
  const imageCommit = process.env.DEVCONTAINER_IMAGE_COMMIT;
  const branch = process.env.DEVCONTAINER_BRANCH;
  const folder = process.env.DEVCONTAINER_WORKSPACE_FOLDER ?? vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  if (imageCommit === undefined || !branch || !folder) return undefined;
  return { folder, imageCommit, branch };
}

export function activate(context: vscode.ExtensionContext): void {
  const ws = workspaceFromEnv();
  const log = vscode.window.createOutputChannel("Dev Container Rebuild", { log: true });
  context.subscriptions.push(log);
  const reportErrors =
    (fn: () => Promise<unknown>) =>
    async (): Promise<void> => {
      try {
        await fn();
      } catch (e) {
        log.error((e as Error).message);
        vscode.window.showErrorMessage((e as Error).message);
      }
    };

  // Locally (extensionKind "ui") and in a workspace alike.
  context.subscriptions.push(vscode.commands.registerCommand("devcontainerBuilder.cloneInWorkspace", reportErrors(() => cloneInWorkspace(context, log))));
  void vscode.commands.executeCommand("setContext", "devcontainerBuilder.inWorkspace", ws !== undefined);

  if (!ws) {
    const inactive = () =>
      vscode.window.showInformationMessage("This command only works in a Coder workspace built by devcontainer-builder.");
    context.subscriptions.push(
      vscode.commands.registerCommand("devcontainerBuilder.check", inactive),
      vscode.commands.registerCommand("devcontainerBuilder.rebuild", inactive),
    );
    return;
  }

  const item = vscode.window.createStatusBarItem("devcontainerBuilder.status", vscode.StatusBarAlignment.Left, 10);
  item.name = "Dev Container Rebuild";
  context.subscriptions.push(item);

  const memory: PromptMemory = {
    snoozed: false,
    ignoredOrigin: context.workspaceState.get<string>(IGNORED_ORIGIN_KEY),
    addConfigDismissed: context.workspaceState.get<boolean>(ADD_CONFIG_DISMISSED_KEY),
  };
  let last: Status | undefined;
  let running: Promise<void> | undefined;
  let again: { fetch: boolean } | undefined;

  const render = (status: Status) => {
    const image = shortSha(status.imageCommit);
    const origin = shortSha(status.originCommit);
    const tip = new vscode.MarkdownString(undefined, true);
    tip.appendMarkdown(`**Dev Container image**: \`${image}\` · **origin/${status.branch}**: \`${origin}\`\n\n`);
    switch (status.kind) {
      case "up-to-date":
        item.text = `$(container) ${image}`;
        item.backgroundColor = undefined;
        tip.appendMarkdown("The image is up to date with the branch's Dev Container configuration.");
        item.command = "devcontainerBuilder.check";
        break;
      case "rebuild-available":
        item.text = "$(sync) Rebuild available";
        item.backgroundColor = new vscode.ThemeColor("statusBarItem.warningBackground");
        tip.appendMarkdown(`Changed on origin since the image was built:\n\n${status.changed.map((f) => `- \`${f}\``).join("\n")}\n\nClick for options.`);
        item.command = "devcontainerBuilder.showPrompt";
        break;
      case "unpushed":
        item.text = "$(cloud-upload) Push Dev Container changes";
        item.backgroundColor = undefined;
        tip.appendMarkdown(
          `Not on origin/${status.branch} yet, so a rebuild wouldn't include them:\n\n${status.local.map((f) => `- \`${f}\``).join("\n")}\n\nCommit and push, then rebuild.`,
        );
        item.command = "workbench.view.scm";
        break;
      case "no-config":
        item.text = "$(add) Add Dev Container config";
        item.backgroundColor = undefined;
        tip.appendMarkdown(
          "This repository has no devcontainer.json, so the workspace runs on a generic image. Click to add a Dev Container configuration from a template.",
        );
        item.command = "devcontainerBuilder.addConfig";
        break;
      default:
        item.text = "$(container) $(question)";
        item.backgroundColor = undefined;
        tip.appendMarkdown(`Couldn't check for Dev Container changes: ${status.reason ?? "unknown error"}\n\nClick to check again.`);
        item.command = "devcontainerBuilder.check";
    }
    item.tooltip = tip;
    item.show();
  };

  const rebuild = async () => {
    const coder: CoderWorkspace | undefined = await coderWorkspace();
    if (!coder) {
      vscode.window.showErrorMessage("Dev Container Rebuild: this workspace's Coder details (CODER_WORKSPACE_ID, CODER_AGENT_URL) aren't set.");
      return;
    }
    const token = await sessionToken();
    const openSettings = async (why: string) => {
      log.info(`${why} - opening ${settingsUrl(coder)}`);
      const choice = await vscode.window.showInformationMessage(
        `${why} Increase Rebuild in the workspace's settings instead, or run \`coder login ${coder.url}\` in a terminal once for one-click rebuilds.`,
        "Open Settings",
      );
      if (choice === "Open Settings") await vscode.env.openExternal(vscode.Uri.parse(settingsUrl(coder)));
    };
    if (!token) {
      await openSettings("Not logged in to Coder in this workspace.");
      return;
    }
    try {
      const next = await vscode.window.withProgress(
        { location: vscode.ProgressLocation.Notification, title: "Requesting a workspace rebuild…" },
        () => requestRebuild(coder, token),
      );
      log.info(`Rebuild requested (rebuild=${next})`);
      vscode.window.showInformationMessage(
        "Rebuild started: the workspace restarts on a new image from origin. VS Code reconnects when it's back; uncommitted work in the repo folder and home is kept.",
      );
    } catch (e) {
      if (e instanceof NotLoggedIn) {
        await openSettings(e.message);
      } else {
        log.error(`Rebuild failed: ${(e as Error).message}`);
        vscode.window.showErrorMessage(`Dev Container Rebuild failed: ${(e as Error).message}`);
      }
    }
  };

  const showRebuildPrompt = async (status: Status) => {
    memory.promptedOrigin = status.originCommit;
    const choice = await vscode.window.showInformationMessage(
      `Dev Container configuration changed on origin/${status.branch} since this workspace's image (${shortSha(status.imageCommit)} → ${shortSha(status.originCommit)}): ${status.changed.join(", ")}. Rebuild the workspace?`,
      "Rebuild",
      "Later",
      "Ignore This Commit",
    );
    if (choice === "Rebuild") {
      await rebuild();
    } else if (choice === "Later") {
      memory.snoozed = true;
    } else if (choice === "Ignore This Commit") {
      memory.ignoredOrigin = status.originCommit;
      await context.workspaceState.update(IGNORED_ORIGIN_KEY, status.originCommit);
    }
  };

  const prompt = async (status: Status) => {
    const decision = decidePrompt(status, memory);
    if (decision.kind === "rebuild") {
      await showRebuildPrompt(status);
    } else if (decision.kind === "add-config") {
      memory.addConfigDismissed = true;
      const choice = await vscode.window.showInformationMessage(
        "This repository has no devcontainer.json, so the workspace runs on a generic image. Add a Dev Container configuration?",
        "Add Configuration",
        "Not Now",
        "Don't Ask Again",
      );
      if (choice === "Add Configuration") await vscode.commands.executeCommand("devcontainerBuilder.addConfig");
      else if (choice === "Don't Ask Again") await context.workspaceState.update(ADD_CONFIG_DISMISSED_KEY, true);
    } else if (decision.kind === "push") {
      memory.nudgedLocal = localKey(status);
      const choice = await vscode.window.showInformationMessage(
        `Dev Container changes aren't on origin/${status.branch} yet (${status.local.join(", ")}). A rebuild builds origin/${status.branch}, so commit and push them first.`,
        "Open Source Control",
      );
      if (choice === "Open Source Control") await vscode.commands.executeCommand("workbench.view.scm");
    }
  };

  // One check at a time; a request during a check runs once after it.
  const check = (opts: { fetch: boolean }): Promise<void> => {
    if (running) {
      again = { fetch: (again?.fetch ?? false) || opts.fetch };
      return running;
    }
    running = (async () => {
      const status = await checkStatus(ws, opts);
      if (status.kind === "unknown") log.warn(`Check failed: ${status.reason}`);
      else log.info(`${status.kind}: image ${shortSha(status.imageCommit)}, origin/${status.branch} ${shortSha(status.originCommit)}, paths ${status.paths.join(" ")}`);
      last = status;
      render(status);
      void prompt(status);
    })().finally(() => {
      running = undefined;
      if (again) {
        const next = again;
        again = undefined;
        void check(next);
      }
    });
    return running;
  };

  context.subscriptions.push(
    vscode.commands.registerCommand("devcontainerBuilder.check", async () => {
      memory.promptedOrigin = undefined;
      memory.snoozed = false;
      await check({ fetch: true });
      if (last?.kind === "up-to-date") vscode.window.showInformationMessage("The workspace's Dev Container image is up to date.");
    }),
    // The status bar's click: the same choices as the notification, even
    // after Later or Ignore, so a rebuild is always a deliberate press.
    // Not in the palette (not contributed); Rebuild Workspace is.
    vscode.commands.registerCommand("devcontainerBuilder.showPrompt", async () => {
      if (last?.kind === "rebuild-available") await showRebuildPrompt(last);
      else await check({ fetch: true });
    }),
    // Not in the palette (not contributed): the status bar's and the
    // notification's way to Dev Containers' own command.
    vscode.commands.registerCommand(
      "devcontainerBuilder.addConfig",
      reportErrors(async () => {
        if ((await vscode.commands.getCommands(true)).includes(DEV_CONTAINERS_ADD_CONFIG)) {
          await vscode.commands.executeCommand(DEV_CONTAINERS_ADD_CONFIG);
          return;
        }
        const choice = await vscode.window.showInformationMessage(
          "Adding a configuration uses the Dev Containers extension's \"Add Dev Container Configuration Files…\", in VS Code Desktop. Commit and push what it adds, then rebuild.",
          "Install Dev Containers",
        );
        if (choice === "Install Dev Containers") await vscode.commands.executeCommand("workbench.extensions.installExtension", DEV_CONTAINERS_EXTENSION);
      }),
    ),
    vscode.commands.registerCommand("devcontainerBuilder.rebuild", async () => {
      if (last?.kind === "unpushed") {
        const choice = await vscode.window.showWarningMessage(
          `Your Dev Container changes aren't on origin/${ws.branch}; a rebuild won't include them.`,
          "Rebuild Anyway",
        );
        if (choice !== "Rebuild Anyway") return;
      }
      await rebuild();
    }),
  );

  // Local changes and fetches (by the user, VS Code's autofetch or a push)
  // re-check without fetching again - fetching here would touch FETCH_HEAD
  // and loop.
  let timer: NodeJS.Timeout | undefined;
  const soon = () => {
    clearTimeout(timer);
    timer = setTimeout(() => void check({ fetch: false }), 2000);
  };
  const folder = vscode.Uri.file(ws.folder);
  for (const pattern of [".devcontainer/**", ".devcontainer.json", ".git/FETCH_HEAD", ".git/packed-refs", `.git/refs/remotes/origin/**`, ".git/HEAD", ".git/index"]) {
    const watcher = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(folder, pattern));
    watcher.onDidChange(soon);
    watcher.onDidCreate(soon);
    watcher.onDidDelete(soon);
    context.subscriptions.push(watcher);
  }
  context.subscriptions.push(vscode.workspace.onDidSaveTextDocument(soon), { dispose: () => clearTimeout(timer) });

  let interval: NodeJS.Timeout | undefined;
  const schedule = () => {
    clearInterval(interval);
    const minutes = vscode.workspace.getConfiguration("devcontainerBuilder").get<number>("checkIntervalMinutes", 5);
    if (minutes > 0) interval = setInterval(() => void check({ fetch: true }), minutes * 60_000);
  };
  schedule();
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => e.affectsConfiguration("devcontainerBuilder.checkIntervalMinutes") && schedule()),
    { dispose: () => clearInterval(interval) },
  );

  void check({ fetch: true });
}

async function coderWorkspace(): Promise<CoderWorkspace | undefined> {
  const url = await coderUrl();
  const { CODER_WORKSPACE_ID: id, CODER_WORKSPACE_NAME: name, CODER_WORKSPACE_OWNER_NAME: owner } = process.env;
  if (!url || !id || !name || !owner) return undefined;
  return { url, id, name, owner, rebuild: Number(process.env.DEVCONTAINER_REBUILD ?? 0) || 0 };
}

export function deactivate(): void {}
