import assert from "node:assert/strict";
import { test } from "node:test";
import { CoalescingRunner, intervalMs } from "./scheduler";

// A task whose runs finish when the test says so.
function controlled() {
  const runs: { opts: { fetch: boolean }; finish: () => void; fail: (e: Error) => void }[] = [];
  const runner = new CoalescingRunner<{ fetch: boolean }>(
    (opts) =>
      new Promise<void>((resolve, reject) => {
        runs.push({ opts, finish: resolve, fail: reject });
      }),
    (a, b) => ({ fetch: a.fetch || b.fetch }),
  );
  return { runner, runs };
}

const tick = () => new Promise((r) => setImmediate(r));

test("a request during a run resolves after the queued run, not the running one", async () => {
  const { runner, runs } = controlled();
  const first = runner.run({ fetch: false });
  await tick();
  let queuedDone = false;
  const queued = runner.run({ fetch: true }).then(() => (queuedDone = true));
  runs[0].finish();
  await first;
  await tick();
  assert.equal(queuedDone, false, "resolved with the stale run");
  assert.equal(runs.length, 2);
  assert.deepEqual(runs[1].opts, { fetch: true });
  runs[1].finish();
  await queued;
  assert.equal(queuedDone, true);
});

test("requests queued together are merged into one run and share its promise", async () => {
  const { runner, runs } = controlled();
  void runner.run({ fetch: false });
  await tick();
  const a = runner.run({ fetch: false });
  const b = runner.run({ fetch: true });
  assert.equal(a, b);
  runs[0].finish();
  await tick();
  assert.equal(runs.length, 2);
  assert.deepEqual(runs[1].opts, { fetch: true });
  runs[1].finish();
  await a;
  // Idle again: the next request starts straight away.
  void runner.run({ fetch: false });
  await tick();
  assert.equal(runs.length, 3);
});

test("a failed run still runs the queued one; each caller sees its own run's outcome", async () => {
  const { runner, runs } = controlled();
  const first = runner.run({ fetch: false });
  await tick();
  const queued = runner.run({ fetch: false });
  runs[0].fail(new Error("boom"));
  await assert.rejects(first, /boom/);
  await tick();
  assert.equal(runs.length, 2);
  runs[1].finish();
  await queued;
});

test("intervalMs: minutes to a safe setInterval delay", () => {
  assert.equal(intervalMs(5), 5 * 60_000);
  assert.equal(intervalMs(0), 0);
  assert.equal(intervalMs(-3), 0);
  assert.equal(intervalMs(Number.NaN), 0);
  assert.equal(intervalMs("x"), 0);
  assert.equal(intervalMs(1e9), 1440 * 60_000);
  assert.ok(intervalMs(1e9) < 2 ** 31 - 1);
});
