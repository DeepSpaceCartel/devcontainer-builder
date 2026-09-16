<title>ADR-0007</title>

# ADR-0007: Structured registry auth, and an auto-rendered settings file

Status: accepted
Date: 2026-09-12

## Context

`charts/devcontainer-builder`'s `registryAuth.dockerConfigJson` value took
a raw docker-config-JSON string — an operator had to hand-build and
pre-base64-encode that string themselves before it could go in a values
file (the quickstart walkthrough's own Step 1 was exactly this: a
`printf '%s:%s' ... | base64` incantation). Separately,
`settingsFile.content`/`settingsFile.filename` took a hand-authored
JSON/YAML blob, escaped into a Helm value, to drive the service's own
`SERVICE_CONFIG_PATH` settings file (`service/src/config.ts`) — even
though every field that file accepts (`buildkit.endpoint`,
`sshHostKeyPolicy`, `registryMapping.rules`) already existed as a real,
structured chart value in its own right.

A first pass at fixing this considered splitting Secret-rendering out
into its own `charts/devcontainer-builder-secrets` chart (and briefly, a
third `-config` chart for settings), reasoning that separating secret
lifecycle from app-release lifecycle would help rotation. Revisited and
rejected before implementation: this chart renders a plain Kubernetes
Secret either way, with no External Secrets Operator or equivalent in
play — a dedicated chart bought no real security, only two (or three)
paired Helm releases to install and keep in sync instead of one, for
every deployment including the simplest.

## Decision

Stay with the single `charts/devcontainer-builder` chart. Fix what
operators actually complained about — the *shape* of two values, not
where they live:

- **`registryAuth.registries`** replaces `registryAuth.dockerConfigJson`:
  a plain list of `{registry, username, password}` entries. The chart
  builds the real `{"auths": {"<registry>": {"auth": "<base64
  user:pass>"}}}` itself via a new `devcontainer-builder.dockerConfigJson`
  helper (`_helpers.tpl`), `required`-guarding each entry's three fields
  so a typo'd entry fails the render loudly instead of silently omitting
  a credential. `registryAuth.existingSecret` is unchanged.
- **The settings ConfigMap is now fully automatic.** `settingsFile.content`/
  `.filename` are gone as values entirely. A new
  `devcontainer-builder.settingsJson` helper renders `settings.json` from
  `buildkit.endpoint`, `sshHostKeyPolicy`, and `registryMapping.rules`
  (only when `registryMapping.existingConfigMap` is unset) — the same
  fields an operator already sets as ordinary chart values, with nothing
  extra to author. `gitCredentials` is **permanently excluded** from this
  file: `config.ts`'s own precedence rules mean `GIT_CREDENTIALS_CONFIG_PATH`,
  which the chart always sets whenever `gitCredentials.enabled`, wins
  entirely over any settings-file copy of the same field — so a copy
  there would be both inert and a needless duplicate of sensitive
  material sitting in a less-guarded ConfigMap instead of a Secret. The
  same "dedicated env var wins entirely" rule is why `registryMapping.rules`
  is excluded from the settings file whenever `existingConfigMap` is set
  — `REGISTRY_MAPPING_CONFIG_PATH` would otherwise make that copy equally
  inert.
- The now-redundant standalone `BUILDKIT_ENDPOINT`/`SSH_HOST_KEY_POLICY`
  env vars and the dedicated `registry-mapping-configmap.yaml` (for the
  inline-rules case) are removed, folded into the one settings file.

No changes to `service/src/config.ts` — only which chart mechanism
populates the settings-file layer changes, never that layer's meaning to
the service.

## Consequences

- **Easier**: nobody hand-builds or pre-encodes a docker-config-JSON
  string, or hand-authors/escapes a settings blob, ever again. One real
  settings-delivery mechanism instead of a redundant env-var/file pair
  that could silently drift out of sync (the env var always won anyway).
- **Harder / a real, accepted cost**: `values.yaml`'s shape changed —
  `registryAuth.dockerConfigJson` and `settingsFile.*` are breaking
  changes for anyone already setting them; both need a values-file edit
  to upgrade past this ADR.

**Alternatives considered**: separate `-secrets`/`-config` charts — this
session's own first pass, rejected: no security benefit over the existing
inline-Secret approach (no External Secrets Operator in play), and worse
operationally (multiple paired releases for every deployment instead of
one). Nesting the settings-related values under a new `config:` key,
mirroring `config.ts`'s own `RawSettingsFile` nesting 1:1 — considered and
declined in favor of the smaller diff: the values already live at the top
level and moving them renames every existing reference for no behavior
change.
