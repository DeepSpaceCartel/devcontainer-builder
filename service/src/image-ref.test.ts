// Image reference rules: derived names, request field patterns, and the
// cache backends a caller may choose.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  checkCacheOption,
  deriveImageName,
  IMAGE_NAME_PATTERN,
  IMAGE_REGISTRY_PATTERN,
  IMAGE_TAG_PATTERN,
  PLATFORM_PATTERN,
} from "./image-ref.js";
import { BuildRequestError } from "./errors.js";

test("derived image names are lower-cased and squeezed into the OCI name grammar", () => {
  assert.equal(deriveImageName("Org/MyRepo.git"), "myrepo");
  assert.equal(deriveImageName("org/example-devcontainer.git"), "example-devcontainer");
  assert.equal(deriveImageName("org/My Repo!!v2"), "my-repo-v2");
  assert.equal(deriveImageName("org/a..b"), "a-b");
  assert.equal(deriveImageName("org/a__b"), "a__b");
  assert.equal(deriveImageName("org/-_Repo_-"), "repo");
  assert.equal(deriveImageName("org/repo.git/"), "repo");
  for (const name of ["myrepo", "my-repo-v2", "a__b"]) assert.match(name, new RegExp(IMAGE_NAME_PATTERN));
});

test("a path with nothing usable asks for image.name", () => {
  assert.throws(() => deriveImageName("org/***.git"), (err: Error) => err instanceof BuildRequestError && /image\.name/.test(err.message));
  assert.throws(() => deriveImageName(""), BuildRequestError);
});

test("request image fields follow the OCI reference grammar", () => {
  const name = new RegExp(IMAGE_NAME_PATTERN);
  const tag = new RegExp(IMAGE_TAG_PATTERN);
  const registry = new RegExp(IMAGE_REGISTRY_PATTERN);
  for (const ok of ["app", "team/app", "a.b_c__d-e", "a--b"]) assert.match(ok, name);
  for (const bad of ["MyRepo", "-app", "app-", "a//b", "app:tag", "a b"]) assert.doesNotMatch(bad, name);
  for (const ok of ["v1.2.3", "sha-abc1234", "_x", "Latest"]) assert.match(ok, tag);
  for (const bad of [".x", "-x", "a:b", "x".repeat(129)]) assert.doesNotMatch(bad, tag);
  for (const ok of ["ghcr.io", "ghcr.io/org", "registry.local:5000", "localhost:5000/team/sub", "[::1]:5000"]) assert.match(ok, registry);
  for (const bad of ["http://ghcr.io", "https://ghcr.io/org", "ghcr.io/Org", "ghcr.io:port", "a b", "ghcr.io/"]) assert.doesNotMatch(bad, registry);
});

test("platforms must look like os/arch[/variant]", () => {
  const platform = new RegExp(PLATFORM_PATTERN);
  for (const ok of ["linux/amd64", "linux/arm64/v8", "linux/arm/v7", "linux/x86_64"]) assert.match(ok, platform);
  for (const bad of ["linux", "linux/amd64,linux/arm64", "linux/amd64 --push", "linux//amd64", "/amd64"]) assert.doesNotMatch(bad, platform);
});

test("cache options allow registry, gha and inline only", () => {
  for (const ok of [
    "ghcr.io/example:cache",
    "type=registry,ref=ghcr.io/example:cache",
    "type=registry,ref=ghcr.io/example:cache,mode=max",
    "ref=ghcr.io/x:cache,type=gha",
    "type=inline",
    "TYPE=Registry,ref=x",
  ]) {
    assert.doesNotThrow(() => checkCacheOption("buildOptions.cacheTo", ok), ok);
  }
  assert.throws(() => checkCacheOption("buildOptions.cacheTo", "type=local,dest=/etc"), /cache type "local" is not allowed/);
  assert.throws(() => checkCacheOption("buildOptions.cacheFrom", "type=s3,bucket=b"), /buildOptions\.cacheFrom: cache type "s3"/);
  assert.throws(() => checkCacheOption("buildOptions.cacheTo", "type=registry,type=local,dest=/x"), /"local"/);
  assert.throws(() => checkCacheOption("buildOptions.cacheTo", "dest=/etc,src=/x"), /must name a cache type/);
  assert.throws(() => checkCacheOption("buildOptions.cacheTo", '"type=local,dest=/etc"'), /quotes/);
});
