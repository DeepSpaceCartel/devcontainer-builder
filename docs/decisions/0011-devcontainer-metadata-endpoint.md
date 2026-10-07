<title>ADR-0011</title>

# ADR-0011: `GET /devcontainer` — merged Dev Container metadata, read from the image

Status: accepted
Date: 2026-10-07

## Context

A Coder workspace built from devcontainer-builder boots the right image, but
everything else in `devcontainer.json` is ignored: lifecycle commands
(`postCreateCommand` & co.) never run and VS Code extensions/settings are
never installed. Whatever runs them — a Coder template's `coder_script`, the
`vscode-web` module's `extensions`/`settings` inputs — needs that
configuration as data.

`devcontainer build` already records it. Every image it builds carries a
`devcontainer.metadata` label: a JSON array with the base image's own
entries, then one entry per Feature in install order, then
`devcontainer.json`'s own entry last — each holding the lifecycle commands,
`remoteUser`, `customizations`, `forwardPorts`, `mounts`, ... it
contributed. Nothing in this service read it.

Alternatives considered:

- **Parse the repository's `devcontainer.json` inside the workspace pod.**
  Template-only, but misses everything Features and the base image
  contribute, needs a JSONC parser in an arbitrary image, and can drift from
  the image that's actually running.
- **Return the metadata from `POST /build`.** No new endpoint, but only
  available when a build runs — existing workspaces, and any start that
  reuses an already-built image, would never see it.
- **`devcontainer read-configuration --include-merged-configuration`
  (plan-time, from the repo).** Needs a clone per call, and for merged
  configuration a Docker daemon to inspect the base image.

## Decision

Add `GET /devcontainer?registry=&name=&tag=[&platform=]`, which reads the
label straight from the registry (manifest → the `platform` entry of a
multi-platform index, default `linux/amd64` → config blob) — no pull, no
Docker daemon — reusing `GET /image`'s query, credential headers, and
ambient-auth fallback ([0008](0008-image-existence-and-deletion-endpoints.md)).

The response separates the spec from this service's additions:

- **`configuration`** is exactly the Dev Containers CLI's own
  `mergedConfiguration` shape: devcontainer.json property names, lifecycle
  hooks as plural lists in run order (`postCreateCommands`), `customizations`
  as a per-tool list of every entry's value. `mergeConfiguration` in
  `service/src/devcontainer-metadata.ts` is a field-by-field port of the
  CLI's own, checked against `@devcontainers/cli` 0.89.0 by feeding the same
  label to both (all 25 merged properties identical). Being the CLI's
  format, it also carries what later template work needs (`forwardPorts`,
  `remoteEnv`, `mounts`, ...) without another API change.
- **`lifecycleScripts`**: each hook rendered as one POSIX `sh` script with
  the CLI's semantics — entries in label order, a string via `/bin/sh -c`,
  an array as argv with no shell, an object's named commands in parallel,
  and the first failure stops the script with that command's exit code.
  Rendering once, here, means a template runs four scripts and needs no JSON
  parser or shell-quoting logic of its own (HCL has neither).
- **`vscode`**: `customizations.vscode` merged the way VS Code does — the
  CLI deliberately leaves that to each tool. Extensions are a union in entry
  order, de-duplicated case-insensitively, with `-publisher.name` removing
  one; settings merge per key, last entry wins.
- **`warnings`** and the raw **`metadata`** entries alongside.

Status codes: `404` when the tag doesn't exist, `422` when the image exists
but has no (or an unparseable) label or no manifest for `platform`, `502`
for registry failures.

Two registry-client changes came with it, both also fixing `GET`/`DELETE
/image`:

- **Namespaced registries.** `registry` as `POST /build` returns it
  (`ghcr.io/deepspacecartel`) used to be put in front of `/v2/` whole,
  producing an invalid URL. The host and namespace are now split; ambient
  credentials are looked up by the exact string, then by the host alone.
- **Plain-HTTP registries via a new `insecureRegistries` setting** — an
  explicit list of hosts reached over `http://`, empty by default. Not an
  automatic HTTPS→HTTP fallback: that would let a network failure or a
  spoofed endpoint downgrade a credentialed request to cleartext. Docker
  (`insecure-registries`) and BuildKit (`buildkitd.toml`) make the same
  choice. Builds themselves are unaffected; pushing is BuildKit's own config.
  Basic-auth (htpasswd) registries are now handled alongside Bearer-token
  ones.

## Consequences

- A Coder template can feed `vscode.extensions`/`vscode.settings` into the
  `vscode-web` module and run `lifecycleScripts` from one `coder_script`.
  That wiring — and a provider data source exposing this endpoint — are
  separate follow-ups.
- **Every-start semantics are the caller's call, and its responsibility.**
  Dev Containers runs `onCreate`/`updateContent`/`postCreate` once per
  container; a Kubernetes pod gets a fresh root filesystem on every start,
  so a template will typically run them on every start. Commands must be
  idempotent. Working directory, user, and hook order are also the caller's.
- **No variable substitution.** `${containerWorkspaceFolder}`,
  `${localEnv:X}`, ... are left as-is (this service has no workspace or
  local environment to substitute from), and each occurrence in a lifecycle
  command is reported in `warnings`.
- `workspaceFolder` is never part of the label, so it isn't returned.
- Rendered scripts are asserted as text in BDD
  (`devcontainer_metadata.feature`); their run-time semantics (ordering,
  parallelism, stop-on-failure with the right exit code) were verified by
  executing them directly, since Thomas has no step that executes a
  captured value.
