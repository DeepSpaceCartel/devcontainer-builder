<title>ADR-0003</title>

# ADR-0003: Registry resolution via server-side mapping rules

Status: accepted
Date: 2026-09-11

## Context

Every built image needs a destination registry. Requiring every caller
to always specify `image.registry` explicitly is the simplest possible
rule, but pushes a genuinely operational concern (which registry does
*this* org's/host's repos push to) onto every individual caller —
fine for one Terraform module invocation, brittle across many
Workspace Templates that should all agree on the same routing without
each one hardcoding it.

## Decision

`image.registry` in the request always wins outright if given.
Otherwise, the server's own configured `registryMapping.rules` are
checked in order (`resolveRegistry` in `build.ts`); the first rule whose
`hostMatch` (if set) and `pathPrefix` (if set) both match the parsed
repository URL wins. A rule with neither field set is a universal
fallback. No `image.registry` and no matching rule is a real,
user-facing `400` (`no registry resolved for repository ...`) — never a
silent default to some hardcoded registry, and never a `500` (this is a
request-shape/configuration problem discovered before any real clone or
build work starts, the same category as an unparseable URL).

See [Configuration](../reference/CONFIGURATION.md#gitcredentialsentries-registrymappingrules)
for the rule shape and [Architecture](../concepts/architecture.md#request-lifecycle-post-build)
for where this fits in the request lifecycle.

## Consequences

- **Easier**: a Workspace Template (or any other caller) doesn't need
  to know or configure which registry a given git host's repos should
  push to — that policy lives once, server-side, and applies uniformly.
- **Easier**: rules compose cleanly with per-request overrides — a
  caller that *does* know exactly where it wants an image pushed always
  gets that, with no way for a server-side rule to silently override an
  explicit request.
- **Harder**: rule *order* matters and is entirely the operator's
  responsibility — two rules that could both match the same repository
  resolve to whichever was listed first, with no conflict detection or
  warning if a later, more specific rule is unreachable behind an
  earlier, broader one.
- **A real, accepted constraint**: there's no way to express "resolve
  the registry, but only for *this* repository" from server-side
  config alone — mapping rules match on the URL's host/path structure,
  not any deeper repository-specific identity.
