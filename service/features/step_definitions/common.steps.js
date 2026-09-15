import { When, Then } from "@cucumber/cucumber";
import assert from "node:assert/strict";
import { substituteNamedValues } from "../support/named_values.js";

// Every migrated feature file's devcontainer-builder Service resolves to
// the *same* DNS name/origin ("http://devcontainer-builder-devcontainer-
// builder.<namespace>.svc.cluster.local:8080"), and undici's global fetch
// agent pools keep-alive connections per origin across the whole
// cucumber-js process - not just within one file. A rollout between two
// scenarios (this file's own Background re-deploying with different
// config, or simply the next feature file in a combined `npm test` run)
// can tear down the specific pod a pooled connection was talking to, so
// reusing that socket for the next request fails outright ("fetch
// failed") rather than transparently falling back to a fresh connection.
// The raw `/dev/tcp` reachability poll every Background does runs over a
// separate, throwaway socket - it never "warms" the specific pooled
// connection fetch() will actually try to reuse, so it doesn't guard
// against this. `Connection: close` forces a fresh connection per
// request, trading a little latency for eliminating the whole class of
// stale-pooled-socket failures.
const NO_KEEPALIVE = { Connection: "close" };

// A combined `npm test` run (all ten files, one long-lived Node process)
// occasionally hits a bare `TypeError: fetch failed` - a connection-level
// failure (refused/reset), never a real HTTP response - that never
// reproduces when the same file runs alone. Every individual feature file
// is independently verified reliable in isolation; this only shows up
// under the combined run's sustained, hours-long real network load
// against a real cluster. Retrying purely the connection failure (not
// swallowing a real 4xx/5xx, which is a legitimate assertion target) is
// the correct fix for that class of flake without masking an actual bug.
async function fetchWithRetry(url, options, attempts = 3) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await fetch(url, options);
    } catch (err) {
      if (attempt >= attempts) throw err;
      await new Promise((resolve) => setTimeout(resolve, 500 * attempt));
    }
  }
}

// Every scenario resolves a "<base-url>"-style named value (from a
// Background/Scenario's "the value ... is known as ..." step, itself
// derived from a Service DNS name or, for a deliberately-not-ready pod, a
// direct pod IP) before ever sending a request - see health.feature and
// service_startup_configuration.feature for how that's built. Substituting
// first always yields a full "http://..." URL here.
When("I send a {word} request to {string}", async function (method, path) {
  const url = substituteNamedValues(this, path);
  const res = await fetchWithRetry(url, { method, headers: NO_KEEPALIVE });
  this.response = { status: res.status, body: await res.text() };
});

// The doc string is forwarded as the request body - including deliberately
// invalid JSON in validation-negative scenarios - except for registered
// named values (see substituteNamedValues above), substituted with real
// per-run fixture addresses so a scenario can reference them in a request
// body the same way it does anywhere else.
When("I send a POST request to {string} with body:", async function (path, docString) {
  const url = substituteNamedValues(this, path);
  const body = substituteNamedValues(this, docString);
  const res = await fetchWithRetry(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...NO_KEEPALIVE },
    body,
  });
  this.response = { status: res.status, body: await res.text() };
});

Then("the service should start successfully", function () {
  assert.equal(this.lastCommand?.code, 0, `expected the service to start, but the last command failed: ${this.lastCommand?.stderr || this.lastCommand?.stdout}`);
});

Then("the service should fail to start", function () {
  if (this.crashLoopConfirmed !== undefined) {
    assert.ok(this.crashLoopConfirmed, "expected the deployment to crash-loop, but it didn't");
  } else {
    assert.notEqual(this.lastCommand?.code, 0, "expected the service to fail to start, but the last command succeeded");
  }
});

// Populated by "the devcontainer-builder's crash logs are captured" (or a
// "kubectl logs ... has been run again" + "the command output is known as
// \"<logs>\"" pair) - index.ts's fatal-exception handler prints one JSON
// line, so this decodes it and matches against the *actual* message/stack
// text rather than the raw JSON blob (which has every internal quote
// backslash-escaped, e.g. `\"tofu\"` - never matching a plain-text
// expectation like `"tofu"`). Falls back to raw text if the line isn't
// JSON.
Then("the startup error should mention {string}", function (substring) {
  let message = this.namedValues?.["<logs>"];
  const jsonLine = message?.split("\n").find((line) => line.trim().startsWith("{"));
  if (jsonLine) {
    try {
      const parsed = JSON.parse(jsonLine);
      message = `${parsed.message ?? ""}\n${parsed.stack ?? ""}`;
    } catch {
      // not JSON - keep the raw text
    }
  }
  assert.ok(
    message?.includes(substring),
    `expected startup error to mention ${JSON.stringify(substring)}, got: ${message}`,
  );
});

Then("the invalid entry should have been logged and skipped", function () {
  assert.match(this.namedValues?.["<logs>"] ?? "", /skipping invalid .* config entry/);
});

Then("the response status should be {int}", function (expectedStatus) {
  assert.equal(this.response.status, expectedStatus);
});

// Substitutes any namedValues declared by prior "... is known as ..."
// steps - lets a scenario assert against real fixture URLs/hosts and the
// fixture's real, content-derived HEAD sha instead of values it can't
// actually control, with every real query now an explicit prior step
// rather than invisible inside this assertion.
Then("the resolved image should be {string}", function (expected) {
  const resolved = substituteNamedValues(this, expected);
  const actual = JSON.parse(this.response.body);
  assert.equal(actual.image, resolved);
});

Then("the response body should equal:", function (docString) {
  assert.deepEqual(JSON.parse(this.response.body), JSON.parse(docString));
});

// Partial match: every key/value pair in the doc string must be present
// (and equal) in the actual response body, which may have other fields too.
Then("the response body should include:", function (docString) {
  const actual = JSON.parse(this.response.body);
  const expected = JSON.parse(docString);
  for (const [key, value] of Object.entries(expected)) {
    assert.deepEqual(actual[key], value, `expected response body's "${key}" to equal ${JSON.stringify(value)}, got ${JSON.stringify(actual[key])}`);
  }
});

Then("the response body should contain {string}", function (substring) {
  assert.ok(
    this.response.body.includes(substring),
    `expected response body to contain ${JSON.stringify(substring)}, got: ${this.response.body}`,
  );
});

Then("the response body should not contain {string}", function (substring) {
  assert.ok(
    !this.response.body.includes(substring),
    `expected response body NOT to contain ${JSON.stringify(substring)}, got: ${this.response.body}`,
  );
});

// git/docker/devcontainer subprocess output is run with stdio:"inherit"
// (see run() in build.ts), so it lands on the pod's own stdout/stderr,
// never in the HTTP response body (which only ever gets the generic
// "<cmd> ... exited with code N" message) - use these (not "the response
// body should ...") to assert on what those tools actually printed, e.g.
// distinguishing a host-key-verification failure from an auth failure, or
// confirming a push's actual HTTP status. Populated by "the
// devcontainer-builder's logs are captured" (or a "kubectl logs ... has
// been run again" + "the command output is known as \"<logs>\"" pair).
Then("the service logs should contain {string}", function (substring) {
  const logs = this.namedValues?.["<logs>"] ?? "";
  assert.ok(
    logs.includes(substring),
    `expected service logs to contain ${JSON.stringify(substring)}, got: ${logs}`,
  );
});

Then("the service logs should not contain {string}", function (substring) {
  const logs = this.namedValues?.["<logs>"] ?? "";
  assert.ok(
    !logs.includes(substring),
    `expected service logs NOT to contain ${JSON.stringify(substring)}, got: ${logs}`,
  );
});
