#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-update check of the purifier contract: the update
# fixture's lockfile pins data.json 2.4.0, an older version than its range
# [2.4.0,2.5.0] allows. `lein-purifier lock` keeps it, `lein-purifier
# update` moves it to 2.5.0, and the lockfile then passes the stale check.
# It runs as a CI job, because it needs the network, and it runs from any
# directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/lein-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures/update" "$work/update"
cd "$work/update"

jar() {
  jq -r '.artifacts[] | select(.path | test("data.json-.*\\.jar$")) | .path' lein-purifier.lock.json
}

[ "$(jar)" = org/clojure/data.json/2.4.0/data.json-2.4.0.jar ] || {
  echo "update.sh: the fixture should pin 2.4.0, and it pins $(jar)" >&2
  exit 1
}

"$cli" lock --force
[ "$(jar)" = org/clojure/data.json/2.4.0/data.json-2.4.0.jar ] || {
  echo "update.sh: lock moved data.json to $(jar); it keeps what the lockfile recorded" >&2
  exit 1
}

"$cli" update org.clojure/data.json
[ "$(jar)" = org/clojure/data.json/2.5.0/data.json-2.5.0.jar ] || {
  echo "update.sh: update left data.json at $(jar)" >&2
  exit 1
}

# The stale check: the command finds the lockfile current, and the
# prefetch reads it through readLock and checkLock.
"$cli" lock | grep -q 'is up to date'
"$cli" prefetch
echo "update.sh: passed"
