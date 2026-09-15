---
title: git-over-SSH could hang waiting for an interactive prompt that would never come
created: 2026-09-06
---

# git-over-SSH could hang on a real TTY - invisible to the BDD suite

## What happened

Running `npm test` by hand (a real interactive terminal, not this session's
sandboxed tool) hit a live SSH host-key confirmation prompt, then three
password prompts, for a git clone the request never supplied credentials
for:

```
The authenticity of host 'test-git-server-...' can't be established.
...
Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
git@test-git-server-...'s password:
git@test-git-server-...'s password:
git@test-git-server-...'s password:
```

104 BDD scenarios covering git-over-SSH (including several negative ones
exercising exactly this "no credentials configured, SSH URL" path) had
never once surfaced this.

## Root cause

`build.ts`'s `buildDevcontainer()`, the `gitCredential.kind === "none"`
branch (no server-config or request-level credential resolved for the
host):

```ts
await run("git", cloneArgs, { ...process.env, GIT_TERMINAL_PROMPT: "0" });
```

`GIT_TERMINAL_PROMPT=0` only suppresses *git's own* (HTTPS-style)
credential prompts. It does nothing for the `ssh` subprocess git spawns
underneath for an `ssh://`/SCP-style URL - no `BatchMode`, no
`StrictHostKeyChecking` override, nothing. Left to its own defaults, `ssh`
happily prompts for host-key confirmation and then falls back to
password/keyboard-interactive auth when no usable identity is offered.

`withSshKeyEnv` (the *credentialed* SSH path) had a milder version of the
same gap: it sets `StrictHostKeyChecking=yes` and `IdentitiesOnly=yes`, but
never `BatchMode=yes` - so a rejected key could *also* fall through to an
interactive password prompt.

## Why the BDD suite never caught it

Every scenario runs through `service_process.js`'s `spawn()`, which never
attaches a TTY (`stdio: ["ignore", "pipe", "pipe"]`) - and every scenario
run through this session's own tooling is likewise non-interactive.
Without a TTY, `ssh` detects it can't prompt and fails immediately instead
of blocking - "Permission denied" or "Host key verification failed" appear
right away, which is exactly the signal several existing negative
scenarios already assert on. The *absence* of `BatchMode=yes` was
completely invisible under non-interactive execution: the failure mode
just happened to look identical (fast, clean, non-interactive) to what
`BatchMode=yes` would have produced on purpose. Only a real TTY exposes
the difference.

This is a real production risk, not just a dev-machine annoyance: a
backend service must never let a subprocess block on stdin waiting for
input that will never come.

## Fix

Added `-o BatchMode=yes` to both SSH invocation paths in `build.ts` -
`ssh` now refuses to prompt for anything (host key confirmation, password,
passphrase) and fails immediately and deterministically instead.

## Verification

BDD scenarios can't tell the difference (no TTY either way), so this was
verified directly with a real pseudo-terminal via `script`, bounded by
`timeout` so a real hang couldn't block the verification itself:

- Without the fix, against an unknown host with no credential: hung at
  the host-key prompt, killed by `timeout` after 12s (exit 124) - the
  literal bug reproduced on demand.
- With the fix: same scenario, `Host key verification failed` in 0.2s
  (exit 128).
- Without the fix, with a real-but-unauthorized key: hung at a password
  prompt, killed by `timeout` after 12s.
- With the fix: same scenario, `Permission denied (publickey,password,
  keyboard-interactive)` in 0.3s.

Full BDD regression (104 scenarios) re-run clean afterward, confirming the
fix changes nothing observable in non-interactive execution - only real
TTY behavior changes, which is exactly the point.
