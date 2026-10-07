import { spawn } from "node:child_process";

export class GitError extends Error {}

export interface GitOptions {
  timeoutMs?: number;
  // false: no GIT_ASKPASS. Coder's askpass waits for a browser sign-in when
  // the git account isn't linked, so background fetches that nobody is
  // watching fail fast instead of hanging until the timeout.
  askpass?: boolean;
}

const MAX_OUTPUT = 16 * 1024 * 1024;

// Runs git in the working copy. Never prompts in a terminal: a background
// check must not hang on credentials - it times out and reports instead. No
// optional locks: `git status` mustn't rewrite .git/index, which the
// extension watches. On a timeout the whole process group is killed, so
// git's helpers (remote-https, ssh, askpass) don't linger.
export function git(cwd: string, args: string[], { timeoutMs = 60_000, askpass = true }: GitOptions = {}): Promise<string> {
  // The subcommand, past global options like --literal-pathspecs.
  const label = args.find((a, i) => !a.startsWith("-") && args[i - 1] !== "-c" && args[i - 1] !== "-C") ?? "";
  return new Promise((resolve, reject) => {
    const env: NodeJS.ProcessEnv = { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_OPTIONAL_LOCKS: "0" };
    if (!askpass) {
      // Empty, not unset: unset would fall back to core.askPass.
      env.GIT_ASKPASS = "";
      env.SSH_ASKPASS = "";
    }
    // A process group of its own (POSIX), so a timeout can kill git's
    // children too. Windows has no process groups; git there is the clone
    // command's ls-remote only.
    const group = process.platform !== "win32";
    const child = spawn("git", args, { cwd, env, detached: group, stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    const out: Buffer[] = [];
    let size = 0;
    let stderr = "";
    let killedFor: string | undefined;
    const kill = (why: string) => {
      killedFor ??= why;
      try {
        if (group && child.pid) process.kill(-child.pid, "SIGKILL");
        else child.kill("SIGKILL");
      } catch {
        // Already gone.
      }
    };
    const timer = setTimeout(() => kill(`timed out after ${timeoutMs / 1000}s`), timeoutMs);
    child.stdout.on("data", (d: Buffer) => {
      size += d.length;
      if (size > MAX_OUTPUT) kill("output too large");
      else out.push(d);
    });
    child.stderr.on("data", (d: Buffer) => {
      if (stderr.length < 64 * 1024) stderr += d.toString("utf8");
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(new GitError(`git ${label}: ${e.message}`));
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      if (killedFor) reject(new GitError(`git ${label}: ${killedFor}`));
      else if (code !== 0) reject(new GitError(`git ${label}: ${stderr.trim() || `exited with ${code ?? signal}`}`));
      else resolve(Buffer.concat(out).toString("utf8"));
    });
  });
}

export async function gitOptional(cwd: string, args: string[], opts?: GitOptions): Promise<string | undefined> {
  try {
    return await git(cwd, args, opts);
  } catch {
    return undefined;
  }
}

export function lines(text: string | undefined): string[] {
  return (text ?? "").split("\n").map((l) => l.trim()).filter(Boolean);
}
