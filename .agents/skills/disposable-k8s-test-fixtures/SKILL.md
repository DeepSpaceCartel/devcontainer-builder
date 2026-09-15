---
name: disposable-k8s-test-fixtures
description: Pattern for BDD/integration tests that need real protocol-level correctness (SSH, git, registry auth, BuildKit) - deploy real, disposable infra via literal helm/kubectl/openssl/ssh-keygen commands directly in each .feature file's Background, instead of mocking or hiding the setup behind a fixture-registry module. Covers the Service-routing-after-ready race, per-namespace isolation on shared clusters, referencing dynamic fixture addresses from test text, and not hardcoding content-derived values. Use when designing or debugging tests that spin up real Kubernetes-backed fixtures.
---

# Disposable Kubernetes test-fixture pattern

The approach used throughout `service/features/`: real Helm-deployed,
disposable infra (`charts/test-*`) proven manually first, then expressed as
literal shell commands run via a small generic step vocabulary
(`service/features/step_definitions/cli.steps.js`) directly in each
`.feature` file's `Background` - rather than faking protocols (SSH, git
smart HTTP, registry auth, BuildKit) with stub binaries, and rather than
hiding the setup behind a bespoke "fixture" abstraction in JS. Real infra
catches real bugs (see the sibling skills in this directory) that a mock
would hide; literal commands in the Gherkin text mean a scenario reads like
exactly the sequence of commands a human would type by hand to reproduce
the same environment.

## The generic step vocabulary (`cli.steps.js`)

Five steps cover everything a fixture needs - deploy, wait, configure,
capture:

- `Given "<command>" has been run` - runs a real shell command (via bash),
  throws immediately on nonzero exit. **Memoized process-wide by the exact,
  already-substituted command text** - a `Background` re-declares the same
  setup commands before every Scenario (Gherkin has no "once per file"
  construct), so without memoization a file with 20 scenarios would redo
  every `helm upgrade --install`/`openssl`/`ssh-keygen` 20 times. The first
  occurrence of a given command in the process actually runs it; every
  later occurrence (a later scenario in the same file, or the same line
  repeated verbatim in a different file) reuses that first run's result.
  This is *why* commands that generate fresh key material
  (`openssl req`, `ssh-keygen`) must use a **fixed, well-known path**
  (e.g. `/tmp/e2e-fixtures/git-tls/...`), never a fresh random temp dir per
  call - a random path would defeat memoization by making every
  "identical" setup command's text actually differ.
- `Given the command output is known as "<name>"` - captures the last
  command's trimmed stdout as a named value (see sentinels below).
- `Given the value "<literal>" is known as "<name>"` - aliases a plain
  string (typically a hand-computed DNS name/URL) to a short name for
  reuse, after substituting any `<name>` tokens already known.
- `Given the following is written to "<path>":` (docstring) - writes a real
  file at the given (substituted) path, creating parent directories as
  needed. Used for Helm values files, TOML configs, SAN config for
  `openssl req -extfile`, etc.
- `Given the content of "<path>" is known as "<name>"` - reads a real file
  and registers its trimmed content as a named value (e.g. private key PEM
  content for a later "server's git credentials are:" table).

A Background for a chart-backed fixture is always the same shape: generate
any needed key material -> `helm upgrade --install <release> <chart> -n
<namespace> [-f <values-file>] [--set-string ...] [--set-file ...] --wait
--timeout <Ns>` -> a TCP-reachability retry loop per port -> alias the real
DNS name for later reuse:

```gherkin
And "helm upgrade --install test-registry ../charts/test-registry -n <namespace> --wait --timeout 120s" has been run
And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/test-registry-test-registry.<namespace>.svc.cluster.local/5000); do sleep 1; done'" has been run
And the value "test-registry-test-registry.<namespace>.svc.cluster.local:5000" is known as "<registry-url>"
```

## Force-overwrite anything the memoization can't make idempotent on its own

`helm upgrade --install`, `kubectl apply`, and writing a file are already
idempotent - safe to re-run (in another process, e.g. a second `npm test`
invocation) even without the in-process memoization above. `ssh-keygen -f
<path>` is not: it interactively prompts "Overwrite (y/n)?" and, reading
EOF from non-interactive stdin, fails closed. Always prefix key-material
generation at a fixed path with a forced clean, e.g. `rm -rf
/tmp/e2e-fixtures/git-ssh && mkdir -p /tmp/e2e-fixtures/git-ssh` before the
`ssh-keygen`/`openssl req` calls, or `rm -f <key> <key>.pub &&` immediately
before a standalone `ssh-keygen` call. Otherwise the suite passes on a
clean checkout and then fails the next time anyone reruns it locally.

## `--set-file` preserves trailing newlines; a single-line value usually can't have one

Helm's `--set-file key=path` reads a file's raw bytes, trailing newline
included. That's exactly right for a multi-line value inserted with
`{{ nindent N }}` in a chart template (an extra trailing newline there is
harmless). It silently breaks a value the template embeds **inline in a
single-line construct** - e.g. an SSH `authorized_keys` line built inside a
shell heredoc in the chart (`echo 'command="...",... {{ .Values.sshAuthorizedKey }}'`)
- because the embedded newline splits that one shell line into two,
corrupting the surrounding YAML block scalar in a way that only shows up as
a confusing downstream `helm upgrade` failure ("YAML parse error ...
Implicit keys need to be on a single line", reported at a wildly different
line number than the actual cause). Use command substitution instead for
values that must not carry a trailing newline - `$(cat ...)` strips it:

```
--set-string sshAuthorizedKey="$(cat /tmp/e2e-fixtures/git-ssh/id_ed25519.pub)"
```

## `helm --wait` doesn't guarantee the Service is actually reachable yet

A pod passing its own readiness probe and the cluster's Service routing
(kube-proxy/EndpointSlice) having caught up are two different things that
can lag behind each other by a few seconds. Trusting `helm --wait` alone
causes intermittent failures on the *first* request(s) right after install,
even though every fixture involved is legitimately healthy moments later.
Poll real TCP reachability against the Service's actual DNS name/port
before declaring a fixture ready - bash's `/dev/tcp` pseudo-device does
this with no extra binary needed, run via the same `"<command>" has been
run` step as everything else:

```gherkin
And "timeout 30 bash -c 'until (exec 3<>/dev/tcp/<host>/<port>); do sleep 1; done'" has been run
```

## One namespace per repo + workspace/user, not a shared `default`

On a cluster other work might also be running on, give test fixtures their
own namespace derived from something stable and collision-resistant (repo
name + CI/workspace owner). Computing this is itself just a shell command
(parameter expansion with a fallback default), no bespoke JS namespace
helper needed:

```gherkin
Given "echo devcontainer-builder-${CODER_WORKSPACE_OWNER_NAME:-${USER:-local}}-default" has been run
And the command output is known as "<namespace>"
And "kubectl create namespace <namespace> --dry-run=client -o yaml | kubectl apply -f -" has been run
And "kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=privileged --overwrite" has been run
```

`kubectl create ... --dry-run=client -o yaml | kubectl apply -f -` (not
plain `kubectl create namespace`) so the command is itself idempotent, safe
to memoize and safe to rerun.

## Reference dynamic fixture addresses via named values in test text, not hardcoded strings

Feature files shouldn't hardcode a namespace-dependent DNS name more than
once. Compute it explicitly the first time (it's just Helm's own
`{{ .Release.Name }}-{{ .Chart.Name }}.<namespace>.svc.cluster.local`
fullname convention, spelled out in the Background) and alias it via `the
value "..." is known as "<name>"`; every later reference - in a table cell,
a JSON docstring body, another command string - goes through the same
`<name>` substitution (`features/support/named_values.js`), sorted
longest-name-first so one registered name can't corrupt an unresolved
occurrence of a longer one that's a superstring of it.

## Don't hardcode a value the real fixture actually computes

A real git commit has a real, content-derived SHA you can't dictate; a real
registry push produces a real digest. Rather than pinning fixture content
so its output happens to match a hardcoded expectation (fragile, breaks the
moment the fixture is redeployed), query the fixture for its actual current
state at test time and assert against *that* - using the same generic
command-running step, piped through ordinary shell tools:

```gherkin
Given "git ls-remote git://<git-host>:9418/<repo-path> HEAD | cut -c1-7" has been run
And the command output is known as "<expected-sha>"
```

## Isolate expensive fixture lifecycles from cheap test suites

Not every test file needs every fixture - a file only writes the
Background lines for the fixtures it actually uses. Teardown
(`features/support/optional/cluster_teardown_hooks.js`, an `AfterAll` hook)
stays out of any glob shared with fast, fixture-free suites (`health.feature`,
`request_validation.feature`) - imported explicitly only by the npm
script(s) that run real fixtures, so a quick validation-only run never pays
for a real `helm uninstall`. It has no fixture-specific knowledge either:
it just `helm uninstall`s whatever `<release>::<namespace>` pairs
`cli.steps.js` saw a `helm upgrade --install ...` command actually
mention during this process.

## A single shared SSH fixture needs `PerSourcePenalties=no`

Modern OpenSSH (9.8+, whatever a plain `apk add openssh` currently pulls)
enables `PerSourcePenalties` by default: a source IP that produces a
failed-auth or crashed connection gets temporarily banned. A BDD suite that
deliberately makes several failed-auth SSH connections against one shared
fixture from one client IP (wrong key, bad host-key pin, malformed key -
exactly the negative scenarios this kind of suite needs) trips this and
then gets *later, legitimate* connections from the same suite dropped too
as collateral punishment - manifesting as a nondeterministic-looking
"Connection closed by remote host" a fixed number of scenarios into a run.
It is deterministic once you know the trigger, not flaky infrastructure.
Disable it for an isolated, single-client test fixture:
`sshd -D -e -o PerSourcePenalties=no` (see `charts/test-git-server`'s
`deployment.yaml`). Don't reach for retries or resource-limit increases
first - check `kubectl logs` on the sshd container for `srclimit_penalise`
before assuming it's something else.
