#!/usr/bin/env bash
# Idempotent Go toolchain installer for building the sibling
# terraform-provider-devcontainer-builder repo (the Terraform provider
# wrapping this service - it lives in its own repo, not provider/ here,
# see CLAUDE.md). Only job: make `go` available at a minimum version. No
# other side effects.
set -euo pipefail

GO_VERSION="1.27.1"
MIN_MAJOR=1
# terraform-plugin-framework (terraform-provider-devcontainer-builder's own
# dependency) requires >= 1.25 as of v1.19.0 - bump this if that dependency
# ever requires more.
MIN_MINOR=25

log() { echo "[install.sh] $*" >&2; }

version_ok() {
  local ver="$1" major minor
  major="$(echo "$ver" | cut -d. -f1)"
  minor="$(echo "$ver" | cut -d. -f2)"
  if [ "$major" -gt "$MIN_MAJOR" ]; then return 0; fi
  if [ "$major" -eq "$MIN_MAJOR" ] && [ "$minor" -ge "$MIN_MINOR" ]; then return 0; fi
  return 1
}

if command -v go >/dev/null 2>&1; then
  current="$(go version | sed -E 's/go version go([0-9]+\.[0-9]+)(\.[0-9]+)?.*/\1/')"
  if version_ok "$current"; then
    log "go ${current} already installed (>= ${MIN_MAJOR}.${MIN_MINOR}), skipping."
    exit 0
  fi
  log "found go ${current}, but ${MIN_MAJOR}.${MIN_MINOR}+ is required; installing go ${GO_VERSION}."
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$arch" in
  x86_64) arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  *)
    log "unsupported architecture: ${arch}"
    exit 1
    ;;
esac

case "$os" in
  linux|darwin) ;;
  *)
    log "unsupported OS: ${os}"
    exit 1
    ;;
esac

if [ -w /usr/local ] || [ "$(id -u)" -eq 0 ]; then
  install_dir="/usr/local"
else
  install_dir="${HOME}/go-toolchain"
  mkdir -p "$install_dir"
  log "/usr/local is not writable; installing under ${install_dir} instead."
fi

tarball="go${GO_VERSION}.${os}-${arch}.tar.gz"
url="https://go.dev/dl/${tarball}"
tmp_tarball="$(mktemp -t go-install-XXXXXX.tar.gz)"
trap 'rm -f "$tmp_tarball"' EXIT

log "downloading ${url}"
curl -fsSL "$url" -o "$tmp_tarball"

log "removing any previous Go install at ${install_dir}/go"
rm -rf "${install_dir:?}/go"

log "extracting to ${install_dir}"
tar -C "$install_dir" -xzf "$tmp_tarball"

go_bin="${install_dir}/go/bin"
profile="${HOME}/.bashrc"
path_line="export PATH=\$PATH:${go_bin}"

if [ -f "$profile" ] && grep -qF "$go_bin" "$profile"; then
  log "PATH entry for ${go_bin} already present in ${profile}"
else
  echo "$path_line" >> "$profile"
  log "appended PATH entry to ${profile}"
fi

log "go ${GO_VERSION} installed at ${go_bin}"
log "restart your shell, or run: export PATH=\$PATH:${go_bin}"
