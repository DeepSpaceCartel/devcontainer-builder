#!/usr/bin/env bash
# Overrides node_modules/thomas with a symlink to a local sibling Thomas
# checkout (../../thomas), for developing against Thomas's own uncommitted
# changes without touching package.json's pinned github: reference. See
# docs/project/testing.md#developing-against-a-local-unreleased-thomas-checkout.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
service_dir="$(dirname "$script_dir")"
thomas_dir="$service_dir/../../thomas"

if [ ! -d "$thomas_dir" ]; then
  echo "error: no local Thomas checkout at $thomas_dir" >&2
  exit 1
fi

(cd "$thomas_dir" && npm install && npm link)
(cd "$service_dir" && npm link thomas)

echo "node_modules/thomas now symlinked to $thomas_dir"
echo "run 'npm install' in service/ (or 'npm unlink thomas') to revert to the pinned commit"
