---
title: Registry pull-through cache (deferred)
created: 2026-09-06
---

# Registry pull-through cache

## What happened

While running the BDD suite's real-infra scenarios (`registry_auth.feature`,
`image_resolution.feature`) repeatedly against real BuildKit/registry
fixtures, real builds pulling `alpine:3.20` from Docker Hub started failing:

```
$ curl -H "Authorization: Bearer $TOKEN" \
    https://registry-1.docker.io/v2/library/alpine/manifests/3.20
{"errors":[{"code":"TOOMANYREQUESTS","message":"You have reached your
unauthenticated pull rate limit. https://www.docker.com/increase-rate-limit"}]}
```

Confirmed: Docker Hub's anonymous pull rate limit, exhausted from this
cluster's shared egress IP after enough real builds in one session. Every
`devcontainer build` invocation does its own pre-build "fetch image
details" step against the base image's registry (separate from BuildKit's
own pull), so it's easy to burn through the limit during iterative BDD
development even before BuildKit itself gets involved.

## Immediate mitigation (done)

Switched the git-server test fixture's seeded `.devcontainer.json` payload
from `alpine:3.20` (Docker Hub) to `mcr.microsoft.com/devcontainers/base:alpine-3.20`
(Microsoft Container Registry - no comparable anonymous rate limit). See
`charts/test-git-server/values.yaml`. This only fixes the *test fixture's*
own payload; it doesn't help a real caller's devcontainer.json that
legitimately needs a Docker Hub image, and doesn't speed up repeat pulls of
the same image across runs.

## Deferred: a real pull-through cache

A registry pull-through/mirror cache would help more durably, in two
possible scopes (not yet decided - explicitly deferred, to be picked up as
its own piece of work in a different scope of this repo):

1. **Disposable test-only**: a `charts/test-registry-cache`-style fixture,
   deployed/torn down the same way the other `test-*` fixtures are (a
   literal `helm upgrade --install`/`helm uninstall` pair driven from each
   `.feature` file's Background - see the `disposable-k8s-test-fixtures`
   skill), configured as the *test* BuildKit's `docker.io` mirror. Fixes
   flaky/rate-limited test runs, zero risk to production, matches the
   disposable-everything pattern already established for `test-*` charts.
   Doesn't help real production builds.
2. **Persistent shared infra**: a long-lived cache both the test BuildKit
   *and* the real production BuildKit (`buildkit` namespace) point at -
   bigger win (also speeds up/de-flakes real devcontainer builds pulling
   from Docker Hub), but needs a namespace/persistent-volume decision and
   touches production-adjacent config, unlike everything built so far.

## Implementation pointers, for whoever picks this up

- `registry:3` (the same image `charts/test-registry` already uses)
  supports pull-through-cache mode natively via config:
  ```yaml
  proxy:
    remoteurl: https://registry-1.docker.io
  ```
  (set via the registry container's config file or `REGISTRY_PROXY_REMOTEURL`
  env var). Clients pull through it as if it *were* Docker Hub; it
  transparently fetches-and-caches on first miss.
- BuildKit needs to be told to use it as a mirror for `docker.io`, via
  `buildkitd.toml`'s `registry.mirrors` directive - same mechanism the test
  suite's Background already uses for the insecure-registry trust config
  (a `buildkitdToml` TOML file written via `the following is written to
  "<path>":` and passed with `--set-file buildkitdToml=<path>`), e.g.:
  ```toml
  [registry."docker.io"]
    mirrors = ["<cache-host>:5000"]
  ```
- If scoped as persistent/shared infra: needs real (not `emptyDir`) storage
  for the cache to actually persist and pay off across runs, and a decision
  on which namespace it lives in (`buildkit` namespace, matching production
  BuildKit's pod-security level, is the natural fit if it needs to be
  privileged - it likely doesn't, since a plain `registry:3` proxy needs no
  special privileges).
