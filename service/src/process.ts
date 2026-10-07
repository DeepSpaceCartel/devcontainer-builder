import { spawn } from "node:child_process";
import { redactUrlCredentials } from "./git-url.js";

// How long a timed-out child gets between SIGTERM and SIGKILL.
const KILL_GRACE_MS = 10_000;

export interface RunOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  // When given, the child's stdout+stderr are piped into it; otherwise
  // stdio is inherited (see build.ts's withCommandLog for why the real
  // clone/build always pass one).
  logStream?: NodeJS.WritableStream;
  // Aborting kills the child's whole process group (SIGTERM, then SIGKILL
  // after a grace period) - `devcontainer build` forks `docker buildx`,
  // which would otherwise outlive a kill of just the direct child. The
  // abort reason's message ends up in the rejection.
  signal?: AbortSignal;
}

// The command line as it appears in errors - with any URL userinfo
// redacted, defense in depth on top of request validation rejecting
// credential-bearing repository URLs outright.
function describe(cmd: string, args: string[]): string {
  return redactUrlCredentials([cmd, ...args].join(" "));
}

function reasonOf(signal: AbortSignal): string {
  const reason: unknown = signal.reason;
  return reason instanceof Error ? reason.message : String(reason);
}

function killGroup(pid: number | undefined, signal: NodeJS.Signals): void {
  if (pid === undefined) return;
  try {
    process.kill(-pid, signal);
  } catch {
    // already gone
  }
}

// Spawns `cmd` and settles on 'close', not 'exit': 'exit' can fire while
// the child's stdout/stderr are still draining, which truncated captured
// output, let a late write land on an already-closed log stream, and could
// resolve runCapture with an empty stdout.
function spawnCommand(cmd: string, args: string[], opts: RunOptions, capture: boolean): Promise<string> {
  return new Promise((resolve, reject) => {
    if (opts.signal?.aborted) {
      reject(new Error(`${describe(cmd, args)} not started: ${reasonOf(opts.signal)}`));
      return;
    }

    const piped = capture || opts.logStream !== undefined;
    const child = spawn(cmd, args, {
      cwd: opts.cwd,
      env: opts.env ?? process.env,
      stdio: piped ? ["ignore", "pipe", opts.logStream ? "pipe" : "inherit"] : "inherit",
      // Its own process group, so a timeout can kill grandchildren too.
      detached: opts.signal !== undefined,
    });

    let stdout = "";
    if (capture) {
      child.stdout!.on("data", (chunk) => {
        stdout += chunk;
        opts.logStream?.write(chunk);
      });
    } else if (opts.logStream) {
      child.stdout?.pipe(opts.logStream, { end: false });
    }
    if (opts.logStream) child.stderr?.pipe(opts.logStream, { end: false });

    let killTimer: NodeJS.Timeout | undefined;
    const onAbort = () => {
      killGroup(child.pid, "SIGTERM");
      killTimer = setTimeout(() => killGroup(child.pid, "SIGKILL"), KILL_GRACE_MS);
      killTimer.unref();
    };
    opts.signal?.addEventListener("abort", onAbort, { once: true });
    const cleanup = () => {
      opts.signal?.removeEventListener("abort", onAbort);
      clearTimeout(killTimer);
    };

    child.on("error", (err) => {
      cleanup();
      reject(err);
    });
    child.on("close", (code, signal) => {
      cleanup();
      if (code === 0) {
        resolve(stdout.trim());
      } else if (opts.signal?.aborted) {
        reject(new Error(`${describe(cmd, args)} was killed by ${signal ?? "SIGTERM"}: ${reasonOf(opts.signal)}`));
      } else if (signal) {
        reject(new Error(`${describe(cmd, args)} was killed by ${signal}`));
      } else {
        reject(new Error(`${describe(cmd, args)} exited with code ${code}`));
      }
    });
  });
}

export async function run(cmd: string, args: string[], opts: RunOptions = {}): Promise<void> {
  await spawnCommand(cmd, args, opts, false);
}

export async function runCapture(cmd: string, args: string[], opts: RunOptions = {}): Promise<{ stdout: string }> {
  return { stdout: await spawnCommand(cmd, args, opts, true) };
}

// An AbortSignal that fires after `seconds`, with a reason naming the
// phase and its limit - so a killed command's error says why it died.
// `dispose` clears the timer once the phase is over.
export function phaseTimeout(phase: string, seconds: number): { signal: AbortSignal; dispose: () => void } {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error(`${phase} timed out after ${seconds}s`)), seconds * 1000);
  timer.unref();
  return { signal: controller.signal, dispose: () => clearTimeout(timer) };
}
