#!/usr/bin/env bash
# Installs what devcontainer.json's `image` (a typescript-node base image)
# is expected to already provide - Node 20, npm, git - for when the
# workspace actually boots from something else instead (e.g. a Coder
# Workspace Template pointed at a plain base image by mistake, with no Node
# runtime at all). Idempotent: a no-op fast-path when the expected image is
# in fact running and already has these.
#
# Then installs sandbox2/'s own npm dependencies (cucumber-js, TypeScript,
# tsx, js-yaml, jmespath - see sandbox2/package.json) so its BDD sources are
# runnable right after the workspace comes up.
#
# Sourced by postCreateCommand.sh (so this only needs to run once per
# workspace, ahead of anything there that shells out to `npm`) and called by
# install.sh (the non-Dev-Containers bootstrap path) - self-contained so
# either can invoke it standalone.
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

# --- Node 20 + npm (NodeSource apt repo, matching service/Dockerfile's
#     pinned major version and CI's actions/setup-node node-version) -------
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -d. -f1 | tr -d v)" -ne 20 ]; then
  echo "Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO bash -
  $SUDO apt-get install -y --no-install-recommends nodejs
fi

# --- git --------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  echo "Installing git..."
  $SUDO apt-get update
  $SUDO apt-get install -y --no-install-recommends git
fi

# --- npm global installs without root --------------------------------------
# NodeSource's nodejs package leaves /usr/lib/node_modules root-owned, unlike
# the typescript-node image (which grants its non-root user write access
# there) - so `npm install -g` (postCreateCommand.sh's @devcontainers/cli
# and Claude Code CLI installs) fails with EACCES. Point npm's global
# prefix at a directory this user owns instead, unconditionally, since we
# can't assume the fast-path (image already had Node) left a writable one.
npm_global_dir="$HOME/.npm-global"
if [ "$(npm config get prefix 2>/dev/null)" != "$npm_global_dir" ]; then
  mkdir -p "$npm_global_dir"
  npm config set prefix "$npm_global_dir"
fi
export PATH="$npm_global_dir/bin:$PATH"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ -f "$rc" ] && ! grep -qF '.npm-global/bin' "$rc"; then
    echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$rc"
  fi
done

# --- sandbox2/ npm dependencies --------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sandbox2_dir="$(cd "$script_dir/.." && pwd)/sandbox2"
if [ -f "$sandbox2_dir/package.json" ] && [ ! -d "$sandbox2_dir/node_modules" ]; then
  echo "Installing sandbox2/ npm dependencies..."
  (cd "$sandbox2_dir" && npm install)
fi

echo "typescript-node.sh done: node, npm, git, sandbox2/ deps ready."
