# Docs screenshots

`capture.mjs` captures the screenshots in `docs/assets/screenshots/` from a
real Coder deployment running this repository's template, with headless
Chromium (Playwright). Re-run it for each release, so the screenshots
always show the current UI.

```bash
cd tools/screenshots
npm install
npx playwright install --with-deps chromium

CODER_URL=https://coder.example.com \
CODER_SESSION_TOKEN=$(cat ~/.config/coderv2/session) \
TEMPLATE=kubernetes-devcontainer \
REDACT='you@yourcompany.com=you@example.com,your-username=you' \
npm run capture
```

| Variable | Default | |
|---|---|---|
| `CODER_URL`, `CODER_SESSION_TOKEN` | *(required)* | The deployment, and a session of a user who can create workspaces from `TEMPLATE`. |
| `TEMPLATE` | `kubernetes-devcontainer` | This repository's template, pushed with `--var subdomain_apps=false` unless the deployment has a wildcard access URL. Its display name shows on the create page, e.g. *Kubernetes (Dev Containers)*. |
| `FIXTURE_REPO`, `FIXTURE_BRANCH` | `DeepSpaceCartel/devcontainer-builder-examples`, `docs-demo` | A small app with a Dev Container configuration. You need push access: the script pushes a configuration change to show *Rebuild available*, then force-resets the branch to where it was. |
| `NO_CONFIG_BRANCH` | `missing-devcontainer-json` | A branch without a configuration, for *Add Dev Container config*. |
| `REDACT` | `""` | `text=replacement,…` replaced on every captured page (your email, your username). |
| `GIT_CREDENTIAL_HELPER` | *(git's own)* | A credential helper for the push, e.g. `!gh auth git-credential`. |
| `KEEP_WORKSPACES` | `0` | `1` keeps the `docs-demo` and `docs-no-config` workspaces it creates (to iterate). |
| `OUT` | `docs/assets/screenshots` | Where the PNGs go. |

What it does:

1. Captures the create page, prefilled with the fixture repository.
2. Creates (or reuses) `docs-demo` on `FIXTURE_BRANCH` and captures its page in the dashboard.
3. Opens VS Code in the browser, trusts the folder as a user would, and captures the status bar
   states:
   - up to date;
   - a local edit, which shows *Push Dev Container changes*;
   - a pushed change, which shows *Rebuild available* and its notification.
4. Creates `docs-no-config` and captures *Add Dev Container config*.
5. Resets the fixture branch and deletes the workspaces it created.

It writes 1280×800 PNGs. Coder pages use the session user's theme; VS Code
uses its default light theme. On failure, it saves `_failed-*.png` next to
the screenshots (gitignored).

VS Code **Desktop**'s *Coder: Clone Repository in Workspace…* runs in a local
window, which this script can't drive. Those shots are taken by hand:
see [`DESKTOP-SHOTS.md`](DESKTOP-SHOTS.md).
