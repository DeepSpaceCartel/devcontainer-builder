import { Given } from "@cucumber/cucumber";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import path from "node:path";
import { trackNamedValue, substituteNamedValues } from "../support/named_values.js";

// Every fixture this suite needs (a registry, a BuildKit instance, a git
// server, TLS/SSH key material) is stood up the same way a human operator
// would from a terminal: helm/kubectl/openssl/ssh-keygen/git invocations,
// spelled out directly in each .feature file's Background. This is the one
// primitive all of that runs through.
function runShell(command) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, { shell: "/bin/bash", stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (c) => (stdout += c));
    child.stderr.on("data", (c) => (stderr += c));
    child.on("error", reject);
    child.on("exit", (code) => resolve({ command, code, stdout, stderr }));
  });
}

// A Background re-declares the same setup commands before every single
// Scenario in a file (Gherkin has no "once per file" construct) - a human
// standing these fixtures up manually would run each command once, not
// redo it before every test they then run by hand. Memoizing by the exact
// (already-substituted) command text gives the same effect here: the
// first occurrence of a given command in this process actually runs it;
// every later occurrence - whether a later scenario in the same file or
// the same line repeated verbatim in a different file - reuses that first
// run's result instead of repeating real, sometimes slow (helm --wait) or
// non-idempotent (openssl/ssh-keygen generate fresh key material every
// invocation) work.
const commandCache = new Map();
function runMemoized(command) {
  if (!commandCache.has(command)) {
    commandCache.set(command, runShell(command));
  }
  return commandCache.get(command);
}

// `helm upgrade --install <release> <chart> ... -n <namespace>` is the
// only shape of command this suite uses to actually deploy something -
// tracked here, generically (just string matching, no chart/fixture
// knowledge), purely so the AfterAll teardown hook knows what to
// `helm uninstall` again at the end of the run.
export const helmInstalls = new Set();
function trackHelmInstall(command) {
  const match = command.match(/\bhelm\s+upgrade\s+--install\s+(\S+)\s+\S+.*?-n\s+(\S+)/);
  if (match) helmInstalls.add(`${match[1]}::${match[2]}`);
}

Given("{string} has been run", async function (commandTemplate) {
  const command = substituteNamedValues(this, commandTemplate);
  trackHelmInstall(command);
  const result = await runMemoized(command);
  this.lastCommand = result;
  assert.equal(
    result.code,
    0,
    `command failed (exit ${result.code}): ${command}\n${result.stderr || result.stdout}`,
  );
});

// Unlike "{string} has been run", never reuses a cached result - for
// commands whose effect must actually happen again even when the literal
// text repeats (e.g. a scenario reverting a Deployment to a config an
// earlier scenario in the same file already used once - the underlying
// live state has moved on in between, so memoization would silently skip
// re-applying it).
Given("{string} has been run again", async function (commandTemplate) {
  const command = substituteNamedValues(this, commandTemplate);
  trackHelmInstall(command);
  const result = await runShell(command);
  this.lastCommand = result;
  assert.equal(
    result.code,
    0,
    `command failed (exit ${result.code}): ${command}\n${result.stderr || result.stdout}`,
  );
});

// For scenarios where the command failing IS the thing under test (a
// `helm upgrade --install --wait` that must time out because the pod can
// never pass its readiness probe, e.g. a crash-looping bad config) - never
// memoized, since these commands' failure is scenario-specific and always
// needs to actually happen.
Given("{string} is run and is expected to fail", async function (commandTemplate) {
  const command = substituteNamedValues(this, commandTemplate);
  trackHelmInstall(command);
  const result = await runShell(command);
  this.lastCommand = result;
  assert.notEqual(result.code, 0, `expected command to fail, but it succeeded: ${command}`);
});

// Faster, more direct alternative to "is run and is expected to fail" for
// the specific case of a config that crashes the process before
// `server.listen()` - polls the pod's own restart count instead of a
// `helm upgrade --install --wait` that's doomed to time out (the pod can
// never pass readiness), and captures the crashed instance's logs as
// "<logs>" in the same step. `<command>` should NOT itself include --wait
// (it's expected to succeed - it just submits the manifest; the actual
// failure is the pod crash-looping, checked here instead).
Given("{string} causes the deployment to crash loop", async function (commandTemplate) {
  const command = substituteNamedValues(this, commandTemplate);
  trackHelmInstall(command);
  const applyResult = await runShell(command);
  assert.equal(
    applyResult.code,
    0,
    `command failed unexpectedly (exit ${applyResult.code}): ${command}\n${applyResult.stderr || applyResult.stdout}`,
  );

  // Resolves and pins the exact crashing pod's name (not just "deploy/X",
  // which - if an old scenario's pod briefly lingers before Recreate fully
  // clears it - can resolve to the WRONG pod's --previous log, silently
  // reading a stale crash from an earlier scenario instead of this one's).
  // Also excludes a pod with a deletionTimestamp set: right after
  // triggering Recreate, the *previous* scenario's pod can still be the
  // only match for a moment, already satisfying "name exists AND
  // restarted >= 1" well before the new pod (this scenario's config) is
  // even created - same race as health.feature's not-ready polling.
  const namespace = substituteNamedValues(this, "<namespace>");
  const pollResult = await runShell(
    `timeout 20 bash -c 'while true; do DT=$(kubectl get pod -n ${namespace} -l app.kubernetes.io/instance=devcontainer-builder -o jsonpath={.items[0].metadata.deletionTimestamp} 2>/dev/null); NAME=$(kubectl get pod -n ${namespace} -l app.kubernetes.io/instance=devcontainer-builder -o jsonpath={.items[0].metadata.name} 2>/dev/null); RC=$(kubectl get pod -n ${namespace} -l app.kubernetes.io/instance=devcontainer-builder -o jsonpath={.items[0].status.containerStatuses[0].restartCount} 2>/dev/null); if [ -z "$DT" ] && [ -n "$NAME" ] && [ "\${RC:-0}" -ge 1 ]; then echo $NAME; break; fi; sleep 0.5; done'`,
  );
  assert.equal(pollResult.code, 0, "expected the deployment to crash-loop (restart at least once), but it didn't within 20s");
  // Distinct from `lastCommand` (which "the service should fail to start"
  // otherwise reads as its exit-code signal) - here the *poll succeeding*
  // means "yes, it crash-looped", the opposite sense of a failed command.
  this.crashLoopConfirmed = true;
  const podName = pollResult.stdout.trim();

  // Right at the instant restartCount first ticks up, the container
  // runtime sometimes hasn't finished making the terminated container's
  // log retrievable yet ("unable to retrieve container logs for
  // containerd://...", not the actual crash output) - retry briefly
  // rather than tie the poll above to a higher, runtime-dependent restart
  // count just to dodge this window.
  let logsResult;
  for (let attempt = 0; attempt < 20; attempt++) {
    logsResult = await runShell(`kubectl logs pod/${podName} -n ${namespace} --previous`);
    if (logsResult.code === 0 && logsResult.stdout.trim().startsWith("{")) break;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  trackNamedValue(this, "<logs>", logsResult.stdout + logsResult.stderr);
});

// Collapses "kubectl logs deploy/<devcontainer-builder> ... has been run
// again" + "the command output is known as \"<logs>\"" into one step -
// specific to the devcontainer-builder-under-test's own release/chart
// name (fixed by this suite's naming convention), for scenarios that need
// to assert on its logs. Always fresh (like "has been run again"), since
// log content is inherently scenario-specific live state.
Given("the devcontainer-builder's logs are captured", async function () {
  const namespace = substituteNamedValues(this, "<namespace>");
  const result = await runShell(`kubectl logs deploy/devcontainer-builder-devcontainer-builder -n ${namespace}`);
  this.lastCommand = result;
  trackNamedValue(this, "<logs>", result.stdout + result.stderr);
});

// Same, but for a crash-looping pod's last terminated instance - see the
// service_startup_configuration.feature Background comment for why
// `--previous` (not plain `kubectl logs`) is the reliable choice there.
Given("the devcontainer-builder's crash logs are captured", async function () {
  const namespace = substituteNamedValues(this, "<namespace>");
  const result = await runShell(`kubectl logs deploy/devcontainer-builder-devcontainer-builder -n ${namespace} --previous`);
  this.lastCommand = result;
  trackNamedValue(this, "<logs>", result.stdout + result.stderr);
});

Given("the command output is known as {string}", function (name) {
  trackNamedValue(this, name, this.lastCommand.stdout.trim());
});

// Plain string aliasing - lets a Background spell out a convention once
// (e.g. a chart's `<release>-<chart>.<namespace>.svc.cluster.local:<port>`
// DNS name) and reference the short name everywhere after, the same way
// the "current HEAD short sha of ... is known as ..." family already
// aliases a computed value.
Given("the value {string} is known as {string}", function (value, name) {
  trackNamedValue(this, name, substituteNamedValues(this, value));
});

Given("the following is written to {string}:", async function (filePath, content) {
  const resolvedPath = substituteNamedValues(this, filePath);
  await mkdir(path.dirname(resolvedPath), { recursive: true });
  await writeFile(resolvedPath, substituteNamedValues(this, content));
});

Given("the content of {string} is known as {string}", async function (filePath, name) {
  const resolvedPath = substituteNamedValues(this, filePath);
  trackNamedValue(this, name, (await readFile(resolvedPath, "utf8")).trim());
});
