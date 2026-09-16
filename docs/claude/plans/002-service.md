---
title: Hybrid credentials, git protocol conversion, and registry auto-resolution
created: 2026-09-05
---

# Hybrid credentials, git protocol conversion, and registry auto-resolution

## Context

The scaffold already implements the core pipeline (clone → configure remote
buildx builder → `devcontainer build --push`) with `BuildRequest.repository`,
`.branch`, `.gitCredentials` (HTTPS-only, netrc-scratch pattern), and a
**required** `.image.{registry,name,tag}`. Registry push auth is currently
entirely ambient (one Helm-mounted Docker config secret, ambient for every
build).

The goal now is to make the service usable by a Terraform caller that often
doesn't know (or want to manage) per-repo registry targets or credentials up
front: the service should carry its own server-side defaults (configured at
Helm-deploy time) for both git credentials (keyed by host, HTTPS-token or
SSH-key) and registry routing, and only require `repository` on each
request. It also needs to reconcile the case where the server is configured
with SSH credentials for a git host but a caller passes an HTTPS URL for that
same host (or vice versa) — by rewriting the clone URL to match whichever
credential actually resolves. Confirmed decisions from user Q&A:

- Request-level `gitCredentials` stays HTTPS-only (username/token); only
  **server-side** default git credentials can be SSH-key-based.
- `image.registry`/`.name`/`.tag` all become optional: `registry` resolves
  via server-side repo→registry mapping rules if omitted (hard 400 if no
  rule matches and none given); `name` derives from the repo path; `tag`
  derives from the actual cloned HEAD SHA (`sha-<short>`).
- SSH host-key verification supports both TOFU (`ssh-keyscan` into a scratch
  `known_hosts`) and pinned (operator supplies the host key), selected by a
  deployment-wide config option; pinned fails closed per-host-entry if no pin
  is configured for a host using SSH creds under that policy.
- Terraform↔service transport stays JSON over HTTP (`data "http"`) —
  unrelated to gRPC, which is only the Terraform-core↔provider-binary
  internal plugin transport.
- Also: split `/healthz` into separate liveness/readiness endpoints, and add
  `docker-ce-cli`/`docker-buildx-plugin`/`@devcontainers/cli` to
  `.devcontainer/postCreateCommand.sh` (currently missing there; Docker CLI
  and the devcontainers CLI are present only in the production
  `service/Dockerfile` today), per CLAUDE.md's explicit dev-vs-prod tooling
  split.

## `service/src/types.ts`

```ts
export interface GitCredentials { username: string; token: string } // unchanged, HTTPS-only

export interface RegistryCredentials {   // NEW request-level override
  registry: string;   // host[:port], used as the docker config.json auths key
  username: string;
  password: string;
}

export interface ImageTarget {           // all now optional
  registry?: string;
  name?: string;
  tag?: string;
}

export interface BuildRequest {
  repository: string;                    // only strictly-required field
  branch?: string;                       // default "main"
  gitCredentials?: GitCredentials;
  image?: ImageTarget;
  registryCredentials?: RegistryCredentials;
}
```

Add `export class BuildRequestError extends Error {}` (or put it in
`build.ts`) — used for user-fixable failures that should map to HTTP 400
(currently: "no registry resolved", "pinned host-key policy but no pin
configured for host"), as opposed to generic `Error` for 500-class execution
failures (git/docker/devcontainer subprocess failures).

## `service/src/server.ts` — liveness vs. readiness endpoints

Split the current single `/healthz` (used today for both probes) into two:

- `GET /healthz` (liveness, unchanged semantics) — always `200 {status:
  "ok"}` if the process can respond at all. No dependency checks: liveness
  must never fail because of external config/state, only because the
  process itself is wedged (k8s restarts the pod on liveness failure, which
  wouldn't fix a bad `BUILDKIT_ENDPOINT`).
- `GET /readyz` (new, readiness) — `200 {status: "ready"}` only if the
  service can actually accept a build: `BUILDKIT_ENDPOINT` is a non-empty
  string, else `503 {status: "not ready", reason: "BUILDKIT_ENDPOINT not
  configured"}`. (Startup config for git-credentials/registry-mapping is
  fail-fast at process start per the config section above, so by the time
  the server is accepting connections that part is already guaranteed
  loaded — no separate check needed for it here.)

Export a small `isReady(): { ready: boolean; reason?: string }` from
`build.ts` (next to the existing `BUILDKIT_ENDPOINT` constant) and call it
from the new `/readyz` handler in `server.ts`.

**`charts/devcontainer-builder/templates/deployment.yaml`**: point
`readinessProbe.httpGet.path` at `/readyz`; leave `livenessProbe` on
`/healthz`.

## `service/src/server.ts` — request validation

Loosen `isValidBuildRequest`:
- `repository`: required non-empty string (unchanged).
- `branch`: optional; if present, non-empty string.
- `image`: optional object; if present, any of `registry`/`name`/`tag` that
  are present (and not `null`) must be non-empty strings — do **not**
  require all three anymore. Treat `null` the same as "absent" for each
  optional field (so a Terraform caller sending explicit JSON `null` isn't
  rejected).
- `gitCredentials`: unchanged.
- `registryCredentials`: new optional object; when present, `registry`,
  `username`, `password` all required non-empty strings (no partial-creds
  case makes sense here, unlike `image`).

Update the 400 message text to list the still-required vs optional fields.

In the `/build` handler's catch block, branch on `err instanceof
BuildRequestError` → `400`, else the current generic `500` path.

## `service/src/build.ts` — control flow

Current order (clone-string-then-clone-then-build) changes because the
image tag now depends on the cloned HEAD SHA:

1. Load server-side config once at module load (see next section).
2. `parseGitUrl(req.repository)` → `{ host, path }` (see below).
3. `branch = req.branch ?? "main"`.
4. Resolve git credential: `req.gitCredentials` (HTTPS) takes priority; else
   look up the server config's git-credential list by `host` (exact match);
   else none.
5. Rewrite the clone URL via `toCloneUrl(parsed, kind)` to match whichever
   credential kind resolved (`"https"` → `https://host/path`, `"ssh"` →
   `ssh://git@host/path`, `"none"` → `req.repository` unchanged/verbatim).
6. Clone using `withNetrcEnv` (HTTPS, existing), the new `withSshKeyEnv`
   (SSH, below), or plain env (no credential) — same `git clone --branch
   <branch> --single-branch --depth 1 <cloneUrl> <repoDir>` args as today.
7. **After** clone succeeds: `runCapture("git", ["rev-parse", "HEAD"], {
   cwd: repoDir })` → `headSha`.
8. Resolve `name = req.image?.name ?? deriveImageName(parsed.path)` (last
   path segment, strip `.git`/leading `/`).
9. Resolve `tag = req.image?.tag ?? \`sha-${headSha.slice(0, 7)}\``.
10. Resolve `registry = req.image?.registry ?? resolveRegistry(parsed,
    config.registryMappingRules)`; if still undefined, `throw new
    BuildRequestError(...)`.
11. `image = \`${registry}/${name}:${tag}\``.
12. Resolve registry-auth env: if `req.registryCredentials` present, build a
    scratch `DOCKER_CONFIG` (seeded from ambient — see hazard below);
    else `dockerConfigEnv = process.env` unchanged (today's behavior).
13. `ensureRemoteBuilder(dockerConfigEnv)` (now takes an env param instead
    of closing over `process.env`, so both its `run()` calls use the
    resolved env).
14. `devcontainer build --workspace-folder repoDir --image-name image --push`
    with `dockerConfigEnv`.
15. `finally`: remove `workDir` and any scratch `DOCKER_CONFIG` dir from
    step 12.

### `parseGitUrl(repository): { host, path, kind: "https"|"ssh"|"scp" }`

Must not crash on SCP-style remotes (today's `new URL()` call does). Check
in order:
1. `scheme://` prefix (regex `/^[a-z][a-z0-9+.-]*:\/\//i`) → use `new URL()`
   directly (`https://`, `ssh://` both valid here); `host = url.hostname`,
   `path = url.pathname.replace(/^\//, "")`.
2. Else SCP-style `[user@]host:path` (git's shorthand,
   e.g. `git@github.com:org/repo.git`) via regex
   `/^(?:[^@/]+@)?([^:/]+):(?!\/\/)(.+)$/` → `host` = group 1, `path` =
   group 2.

### `toCloneUrl(parsed, kind)`
- `"none"` → return `req.repository` verbatim (no rewrite).
- `"https"` → `https://${host}/${path}`.
- `"ssh"` → `ssh://git@${host}/${path}`.

### `withSshKeyEnv` (new, mirrors `withNetrcEnv`)

Scratch dir with `id` (private key, `chmod 0600`) and `known_hosts`
(`chmod 0600`), env `GIT_SSH_COMMAND="ssh -i <key> -o
UserKnownHostsFile=<known_hosts> -o StrictHostKeyChecking=yes -o
IdentitiesOnly=yes"` + `GIT_TERMINAL_PROMPT=0`, cleaned up in `finally` —
same never-argv/never-embedded-URL rationale as `withNetrcEnv`.
`known_hosts` content depends on policy:
- `"tofu"`: `runCapture("ssh-keyscan", ["-H", host])` → write stdout.
- `"pinned"`: use the git-credential entry's configured pin; throw
  `BuildRequestError` if policy is `"pinned"` and this entry has no pin.

`StrictHostKeyChecking=yes` in both modes — only the known_hosts content
differs; "accept any key silently" is never an option.

### `runCapture` (new)

Same shape as `run()` but `stdio: ["ignore", "pipe", "inherit"]`, captures
stdout, resolves `{ stdout: string }` (trimmed) on exit 0. Used for `git
rev-parse HEAD` and `ssh-keyscan`.

### Registry-credential vs. buildx-builder-state hazard

`docker buildx` stores builder definitions under `$DOCKER_CONFIG/buildx/`.
If a per-request `registryCredentials` override swaps in a **fresh** scratch
`DOCKER_CONFIG`, `ensureRemoteBuilder`'s `docker buildx inspect` won't find
the already-created "remote" builder and will recreate it every such
request. Fix: when `registryCredentials` is present, seed the scratch dir
from the ambient one before merging in the override:

1. `scratchDockerConfig = mkdtemp(...)`.
2. `fs.cp(process.env.DOCKER_CONFIG ?? join(os.homedir(), ".docker"),
   scratchDockerConfig, { recursive: true })` — copies `config.json` *and*
   `buildx/` in one step.
3. Read `scratchDockerConfig/config.json` (or `{}` if none), merge in one
   `auths` entry: `{ [registry]: { auth: base64("user:pass") } }` — same
   shape Docker's own config.json already uses, no new format.
4. Write back, `chmod 0600`.
5. Run `ensureRemoteBuilder` and the build step with `DOCKER_CONFIG =
   scratchDockerConfig`.
6. `finally`: remove the scratch dir.

No-override case (the common path) is completely unchanged: `process.env`
passed straight through, zero new cost.

### Config lookups

```ts
function findGitCredentialForHost(host, entries) // exact host match
function resolveRegistry(parsed, rules)          // first-match-wins over rules[]
```
`rules` are checked in array order (operator controls precedence by
ordering, most-specific-first) — no dependency-requiring "best match"
logic.

## Server-side startup config

New small module `service/src/config.ts` (or top of `build.ts`), loaded
once via synchronous `readFileSync` + `JSON.parse` at process start (fail
fast on missing/malformed *file*; log-and-skip one malformed *entry* inside
an otherwise-valid array — same spirit as `isValidBuildRequest`, since these
are operator-authored via Helm values):

- `GIT_CREDENTIALS_CONFIG_PATH` env var → JSON array:
  ```json
  [
    {"host": "github.com", "kind": "https", "username": "svc-bot", "token": "..."},
    {"host": "gitlab.internal.example.com", "kind": "ssh", "privateKey": "-----BEGIN...", "pinnedHostKey": "gitlab.internal... ssh-ed25519 AAAA..."}
  ]
  ```
- `REGISTRY_MAPPING_CONFIG_PATH` env var → JSON array:
  ```json
  [
    {"hostMatch": "github.com", "pathPrefix": "org-a/", "registry": "ghcr.io/org-a"}
  ]
  ```
  (`hostMatch`/`pathPrefix` both optional per rule — an all-optional rule is
  a universal fallback, letting an operator define a true default registry.)
- `SSH_HOST_KEY_POLICY` env var: `"tofu"` (default) or `"pinned"`.

Unset paths → empty list (all-optional feature, no server config needed for
the existing HTTPS-only / no-registry-mapping behavior to keep working
as-is).

## `charts/devcontainer-builder/`

**`values.yaml`** additions:
```yaml
gitCredentials:
  existingSecret: ""
  entries: []   # [{host, kind: https|ssh, username/token or privateKey/pinnedHostKey}]

sshHostKeyPolicy: tofu   # tofu | pinned

registryMapping:
  rules: []   # [{hostMatch?, pathPrefix?, registry}]
```

**New template `templates/git-credentials-secret.yaml`** — mirrors
`templates/secret.yaml`'s `existingSecret`-guard exactly; renders
`.Values.gitCredentials.entries | toJson | b64enc` under key
`git-credentials.json`. Add `devcontainer-builder.gitCredentialsSecretName`
helper in `_helpers.tpl` (same if/else shape as the existing
`devcontainer-builder.secretName` helper).

**New template `templates/registry-mapping-configmap.yaml`** — plain
ConfigMap (non-sensitive routing data, no need for Secret-grade handling)
with `registry-mapping.json` key from `.Values.registryMapping.rules |
toJson`.

**`templates/deployment.yaml`**: add env vars `GIT_CREDENTIALS_CONFIG_PATH`,
`REGISTRY_MAPPING_CONFIG_PATH` (both pointing at mounted file paths under
e.g. `/home/builder/.config/`), `SSH_HOST_KEY_POLICY` (from
`.Values.sshHostKeyPolicy`); add two new read-only volume mounts (Secret
`subPath: git-credentials.json`, ConfigMap `registry-mapping.json`) and
their corresponding `volumes` entries. Existing `registry-auth`
Secret/mount, `scratch` emptyDir, and ServiceAccount stay untouched — this
still needs no RBAC.

## `terraform/devcontainer-build/`

**`variables.tf`**: drop the `validation` blocks (and thus required-ness)
from `image_registry`, `image_name`, `image_tag`; give each `default = ""`
and update `description` to state the server-side fallback. Add:
```hcl
variable "registry_username" { description = "..."; type = string; default = ""; sensitive = true }
variable "registry_password" { description = "..."; type = string; default = ""; sensitive = true }
```
Leave `branch`'s existing default+validation alone (harmless, still useful
for non-Terraform callers of the service that don't get this validation for
free).

**`main.tf`**: extend `locals` with `registry_credentials` (non-null only
when both `registry_username`/`registry_password` are set; `registry` field
sourced from `var.image_registry` since that's the only registry-shaped
input this module has — add a variable-level note that supplying registry
credentials without `image_registry` is not meaningful) and `image` (null
unless at least one of the three is non-empty, each empty field omitted via
per-field ternary → `null`, not empty string). Change `request_body` to
build via `merge()` so `gitCredentials`/`image`/`registryCredentials` keys
are omitted entirely when null, rather than sent as JSON `null` — cleaner
body, and the server-side validator should still tolerate `null` defensively
per the `types.ts`/`server.ts` note above.

**`outputs.tf`**: unchanged.

**`build.tftest.hcl`**: remove `run "rejects_empty_image_tag"` (empty
`image_tag` is now valid input, not a validation failure); add a
`run "accepts_empty_image_fields"` (`command = plan`, all three `image_*`
vars `""`) asserting the plan succeeds. Keep
`rejects_empty_repository`/`rejects_empty_service_url` as-is. Keep the
file's existing header comment about `data "http"` always executing on
plan — note there that these three vars are now Terraform-unconstrained, so
a live-service 400 for "no registry resolved" isn't testable here without
`mock_provider "http"`.

## `.devcontainer/postCreateCommand.sh`

Add a Docker section after the Terraform block (same apt-repo grouping),
before kubectl — mirrors `service/Dockerfile`'s Docker-repo install exactly,
adapted to this script's `$SUDO`/idempotency style and reusing the
already-computed `arch` var. Also install the `@devcontainers/cli` npm
package (the base image is `mcr.microsoft.com/devcontainers/typescript-node:1-20-bookworm`,
so `node`/`npm` are already present — no separate Node install needed here,
unlike `install.sh` at the repo root):

```bash
# --- Docker CLI + buildx plugin + devcontainers CLI (same apt repo and
#     `npm install -g @devcontainers/cli` as service/Dockerfile — this is
#     for developing/testing builds against the remote BuildKit endpoint
#     from the workspace, not for running containers locally) ------------
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing docker-ce-cli + docker-buildx-plugin..."
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
  $SUDO apt-get update
  $SUDO apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin
fi

if ! command -v devcontainer >/dev/null 2>&1; then
  echo "Installing @devcontainers/cli..."
  npm install -g @devcontainers/cli
fi
```

Unlike `service/Dockerfile`, do **not** purge `gnupg` afterward (dev
workspace keeps it for other uses, e.g. commit signing). Update the header
comment and the final "postCreateCommand.sh done: ..." echo line to
mention Docker CLI + devcontainers CLI.

Note: `service/Dockerfile:20` already runs `npm install -g
@devcontainers/cli` — no change needed there, only `postCreateCommand.sh`
is missing it today.

## Ordering hazards to keep in mind while implementing

1. `parseGitUrl` fully replaces the old `new URL(req.repository).hostname`
   call site — don't leave the crash-on-SCP-style path anywhere.
2. Image (`name`/`tag`/`registry`) resolution must stay strictly after the
   clone step (needs the real HEAD SHA) and before `ensureRemoteBuilder`.
3. Registry-credential scratch `DOCKER_CONFIG` must be seeded from ambient,
   never created empty (the buildx-recreate hazard above).
4. Optional-field checks in `server.ts` must treat `null` the same as
   `undefined`.
5. "No registry resolved" and "pinned policy, no pin for host" must throw
   `BuildRequestError` → 400, not fall through to the generic 500 path.
6. Config-file load is fail-fast (crash at startup on bad file); a single
   malformed entry inside an otherwise-valid list is log-and-skip.

## Verification

- `cd service && npm run build` — TypeScript compiles clean (confirm
  node/npm are on PATH first; if not, say so rather than assuming).
- Add/extend unit-free manual checks by running the compiled server locally
  with `BUILDKIT_ENDPOINT` unset/set and POSTing sample bodies to `/build`
  via `curl` covering: no `image` at all (registry-mapping-driven), SCP-style
  `repository`, a host with only server-configured SSH creds while the
  request supplies an HTTPS URL for that host, and `registryCredentials`
  present vs. absent — check `/tmp` scratch dirs are cleaned up after each
  (no leftover `git-creds-*`/`git-ssh-*`/`docker-config-*` dirs).
- `helm lint charts/devcontainer-builder` and `helm template
  charts/devcontainer-builder -f <values with gitCredentials.entries and
  registryMapping.rules populated>` — confirm the new Secret/ConfigMap
  render and mount paths line up with the new env vars.
- `cd terraform/devcontainer-build && terraform fmt -check -diff &&
  terraform validate && terraform test` — the relaxed variable validations
  and new `registry_username`/`registry_password` vars should pass; the
  `data "http"` call itself still requires a live service per the existing
  test-file caveat.
