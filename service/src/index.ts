// The real entrypoint (see Dockerfile's ENTRYPOINT). server.ts's own
// startup (loading env/CLI/settings-file config) throws synchronously
// during module evaluation on misconfiguration - before server.ts's own
// body, let alone anything it could register, ever runs. A static
// `import "./server.js"` here would throw at the same uncatchable point,
// so this stays a dynamic import: it runs after the handlers below are
// already registered, which is what actually gets a chance to format the
// crash before Node's own default (a raw stack trace to stderr) fires.
function logFatal(err: unknown): void {
  const message = err instanceof Error ? err.message : String(err);
  const stack = err instanceof Error ? err.stack : undefined;
  console.error(JSON.stringify({ level: "fatal", timestamp: new Date().toISOString(), message, stack }));
}

process.on("uncaughtException", (err) => {
  logFatal(err);
  process.exit(1);
});

process.on("unhandledRejection", (reason) => {
  logFatal(reason);
  process.exit(1);
});

await import("./server.js");
