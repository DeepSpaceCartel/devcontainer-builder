// Child-process handling: complete output capture, signals in errors,
// and timeouts that kill the whole process tree.
import { test } from "node:test";
import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { phaseTimeout, run, runCapture } from "./process.js";

function collect(): { stream: PassThrough; text: () => string } {
  const stream = new PassThrough();
  let text = "";
  stream.on("data", (chunk) => (text += chunk));
  return { stream, text: () => text };
}

test("runCapture returns all of a large stdout, not what arrived before 'exit'", async () => {
  const { stdout } = await runCapture("sh", ["-c", "head -c 3000000 /dev/zero | tr '\\0' 'x'; echo"]);
  assert.equal(stdout.length, 3_000_000);
});

test("run pipes all stdout and stderr into the log stream before resolving", async () => {
  const log = collect();
  await run("sh", ["-c", "head -c 2000000 /dev/zero | tr '\\0' 'y'; echo done >&2"], { logStream: log.stream });
  assert.equal(log.text().length, 2_000_000 + "done\n".length);
});

test("a non-zero exit names the command and code, with URL credentials redacted", async () => {
  await assert.rejects(run("sh", ["-c", "exit 3", "https://u:secret@host/r"]), (err: Error) => {
    assert.equal(err.message, "sh -c exit 3 https://[redacted]@host/r exited with code 3");
    return true;
  });
});

test("a child killed by a signal says so", async () => {
  await assert.rejects(runCapture("sh", ["-c", "kill -TERM $$"]), /^Error: sh -c kill -TERM \$\$ was killed by SIGTERM$/);
});

test("a phase timeout kills the child and its children, and names the phase", async () => {
  const timeout = phaseTimeout("git clone", 0.2);
  const started = Date.now();
  try {
    // The grandchild sleep holds stdout open: unless the whole process
    // group is killed, 'close' would wait the full 30s for it.
    await assert.rejects(
      run("sh", ["-c", "sleep 30 & sleep 30"], { logStream: collect().stream, signal: timeout.signal }),
      /was killed by SIGTERM: git clone timed out after 0\.2s/,
    );
  } finally {
    timeout.dispose();
  }
  assert.ok(Date.now() - started < 5000, "child tree was killed promptly");
});

test("an already-expired phase doesn't start the command", async () => {
  const controller = new AbortController();
  controller.abort(new Error("image build and push timed out after 1s"));
  await assert.rejects(run("true", [], { signal: controller.signal }), /true not started: image build and push timed out/);
});
