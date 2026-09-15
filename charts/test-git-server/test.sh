#!/usr/bin/env bash
# Manual smoke/inspection script for the test-git-server chart: deploys it
# standalone (real Helm install, no Cucumber involved), then exercises
# every transport it serves - git://, http://, https://, ssh://, and
# SCP-style - with real `git clone`/`git fetch`, printing what actually
# landed on disk (ls/tree) so you can eyeball it directly.
#
# Usage:
#   ./test.sh            deploy + generate CA/SSH key + clone over all transports + inspect
#   ./test.sh cleanup    helm uninstall the release this script deployed (same namespace/release name)
#
# Leaves the fixture running after a normal run - it does NOT uninstall for
# you - so you can keep poking at it (kubectl exec, more clones, a push,
# etc). Run with `cleanup` when you're done.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART_PATH="$REPO_ROOT/charts/test-git-server"
NAMESPACE="${TEST_FIXTURES_NAMESPACE:-$(basename "$REPO_ROOT")-${CODER_WORKSPACE_OWNER_NAME:-${USER:-local}}}"
RELEASE="test-git-server"
GIT_FIXTURE_HOST="${RELEASE}-test-git-server.${NAMESPACE}.svc.cluster.local"

log() { printf '\n=== %s ===\n' "$*"; }

if [[ "${1:-}" == "cleanup" ]]; then
  log "Uninstalling $RELEASE from namespace $NAMESPACE"
  helm uninstall "$RELEASE" -n "$NAMESPACE" || true
  exit 0
fi

WORKDIR="$(mktemp -d /tmp/test-git-server-inspect.XXXXXX)"
log "Work directory: $WORKDIR"

# --- namespace -------------------------------------------------------------
log "Ensuring namespace $NAMESPACE exists (privileged pod-security)"
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl create namespace "$NAMESPACE"
  kubectl label namespace "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged
fi

# --- real self-signed CA + leaf cert (SAN = the fixture's real Service DNS name) ---
log "Generating self-signed CA + leaf cert for $GIT_FIXTURE_HOST"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORKDIR/ca-key.pem" -out "$WORKDIR/ca-cert.pem" \
  -days 2 -subj "/CN=devcontainer-builder-test-ca" 2>/dev/null

openssl req -newkey rsa:2048 -nodes \
  -keyout "$WORKDIR/server-key.pem" -out "$WORKDIR/server-csr.pem" \
  -subj "/CN=devcontainer-builder-test-git-server" 2>/dev/null

# CN has a hard 64-char limit and the real hostname exceeds it - SAN (no
# such limit) is what TLS clients actually validate against.
echo "subjectAltName=DNS:${GIT_FIXTURE_HOST}" > "$WORKDIR/san.conf"
openssl x509 -req -in "$WORKDIR/server-csr.pem" \
  -CA "$WORKDIR/ca-cert.pem" -CAkey "$WORKDIR/ca-key.pem" -CAcreateserial \
  -out "$WORKDIR/server-cert.pem" -days 2 -extfile "$WORKDIR/san.conf" 2>/dev/null

# --- real SSH keypair, authorized on the fixture ---------------------------
log "Generating SSH keypair (this will be the fixture's one authorized key)"
ssh-keygen -t ed25519 -N "" -f "$WORKDIR/id_ed25519" -C devcontainer-builder-test -q

# --- deploy ------------------------------------------------------------------
# Command substitution (not --set-file) deliberately, to strip the trailing
# newline ssh-keygen/openssl leave on these files - sshAuthorizedKey is
# substituted inline on a single script line (not `nindent`-wrapped like
# tlsCert/tlsKey below), so a leftover trailing newline there splits that
# line in two and de-indents the second half, which breaks the surrounding
# YAML block scalar ("found unexpected end of stream").
log "helm upgrade --install $RELEASE (namespace $NAMESPACE)"
helm upgrade --install "$RELEASE" "$CHART_PATH" -n "$NAMESPACE" \
  --set-string "sshAuthorizedKey=$(cat "$WORKDIR/id_ed25519.pub")" \
  --set-string "tlsCert=$(cat "$WORKDIR/server-cert.pem")" \
  --set-string "tlsKey=$(cat "$WORKDIR/server-key.pem")" \
  --wait --timeout 180s

log "Pod status"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o wide

# helm --wait only confirms pod readiness, not Service/kube-proxy routing
# propagation - poll actual TCP reachability before trusting the DNS name.
log "Waiting for all four ports to actually accept connections"
for port in 9418 8080 443 22; do
  for attempt in $(seq 1 15); do
    if (exec 3<>"/dev/tcp/${GIT_FIXTURE_HOST}/${port}") 2>/dev/null; then
      exec 3>&- 3<&-
      echo "port $port: reachable"
      break
    fi
    if [[ $attempt -eq 15 ]]; then
      echo "port $port: still unreachable after 15 attempts" >&2
    fi
    sleep 2
  done
done

# --- what's actually on disk inside the fixture -----------------------------
POD="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[0].metadata.name}')"
log "Repo layout inside the fixture pod ($POD, /repos)"
kubectl exec -n "$NAMESPACE" "$POD" -c git-daemon -- sh -c '
  if command -v tree >/dev/null 2>&1; then tree -a /repos; else find /repos | sort; fi
'

inspect() {
  local label="$1" dir="$2"
  log "ls -la: $label"
  ls -la "$dir"
  log "tree: $label"
  if command -v tree >/dev/null 2>&1; then
    tree -a "$dir"
  else
    find "$dir" | sort
  fi
}

# --- git:// ------------------------------------------------------------------
log "git clone git://${GIT_FIXTURE_HOST}:9418/..."
git clone "git://${GIT_FIXTURE_HOST}:9418/example/example-devcontainer.git" "$WORKDIR/clone-git"
inspect "git://" "$WORKDIR/clone-git"
git -C "$WORKDIR/clone-git" fetch -v origin

# --- http:// -----------------------------------------------------------------
log "git clone http://${GIT_FIXTURE_HOST}:8080/..."
git clone "http://${GIT_FIXTURE_HOST}:8080/example/example-devcontainer.git" "$WORKDIR/clone-http"
inspect "http://" "$WORKDIR/clone-http"
git -C "$WORKDIR/clone-http" fetch -v origin

# --- https:// (real TLS, trusting the CA generated above) --------------------
log "git clone https://${GIT_FIXTURE_HOST}/... (GIT_SSL_CAINFO=generated CA)"
GIT_SSL_CAINFO="$WORKDIR/ca-cert.pem" git clone "https://${GIT_FIXTURE_HOST}/example/example-devcontainer.git" "$WORKDIR/clone-https"
inspect "https://" "$WORKDIR/clone-https"
GIT_SSL_CAINFO="$WORKDIR/ca-cert.pem" git -C "$WORKDIR/clone-https" fetch -v origin

# --- ssh:// and SCP-style, using the authorized key ---------------------------
SSH_CMD="ssh -i $WORKDIR/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

log "git clone ssh://git@${GIT_FIXTURE_HOST}/..."
GIT_SSH_COMMAND="$SSH_CMD" git clone "ssh://git@${GIT_FIXTURE_HOST}/example/example-devcontainer.git" "$WORKDIR/clone-ssh"
inspect "ssh://" "$WORKDIR/clone-ssh"
GIT_SSH_COMMAND="$SSH_CMD" git -C "$WORKDIR/clone-ssh" fetch -v origin

log "git clone git@${GIT_FIXTURE_HOST}:... (SCP-style)"
GIT_SSH_COMMAND="$SSH_CMD" git clone "git@${GIT_FIXTURE_HOST}:example/example-devcontainer.git" "$WORKDIR/clone-scp"
inspect "scp-style" "$WORKDIR/clone-scp"

log "Done"
cat <<EOF
Fixture is still running - it was NOT torn down.

  namespace: $NAMESPACE
  release:   $RELEASE
  host:      $GIT_FIXTURE_HOST
  workdir:   $WORKDIR   (cloned repos + generated CA/SSH key live here)

Poke around further, e.g.:
  kubectl logs -n $NAMESPACE $POD -c git-http
  kubectl exec  -n $NAMESPACE $POD -c git-ssh -- sh
  GIT_SSH_COMMAND="$SSH_CMD" git clone git@${GIT_FIXTURE_HOST}:solo-repo.git

When you're done:
  $0 cleanup
EOF
