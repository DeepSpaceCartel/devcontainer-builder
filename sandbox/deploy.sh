#!/usr/bin/env bash
set -euo pipefail
helm upgrade --install sandbox-nginx "$(dirname "$0")/nginx" -n sandbox --create-namespace --set replicaCount=2 -o yaml

