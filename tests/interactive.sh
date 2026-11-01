#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests `lein-purifier lein`, which runs Leiningen offline on the locked
# downloads, on copies of the fixtures. It needs the Nix daemon, which
# fetches the locked files, and it runs from any directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/lein-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures/." "$work"

expect() {
  local expected=$1 output=$2
  if ! grep -qxF "$expected" <<<"$output"; then
    echo "interactive.sh: expected $expected, got:" >&2
    echo "$output" >&2
    exit 1
  fi
}

# A single project runs its main function.
expect '{"hello":"you"}' "$(cd "$work/hello" && "$cli" lein run you)"

# A version range, a SNAPSHOT, a mirror and a repository inside the
# project resolve offline.
expect '{"greeting":"Hello from the in-project repository, sources","snapshot":true}' \
  "$(cd "$work/sources" && "$cli" lein run)"

# In a project with subprojects, the application resolves the library
# once `lein install` has put it into the local repository, as with
# Leiningen itself.
(cd "$work/multi-sub/lib" && "$cli" lein install)
expect 'MULTI-SUB!' "$(cd "$work/multi-sub/app" && "$cli" lein run)"

echo "interactive.sh: passed"
