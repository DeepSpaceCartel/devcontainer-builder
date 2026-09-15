<title>ADR-0004</title>

# ADR-0004: SSH host key verification is always enforced

Status: accepted
Date: 2026-09-11

## Context

Cloning over SSH means verifying the remote host is who it claims to
be, the same real risk any SSH client faces — a compromised or
spoofed git host is exactly the kind of failure host key checking
exists to catch, and it's tempting (and common, in throwaway
automation) to disable it entirely (`StrictHostKeyChecking=no`) to
avoid dealing with `known_hosts` management in a backend service with
no human ever available to answer an interactive host-key prompt.

## Decision

Host key verification (`StrictHostKeyChecking=yes`) is **always** on
for every SSH clone this service performs — there is no configuration
path, request field, or CLI flag that disables it. What's configurable
is only *how* `known_hosts` gets populated, via the deployment-wide
`SSH_HOST_KEY_POLICY` (`withSshKeyEnv` in `build.ts`):

- **`tofu`** (trust-on-first-use, the default) — a real `ssh-keyscan`
  at clone time, trusting whatever key the host presents *right now*.
  Real protection against a wholesale host substitution; no protection
  against a key that changes between one clone and the next.
- **`pinned`** — the operator supplies the exact expected host key
  (`pinnedHostKey`) per credential entry, with no scan at all. A
  request whose resolved credential has no pin under this policy fails
  closed immediately (`BuildRequestError`, before any network call) —
  never silently falls back to TOFU.

`BatchMode=yes` is set unconditionally alongside this, so a host key
that genuinely fails verification under either policy produces a real,
fast SSH failure rather than an invisible hang on an interactive prompt
(no TTY is ever attached). See
[Credential handling](../concepts/credential-handling.md#ssh-a-scratch-key-known_hosts-gated-by-host-key-policy)
for the full mechanics.

## Consequences

- **Easier**: `tofu` needs zero operator setup to get real (if weaker)
  host verification working immediately against any new SSH host.
- **Easier**: `pinned` gives a real, auditable guarantee — the exact
  key an operator expects, checked every time, with a loud failure the
  moment it's missing rather than a silent downgrade.
- **Harder**: `tofu` has a real, accepted gap — a host key that changes
  *between* two clones of the same host (a real key rotation, or a real
  MITM) is trusted on the second clone exactly as readily as the first,
  since nothing persists a previously-scanned key across requests.
  Operators who need real protection against that specific gap need
  `pinned`, not `tofu`.
- **A real, accepted constraint**: there is deliberately no "insecure"
  escape hatch (no `StrictHostKeyChecking=no` equivalent reachable from
  any request field or config source) — a caller/operator who wants to
  skip host verification entirely has no way to do so through this
  service.
