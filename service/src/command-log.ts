import { createWriteStream, type WriteStream } from "node:fs";
import { mkdir, readdir, readFile, rm, stat } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { serviceConfig } from "./config.js";

export type CommandLogKind = "git" | "docker";

// Reuses the same ephemeral scratch space (os.tmpdir(), backed by the
// chart's emptyDir "scratch" volume) build.ts's own per-build workDir
// already lives under - not a new persistent volume. These files
// deliberately do not survive a pod restart; that's an accepted
// limitation (see ADR-0010), not a gap this closes.
const logsDir = join(tmpdir(), "devcontainer-builder-logs");

// A client-supplied id (GET/DELETE /logs/:id) must never be trusted as a
// path segment directly - this is the only thing standing between a
// malformed id and a path-traversal read/delete outside logsDir. Mirrored
// at the HTTP layer by schemas.ts's own pattern-validated param, but kept
// here too as defense in depth for any other caller of this module.
const ID_RE = /^(git|docker)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function pathForId(id: string): string | undefined {
  if (!ID_RE.test(id)) return undefined;
  return join(logsDir, `${id}.log`);
}

export interface CommandLog {
  kind: CommandLogKind;
  id: string;
  stream: WriteStream;
}

export async function openCommandLog(kind: CommandLogKind): Promise<CommandLog> {
  await mkdir(logsDir, { recursive: true });
  const id = `${kind}-${randomUUID()}`;
  const stream = createWriteStream(join(logsDir, `${id}.log`));
  return { kind, id, stream };
}

// Ends the stream, then prunes this kind's own bucket down to
// serviceConfig.commandLogRetention, oldest first - "git" and "docker" are
// independent buckets, each capped on their own.
export async function closeCommandLog(log: CommandLog): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    log.stream.end((err: NodeJS.ErrnoException | null | undefined) => (err ? reject(err) : resolve()));
  });
  await rotateCommandLogs(log.kind);
}

async function rotateCommandLogs(kind: CommandLogKind): Promise<void> {
  const entries = await readdir(logsDir).catch((err: NodeJS.ErrnoException) => {
    if (err.code === "ENOENT") return [];
    throw err;
  });

  const candidates = entries.filter((name) => name.startsWith(`${kind}-`) && name.endsWith(".log"));
  const withMtime = await Promise.all(
    candidates.map(async (name) => ({ name, mtimeMs: (await stat(join(logsDir, name))).mtimeMs })),
  );
  withMtime.sort((a, b) => b.mtimeMs - a.mtimeMs);

  const stale = withMtime.slice(serviceConfig.commandLogRetention);
  await Promise.all(stale.map(({ name }) => rm(join(logsDir, name), { force: true })));
}

export async function readCommandLog(id: string): Promise<Buffer | undefined> {
  const path = pathForId(id);
  if (!path) return undefined;

  try {
    return await readFile(path);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw err;
  }
}

export async function deleteCommandLog(id: string): Promise<boolean> {
  const path = pathForId(id);
  if (!path) return false;

  try {
    await rm(path);
    return true;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw err;
  }
}
