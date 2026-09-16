<title>ADR-0010</title>

# ADR-0010: Capture git/docker subprocess output to files instead of stdout

Status: accepted
Date: 2026-09-16

## Context

`0009` made every log call in this service structured JSON, but two
subprocess-heavy phases of a build weren't touched by it: `git clone` and
`devcontainer build --push` (`build.ts`'s `run()`/`runCapture()`) were
spawned with `stdio: "inherit"`, writing their raw text straight onto this
process's own stdout/stderr. That interleaves with, and corrupts, the JSON
log stream every other line now emits — exactly the kind of anti-pattern
`0009` set out to remove, just for a source that ADR hadn't reached yet.
It surfaced concretely once tracing (also `0009`) added `git.clone`/
`image.build_push` spans around these same phases and made the problem
visible end to end.

## Decision

Stop inheriting stdio for these two phases. Instead:

- **Capture, don't inherit.** `run()`/`runCapture()` (`build.ts`) accept an
  optional `logStream`; when given, the child's stdout+stderr are piped
  into it instead of the parent's own stdio. Every call inside the
  `git.clone` span (all three credential branches, plus `git rev-parse
  HEAD`) and every call inside the `image.build_push` span (remote-builder
  setup plus the actual `devcontainer build --push`) now passes one.
- **One file per phase invocation** (`command-log.ts`), under
  `os.tmpdir()`'s existing ephemeral scratch space — the same volume
  `build.ts`'s own per-build workdir already lives on, not a new
  persistent volume. `"git"` and `"docker"` are the two file-name buckets;
  each is independently capped at `serviceConfig.commandLogRetention`
  (default 10, see [Configuration](../reference/CONFIGURATION.md)) —
  oldest files pruned first whenever a new one closes.
- **A JSON breadcrumb, not the content, goes to stdout.** Once a phase's
  log file closes, one structured line (`git.clone.output_captured`/
  `image.build_push.output_captured`, `"log.id"`) reports the id — the
  actual git/docker text never touches this process's own stdout again.
  Emitted via the shared `logger` singleton, not `request.log` (`build.ts`
  has no request context), but `trace.id`/`span.id` still get injected
  automatically since it's called from inside the active span.
- **The id travels with the result, success or failure.** `POST /build`
  now returns `gitCloneLogId`/`imageBuildLogId` on `200`, and `logId` on a
  `400`/`500` (an error thrown mid-clone or mid-build+push carries the
  relevant id as a plain property, read back in `server.ts`'s catch block)
  — so a caller or an operator reading the `build.failed` log line always
  knows exactly which file has the real detail, without guessing.
- **New `GET`/`DELETE /logs/:id`** (`server.ts`) fetch or remove one
  captured file by that id. `id` is validated against a strict
  `(git|docker)-<uuid>` pattern both at the HTTP schema layer
  (`LogIdParamSchema`) and inside `command-log.ts` itself — defense in
  depth against a client-supplied id ever being used to traverse outside
  the logs directory.
- **Explicitly not solved here: durability across a pod restart.** These
  files live on the same ephemeral scratch space as an in-progress build's
  own workdir — a restart loses them, same as an in-progress build would
  be lost. No PVC or object-storage backing was introduced; that's a
  deliberate scope boundary, not an oversight, since nothing about this
  service's deployment model (single ClusterIP instance, no autoscaling)
  currently needs output to outlive the pod that produced it.

## Consequences

- **Easier**: this pod's stdout is now unconditionally valid JSON, every
  line, for the entire lifetime of a build request — no more raw git/
  docker text breaking a `kubectl logs | jq` pipeline or Loki's own line
  parsing mid-build. A failed build's exact output is one `GET /logs/:id`
  away, keyed directly off the error response, instead of scrolling
  through interleaved pod logs.
- **Harder**: the BDD suite's `"the service logs should contain/not
  contain {string}"` steps (`features/step_definitions/common.steps.js`)
  previously asserted directly against raw git/docker text landing on pod
  stdout — that assumption no longer holds, and those scenarios were
  rewritten to fetch the relevant content via `GET /logs/:id` instead.
- **A real, accepted trade-off**: output capture only exists for the two
  phases wrapped in a span (git clone, build+push) — smaller helper calls
  (`ssh-keyscan`, the individual `buildx inspect`/`create`/`use` steps
  outside of a `runBuild` invocation) still inherit stdio when called
  without a `logStream`, unchanged from before this decision. In practice
  every meaningful command already runs inside one of the two wrapped
  phases, so this hasn't left a real gap.
