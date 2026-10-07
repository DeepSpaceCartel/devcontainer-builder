<title>Running the tests</title>

# Running the tests

The suite (`service/features/`) runs real commands against a real
Kubernetes cluster — see
[Testing philosophy](../concepts/testing.md) for why, and Thomas's own
[BDD conventions](https://alexander.ilyin.eu/Thomas/concepts/bdd-conventions/)
for the step vocabulary itself.

There are two suites: fast unit tests (`npm run test:unit`, seconds, no
cluster — [below](#unit-tests)) and the BDD suite (`npm test`, real
cluster, the rest of this page).

## Unit tests

```bash
cd service
npm run test:unit        # every src/*.test.ts, files in parallel
npm run test:coverage    # same, plus a per-file coverage table (Node >= 22.5)
```

`node --test` runs each test file in its own process, several at once
(one fewer than the CPU count by default). Two things make that safe and
quiet, both in `src/testing/setup.ts`, which both scripts preload with
`--import`:

- **A private `TMPDIR` per test process**, removed on exit.
  `command-log.ts` keeps its logs under `os.tmpdir()` and prunes them, so
  without this one file's rotation test could delete a log another file
  is about to read back.
- **Silent service logs.** Every injected request logs a line; set
  `TEST_LOGS=1` to see them.

Tests change settings by assigning to the exported `serviceConfig` and
restoring it afterwards, never through env vars after import, because
`config.ts` reads its sources once at import time. `config.test.ts` and
`config-files.test.ts` call `loadServiceConfig()` directly to test the
sources themselves.

The HTTP routes are tested through `buildApp()` and Fastify's
`app.inject()`, with no port open and no cluster (`server.test.ts`,
`server-routes.test.ts`). `GET`/`DELETE /image` and `GET /devcontainer`
run against `src/testing/fake-registry.ts`. It is a small OCI
distribution registry on `node:http` on `127.0.0.1` that supports
anonymous, Basic and Bearer (token exchange) auth, content-addressed
manifests, indexes and config blobs, `DELETE`, redirected blobs, and an
`override` hook for injecting failures. List its `host` in
`serviceConfig.insecureRegistries` so the client uses plain http.
`src/testing/` is excluded from the `tsc` build, so none of it ships.

!!! note "`test:coverage` needs Node 22.5 or newer"
    It uses `--test-coverage-include`/`--test-coverage-exclude`, which
    Node 22.5 added. CI runs Node 24. On older Node, run
    `node --import tsx --test --experimental-test-coverage src/*.test.ts`
    instead (that table also lists the test files).

## Prerequisites

- A real, reachable Kubernetes cluster, with `kubectl`'s current context
  pointed at it.
- `helm`, `docker` (with the `buildx` plugin), and `openssl`/`ssh-keygen`
  on `PATH`.
- Real GHCR push credentials, logged in ambiently (not threaded through
  any `.feature` file): `gh auth token | docker login ghcr.io -u
  <user> --password-stdin`, with the token scoped for `write:packages`.
  Every scenario that deploys the service itself builds and pushes this
  repo's own current source first, against the already-running shared
  BuildKit instance — see
  [Testing philosophy](../concepts/testing.md#fixture-cost-is-real-and-accepted).

## Running it

```bash
cd service
npm install    # pulls in thomas via a pinned github:DeepSpaceCartel/thomas commit
npm test
```

### Developing against a local, unreleased Thomas checkout

`service/package.json`'s `thomas` devDependency is pinned to a real commit
on Thomas's `github:DeepSpaceCartel/thomas` remote (npm resolves this via a
real `git clone`, so a plain `npm install` works from a fresh checkout with
no sibling directory needed — this is deliberate, see
[0005](../decisions/0005-bdd-suite-on-thomas.md)). Thomas itself is still
actively developed alongside this repo, though, so day-to-day work usually
means testing against a local checkout's uncommitted changes, not the pinned
commit. Do that with `npm link` instead of editing `package.json`:

```bash
cd ../../thomas && npm install && npm link
cd -  # back to service/
npm link thomas
```

This symlinks `node_modules/thomas` to the local checkout without touching
the pinned reference everyone else (and CI) installs. `npm install` in
`service/` again (or `npm unlink thomas`) reverts to the pinned commit.

`cucumber.mjs` (this project's own Cucumber config, not `package.json`)
is the one place this suite's Cucumber setup lives — it wires in
Thomas's step definitions from `node_modules/thomas/` alongside this
project's own `features/support/`/`features/step_definitions/`, targets
every `features/**/*.feature` file, and sets `parallel: 3` (see
[below](#running-scenarios-in-parallel)). `npm test` with no arguments
runs the entire real suite this way.

!!! warning "Running `cucumber-js` directly needs `NODE_OPTIONS='--import tsx'`"
    `npm test` is `NODE_OPTIONS='--import tsx' cucumber-js`, not a plain
    `npx cucumber-js` — `parallel: 3` in `cucumber.mjs` means every run
    (even a targeted single-file one below) loads support code inside
    separate worker subprocesses, and cucumber.mjs's own top-level
    `register()` call only registers tsx's ESM loader for whichever
    process evaluates that file first, never for a worker it spawns
    afterward (confirmed live: omitting `NODE_OPTIONS` fails with
    `ERR_UNKNOWN_FILE_EXTENSION` on a `.ts` file). Every command below
    that calls `cucumber-js` directly needs the same
    `NODE_OPTIONS='--import tsx'` prefix `npm test` already carries.

### One file at a time

```bash
NODE_OPTIONS='--import tsx' npx cucumber-js features/health.feature
```

!!! warning "Cucumber merges CLI path arguments with `cucumber.mjs`'s own `paths:`, it doesn't override them"
    Passing a specific file on the command line does **not** by itself
    limit the run to that file — cucumber-js merges explicit path
    arguments with whatever `paths:` the config file already declares,
    rather than replacing it. A config with `paths: ['features/**/*.feature']`
    plus a CLI argument for one file still runs the *entire* suite. Use
    a scratch config with an empty `paths: []` for a genuinely targeted
    run:
    ```js
    // .cache/cucumber.targeted.mjs
    import { register } from 'tsx/esm/api';
    register();
    export default {
      import: ['node_modules/thomas/features/support/**/*.ts', 'node_modules/thomas/features/step_definitions/**/*.ts', 'features/support/**/*.ts', 'features/step_definitions/**/*.ts'],
      paths: [],
      parallel: 3,
    };
    ```
    ```bash
    NODE_OPTIONS='--import tsx' npx cucumber-js --config .cache/cucumber.targeted.mjs features/health.feature
    ```

### Only one real suite invocation at a time

Every scenario deploys into (and cleans up after itself in) a real,
shared namespace keyed off `${CODER_WORKSPACE_OWNER_NAME:-${USER:-local}}`
plus a worker id (`-w0`, `-w1`, ... — see
[below](#running-scenarios-in-parallel)). That makes the workers *within*
one invocation safe to run concurrently, but two separate invocations
(two people running the suite at the same time, or a run you thought you
killed but didn't) still collide — both would reset `CUCUMBER_WORKER_ID`
independently and reuse the same `-w0`/`-w1`/... names, corrupting each
other's cluster state (stray releases, a Docker Buildx Builder one run's
cleanup can't remove because another run already recreated it under the
same name). Confirm nothing else is running (`ps` for a stray
`cucumber-js`) before starting a real run, and if a run does get
interrupted, check for and clean up leftovers before retrying:

```bash
docker buildx ls
helm list -n "devcontainer-builder-${USER}-w0"
kubectl get pods,secrets,configmaps -n "devcontainer-builder-${USER}-w0"
```

## Running scenarios in parallel

`cucumber.mjs` sets `parallel: 3` — every `npm test` run already runs
scenarios concurrently across 3 worker subprocesses,
each with a real `CUCUMBER_WORKER_ID` env var set (see
[cucumber-js's own docs](https://github.com/cucumber/cucumber-js/blob/main/docs/parallel.md)).
Every file's Background captures that into `<WorkerId>` (`"0"` if
somehow unset) and folds it into every real, otherwise-shared name this
suite creates: the Kubernetes namespace
(`devcontainer-builder-<Owner>-w<WorkerId>`), the Docker Buildx Builder
name (e.g. `devcontainer-builder-health-w<WorkerId>`), and every
generated fixture path (e.g.
`.cache/fixtures/git-source-resolution-w<WorkerId>/...`) — so concurrent
workers never collide on any of them. Several distinct namespaces/builder
names/fixture directories genuinely appear on the cluster/local
filesystem while a run is in flight — that's expected, not a leak, as
long as they're all gone again once it finishes.

Every worker deploys its own full fixture set (the service, two
registries, BuildKit, a git server), so the worker count is bounded by
the cluster's schedulable memory, not the machine running cucumber: at
`--parallel 10`, the dev cluster's two 4 GB worker nodes ran out of
memory requests, pods sat `Pending`, and most scenarios failed on Helm
`--wait` timeouts rather than on anything they test. Raise it only on a
cluster with room (or a working autoscaler) to match.

Override the worker count with `--parallel N` (`--parallel 1` for fully
sequential, useful while debugging one scenario):

```bash
NODE_OPTIONS='--import tsx' npx cucumber-js --parallel 4 features/git_source_resolution.feature
```

(subject to the same CLI-path-merging caveat above — pair it with the
scratch targeted config to actually limit the run to one file).

## Making the suite faster

A full `npm test` runs **140 scenarios** (Scenario Outline example rows
counted separately). Every one runs its file's whole Background again:
there is no per-file or per-worker setup, and every scenario ends by
uninstalling its namespace with `--wait`. Each of those 140 runs:

- creates a Docker Buildx Builder;
- builds and pushes `ghcr.io/deepspacecartel/devcontainer-builder-test:test`
  from `.`;
- installs a fresh namespace.

Of the 140, 59 (in 8 files) also install their own registry or registries
and a fresh BuildKit, and 44 of those (in 6 files) add a git server too.
The suggestions below are ordered by how much time they would save. Each
one comes from what the code does today; none has been measured on the
cluster yet.

1. **Move HTTP-only scenarios to `inject()` unit tests.** About half of the
   scenarios never need a real git server, BuildKit or registry:
    - all 53 rows of `request_validation.feature`;
    - the seven 404 rows and the readiness and liveness scenarios in
      `health.feature`;
    - "An unparseable repository URL is rejected" in
      `git_source_resolution.feature`;
    - the config-parsing scenarios in `service_startup_configuration.feature`
      and `service_settings_file.feature`.

    `server.test.ts`, `server-routes.test.ts` and `config-files.test.ts`
    already cover most of these rules in milliseconds. Keep one wiring
    scenario per file in BDD (a real pod answers a 400, a real bad setting
    crash-loops) and delete the rest. Each scenario removed saves a whole
    namespace, image build and Helm cycle.
2. **Build and push the service image once per run, not once per
   scenario.** The tag is identical every time, and so is the content:
   the Dockerfile only copies `package*.json`, `tsconfig.json` and
   `src/`. Yet each Background rebuilds and pushes it, all three workers
   push the same tag at once, and every release sets
   `image.pullPolicy=Always`, so every pod pulls it again.
    - Build it once before cucumber starts, for example in an npm
      `pretest` script. A cucumber `BeforeAll` runs once per worker, so it
      would still build three times.
    - Tag it with the source's content hash or git SHA.
    - Deploy with `pullPolicy: IfNotPresent`, so kubelet caches the image
      per node.
    - This also removes the per-scenario `docker buildx create`/`rm`,
      which exists only for this build.
3. **Share fixtures per worker.** The namespace name already depends only
   on the worker id. Within a file, the registries, BuildKit and git
   server get the same values in every scenario; only the service release
   (and, in `git_source_resolution.feature`, a CA ConfigMap) differs.
   Installing those fixtures once per worker would:
    - remove three to five Helm installs and uninstalls per scenario;
    - keep the BuildKit cache warm. Today every fresh BuildKit pulls the
      Dev Container base image again for each build.

    This trades away part of [Fixture cost is real and
    accepted](../concepts/testing.md#fixture-cost-is-real-and-accepted),
    so record that decision in an ADR first.
4. **Drop redundant uninstalls.** Teardown runs up to five
   `helm uninstall` calls before the final namespace uninstall with
   `--wait`, which deletes everything in the namespace anyway (see
   `image_resolution.feature`). Keep the namespace uninstall only.
5. **Faster probes and polls for test releases.** The chart's startup and
   readiness probes check every 5s, so each `helm --wait` for the service
   finishes in 5–10s steps. The `--set` lines of a test release could
   shorten those probe periods to 1s. The log and Pod polls use 1–2s
   intervals, and a shorter interval also ends a poll sooner once its
   condition is met. The suite has no fixed sleeps.
6. ~~Fix `cucumber.mjs`'s support globs~~ (done): the `.js` support and
   step files under `features/` were left over from before the suite moved
   to Thomas, and `cucumber.mjs` never loaded them (it imports `*.ts` only).
   They were deleted; Thomas provides every step and the defaults.
7. **Quick profiles.** `@smoke` exists on `end_to_end_build.feature` but
   nothing selects it. A `smoke` profile (`--tags @smoke`) plus `failFast`
   for local runs would stop a broken run early instead of finishing all
   140 scenarios.

The unit suite already runs its files in parallel, and none of its tests
sleeps. The longest tests are about 200ms each: the 200ms registry timeout
and the phase-timeout kill test, both deliberately short. Most of its
wall time is each file's process loading Fastify and `@sentry/node`
through tsx, about 1.5s for files that import `server.ts`.
`--test-isolation=none`, which runs all files in one process, doesn't
work today: `config.ts` parses `process.argv` when it is imported and
rejects the test runner's file arguments.
