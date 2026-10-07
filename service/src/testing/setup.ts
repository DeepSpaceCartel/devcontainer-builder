// Preloaded into every unit-test process by `npm run test:unit` (`--import`),
// before any test file - and so before config.ts, logger.ts and
// command-log.ts evaluate.
//
// - A private TMPDIR per test process: `node --test` runs files
//   concurrently, and command-log.ts derives its logs directory from
//   os.tmpdir() at import time and rotates it - without this, one file's
//   rotation test could prune another file's freshly written log.
// - Quiet logs: the service's structured logs (one line per injected
//   request) otherwise drown the test report. TEST_LOGS=1 brings them back.
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "dcb-unit-"));
process.env.TMPDIR = dir;
process.on("exit", () => rmSync(dir, { recursive: true, force: true }));

if (process.env.TEST_LOGS !== "1") {
  const { logger } = await import("../logger.js");
  logger.level = "silent";
}
