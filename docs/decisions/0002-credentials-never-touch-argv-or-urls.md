<title>ADR-0002</title>

# ADR-0002: Credentials never touch argv, env history, or the clone URL

Status: accepted
Date: 2026-09-11

## Context

A single `/build` request can carry up to three distinct credentials —
a git HTTPS token or SSH private key, and a registry push
username/password — and the service shells out to real `git`, `docker`,
and `devcontainers` CLI subprocesses to actually use them. The obvious,
easy ways to hand a credential to a subprocess are also the ones most
likely to leak it: as a command-line argument (visible in `ps` output
and process-launch audit logs to any other process on the same host),
embedded directly in a clone URL (`https://user:token@host/...`, which
git itself then writes into its own on-disk remote config and any log
line that prints the URL), or as a long-lived environment variable
(inherited by every child process, not just the one that needs it).

## Decision

Every credential a request supplies is written to a scratch file,
scoped to that one request, and removed in a `finally` block regardless
of success or failure — never passed as a CLI argument, never embedded
in a URL:

- **Git HTTPS** (`withNetrcEnv`): a scratch `$HOME/.netrc`, `chmod 0600`,
  in a fresh scratch `$HOME` (not just a scratch file — see
  [Credential handling](../concepts/credential-handling.md#https-a-scratch-netrc)
  for why the whole `$HOME` needs to be per-request).
- **Git SSH** (`withSshKeyEnv`): a scratch private key file + a scratch
  `known_hosts`, referenced via `GIT_SSH_COMMAND`'s own `-i`/
  `-o UserKnownHostsFile` flags rather than the default `~/.ssh/`.
- **Registry push** (`withRegistryAuthEnv`): a scratch `DOCKER_CONFIG`
  overlay, seeded from the ambient one (so builder-state reuse isn't
  broken — see [0001](0001-remote-buildkit-builder.md)) with one
  `auths[<registry>]` entry merged in.

The one genuine environment variable used at all
(`GIT_SSH_COMMAND`/`DOCKER_CONFIG`/`HOME`) points *at* the scratch file,
it never *contains* the secret itself.

## Consequences

- **Easier**: a credential leak from this service's own process
  behavior (not an upstream tool's own bug) is structurally hard to
  produce — there's no code path where a secret value is ever a
  `spawn()` argument or a URL string.
- **Harder**: every credential-bearing operation needs its own
  `mkdtemp`/write/`chmod`/`finally`-cleanup boilerplate rather than a
  one-line env var assignment — real, deliberate verbosity in exchange
  for the leak-resistance above.
- **A real, accepted constraint**: `stdio: "inherit"` subprocess output
  (both `run()` and `runCapture()` in `build.ts`) means the *actual*
  underlying error text — a registry's real 401 body, git's real
  "Permission denied" — lands on the parent process's own stdout/stderr,
  never captured into the `Error` object a caller's HTTP response is
  built from beyond a generic exit-code message. Choosing not to capture
  subprocess output more granularly was a deliberate trade against
  accidentally capturing (and returning to an HTTP caller) some other
  sensitive line the subprocess happened to print.
