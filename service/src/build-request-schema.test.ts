// The new POST /build fields' shape rules (ADR-0016), checked against the
// TypeBox schema Fastify validates with.
import { test } from "node:test";
import assert from "node:assert/strict";
import { Value } from "@sinclair/typebox/value";
import { BuildRequestSchema, BuildResponseSchema } from "./schemas.js";

const base = { repository: "https://github.com/deepspacecartel/devcontainer-builder-examples.git" };

test("instances: optional, null, or a non-empty list of non-empty strings", () => {
  assert.ok(Value.Check(BuildRequestSchema, base));
  assert.ok(Value.Check(BuildRequestSchema, { ...base, instances: null }));
  assert.ok(Value.Check(BuildRequestSchema, { ...base, instances: ["main", "backend"] }));
  assert.ok(!Value.Check(BuildRequestSchema, { ...base, instances: [] }));
  assert.ok(!Value.Check(BuildRequestSchema, { ...base, instances: [""] }));
  assert.ok(!Value.Check(BuildRequestSchema, { ...base, instances: "main" }));
  assert.ok(!Value.Check(BuildRequestSchema, { ...base, instances: [1] }));
});

test("dryRun: optional boolean", () => {
  assert.ok(Value.Check(BuildRequestSchema, { ...base, dryRun: true }));
  assert.ok(Value.Check(BuildRequestSchema, { ...base, dryRun: false }));
  assert.ok(!Value.Check(BuildRequestSchema, { ...base, dryRun: "yes" }));
});

test("response: today's single-image fields plus images, imageBuildLogId optional for a dry run", () => {
  const item = {
    id: "main",
    configPath: ".devcontainer.json",
    image: "r.example/repo:sha-abcdef0",
    registry: "r.example",
    name: "repo",
    tag: "sha-abcdef0",
  };
  const response = { image: item.image, registry: "r.example", name: "repo", tag: "sha-abcdef0", branch: "main", commit: "abc", images: [item] };
  assert.ok(Value.Check(BuildResponseSchema, response));
  assert.ok(Value.Check(BuildResponseSchema, { ...response, imageBuildLogId: "docker-x", images: [{ ...item, imageBuildLogId: "docker-x" }] }));
  assert.ok(!Value.Check(BuildResponseSchema, { ...response, images: [] }));
});
