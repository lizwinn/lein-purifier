#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Unit tests of the lock run's parsing (pkgs/lein-purifier/entries.sh): it
# turns made-up transfer logs and local repositories into lockfile entries
# and compares them with what each case expects. It needs no network, and
# the flake check `unit` runs it in the sandbox:
#
#   tests/unit.sh pkgs/lein-purifier/entries.sh
set -euo pipefail

# shellcheck source=pkgs/lein-purifier/entries.sh
source "$1"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# A fresh case: an empty local repository, transfer log and project.
newCase() {
  case=$work/$1
  m2=$case/m2
  project=$case/project
  mkdir -p "$m2" "$project"
  : >"$case/transfers"
  : >"$case/artifacts"
  : >"$case/repositories"
}

# Puts a file into the local repository and logs its download.
download() {
  local repository=$1 rel=$2 content=$3
  mkdir -p "$(dirname "$m2/$rel")"
  printf '%s' "$content" >"$m2/$rel"
  printf '%s\t%s\t%s\t%s\n' "$repository" "$rel" "$m2/$rel" "$project" >>"$case/transfers"
}

run() {
  lockEntries "$m2" "$case/transfers" "$project" "$case/artifacts" "$case/repositories" "$@"
}

entry() {
  jq -c --arg path "$1" 'select(.path == $path)' "$case/artifacts"
}

# A download becomes a file entry with the URL it came from and the SRI
# SHA-256 of the file. A repository other than Maven Central has no
# fallback URLs.
newCase plain
download https://repo.clojars.org/ org/example/a/1.0/a-1.0.jar hello
run || fail "plain: lockEntries failed"
[ "$(entry org/example/a/1.0/a-1.0.jar)" = \
  '{"path":"org/example/a/1.0/a-1.0.jar","url":"https://repo.clojars.org/org/example/a/1.0/a-1.0.jar","mirrors":[],"hash":"sha256-LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ="}' ] ||
  fail "plain: $(entry org/example/a/1.0/a-1.0.jar)"

# A file from Maven Central, or from its mirror, has its URL at Maven
# Central and its URL at the mirror as the fallback.
newCase central
download https://repo1.maven.org/maven2/ org/example/a/1.0/a-1.0.jar hello
download https://maven-central.storage-download.googleapis.com/maven2 org/example/b/1.0/b-1.0.jar hello
run || fail "central: lockEntries failed"
for name in a b; do
  [ "$(entry "org/example/$name/1.0/$name-1.0.jar" | jq -c '{url, mirrors}')" = \
    "{\"url\":\"https://repo1.maven.org/maven2/org/example/$name/1.0/$name-1.0.jar\",\"mirrors\":[\"https://maven-central.storage-download.googleapis.com/maven2/org/example/$name/1.0/$name-1.0.jar\"]}" ] ||
    fail "central: $(entry "org/example/$name/1.0/$name-1.0.jar")"
done

# A repository URL without a trailing slash joins the resource name with
# one slash, and any other mirror is recorded with its own URL.
newCase mirror
download https://mirror.example/maven2 org/example/a/1.0/a-1.0.pom pom
run || fail "mirror: lockEntries failed"
[ "$(entry org/example/a/1.0/a-1.0.pom | jq -r .url)" = https://mirror.example/maven2/org/example/a/1.0/a-1.0.pom ] ||
  fail "mirror: $(entry org/example/a/1.0/a-1.0.pom)"

# Checksum files are not entries, and a file logged twice is one entry.
newCase duplicates
download https://repo1.maven.org/maven2/ org/example/a/1.0/a-1.0.jar hello
download https://repo1.maven.org/maven2/ org/example/a/1.0/a-1.0.jar.sha1 aaaa
download https://repo.clojars.org/ org/example/a/1.0/a-1.0.jar hello
run || fail "duplicates: lockEntries failed"
[ "$(wc -l <"$case/artifacts")" = 1 ] || fail "duplicates: $(cat "$case/artifacts")"
[ "$(entry org/example/a/1.0/a-1.0.jar | jq -r .url)" = https://repo1.maven.org/maven2/org/example/a/1.0/a-1.0.jar ] ||
  fail "duplicates: the first download is not the one locked"

# A relative file: repository inside the project is a project repository,
# and its files are not entries.
newCase inside
mkdir -p "$project/repository"
download file:repository/ example/g/1.0/g-1.0.jar jar
run || fail "inside: lockEntries failed"
[ ! -s "$case/artifacts" ] || fail "inside: $(cat "$case/artifacts")"
[ "$(cat "$case/repositories")" = repository ] || fail "inside: $(cat "$case/repositories")"

# A file: repository outside the project cannot be locked.
newCase outside
download file:///elsewhere/repository/ example/g/1.0/g-1.0.jar jar
if run 2>"$case/errors"; then fail "outside: lockEntries accepted it"; fi
grep -q 'outside the project' "$case/errors" || fail "outside: $(cat "$case/errors")"

# Artifact-level metadata is written anew with the versions the lock run
# downloaded, in version order, whatever the repository listed.
newCase range
download https://repo1.maven.org/maven2/ org/example/r/2.10.0/r-2.10.0.pom p
download https://repo1.maven.org/maven2/ org/example/r/2.9.0/r-2.9.0.pom p
download https://repo1.maven.org/maven2/ org/example/r/maven-metadata-central.xml \
  '<metadata><versioning><versions><version>2.9.0</version><version>2.10.0</version><version>2.11.0</version></versions></versioning></metadata>'
run || fail "range: lockEntries failed"
metadata=$(entry org/example/r/maven-metadata-central.xml | jq -r .contents)
grep -qx '    <release>2.10.0</release>' <<<"$metadata" || fail "range: $metadata"
[ "$(grep -o '<version>[^<]*' <<<"$metadata" | tr '\n' ' ')" = '<version>2.9.0 <version>2.10.0 ' ] ||
  fail "range: $metadata"
grep -q '<groupId>org.example</groupId>' <<<"$metadata" || fail "range: $metadata"

# SNAPSHOT metadata is locked as it is, the timestamped files are
# downloads, and the -SNAPSHOT copies Maven Resolver makes are not.
newCase snapshot
download https://repo.clojars.org/ s/s/1.0-SNAPSHOT/s-1.0-20140131.171516-1.jar jar
download https://repo.clojars.org/ s/s/1.0-SNAPSHOT/maven-metadata-clojars.xml '<metadata>snapshot</metadata>'
printf jar >"$m2/s/s/1.0-SNAPSHOT/s-1.0-SNAPSHOT.jar"
printf 'record' >"$m2/s/s/1.0-SNAPSHOT/_remote.repositories"
run || fail "snapshot: lockEntries failed"
[ "$(entry s/s/1.0-SNAPSHOT/maven-metadata-clojars.xml | jq -r .contents)" = '<metadata>snapshot</metadata>' ] ||
  fail "snapshot: $(entry s/s/1.0-SNAPSHOT/maven-metadata-clojars.xml)"
[ -z "$(entry s/s/1.0-SNAPSHOT/s-1.0-SNAPSHOT.jar)" ] || fail "snapshot: the -SNAPSHOT copy is an entry"

# A file in the local repository that no download explains stops the lock
# run, unless it belongs to a project the lock run installed.
newCase unexplained
download https://repo1.maven.org/maven2/ org/example/a/1.0/a-1.0.jar hello
mkdir -p "$m2/org/example/stray/1.0" "$m2/example/lib/1.0"
printf x >"$m2/org/example/stray/1.0/stray-1.0.jar"
printf x >"$m2/example/lib/1.0/lib-1.0.jar"
printf x >"$m2/example/lib/maven-metadata-local.xml"
if run example/lib/ 2>"$case/errors"; then fail "unexplained: lockEntries accepted a stray file"; fi
grep -qx '  org/example/stray/1.0/stray-1.0.jar' "$case/errors" || fail "unexplained: $(cat "$case/errors")"
if grep -q 'example/lib' "$case/errors"; then fail "unexplained: an installed project is listed"; fi

# The metadata of a previous lockfile is seeded into the local repository
# and logged, except that of each package named for `update`. A seeded
# file becomes an entry as a downloaded one does.
newCase seeded
cat >"$case/previous.json" <<'EOF'
{"artifacts":[{"path":"org/example/r/maven-metadata-central.xml","contents":"<metadata>r</metadata>\n"},
              {"path":"s/s/1.0-SNAPSHOT/maven-metadata-clojars.xml","contents":"<metadata>s</metadata>\n"},
              {"path":"org/example/r/2.9.0/r-2.9.0.pom","url":"https://r/r.pom","mirrors":[],"hash":"sha256-x"}]}
EOF
seedMetadata "$case/previous.json" "$m2" "$case/transfers" s/s
[ "$(cat "$m2/org/example/r/maven-metadata-central.xml")" = '<metadata>r</metadata>' ] || fail "seeded: the metadata of r was not seeded"
[ ! -e "$m2/s/s/1.0-SNAPSHOT/maven-metadata-clojars.xml" ] || fail "seeded: the metadata of s, named for update, was seeded"
grep -q '^maven-metadata-central.xml.lastUpdated=[0-9]\{13\}$' "$m2/org/example/r/resolver-status.properties" ||
  fail "seeded: no lastUpdated record for r: $(cat "$m2/org/example/r/resolver-status.properties" 2>&1)"
[ "$(cut -f1,2 "$case/transfers")" = "seeded	org/example/r/maven-metadata-central.xml" ] || fail "seeded: $(cat "$case/transfers")"
download https://repo1.maven.org/maven2/ org/example/r/2.9.0/r-2.9.0.pom p
run || fail "seeded: lockEntries failed"
grep -q '<version>2.9.0</version>' <<<"$(entry org/example/r/maven-metadata-central.xml | jq -r .contents)" ||
  fail "seeded: $(entry org/example/r/maven-metadata-central.xml)"

# The integrity changes with any field of the lockfile, a content entry
# included, and not otherwise.
newCase integrity
cat >"$case/lock.json" <<'EOF'
{"version":2,"leinVersion":"2.12.0","javaVersion":"21","definitionHash":"d","uberjar":true,
 "projects":[{"dir":".","group":"g","name":"n","version":"1","mainClass":null,"outputs":["target/n-1.jar"],"dependsOn":[]}],
 "projectRepositories":[],
 "artifacts":[{"path":"a/a.jar","url":"https://r/a/a.jar","mirrors":[],"hash":"sha256-x"},
              {"path":"a/maven-metadata-central.xml","contents":"<metadata/>\n"}]}
EOF
base=$(lockIntegrity "$case/lock.json")
[ "$(lockIntegrity "$case/lock.json")" = "$base" ] || fail "integrity: not stable"
jq '.artifacts[0].hash = "sha256-y"' "$case/lock.json" >"$case/changed.json"
[ "$(lockIntegrity "$case/changed.json")" != "$base" ] || fail "integrity: a hash edit kept it"
jq '.artifacts[1].contents = "<metadata></metadata>\n"' "$case/lock.json" >"$case/changed.json"
[ "$(lockIntegrity "$case/changed.json")" != "$base" ] || fail "integrity: a content edit kept it"
jq 'del(.artifacts[0])' "$case/lock.json" >"$case/changed.json"
[ "$(lockIntegrity "$case/changed.json")" != "$base" ] || fail "integrity: a removed entry kept it"

if [ $failures -gt 0 ]; then
  echo "unit.sh: $failures failed" >&2
  exit 1
fi
echo "unit.sh: passed"
