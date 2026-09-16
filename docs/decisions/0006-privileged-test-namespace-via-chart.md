<title>ADR-0006</title>

# ADR-0006: A reusable chart owns every test namespace, not `--create-namespace`

Status: accepted
Date: 2026-09-12

## Context

Making the BDD suite safe to run under cucumber-js's `--parallel` (see
the worker-scoped namespace/fixture-path work this session) surfaced a
real bug: a fresh, never-before-seen namespace is rejected by this
cluster's `baseline` PodSecurity admission, which blocks the
`test-buildkit` fixture's privileged container. The immediate fix was an
imperative `When I label namespace "<Namespace>" with --overwrite
pod-security.kubernetes.io/enforce=privileged` step, added to the 6
`.feature` files that install `test-buildkit`. It worked, and matched
this project's own pre-Thomas documented convention
(`.agents/skills/disposable-k8s-test-fixtures/SKILL.md`'s "One namespace
per repo + workspace/user" section already recommended exactly this
imperative `kubectl label` fix for the old JS suite).

Reviewing it further: every one of the 10 `.feature` files creates its
own namespace via `--create-namespace` on whatever Helm release happens
to run first — an ad hoc, implicit mechanism with no single owner,
repeated (or, for the 6 buildkit files, repeated *plus* a bespoke label
step) in every file. And none of those bare, `--create-namespace`-created
namespaces are ever deleted by anything — they accumulate forever, one
per real Owner+WorkerId combination.

## Decision

A new, small, project-owned chart, `charts/test-namespace`, is the one
thing that creates and labels every test namespace. Its only template is
a `Namespace` object, named from `.Values.targetNamespace` and
optionally labeled `pod-security.kubernetes.io/enforce: privileged` when
`.Values.privileged` is set.

**The chart's own release always lives in the cluster's `default`
namespace, never in the namespace it creates.** This was not the
original design — the first attempt had the chart's release target the
namespace it was also creating (the obvious shape), and that fails
empirically: `helm upgrade --install --create-namespace` bare-creates
the namespace via its own client-side precondition, then fails applying
the chart's *own* `Namespace` manifest for that same name with `Error:
... namespaces "..." already exists` — confirmed this also fails with
Helm's `--take-ownership` flag. Helm specifically refuses to let a
release's chart own the `Namespace` object matching that release's own
namespace, separate from its generic (and more permissive)
resource-adoption rules. Installing the release into `default` instead
(always exists, so `--create-namespace` isn't even needed for the
release's own home) and passing the real target as a plain value sidesteps
this entirely — confirmed working, including a full uninstall-then-
reinstall cycle against the same target name.

Every `.feature` file installs this chart first, in `Background`, and
every scenario uninstalls it last, as the final step of its own
teardown — real, complete per-scenario namespace deletion, not the
previous forever-lingering bare namespace. Every other Helm release
across all 10 files had its own `--create-namespace` row removed:
keeping it would silently paper over a skipped/reordered/broken
namespace-chart step with an unlabeled ad hoc namespace instead of
failing loudly.

## Consequences

- **Easier**: one real, declarative, Helm-tracked object is the
  namespace's whole lifecycle — creation, the PodSecurity label, and
  deletion — instead of an ad hoc `--create-namespace` per file plus a
  side-channel label step some files needed and others didn't. A future
  file needing a privileged fixture just sets one value
  (`privileged=true`), not a bespoke step to remember.
- **Easier**: real, complete namespace cleanup after every scenario,
  which this suite never had before.
- **Harder / a real, accepted cost**: every scenario now pays a real
  delete-then-recreate namespace cost, not just release
  install/uninstall — deliberately accepted for real cleanliness, not an
  oversight. An empty namespace's full deletion measured in the low
  single-digit seconds on this cluster; a scenario's real, populated
  namespace (Deployments, Secrets, ConfigMaps) will take measurably
  longer, though still bounded by the same `helm uninstall` step every
  other release already goes through.
- **A real, accepted constraint**: the namespace-owning release lives in
  `default`, named `test-namespace-<real-target-namespace>` to stay
  unique there across every file/worker's own release — a real, if
  unusual, shape forced by Helm's own restriction on a chart owning its
  release's namespace, not a stylistic choice.

**Alternatives considered**: folding this into `charts/test-registry`
instead of a dedicated chart — rejected, couples an unrelated concern
(cluster-wide namespace policy) to a registry fixture, and doesn't
generalize to files that don't install `test-registry` at all (e.g.
`service_settings_file.feature`). Tearing the namespace down only once
per file/run (a new `AfterAll`-style hook) instead of once per scenario —
rejected this round in favor of real, per-scenario cleanliness; worth
revisiting if the added per-scenario namespace-churn cost turns out to
dominate a file's real run time.
