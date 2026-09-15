<title>ADR-0005</title>

# ADR-0005: The BDD suite runs on Thomas, a real-command framework

Status: accepted
Date: 2026-09-11

## Context

The suite originally started as plain JavaScript Cucumber.js: no typed
alias layer over the things it constructed (a `HelmRelease`, a `Pod`,
an `SshKeyPair`), real test logic embedded as raw bash one-liners inside
Gherkin `DataTable`s, an ~30-line fixture-bringup `Background` copy-pasted
near-verbatim across 8 of the suite's 10 files, and module-level mutable
`Map`/`Set` globals standing in for what a real framework would own.
Every scenario still ran real commands against a real cluster — the
problem was never mocking, it was that the suite itself had grown
without a framework underneath it.

## Decision

The suite was migrated onto [Thomas](https://alexander.ilyin.eu/Thomas/),
a separate, general-purpose real-command BDD framework built out
specifically to give this kind of suite a real "define, then act"
typed-alias layer (a `Given <Type> known as "<Alias>":` step constructs
a typed object; a separate `When` step performs the real action) instead
of raw bash strings. Where migrating a scenario needed capability Thomas
didn't already have, that capability was added to Thomas itself as a
proper, dogfooded, documented domain — not a project-local workaround —
so it's available to any other real-command suite built on Thomas, not
just this one. Docker/buildx, SSH, and TLS domains, and several
smaller additions (a captured-value comparison step, `ConfigMap`/`Secret`
creation from a real file, file-content/raw-`STDOUT` capture) all shipped
this way during the migration.

The guiding rule throughout: don't translate an old step 1:1 into a new
one — look at what it's *actually* accomplishing and use (or add) the
Thomas-native way to do that. Several apparent gaps turned out to be
unnecessary once checked against what Thomas (or Helm's own `--set`
array-index syntax, or the target application's own real behavior)
already did.

## Consequences

- **Easier**: every scenario reads as what it actually does — a typed
  `Given`/`When` sequence, not an embedded shell script — and the
  fixture-bringup duplication across files is gone (each file's
  `Background` now only builds what *that* file's scenarios actually
  need, not a copy of the largest file's own fixture stack).
- **Easier**: real gaps found while migrating became real, dogfooded
  framework capability instead of one-off scripts — including two
  genuine Thomas bugs (a substitution gap in its TLS/SSH domains, found
  via a live TLS handshake failure) that are now fixed for every future
  consumer of those domains, not patched around locally.
- **Harder / a real, accepted cost**: every scenario whose server
  configuration needs to differ installs its own Helm release rather
  than sharing one across scenarios — real, measured per-file run time
  in minutes, not seconds, particularly for files needing a disposable
  registry + trust-configured BuildKit + git-server fixture stack. This
  was deliberately accepted over more clever fixture-sharing to keep
  every scenario a genuinely independent, real round trip.
- **A real, accepted constraint**: the suite depends on Thomas via a
  local `file:../../thomas` dependency (`npm install --install-links` —
  a plain `file:` symlink pulls in Thomas's *own* `node_modules`,
  causing a dual-instance `@cucumber/cucumber` conflict) — every edit to
  Thomas needs a manual re-sync (`rm -rf node_modules/thomas && npm
  install`) in `service/`, it isn't automatic.
