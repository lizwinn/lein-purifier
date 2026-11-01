#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests `lein-purifier deploy` on a copy of the hello fixture: it deploys
# to a repository in a temporary directory, and the deployed jar must be
# the one Nix built. It needs the Nix daemon, and it runs from any
# directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/lein-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures/hello" "$work/hello"

# The repository `test` is a directory. A Leiningen home of its own
# defines it, with signing off, since the test has no key to sign with.
mkdir -p "$work/lein-home"
cat >"$work/lein-home/profiles.clj" <<EOF
{:user {:deploy-repositories [["test" {:url "file://$work/deployed" :sign-releases false}]]}}
EOF

(cd "$work/hello" && LEIN_HOME="$work/lein-home" "$cli" deploy test)

deployed="$work/deployed/example/hello/1.0.0"
package="$work/hello/target/lein-purifier/package-hello/share/java"
cmp "$deployed/hello-1.0.0.jar" "$package/hello-1.0.0.jar"
cmp "$deployed/hello-1.0.0.pom" "$package/hello-1.0.0.pom"
echo "deploy.sh: passed"
