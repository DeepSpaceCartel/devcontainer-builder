import { register } from 'tsx/esm/api';

// Registers tsx's ESM loader hooks for *this* process, so `.ts` files
// under `import` below can be loaded here without the caller having to
// pass NODE_OPTIONS themselves - same pattern Thomas uses for itself
// (see node_modules/thomas/cucumber.mjs, or Thomas's own
// docs/concepts/installing.md). NOT sufficient on its own here, though:
// with `parallel` set below (any value, even 1), cucumber-js loads
// support code inside separate worker subprocesses that never run this
// file's own top-level code, so this registration never reaches them
// (confirmed live: a worker-mode run throws `ERR_UNKNOWN_FILE_EXTENSION`
// on a `.ts` file with only this in place). `package.json`'s own `test`
// script sets `NODE_OPTIONS='--import tsx'` for exactly this reason - an
// env var every spawned process (coordinator and workers alike)
// inherits, unlike a call inside one process's own module code.
register();

export default {
  import: [
    'node_modules/thomas/features/support/**/*.ts',
    'node_modules/thomas/features/step_definitions/**/*.ts',
    'features/support/**/*.ts',
    'features/step_definitions/**/*.ts',
  ],
  paths: ['features/**/*.feature'],
  // Every scenario's own Background scopes its namespace/Docker Buildx
  // Builder name/fixture paths by a real CUCUMBER_WORKER_ID (see
  // docs/project/testing.md) specifically so this is safe by default -
  // override with `--parallel N` (N=1 to force fully sequential) rather
  // than editing this file for a one-off run.
  parallel: 10,
};
