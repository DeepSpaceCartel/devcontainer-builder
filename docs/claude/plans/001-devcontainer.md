---
title: Add .devcontainer.json + manual-mode bootstrap scripts
created: 2026-09-05
---

# Add .devcontainer.json + manual-mode bootstrap scripts

## Context

This repo (`devcontainer-builder`) exists to let a Coder Workspace Template on
Kubernetes boot a container straight from a repo's `.devcontainer.json`. It's
scaffold-only right now (per README "Status") — Dev Container support in this
Coder/K8s setup isn't wired up yet, which means the person developing *this
repo* can't yet use a Dev Container to develop it. That's a temporary
chicken-and-egg gap, not a reason to skip authoring `.devcontainer.json`
correctly for when it *is* wired up.

So we're adding three files with a clear division of labor:

1. `.devcontainer/devcontainer.json` — the correct, future-facing config.
   Assumes a prebuilt Microsoft dev image and a `postCreateCommand` lifecycle
   hook, same as any normal Dev Container.
2. `.devcontainer/postCreateCommand.sh` — installs the tools the prebuilt
   image *doesn't* include (Helm, Terraform, kubectl, k9s, the `helm tui`
   plugin), because Dev Container Features aren't usable yet either and
   everything has to go through plain shell for now. This script keeps
   working once Features are usable too.
3. `install.sh` (repo root) — a manual bootstrap for the user's *current*
   environment: a plain K8s pod (Coder workspace) with a service account
   mounted, no Dev Container runtime at all. It installs what the
   `typescript-node` base image would otherwise provide (Node 20, npm, git)
   and then runs `postCreateCommand.sh` so one script gets a fully-equipped
   shell today.

No Docker/DIND anywhere — the user drives Kubernetes directly via `kubectl`/
`helm`/`k9s` against the pod's mounted service account. `service/Dockerfile`
is explicitly out of scope (production runtime image for the service, not a
dev environment).

## Research findings that shape version choices

- Node: pinned to major `20` everywhere that matters (`service/Dockerfile:1,10`,
  CI's `actions/setup-node@v4` `node-version: "20"`). No `engines` field in
  `service/package.json`, no lockfile.
- TypeScript: `^5.6.0` devDependency (`service/package.json`).
- Terraform: `required_version = ">= 1.0"` (`terraform/devcontainer-build/main.tf:2`),
  CI's `hashicorp/setup-terraform@v3` has no `terraform_version` pin either.
- Helm: no version constraint anywhere (`Chart.yaml` has no `kubeVersion`), CI's
  `azure/setup-helm@v4` has no version pin either.
- kubectl: not mentioned anywhere in the repo.
- Conclusion: the repo's existing convention for Helm/Terraform/kubectl is
  "install whatever's currently latest/stable," not pin-and-bump. The new
  scripts follow that same convention (official installers that fetch latest
  stable) rather than inventing a hardcoded version nothing else in the repo
  tracks. Node stays pinned to major `20` since that's the one version
  constraint that already exists and matters for compatibility with
  `service/`.
- k9s and the `helm tui` Helm plugin (https://github.com/pidanou/helm-tui)
  both ship prebuilt binaries (k9s via GitHub release tarballs; helm-tui via
  its plugin's `install-binary.sh` hook run by `helm plugin install`) — no Go
  toolchain needed for either.

## Files added

### `.devcontainer/devcontainer.json`

- `"image": "mcr.microsoft.com/devcontainers/typescript-node:1-20-bookworm"`
  — Node 20 major (matches `service/Dockerfile`/CI), Bookworm (matches
  `service/Dockerfile`'s `node:20-bookworm-slim`).
- `"remoteUser": "node"` (the image's built-in non-root user).
- `"postCreateCommand": "bash .devcontainer/postCreateCommand.sh"`.
- No `features` block — deliberately, so tool install logic lives in one
  place (shell scripts) that works identically whether or not Dev Container
  Features are usable, per the user's constraint.
- Light `customizations.vscode.extensions`: `hashicorp.terraform`,
  `redhat.vscode-yaml`. Nothing docker-related.

### `.devcontainer/postCreateCommand.sh`

Bash, `set -euo pipefail`, idempotent (skip install if the binary already
exists). Installs, in order:

1. **Helm** — official `get_helm.sh` installer (latest stable).
2. **Terraform** — HashiCorp's apt repo (same GPG-key-then-apt-source pattern
   already used for Docker's apt repo in `service/Dockerfile:12-19`, adapted
   for HashiCorp's repo), `apt-get install terraform` (latest).
3. **kubectl** — official binary download using the `dl.k8s.io/release/stable.txt`
   pointer (latest stable), architecture-detected via `dpkg --print-architecture`.
4. **k9s** — latest GitHub release tarball for the detected arch
   (`derailed/k9s`), binary extracted to `/usr/local/bin/k9s`.
5. **helm tui plugin** — `helm plugin install https://github.com/pidanou/helm-tui`
   (skipped if `helm plugin list` already shows `tui`), invoked afterwards as
   `helm tui`.

Comment at the top explaining *why* nothing here is version-pinned (mirrors
CI's own unpinned Helm/Terraform setup) and *why* this file exists separately
from `install.sh` (this piece keeps applying once Dev Containers/Features
work; `install.sh` is the temporary bridge until then).

### `install.sh` (repo root)

Bash, `set -euo pipefail`. For the user's current manual-mode pod:

1. Install Node 20 + npm via NodeSource's apt setup script (Debian/Bookworm
   assumed, matching the rest of the repo's tooling) — skip if `node -v`
   already reports major 20.
2. Install `git` if missing.
3. Exec `.devcontainer/postCreateCommand.sh` at the end so Helm/Terraform/
   kubectl/k9s/helm-tui come from the one script that will also run later
   once Dev Containers work — no duplicated install logic.

Comment at the top: this script exists only because Dev Containers aren't
usable yet in this Coder/K8s setup; once they are, `devcontainer.json` +
`postCreateCommand.sh` alone are sufficient and this file can be deleted.

## Out of scope

- No changes to `service/Dockerfile`.
- No Dev Container Features.
- No README/CLAUDE.md edits.
- No `.gitignore` changes needed (new files are meant to be committed).

## Verification

- `bash -n .devcontainer/postCreateCommand.sh` and `bash -n install.sh`
  (syntax check only — can't exercise the installs themselves without
  network/root in this environment, and can't spin up the Dev Container at
  all yet per the user's constraint).
- `chmod +x .devcontainer/postCreateCommand.sh install.sh` so both are
  directly runnable.
- Cross-check both scripts against `service/Dockerfile`'s apt-repo pattern
  for consistency (key import → source list → apt-get update → install).
