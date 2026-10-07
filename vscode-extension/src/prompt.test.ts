import assert from "node:assert/strict";
import { test } from "node:test";
import { decidePrompt, localKey } from "./prompt";
import type { Status } from "./status";

const status = (over: Partial<Status>): Status => ({
  kind: "rebuild-available",
  branch: "main",
  imageCommit: "a".repeat(40),
  originCommit: "b".repeat(40),
  changed: [".devcontainer/devcontainer.json"],
  local: [],
  paths: [],
  ...over,
});

test("prompts once per origin commit", () => {
  assert.equal(decidePrompt(status({}), { snoozed: false }).kind, "rebuild");
  assert.equal(decidePrompt(status({}), { snoozed: false, promptedOrigin: "b".repeat(40) }).kind, "none");
  assert.equal(decidePrompt(status({ originCommit: "c".repeat(40) }), { snoozed: false, promptedOrigin: "b".repeat(40) }).kind, "rebuild");
});

test("Later snoozes everything; Ignore until origin moves", () => {
  assert.equal(decidePrompt(status({}), { snoozed: true }).kind, "none");
  assert.equal(decidePrompt(status({}), { snoozed: false, ignoredOrigin: "b".repeat(40) }).kind, "none");
  assert.equal(decidePrompt(status({ originCommit: "c".repeat(40) }), { snoozed: false, ignoredOrigin: "b".repeat(40) }).kind, "rebuild");
});

test("push nudge once per set of local changes; nothing otherwise", () => {
  const s = status({ kind: "unpushed", changed: [], local: [".devcontainer/devcontainer.json"] });
  assert.equal(decidePrompt(s, { snoozed: false }).kind, "push");
  assert.equal(decidePrompt(s, { snoozed: false, nudgedLocal: localKey(s) }).kind, "none");
  assert.equal(decidePrompt(status({ kind: "up-to-date" }), { snoozed: false }).kind, "none");
  assert.equal(decidePrompt(status({ kind: "unknown" }), { snoozed: false }).kind, "none");
});
