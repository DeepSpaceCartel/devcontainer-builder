import { setDefaultTimeout } from "@cucumber/cucumber";

// Cucumber's built-in default (5000ms) is fine for pure validation-boundary
// checks, but too tight once a step triggers a real clone + BuildKit build +
// registry push - especially the first request in a run, which also has to
// cold-create the local `docker buildx` builder connection AND cold-pull
// whatever base image the fixture's devcontainer.json references onto the
// BuildKit worker node for the first time (observed: a first-ever pull of
// mcr.microsoft.com/devcontainers/base needed more than 30s). Applies
// globally (cheap for fast suites too - it only raises the ceiling before a
// genuinely hung step gets reported, it doesn't slow anything down).
//
// Must stay comfortably above the largest `--timeout` any step's own `helm
// upgrade --install --wait` uses (currently 180s, for test-git-server/
// buildkit fixtures) - if Cucumber's own step timeout fires first, it only
// abandons the JS-level await; the actual `helm` child process it was
// waiting on keeps running in the background (orphaned), which then holds
// a release lock and makes the *next* scenario's `helm upgrade` on the same
// release fail with "another operation (install/upgrade/rollback) is in
// progress" - a confusing failure one scenario removed from its real cause.
setDefaultTimeout(240_000);
