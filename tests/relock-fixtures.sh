#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks every test fixture with the lein-purifier command of this
# checkout. It needs the network, and it runs from any directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")

for fixture in "$root"/tests/fixtures/*/; do
  echo "== $fixture"
  (cd "$fixture" && "$cli/bin/lein-purifier" lock --force)
done
