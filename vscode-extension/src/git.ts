import { execFile } from "node:child_process";

export class GitError extends Error {}

// Runs git in the working copy. Never prompts: a background check must not
// hang on credentials (Coder's GIT_ASKPASS waits for a browser sign-in when
// external auth isn't linked yet) - it times out and reports instead. No
// optional locks: `git status` mustn't rewrite .git/index, which the
// extension watches.
export function git(cwd: string, args: string[], timeoutMs = 60_000): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      "git",
      args,
      { cwd, timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024, env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_OPTIONAL_LOCKS: "0" } },
      (error, stdout, stderr) => {
        if (error) {
          const why = error.killed ? `timed out after ${timeoutMs / 1000}s` : (stderr.trim() || error.message);
          reject(new GitError(`git ${args[0]}: ${why}`));
        } else {
          resolve(stdout);
        }
      },
    );
  });
}

export async function gitOptional(cwd: string, args: string[]): Promise<string | undefined> {
  try {
    return await git(cwd, args);
  } catch {
    return undefined;
  }
}

export function lines(text: string | undefined): string[] {
  return (text ?? "").split("\n").map((l) => l.trim()).filter(Boolean);
}
