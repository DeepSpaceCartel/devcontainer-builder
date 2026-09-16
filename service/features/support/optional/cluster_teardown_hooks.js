import { AfterAll } from "@cucumber/cucumber";
import { spawn } from "node:child_process";
import { helmInstalls } from "../../step_definitions/cli.steps.js";

// Deliberately NOT part of the shared features/support/*.js glob - only
// suites that actually run real "helm upgrade --install ..." commands
// (via cli.steps.js's "... has been run" step) import this file, for
// teardown. There's no fixture registry to consult any more: this just
// reverses whatever `helm upgrade --install <release> ... -n <namespace>`
// commands this process actually ran (tracked generically by cli.steps.js,
// with no chart/fixture-specific knowledge), the same way a human who set
// several things up by hand would `helm uninstall` each of them when done.
AfterAll({ timeout: 120_000 }, async function () {
  await Promise.all(
    [...helmInstalls].map((key) => {
      const [release, namespace] = key.split("::");
      return new Promise((resolve) => {
        const child = spawn("helm", ["uninstall", release, "-n", namespace, "--wait", "--timeout", "60s"], {
          stdio: "ignore",
        });
        child.on("error", resolve);
        child.on("exit", resolve);
      });
    }),
  );
});
