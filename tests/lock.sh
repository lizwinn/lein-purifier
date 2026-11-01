#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests `lein-purifier lock`: it relocks a copy of each fixture, and the
# result must be byte for byte the committed lockfile. It needs the
# network, and it runs from any directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/lein-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures/." "$work"

for fixture in "$work"/*/; do
  name=$(basename "$fixture")
  (cd "$fixture" && "$cli" lock --force)
  if ! cmp "$root/tests/fixtures/$name/lein-purifier.lock.json" "$fixture/lein-purifier.lock.json"; then
    diff <(jq -S . "$root/tests/fixtures/$name/lein-purifier.lock.json") <(jq -S . "$fixture/lein-purifier.lock.json") || true
    echo "lock.sh: the lock of $name differs from the committed one (above)" >&2
    exit 1
  fi
done
echo "lock.sh: passed"
