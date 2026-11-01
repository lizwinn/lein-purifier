#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-rebuild check of the purifier contract: each fixture
# package, built once, is built again with `nix build --rebuild`, which
# fails when the second build gives different bytes. It runs as a CI job,
# because a check in the sandbox cannot run Nix, and it runs from any
# directory. ROUNDS (3 by default) rebuilds each package that many times,
# since nondeterminism shows only on some builds.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
system=$(nix eval --raw --impure --expr builtins.currentSystem)
packages=(hello sources multi-lib multi-app mono-core mono-tool)

for package in "${packages[@]}"; do
  nix build --no-link "$root#checks.$system.$package"
  for round in $(seq "${ROUNDS:-3}"); do
    echo "rebuild.sh: rebuilding $package, round $round"
    nix build --no-link --rebuild "$root#checks.$system.$package"
  done
done
echo "rebuild.sh: passed"
