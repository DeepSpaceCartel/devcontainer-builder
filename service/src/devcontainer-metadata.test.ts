// Fast, cluster-free tests for GET /devcontainer's pure logic: merging,
// script rendering, variable rewriting and runArgs translation. Rendered
// scripts are *executed* with sh here, not just compared as text. The
// cluster-level BDD suite (features/devcontainer_metadata.feature) covers
// the same endpoint against real built images.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { buildDevcontainerMetadata, configLabelValue, mergeVscode, parsePasswdEntry, remoteUserFor } from "./devcontainer-metadata.js";
import { detectVariables, rewriteForShellString, shellWord } from "./devcontainer-variables.js";
import { parseByteSize, parseRunArgs } from "./devcontainer-runtime.js";

function sh(script: string, env: Record<string, string> = {}): { stdout: string; status: number | null } {
  const res = spawnSync("sh", ["-c", script], { env: { PATH: process.env.PATH ?? "/usr/bin:/bin", ...env }, encoding: "utf8" });
  return { stdout: res.stdout, status: res.status };
}

test("variables become shell references with the devcontainer.json default", () => {
  assert.equal(rewriteForShellString("a ${localEnv:TOKEN} b"), "a ${DEVCONTAINER_LOCALENV_TOKEN} b");
  assert.equal(rewriteForShellString("${env:ORG:acme}"), '${DEVCONTAINER_LOCALENV_ORG:-acme}');
  assert.equal(rewriteForShellString("${containerEnv:PATH}:/x"), "${PATH}:/x");
  assert.equal(rewriteForShellString("${containerWorkspaceFolderBasename}"), "${DEVCONTAINER_WORKSPACE_FOLDER_BASENAME}");
  // Not a devcontainer.json variable: left exactly as written, like the CLI.
  assert.equal(rewriteForShellString("${HOME} ${unknown:x}"), "${HOME} ${unknown:x}");
});

test("shellWord keeps literal text literal and expands references", () => {
  const word = shellWord('it\'s "q" $HOME `x` ${localEnv:ORG:dsc}');
  assert.equal(sh(`printf %s ${word}`, { HOME: "/h" }).stdout, 'it\'s "q" $HOME `x` dsc');
  assert.equal(sh(`printf %s ${word}`, { DEVCONTAINER_LOCALENV_ORG: "acme" }).stdout, 'it\'s "q" $HOME `x` acme');
});

test("detectVariables records kind, default and every place a variable is used", () => {
  const found = detectVariables([{ path: "remoteEnv", value: { A: "${localEnv:T:d}", B: "${localEnv:T}" } }]);
  assert.deepEqual(found, [{ kind: "localEnv", name: "T", default: "d", usedIn: ["remoteEnv.A", "remoteEnv.B"] }]);
});

test("runArgs: supported flags translate, everything else warns", () => {
  const warnings: string[] = [];
  const parsed = parseRunArgs(
    ["--cap-add=sys_ptrace", "--shm-size", "512m", "-e", "A=1", "--add-host=api.local:10.0.0.5", "--init", "--network=host", "-v", "/host:/c", "--cpus=1.5"],
    warnings,
  );
  assert.deepEqual(parsed.capAdd, ["SYS_PTRACE"]);
  assert.equal(parsed.shmSizeBytes, 512 * 2 ** 20);
  assert.deepEqual(parsed.env, [["A", "1"]]);
  assert.deepEqual(parsed.hostAliases, [{ ip: "10.0.0.5", hostnames: ["api.local"] }]);
  assert.equal(parsed.init, true);
  assert.equal(parsed.cpus, 1.5);
  assert.equal(warnings.length, 2, warnings.join("; "));
  assert.match(warnings.join("\n"), /--network=host/);
  assert.match(warnings.join("\n"), /bind mount -v \/host:\/c/);
});

test("parseByteSize understands Docker sizes", () => {
  assert.equal(parseByteSize("1g"), 2 ** 30);
  assert.equal(parseByteSize("64MiB"), 64 * 2 ** 20);
  assert.equal(parseByteSize("100"), 100);
  assert.equal(parseByteSize("lots"), null);
});

test("configLabelValue picks creation-time properties from JSONC", () => {
  const value = configLabelValue('{ // c\n "image": "x", "workspaceFolder": "/w", "runArgs": ["--init"], "remoteUser": "u", }');
  assert.deepEqual(JSON.parse(value!), { workspaceFolder: "/w", runArgs: ["--init"] });
  assert.equal(configLabelValue("not json"), undefined);
});

const label = JSON.stringify([
  { id: "ghcr.io/x/feature:1", postCreateCommand: "echo feature", customizations: { vscode: { extensions: ["A.b", "ms-python.python"] } } },
  {
    remoteUser: "vscode",
    containerEnv: { PATH: "${containerEnv:PATH}:/opt/bin" },
    remoteEnv: { ORG: "${localEnv:ORG:dsc}", DIR: "${containerWorkspaceFolder}" },
    postCreateCommand: ["printf", "%s|%s\\n", "${localEnv:ORG:dsc}", "${containerWorkspaceFolder}"],
    postStartCommand: { a: "echo a", b: ["echo", "b"] },
    forwardPorts: [3000, "db:5432"],
    portsAttributes: { "3000": { label: "Web" } },
    customizations: { vscode: { extensions: ["a.B", "-ms-python.python"] } },
  },
]);
const configLabel = JSON.stringify({ workspaceFolder: "/workspaces/${localWorkspaceFolderBasename}-app", runArgs: ["--cap-add=NET_ADMIN"], initializeCommand: "echo init" });

test("buildDevcontainerMetadata: runtime, env scripts and lifecycle scripts work together", () => {
  const out = buildDevcontainerMetadata(label, { configLabel, imageUser: "root" });
  assert.equal(out.runtime.remoteUser, "vscode");
  assert.deepEqual(out.runtime.ports, [{ port: 3000, label: "Web" }]);
  assert.deepEqual(out.runtime.capAdd, ["NET_ADMIN"]);
  assert.equal(out.configuration.workspaceFolder, "/workspaces/${localWorkspaceFolderBasename}-app");
  assert.deepEqual(mergeVscode(JSON.parse(label)).extensions, ["A.b"]);
  assert.match(out.warnings.join("\n"), /db:5432/);

  const runtimeEnv = { PATH: "/usr/bin:/bin", DEVCONTAINER_WORKSPACE_FOLDER: "/workspaces/repo-app", DEVCONTAINER_LOCALENV_ORG: "acme" };
  const env = sh(`${out.envScripts.containerEnv}${out.envScripts.remoteEnv}echo "$PATH|$ORG|$DIR"`, runtimeEnv);
  assert.equal(env.stdout.trim(), "/usr/bin:/bin:/opt/bin|acme|/workspaces/repo-app");

  const postCreate = sh(out.lifecycleScripts.postCreateCommand!, runtimeEnv);
  assert.equal(postCreate.status, 0);
  assert.match(postCreate.stdout, /feature\n/);
  assert.match(postCreate.stdout, /acme\|\/workspaces\/repo-app\n/);
  assert.ok(postCreate.stdout.indexOf("feature") < postCreate.stdout.indexOf("acme"), "Feature hooks run first");

  assert.match(sh(out.lifecycleScripts.initializeCommand!).stdout, /init/);
  const start = sh(out.lifecycleScripts.postStartCommand!);
  assert.equal(start.status, 0);
  assert.match(start.stdout, /\ba\n/);
  assert.match(start.stdout, /\bb\n/);
});

test("a failing hook stops the script with its exit code", () => {
  const out = buildDevcontainerMetadata(JSON.stringify([{ postCreateCommand: "exit 7" }, { postCreateCommand: "echo never" }]), { configLabel: "{}" });
  const res = sh(out.lifecycleScripts.postCreateCommand!);
  assert.equal(res.status, 7);
  assert.doesNotMatch(res.stdout, /never/);
});

test("images built before 0.3.0 (no config label) still work, with a warning", () => {
  const out = buildDevcontainerMetadata(JSON.stringify([{ remoteUser: "node" }]));
  assert.equal(out.configuration.workspaceFolder, "/workspaces/${localWorkspaceFolderBasename}");
  assert.match(out.warnings.join("\n"), /built before devcontainer-builder 0\.3\.0/);
});

test("the build-time account record is used only for the same remote user", () => {
  assert.deepEqual(parsePasswdEntry("dev:x:1001:1002::/home/dev:/bin/bash\n"), { name: "dev", uid: 1001, gid: 1002, home: "/home/dev" });
  assert.equal(parsePasswdEntry(""), undefined);
  assert.equal(remoteUserFor(JSON.stringify([{ remoteUser: "dev" }]), "root"), "dev");
  assert.equal(remoteUserFor(JSON.stringify([{}]), "node:node"), "node");

  const account = { name: "dev", uid: 1001, gid: 1002, home: "/home/dev" };
  const matching = buildDevcontainerMetadata(JSON.stringify([{ remoteUser: "dev" }]), { configLabel: JSON.stringify({ remoteUserAccount: account }) });
  assert.deepEqual([matching.runtime.remoteUserUid, matching.runtime.remoteUserGid, matching.runtime.remoteUserHome], [1001, 1002, "/home/dev"]);
  const other = buildDevcontainerMetadata(JSON.stringify([{ remoteUser: "node" }]), { configLabel: JSON.stringify({ remoteUserAccount: account }) });
  assert.equal(other.runtime.remoteUserUid, null);
});

// Keep the sh used above honest: a POSIX shell must exist for these tests.
test("sh is available", () => {
  assert.equal(execFileSync("sh", ["-c", "echo ok"], { encoding: "utf8" }).trim(), "ok");
});
