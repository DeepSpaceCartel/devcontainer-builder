import { Then } from "@cucumber/cucumber";
import assert from "node:assert/strict";

// Asserts only the validation boundary, not the eventual build outcome: a
// request that passes validation may still fail later (unresolvable
// registry, a real clone attempt against a nonexistent repo, ...) - this
// step only distinguishes "rejected before any build work started" from
// everything else.
Then("the request should pass validation", function () {
  if (this.response.status !== 400) return;

  let parsed;
  try {
    parsed = JSON.parse(this.response.body);
  } catch {
    return;
  }

  const isValidationError =
    parsed && typeof parsed.error === "string" && parsed.error.startsWith("missing or invalid fields");
  assert.ok(!isValidationError, `expected request to pass validation, but got a validation error: ${this.response.body}`);
});
