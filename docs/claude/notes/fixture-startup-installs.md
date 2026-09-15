---
title: Transient "Unhealthy" pods from installing packages at container startup
created: 2026-09-06
---

# Transient "Unhealthy" pods from installing packages at container startup

## What happened

`kubectl describe pod` on `charts/test-git-server`'s pods showed real
`Unhealthy: connection refused` readiness-probe events during startup -
one repeated **9 times over 27 seconds** for the `git-http` container:

```
Warning  Unhealthy  32s               kubelet  git-daemon: Readiness probe failed: dial tcp ...:9418: connect: connection refused
Warning  Unhealthy  3s (x9 over 27s)  kubelet  git-http: Readiness probe failed: dial tcp ...:8080: connect: connection refused
```

## Root cause

`charts/test-git-server`'s `git-daemon` and `git-http` containers install
their own packages **at every pod startup** rather than using a pre-built
image with those packages already baked in:

- `git-daemon` (plain `alpine`, not `alpine/git`): `apk add --no-cache git
  git-daemon` - Alpine's base `git` package doesn't include the
  `git-daemon` binary, so it's installed explicitly.
- `git-http` (`python:3-slim`): `apt-get update && apt-get install -y git`
  - a real `apt-get update` against Debian's package index over the
  network, every single time the pod starts.

Neither container can start listening (and so can't pass its readiness
probe) until its install step finishes, which is genuinely slow and
somewhat variable (network-dependent `apt-get`/`apk` fetch time) - hence
the repeated failed probes.

## This is not a bug

`helm --wait` (part of the `helm upgrade --install ... --wait` command each
`.feature` file's Background runs to deploy this fixture) correctly waits
through this - it only returns once the pod's readiness probe actually
passes, however long that takes. The "Unhealthy" events are harmless noise,
not a real failure. (Contrast with the *actual* bug found alongside this:
`helm --wait` says nothing about Service-routing having caught up after the
pod is ready - see the TCP-reachability-poll fix (now a literal `timeout
30 bash -c 'until (exec 3<>/dev/tcp/<host>/<port>); do sleep 1; done'`
command in the Background, per the `disposable-k8s-test-fixtures` skill),
which is a genuinely different, already-fixed problem.)

## The real cost, and the deferred fix

The cost is pod startup latency and probe-log noise - up to 10-30s+ per
fresh `test-git-server` pod, worse under network contention. Documented
directly at the source: see the `TRADEOFF` comment above the `git-daemon`
container in `charts/test-git-server/templates/deployment.yaml`, and the
matching note in `charts/test-git-server/Chart.yaml`'s description.

Not fixed yet (deferred, same spirit as the pull-through-cache note): the
proper fix is a small pre-built image (`git` + `git-daemon` already
installed) pushed to a registry, used instead of installing on every pod
start. This repo's own `test-registry`/test BuildKit fixtures could
actually build and push that image themselves once such a workflow exists.
Low priority since it's a latency/noise problem, not a correctness one.
