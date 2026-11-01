#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests `lein-purifier lock`: it relocks a copy of each fixture and
# compares the result with the committed lockfile. Repository metadata
# changes over time at its URL, so the content of metadata entries is left
# out of the comparison, and their paths are compared. It needs the
# network, and it runs from any directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/lein-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures/." "$work"

comparable='.artifacts |= map(if has("contents") then { path } else . end)'
for fixture in "$work"/*/; do
  name=$(basename "$fixture")
  (cd "$fixture" && "$cli" lock --force)
  if ! diff <(jq -S "$comparable" "$root/tests/fixtures/$name/lein-purifier.lock.json") \
    <(jq -S "$comparable" "$fixture/lein-purifier.lock.json"); then
    echo "lock.sh: the lock of $name differs from the committed one (above)" >&2
    exit 1
  fi
done
echo "lock.sh: passed"
