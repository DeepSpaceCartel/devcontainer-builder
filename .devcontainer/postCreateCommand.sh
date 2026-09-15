#!/usr/bin/env bash
# Installs the CLI tools the base devcontainer image doesn't already provide:
# Starship, Helm, Terraform, GitHub CLI, kubectl, k9s, Docker CLI + buildx
# plugin + devcontainers CLI, Claude Code CLI, and the `helm tui` plugin. No
# Dev Container
# Features are used here (they aren't usable yet in this repo's Coder/K8s
# setup) - everything goes through plain shell so this script also works
# when invoked manually via install.sh at the repo root.
#
# Versions are intentionally not pinned: nothing else in this repo pins
# Helm/Terraform/kubectl either (CI's setup-helm/setup-terraform actions run
# unpinned, see .github/workflows/ci.yaml), so these installers just fetch
# whatever's currently latest/stable, matching that convention.
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

arch="$(dpkg --print-architecture)"

# --- Node 20 + npm + git + sandbox2/ deps ---------------------------------
# devcontainer.json's `image` is supposed to already provide these
# (mcr.microsoft.com/devcontainers/typescript-node:1-20-bookworm) - this
# call is a fast no-op there. It only does real work when the workspace
# actually booted from something else (e.g. a Coder Workspace Template not
# overriding its image), which otherwise breaks every npm-based step below.
bash "$(dirname "${BASH_SOURCE[0]}")/typescript-node.sh"

# --- Timezone -------------------------------------------------------------
tz="America/Los_Angeles"
if [ "$(cat /etc/timezone 2>/dev/null)" != "$tz" ]; then
  echo "Setting timezone to ${tz}..."
  $SUDO ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
  echo "$tz" | $SUDO tee /etc/timezone > /dev/null
  if command -v dpkg-reconfigure >/dev/null 2>&1; then
    $SUDO dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true
  fi
fi

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ -f "$rc" ] && ! grep -qF 'export TZ=' "$rc"; then
    echo "export TZ=\"${tz}\"" >> "$rc"
  fi
done

if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
  $SUDO apt-get update
  $SUDO apt-get install -y --no-install-recommends ca-certificates curl gnupg
fi

# --- MkDocs Material -----------------------------------------------------
# Install into an isolated pipx environment so Debian's system Python stays
# untouched while the mkdocs command remains available to the workspace user.
if ! command -v mkdocs >/dev/null 2>&1; then
  echo "Installing MkDocs Material..."
  if ! command -v pipx >/dev/null 2>&1; then
    $SUDO apt-get update
    $SUDO apt-get install -y --no-install-recommends pipx python3-venv
  fi
  export PATH="$HOME/.local/bin:$PATH"
  pipx install --include-deps mkdocs-material
fi

export PATH="$HOME/.local/bin:$PATH"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ -f "$rc" ] && ! grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$rc"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
  fi
done

# --- Starship prompt ------------------------------------------------------
if ! command -v starship >/dev/null 2>&1; then
  echo "Installing Starship prompt..."
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y
fi

if [ -f "$HOME/.bashrc" ] && ! grep -qF 'starship init bash' "$HOME/.bashrc"; then
  echo 'eval "$(starship init bash)"' >> "$HOME/.bashrc"
fi
if [ -f "$HOME/.zshrc" ] && ! grep -qF 'starship init zsh' "$HOME/.zshrc"; then
  echo 'eval "$(starship init zsh)"' >> "$HOME/.zshrc"
fi

# --- Helm ---------------------------------------------------------------
if ! command -v helm >/dev/null 2>&1; then
  echo "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | $SUDO bash
fi

# --- Terraform (HashiCorp apt repo, same pattern as the Docker apt repo in
#     service/Dockerfile: import key -> add source -> apt-get install) ----
if ! command -v terraform >/dev/null 2>&1; then
  echo "Installing Terraform..."
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://apt.releases.hashicorp.com/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg
  $SUDO chmod a+r /etc/apt/keyrings/hashicorp.gpg
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
    | $SUDO tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
  $SUDO apt-get update
  $SUDO apt-get install -y --no-install-recommends terraform
fi

# --- Docker CLI + buildx plugin + devcontainers CLI (same apt repo and
#     `npm install -g @devcontainers/cli` as service/Dockerfile - this is
#     for developing/testing builds against the remote BuildKit endpoint
#     from the workspace, not for running containers locally: no dockerd
#     here either) --------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing docker-ce-cli + docker-buildx-plugin..."
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
  $SUDO apt-get update
  $SUDO apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin
fi

if ! command -v devcontainer >/dev/null 2>&1; then
  echo "Installing @devcontainers/cli..."
  npm install -g @devcontainers/cli
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "Installing Claude Code CLI..."
  npm install -g @anthropic-ai/claude-code
fi

# --- GitHub CLI (apt repo, same key -> source -> apt-get install pattern as
#     Docker/Terraform above) ----------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  echo "Installing GitHub CLI..."
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | $SUDO tee /etc/apt/keyrings/githubcli.gpg > /dev/null
  $SUDO chmod a+r /etc/apt/keyrings/githubcli.gpg
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
    | $SUDO tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  $SUDO apt-get update
  $SUDO apt-get install -y --no-install-recommends gh
fi

# --- kubectl --------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  echo "Installing kubectl..."
  kubectl_version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  tmp_kubectl="$(mktemp)"
  curl -fsSL -o "$tmp_kubectl" "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${arch}/kubectl"
  $SUDO install -m 0755 "$tmp_kubectl" /usr/local/bin/kubectl
  rm -f "$tmp_kubectl"
fi

# --- krew (kubectl plugin manager) + kubectl-tree plugin -----------------
# Install steps from https://krew.sigs.k8s.io/docs/user-guide/setup/install/
krew_root="${KREW_ROOT:-$HOME/.krew}"
if [ ! -x "$krew_root/bin/kubectl-krew" ]; then
  echo "Installing krew..."
  krew_tmp_dir="$(mktemp -d)"
  (
    cd "$krew_tmp_dir"
    krew_os="$(uname | tr '[:upper:]' '[:lower:]')"
    krew_arch="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')"
    krew="krew-${krew_os}_${krew_arch}"
    curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${krew}.tar.gz"
    tar -zxf "${krew}.tar.gz"
    "./${krew}" install krew
  )
  rm -rf "$krew_tmp_dir"
fi

export PATH="${krew_root}/bin:${PATH}"

# Persist krew's bin dir on PATH for future interactive shells.
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ -f "$rc" ] && ! grep -qF '.krew/bin' "$rc"; then
    echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> "$rc"
  fi
done

if ! kubectl krew list 2>/dev/null | grep -qw tree; then
  echo "Installing kubectl-tree plugin via krew..."
  kubectl krew install tree
fi

# --- kubeconfig from in-cluster ServiceAccount ---------------------------
# This workspace has no mounted kubeconfig, so kubectl silently falls back
# to in-cluster auth (via the auto-mounted ServiceAccount) for one-off
# commands - that works, but leaves no named context. Tools like k9s key
# their per-context state (namespace history/favorites) off a context name,
# so without one k9s logs "no active context available" on a loop and
# namespace switching (e.g. `w`, the 1-9 namespace bar) falls back to
# `default` instead of tracking the real namespace. Build a real kubeconfig
# from the ServiceAccount so kubectl/k9s have an explicit context.
sa_dir=/var/run/secrets/kubernetes.io/serviceaccount
if [ -n "${KUBERNETES_SERVICE_HOST:-}" ] && [ -f "$sa_dir/token" ] && [ -f "$sa_dir/ca.crt" ] \
  && ! kubectl config current-context >/dev/null 2>&1; then
  echo "Generating kubeconfig from in-cluster ServiceAccount..."
  ns="$(cat "$sa_dir/namespace")"
  kubeconfig="$HOME/.kube/config"
  mkdir -p "$HOME/.kube"
  kubectl config set-cluster in-cluster \
    --server="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}" \
    --certificate-authority="$sa_dir/ca.crt" \
    --embed-certs=true \
    --kubeconfig="$kubeconfig"
  kubectl config set-credentials in-cluster-sa \
    --token="$(cat "$sa_dir/token")" \
    --kubeconfig="$kubeconfig"
  kubectl config set-context "$ns" \
    --cluster=in-cluster \
    --user=in-cluster-sa \
    --namespace="$ns" \
    --kubeconfig="$kubeconfig"
  kubectl config use-context "$ns" --kubeconfig="$kubeconfig"
  chmod 600 "$kubeconfig"
fi

# --- k9s --------------------------------------------------------------
if ! command -v k9s >/dev/null 2>&1; then
  echo "Installing k9s..."
  tmp_dir="$(mktemp -d)"
  asset_url="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]*[Ll]inux_'"${arch}"'\.tar\.gz"' \
    | head -n1 | cut -d'"' -f4)"
  curl -fsSL -o "$tmp_dir/k9s.tar.gz" "$asset_url"
  tar -xzf "$tmp_dir/k9s.tar.gz" -C "$tmp_dir" k9s
  $SUDO install -m 0755 "$tmp_dir/k9s" /usr/local/bin/k9s
  rm -rf "$tmp_dir"
fi

# --- helm tui plugin (https://github.com/pidanou/helm-tui) ---------------
# Ships a prebuilt binary via its own install-binary.sh hook - no Go
# toolchain needed. Run as `helm tui` once installed.
if command -v helm >/dev/null 2>&1 && ! helm plugin list 2>/dev/null | grep -qw tui; then
  echo "Installing helm tui plugin..."
  helm plugin install https://github.com/pidanou/helm-tui
fi

echo "postCreateCommand.sh done: node, timezone, starship, helm, terraform, gh, kubectl, krew (kubectl-tree), k9s, docker cli, devcontainers cli, claude code cli, MkDocs Material, helm tui plugin ready."
