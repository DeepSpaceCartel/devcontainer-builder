<title>Running the tests</title>

# Running the tests

The suite (`service/features/`) runs real commands against a real
Kubernetes cluster — see
[Testing philosophy](../concepts/testing.md) for why, and Thomas's own
[BDD conventions](https://alexander.ilyin.eu/Thomas/concepts/bdd-conventions/)
for the step vocabulary itself.

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
npm install    # pulls in thomas via file:../../thomas
npm test
```

`cucumber.mjs` (this project's own Cucumber config, not `package.json`)
is the one place this suite's Cucumber setup lives — it wires in
Thomas's step definitions from `node_modules/thomas/` alongside this
project's own `features/support/`/`features/step_definitions/`, targets
every `features/**/*.feature` file, and sets `parallel: 2` (see
[below](#running-scenarios-in-parallel)). `npm test` with no arguments
runs the entire real suite this way.

!!! warning "Running `cucumber-js` directly needs `NODE_OPTIONS='--import tsx'`"
    `npm test` is `NODE_OPTIONS='--import tsx' cucumber-js`, not a plain
    `npx cucumber-js` — `parallel: 2` in `cucumber.mjs` means every run
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
      parallel: 2,
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

`cucumber.mjs` sets `parallel: 2` — every `npm test` run already runs
scenarios concurrently across 2 worker subprocesses,
each with a real `CUCUMBER_WORKER_ID` env var set (see
[cucumber-js's own docs](https://github.com/cucumber/cucumber-js/blob/main/docs/parallel.md)).
Every file's Background captures that into `<WorkerId>` (`"0"` if
somehow unset) and folds it into every real, otherwise-shared name this
suite creates: the Kubernetes namespace
(`devcontainer-builder-<Owner>-w<WorkerId>`), the Docker Buildx Builder
name (e.g. `devcontainer-builder-health-w<WorkerId>`), and every
generated fixture path (e.g.
`.cache/fixtures/git-source-resolution-w<WorkerId>/...`) — so concurrent
workers never collide on any of them. Two distinct namespaces/builder
names/fixture directories genuinely appear on the cluster/local
filesystem while a run is in flight — that's expected, not a leak, as
long as they're all gone again once it finishes.

Override the worker count with `--parallel N` (`--parallel 1` for fully
sequential, useful while debugging one scenario):

```bash
NODE_OPTIONS='--import tsx' npx cucumber-js --parallel 4 features/git_source_resolution.feature
```

(subject to the same CLI-path-merging caveat above — pair it with the
scratch targeted config to actually limit the run to one file).
