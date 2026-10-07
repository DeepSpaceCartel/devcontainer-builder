// One run at a time. A request during a run is queued (requests queued
// together are merged into one run), and the caller's promise settles when
// the run that covers its request has finished - not the one already under
// way, whose results may be older than the request.
export class CoalescingRunner<T> {
  private running: Promise<void> | undefined;
  private queued: { opts: T; done: Promise<void> } | undefined;

  constructor(
    private readonly task: (opts: T) => Promise<void>,
    private readonly merge: (a: T, b: T) => T,
  ) {}

  run(opts: T): Promise<void> {
    if (this.queued) {
      this.queued.opts = this.merge(this.queued.opts, opts);
      return this.queued.done;
    }
    if (!this.running) return this.start(opts);
    const queued = { opts } as { opts: T; done: Promise<void> };
    queued.done = this.running
      .catch(() => undefined)
      .then(() => {
        this.queued = undefined;
        return this.start(queued.opts);
      });
    this.queued = queued;
    return queued.done;
  }

  private start(opts: T): Promise<void> {
    const run: Promise<void> = Promise.resolve()
      .then(() => this.task(opts))
      .finally(() => {
        if (this.running === run) this.running = undefined;
      });
    this.running = run;
    return run;
  }
}

export const MAX_INTERVAL_MINUTES = 1440;

// checkIntervalMinutes as a setInterval delay: 0 (or anything that isn't a
// positive number) is off, and at most a day - setInterval treats delays
// over 2^31-1 ms as 1 ms.
export function intervalMs(minutes: unknown): number {
  const n = typeof minutes === "number" ? minutes : Number(minutes);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.min(n, MAX_INTERVAL_MINUTES) * 60_000;
}
