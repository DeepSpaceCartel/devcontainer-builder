#!/usr/bin/env bash
# Runs as root at image build time (a Dev Container Feature). Same installs
# postCreateCommand.sh falls back to on a plain machine (install.sh) - here
# they land in the image, so the per-start postCreateCommand finds them.
set -euo pipefail

arch="$(dpkg --print-architecture)"
codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg tzdata pipx python3-venv
install -m 0755 -d /etc/apt/keyrings

# --- Docker CLI + buildx plugin (no dockerd: builds go to a remote BuildKit)
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" \
  > /etc/apt/sources.list.d/docker.list

# --- 1Password CLI (apt repo + debsig verification, per
#     https://developer.1password.com/docs/cli/get-started/#install)
curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
  | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
echo "deb [arch=${arch} signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/${arch} stable main" \
  > /etc/apt/sources.list.d/1password.list
mkdir -p /etc/debsig/policies/AC2D62742012EA22/ /usr/share/debsig/keyrings/AC2D62742012EA22
curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol \
  > /etc/debsig/policies/AC2D62742012EA22/1password.pol
curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
  | gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg

apt-get update
apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin 1password-cli
rm -rf /var/lib/apt/lists/*

# --- Dev Containers CLI (same as service/Dockerfile)
npm install -g @devcontainers/cli

# --- k9s (latest release binary)
tmp_dir="$(mktemp -d)"
asset_url="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest \
  | grep -oE '"browser_download_url":[[:space:]]*"[^"]*[Ll]inux_'"${arch}"'\.tar\.gz"' \
  | head -n1 | cut -d'"' -f4)"
curl -fsSL -o "$tmp_dir/k9s.tar.gz" "$asset_url"
tar -xzf "$tmp_dir/k9s.tar.gz" -C "$tmp_dir" k9s
install -m 0755 "$tmp_dir/k9s" /usr/local/bin/k9s
rm -rf "$tmp_dir"

# --- Starship prompt (the binary; postCreateCommand.sh wires up the rc files)
curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin
