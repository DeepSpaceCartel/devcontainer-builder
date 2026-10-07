import assert from "node:assert/strict";
import { test } from "node:test";
import { parseJsonc } from "./jsonc";
import { rebuildPaths, unionPaths } from "./paths";

test("parseJsonc strips comments and trailing commas, not string contents", () => {
  const text = `{
    // line comment
    "image": "mcr.microsoft.com/devcontainers/base", /* block */
    "url": "https://example.com//not-a-comment",
    "list": ["a", "b",],
  }`;
  assert.deepEqual(parseJsonc(text), {
    image: "mcr.microsoft.com/devcontainers/base",
    url: "https://example.com//not-a-comment",
    list: ["a", "b"],
  });
});

test("parseJsonc leaves ,] and ,} inside strings alone", () => {
  const text = `{
    "a": "x,]",
    "b": "y, }",
    "c": "\\",]", // an escaped quote, then ,]
    "d": [1, /* gap */ 2, // trailing
    ],
  }`;
  assert.deepEqual(parseJsonc(text), { a: "x,]", b: "y, }", c: '",]', d: [1, 2] });
  assert.throws(() => parseJsonc(`[1,,]`));
});

test("an image-only config only has the Dev Container files", () => {
  assert.deepEqual(rebuildPaths(".devcontainer/devcontainer.json", `{"image": "x"}`), [".devcontainer", ".devcontainer.json"]);
});

test("build.dockerfile and context resolve relative to devcontainer.json", () => {
  assert.deepEqual(
    rebuildPaths(".devcontainer/devcontainer.json", `{"build": {"dockerfile": "../docker/Dockerfile", "context": "../docker"}}`),
    [".devcontainer", ".devcontainer.json", "docker", "docker/Dockerfile"],
  );
});

test("a Dockerfile without a context defaults to devcontainer.json's folder", () => {
  assert.deepEqual(rebuildPaths(".devcontainer/devcontainer.json", `{"build": {"dockerfile": "Dockerfile"}}`), [
    ".devcontainer",
    ".devcontainer.json",
    ".devcontainer/Dockerfile",
  ]);
});

test("a context at or above the repo root means every change", () => {
  assert.deepEqual(rebuildPaths(".devcontainer/devcontainer.json", `{"build": {"dockerfile": "Dockerfile", "context": ".."}}`), ["."]);
  assert.deepEqual(rebuildPaths(".devcontainer.json", `{"build": {"dockerfile": "Dockerfile"}}`), ["."]);
  assert.deepEqual(rebuildPaths(".devcontainer/devcontainer.json", `{"build": {"context": "../.."}}`), ["."]);
});

test("legacy dockerFile/context and unparsable configs", () => {
  assert.deepEqual(rebuildPaths(".devcontainer/devcontainer.json", `{"dockerFile": "../Dockerfile", "context": "../src"}`), [
    ".devcontainer",
    ".devcontainer.json",
    "Dockerfile",
    "src",
  ]);
  assert.deepEqual(rebuildPaths(".devcontainer/devcontainer.json", `{ nope`), [".devcontainer", ".devcontainer.json"]);
});

test("unionPaths", () => {
  assert.deepEqual(unionPaths(["b", "a"], ["a", "c"]), ["a", "b", "c"]);
  assert.deepEqual(unionPaths(["a"], ["."]), ["."]);
});
