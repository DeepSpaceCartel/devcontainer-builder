// Repository URL policy: which URLs a build may clone, and how URL
// credentials are kept out of logs and errors.
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkRepositoryUrl, gitAllowProtocol, parseGitUrl, redactUrlCredentials } from "./git-url.js";
import { BuildRequestError } from "./errors.js";

test("https, ssh and SCP-style URLs are accepted", () => {
  assert.deepEqual(checkRepositoryUrl("https://github.com/Org/Repo.git", false), {
    scheme: "https",
    host: "github.com",
    path: "Org/Repo.git",
  });
  assert.equal(checkRepositoryUrl("ssh://git@github.com:22/org/repo.git", false).host, "github.com");
  assert.deepEqual(checkRepositoryUrl("git@github.com:org/repo.git", false), { scheme: "scp", host: "github.com", path: "org/repo.git" });
});

test("credentials in an http(s) URL are rejected, pointing at gitCredentials", () => {
  for (const url of ["https://user:ghp_secret@github.com/org/repo.git", "https://ghp_secret@github.com/org/repo.git"]) {
    assert.throws(
      () => checkRepositoryUrl(url, false),
      (err: Error) => err instanceof BuildRequestError && /gitCredentials/.test(err.message) && !err.message.includes("ghp_secret"),
    );
  }
  assert.throws(() => checkRepositoryUrl("ssh://git:hunter2@github.com/org/repo.git", false), BuildRequestError);
});

test("file://, ext:: and other schemes are rejected; git:// and http:// only with the opt-in", () => {
  for (const url of ["file:///etc/repo.git", "ftp://host/repo.git", "ext::sh -c touch% /tmp/pwned"]) {
    assert.throws(() => checkRepositoryUrl(url, true), BuildRequestError, url);
  }
  for (const url of ["git://host:9418/repo.git", "http://host/repo.git"]) {
    assert.throws(() => checkRepositoryUrl(url, false), /allowInsecureGitProtocols/);
    assert.equal(checkRepositoryUrl(url, true).host, "host");
  }
});

test("an SCP-style host that ssh would read as an option is rejected", () => {
  assert.throws(() => checkRepositoryUrl("-oProxyCommand=touch /tmp/pwned:repo", false), BuildRequestError);
});

test("an unparseable URL is a BuildRequestError without its credentials", () => {
  assert.throws(() => parseGitUrl("not a git url at all"), /unable to parse git repository URL: not a git url at all/);
  assert.throws(
    () => parseGitUrl("https://user:secret@[bad/repo"),
    (err: Error) => err instanceof BuildRequestError && !err.message.includes("secret"),
  );
});

test("GIT_ALLOW_PROTOCOL follows the opt-in", () => {
  assert.equal(gitAllowProtocol(false), "https:ssh");
  assert.equal(gitAllowProtocol(true), "https:ssh:http:git");
});

test("URL credentials are redacted anywhere in a string; a bare ssh user is kept", () => {
  assert.equal(
    redactUrlCredentials("git clone -- https://user:tok@github.com/org/repo.git /tmp/x"),
    "git clone -- https://[redacted]@github.com/org/repo.git /tmp/x",
  );
  assert.equal(redactUrlCredentials("https://ghp_tok@github.com/r"), "https://[redacted]@github.com/r");
  assert.equal(redactUrlCredentials("ssh://git@github.com/r"), "ssh://git@github.com/r");
  assert.equal(redactUrlCredentials("ssh://git:pw@github.com/r"), "ssh://[redacted]@github.com/r");
  assert.equal(redactUrlCredentials("no urls here"), "no urls here");
});
