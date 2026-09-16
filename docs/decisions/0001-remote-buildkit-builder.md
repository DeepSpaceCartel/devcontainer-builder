<title>ADR-0001</title>

# ADR-0001: Remote BuildKit builder, no local Docker-in-Docker

Status: accepted
Date: 2026-09-11

## Context

devcontainer-builder runs as a long-lived Kubernetes pod that needs to
build and push arbitrary, caller-supplied `.devcontainer.json` images on
demand. Giving that pod the ability to build container images the
conventional way means either a local `dockerd` (Docker-in-Docker,
usually `--privileged` or requiring specific kernel capabilities) or a
build daemon it talks to over the network. Docker-in-Docker inside a
Kubernetes pod carries real, well-known operational cost: privileged
containers are a genuine security surface, nested storage drivers are
fragile, and the resulting pod can't be scaled or scheduled like an
ordinary one.

## Decision

The service never runs `dockerd` itself. It talks to a remote BuildKit
daemon over TCP via `docker buildx create --driver remote <endpoint>`
(`build.ts`'s `ensureRemoteBuilder`), configured entirely through
`BUILDKIT_ENDPOINT` (see [Configuration](../reference/CONFIGURATION.md)).
The devcontainer CLI's own `devcontainer build --push` is then
transparently routed through that builder — from its own point of view
it's just invoking `docker build` against whatever the active buildx
context happens to be.

The builder is created once and reused by name across requests
(`docker buildx inspect <name>` first, create only on a genuine miss) —
recreating it per request would mean re-registering the same named
builder against the same remote endpoint on every single call, for no
benefit.

## Consequences

- **Easier**: the pod itself needs no elevated privileges and no
  persistent local storage for image layers — it's an ordinary,
  horizontally-uninteresting (single-replica, by design) HTTP service.
  BuildKit's own scaling/caching/storage concerns live entirely in
  whatever deploys the remote daemon, decoupled from this service's own
  deployment.
- **Harder**: insecure/HTTP registry trust is *server-side*
  configuration on the BuildKit daemon itself
  (`buildkitd.toml`'s `[registry."host"]` block) — there is no reliable
  client-side flag to make the local `docker` CLI treat a target
  registry as trusted when the actual push happens on a different
  machine. A registry a build needs to push to (or pull a base image
  from) that the remote daemon doesn't already trust fails with an
  opaque TLS/401 error that has nothing to do with this service's own
  code.
- **Harder**: `@devcontainers/cli build` does its own pre-build
  image-detail fetch (to determine base-image user/arch for feature
  installation) before ever invoking `buildx`, falling back to a local
  `docker pull`/`docker inspect` if that fails — with no local `dockerd`
  anywhere in this architecture, that fallback always fails too. A
  transient registry issue on the *fetch* step aborts the whole build
  with a confusing `docker pull` error before BuildKit is ever
  contacted.
- **A real, accepted constraint**: this service assumes a BuildKit
  daemon is already running and reachable — it never provisions one.
