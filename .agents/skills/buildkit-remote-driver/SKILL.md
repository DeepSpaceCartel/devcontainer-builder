---
name: buildkit-remote-driver
description: Gotchas using `docker buildx` with a remote BuildKit daemon (--driver remote) - registry auth vs. builder-state sharing DOCKER_CONFIG, insecure/HTTP registry trust being server-side config not a client flag, devcontainers CLI's own pre-build image-detail fetch, and Docker Hub anonymous rate limiting. Use when working with `docker buildx create --driver remote`, BuildKit, `@devcontainers/cli`, or debugging a failed image push.
---

# BuildKit remote-driver gotchas

Concrete lessons from `service/src/build.ts` (production code) and the
disposable test BuildKit instances deployed via literal `helm upgrade
--install ... buildkit-service --repo https://andrcuns.github.io/charts`
commands in each `.feature` file's Background (see the
`disposable-k8s-test-fixtures` skill).

## `DOCKER_CONFIG` controls two unrelated things at once

The `docker` CLI reads registry credentials from `$DOCKER_CONFIG/config.json`
**and** stores buildx builder definitions under `$DOCKER_CONFIG/buildx/`.
Swap `DOCKER_CONFIG` to a fresh scratch directory for a one-off registry
credential, and `docker buildx inspect <builder-name>` silently won't find
the builder that already exists under the *ambient* `DOCKER_CONFIG` -
instead of reusing it, `buildx create` runs again every single time.

Fix: when you need a scoped credential override, seed the scratch dir from
ambient first (this copies `config.json` *and* `buildx/` in one step),
*then* merge in the override:

```js
await fs.cp(ambientDockerConfig, scratchDir, { recursive: true }); // brings buildx/ along
const config = JSON.parse(await fs.readFile(path.join(scratchDir, "config.json"), "utf8").catch(() => "{}"));
config.auths = { ...config.auths, [registry]: { auth: Buffer.from(`${user}:${pass}`).toString("base64") } };
await fs.writeFile(path.join(scratchDir, "config.json"), JSON.stringify(config));
```

See `service/src/build.ts`'s `withRegistryAuthEnv` for the production
implementation of this exact pattern.

## Insecure/HTTP registry trust is server-side, not a client flag

`docker buildx build --push` to a registry without valid TLS fails with
`unexpected status ... 401/xxx` (or a TLS error) unless the **BuildKit
daemon itself** (not the local `docker` CLI) is configured to trust it.
There is no reliable client-side `--insecure` equivalent for the `remote`
driver - the actual push happens on the remote daemon. Configure via
`buildkitd.toml`, mounted at the daemon's default config path
(`/etc/buildkit/buildkitd.toml`):

```toml
[registry."my-registry-host:5000"]
  http = true
  insecure = true
```

The `andrcuns/charts` `buildkit-service` Helm chart exposes this directly
as a `buildkitdToml` values string - written to a real file via `the
following is written to "<path>":` and passed with `--set-file
buildkitdToml=<path>` in the test suite's Background (see the
`disposable-k8s-test-fixtures` skill).

## `docker buildx create --driver remote <endpoint>` is idempotent by name, reuse it

```bash
docker buildx inspect <name> || docker buildx create --name <name> --driver remote <endpoint>
docker buildx use <name>
```

`buildx create` against an already-registered name errors; always
inspect-or-create rather than blindly creating every time (this is exactly
`ensureRemoteBuilder()` in `build.ts`).

## `stdio:"inherit"` subprocess output never reaches a wrapping HTTP response

If you shell out to `docker`/`devcontainer`/`git` with inherited stdio and
only propagate the exit code as an `Error`, the *actual* error text (a
registry's 401 body, git's "Permission denied", etc.) lands on the parent
process's own stdout/stderr - never in a response body built from
`err.message`. If a test or caller needs to assert on the real underlying
error, capture the subprocess's stdout/stderr separately rather than
inspecting whatever surfaced via the generic wrapper error.

## `@devcontainers/cli build` does its own pre-build image-detail fetch

Before ever invoking `docker buildx`, `devcontainer build` tries to fetch
the base image's manifest (to determine user/arch for feature install),
falling back to a local `docker pull`/`docker inspect` if that fails. In an
environment with no local `dockerd` (this repo's actual production
architecture - buildx talks to a *remote* daemon, no local one needed for
the real push), that fallback always fails too - so if the *first* fetch
attempt fails for any reason (registry down, rate-limited), the whole build
aborts before BuildKit is ever contacted, with a confusing
`Command failed: docker pull <image>` / `no such file or directory` error
that has nothing to do with BuildKit or the actual push target.

## Docker Hub anonymous pull-rate limiting is real and easy to hit

Repeated real builds against the same base image from one egress IP
(exactly what iterative BDD testing does) can exhaust Docker Hub's
anonymous limit within a single working session:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  https://registry-1.docker.io/v2/library/alpine/manifests/3.20
# {"errors":[{"code":"TOOMANYREQUESTS", ...}]}
```

For test fixtures/base images pulled repeatedly and only for their
existence (not their exact contents), prefer a registry without a
comparable anonymous limit - e.g. `mcr.microsoft.com` - over
`docker.io/library/...`. See
`docs/claude/notes/registry-pull-through-cache.md` for the deferred,
more thorough fix (a pull-through cache).
