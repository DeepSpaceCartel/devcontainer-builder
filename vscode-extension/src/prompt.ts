import type { Status } from "./status";

export interface PromptMemory {
  // "Later": no prompts until the window reloads (a restart after a
  // rebuild reloads it too).
  snoozed: boolean;
  // "Ignore this commit": no prompts until origin moves past it.
  ignoredOrigin?: string;
  // Already prompted (or nudged) for this origin commit in this window.
  promptedOrigin?: string;
  nudgedLocal?: string;
  // "Not Now" / "Don't Ask Again" on adding a configuration.
  addConfigDismissed?: boolean;
}

export type Prompt = { kind: "rebuild" } | { kind: "push" } | { kind: "add-config" } | { kind: "none" };

// Whether a fresh status should interrupt with a notification. The status
// bar always shows the state; notifications are once per origin commit.
export function decidePrompt(status: Status, memory: PromptMemory): Prompt {
  if (status.kind === "rebuild-available") {
    if (memory.snoozed || status.originCommit === memory.ignoredOrigin || status.originCommit === memory.promptedOrigin) {
      return { kind: "none" };
    }
    return { kind: "rebuild" };
  }
  if (status.kind === "no-config") {
    return memory.addConfigDismissed ? { kind: "none" } : { kind: "add-config" };
  }
  if (status.kind === "unpushed") {
    return memory.nudgedLocal === localKey(status) ? { kind: "none" } : { kind: "push" };
  }
  return { kind: "none" };
}

// Identifies a set of local changes, so the "push first" nudge isn't
// repeated for the same files.
export function localKey(status: Status): string {
  return status.local.join("\n");
}

// The rebuild notification. Local changes still matter when origin also
// changed: a rebuild wouldn't include them, so say so here too.
export function rebuildMessage(status: Status): string {
  const what = status.changed.length > 0 ? `: ${status.changed.join(", ")}` : status.reason ? `. ${status.reason}` : "";
  let message = `Dev Container configuration changed on origin/${status.branch} since this workspace's image (${shortSha(status.imageCommit)} → ${shortSha(status.originCommit)})${what}`;
  if (!/[.!?]$/.test(message)) message += ".";
  if (status.local.length > 0) {
    message += ` Your changes to ${status.local.join(", ")} aren't on origin/${status.branch} yet, so a rebuild won't include them - commit and push them first.`;
  }
  return `${message} Rebuild the workspace?`;
}

export function shortSha(sha: string | undefined): string {
  return sha ? sha.slice(0, 7) : "unknown";
}
