# SPDX-License-Identifier: MIT
#
# lein-purifier: locks the downloads of a Leiningen project, and runs
# Leiningen on the locked downloads.
#
# The package sets LEIN_PURIFIER_LIB (the Nix library, nix/lib) and
# LEIN_PURIFIER_FORMAT (the lock format version it reads).

lockName=lein-purifier.lock.json

usage() {
  cat <<'EOF'
Usage:
  lein-purifier lock [--force] [--no-uberjar]
      Runs the project's build with an empty local Maven repository and
      records every file Leiningen downloads in lein-purifier.lock.json.
      Without --force, an up-to-date lockfile is left as it is.
  lein-purifier lein ARGS...
      Runs Leiningen offline, with a local repository that holds exactly
      the locked files.
EOF
}

die() {
  echo "lein-purifier: $*" >&2
  exit 1
}

# The project root: the nearest directory, from here upwards, that holds
# project.clj.
projectRoot() {
  local dir
  dir=$(pwd)
  while [ "$dir" != / ]; do
    if [ -f "$dir/project.clj" ]; then
      echo "$dir"
      return
    fi
    dir=$(dirname "$dir")
  done
  die "no project.clj in $(pwd) or above it"
}

# The SHA-256 of project.clj followed by profiles.clj, in hex. The Nix
# builder hashes the same files in the same order.
definitionHash() {
  local root=$1
  {
    cat "$root/project.clj"
    if [ -f "$root/profiles.clj" ]; then cat "$root/profiles.clj"; fi
  } | sha256sum | cut -d' ' -f1
}

# Prints the Leiningen version and the Java version, separated by a space.
# Inside a project, `lein version` would load the project and resolve its
# plugins, so it runs from the root directory.
leinVersion() {
  # "Leiningen 2.12.0 on Java 21.0.12 OpenJDK 64-Bit Server VM"
  (cd / && lein version 2>/dev/null) | sed -n 's/^Leiningen \([^ ]*\) on Java \([^ ]*\) .*/\1 \2/p'
}

# Whether the lockfile was made from this project definition, by this
# lock format and with this Leiningen.
lockIsCurrent() {
  local root=$1 lockFile=$2 versions
  [ -f "$lockFile" ] || return 1
  versions=$(leinVersion)
  [ "$(jq -r .version "$lockFile")" = "$LEIN_PURIFIER_FORMAT" ] &&
    [ "$(jq -r .definitionHash "$lockFile")" = "$(definitionHash "$root")" ] &&
    [ "$(jq -r .leinVersion "$lockFile")" = "${versions%% *}" ]
}

# Prints "<id>\t<url>" for each repository of the project, from the POM
# Leiningen writes. Each URL ends in a slash.
repositories() {
  awk '
    /<repository>/ { inside = 1; id = ""; url = "" }
    inside && /<id>/ { id = $0; gsub(/.*<id>|<\/id>.*/, "", id) }
    inside && /<url>/ { url = $0; gsub(/.*<url>|<\/url>.*/, "", url) }
    /<\/repository>/ {
      if (url !~ /\/$/) url = url "/"
      print id "\t" url
      inside = 0
    }
  ' "$1"
}

cmdLock() {
  local force=0 uberjar=true
  while [ $# -gt 0 ]; do
    case $1 in
    --force) force=1 ;;
    --no-uberjar) uberjar=false ;;
    *) die "lock: unknown argument $1" ;;
    esac
    shift
  done

  local root lockFile
  root=$(projectRoot)
  lockFile="$root/$lockName"
  if [ $force = 0 ] && lockIsCurrent "$root" "$lockFile"; then
    echo "lein-purifier: $lockFile is up to date"
    return
  fi

  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/lein-purifier.XXXXXX")
  # shellcheck disable=SC2064 # work is fixed from here on
  trap "rm -rf '$work'" EXIT
  mkdir -p "$work/project" "$work/home/.lein" "$work/java-tmp"
  tar -C "$root" --exclude=./target --exclude=./.git -cf - . | tar -C "$work/project" -xf -

  # The lock run sees what a sandboxed build sees: an empty local
  # repository, no user profile, and none of the files in the home
  # directory. The JVM of Leiningen takes its local repository from
  # user.home, which HOME does not set. LEIN_JVM_OPTS from the caller stays
  # in effect, for proxy settings.
  local m2="$work/home/.m2/repository" log="$work/log" versions
  export HOME="$work/home"
  export LEIN_HOME="$work/home/.lein"
  export LEIN_JVM_OPTS="-Duser.home=$work/home -Djava.io.tmpdir=$work/java-tmp ${LEIN_JVM_OPTS:-}"
  export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$work/java-tmp ${JAVA_TOOL_OPTIONS:-}"
  versions=$(leinVersion)

  local tasks="jar,"
  if [ "$uberjar" = true ]; then tasks="$tasks uberjar,"; fi
  echo "lein-purifier: locking $root"
  if ! (
    cd "$work/project"
    lein with-profile +test deps
    # The task list splits into words, and `do` is the Leiningen task.
    # shellcheck disable=SC2086,SC1010
    lein do $tasks pom
  ) 2>&1 | tee "$log"; then
    die "the lock run failed; see the output above"
  fi

  # The outputs are the files Leiningen reports creating, relative to the
  # project root.
  local outputs
  outputs=$(sed -n "s|^Created $work/project/||p" "$log" | sort -u | jq -R . | jq -s .)

  local mainClass=null standalone
  standalone=$(jq -r '.[] | select(endswith("-standalone.jar"))' <<<"$outputs")
  if [ -n "$standalone" ]; then
    mainClass=$(unzip -p "$work/project/$standalone" META-INF/MANIFEST.MF |
      tr -d '\r' | sed -n 's/^Main-Class: *//p' | jq -R . | jq -s 'first // null')
  fi

  local pom="$work/project/pom.xml" group name version
  group=$(awk '/<groupId>/ { gsub(/.*<groupId>|<\/groupId>.*/, ""); print; exit }' "$pom")
  name=$(awk '/<artifactId>/ { gsub(/.*<artifactId>|<\/artifactId>.*/, ""); print; exit }' "$pom")
  version=$(awk '/<version>/ { gsub(/.*<version>|<\/version>.*/, ""); print; exit }' "$pom")

  declare -A repositoryUrl
  local id url
  while IFS=$'\t' read -r id url; do
    repositoryUrl[$id]=$url
  done < <(repositories "$pom")

  # Every file in the local repository is a download, except the records
  # Maven Resolver keeps. Each download is named in the
  # _remote.repositories file of its directory, with the id of the
  # repository it came from.
  local artifacts="$work/artifacts.jsonl" untracked=() unknown=() metadata=()
  : >"$artifacts"
  local rel dir base
  while IFS= read -r rel; do
    dir=$(dirname "$rel")
    base=$(basename "$rel")
    case $base in
    _remote.repositories | *.lastUpdated | resolver-status.properties | *.sha1 | *.md5 | *.sha256 | *.sha512)
      continue
      ;;
    maven-metadata*.xml)
      metadata+=("$rel")
      continue
      ;;
    esac
    id=$(awk -F'>' -v file="$base" '$1 == file { sub(/=$/, "", $2); print $2; exit }' \
      "$m2/$dir/_remote.repositories" 2>/dev/null || true)
    if [ -z "$id" ]; then
      untracked+=("$rel")
      continue
    fi
    url=${repositoryUrl[$id]:-}
    if [ -z "$url" ]; then
      unknown+=("$rel (repository $id)")
      continue
    fi
    jq -cn --arg path "$rel" --arg url "$url$rel" --arg hash "$(nix-hash --type sha256 --flat --sri "$m2/$rel")" \
      '{ path: $path, url: $url, hash: $hash }' >>"$artifacts"
  done < <(cd "$m2" && find . -type f -printf '%P\n' | LC_ALL=C sort)

  if [ ${#metadata[@]} -gt 0 ]; then
    printf '  %s\n' "${metadata[@]}" >&2
    die "the project resolves repository metadata (above), which a version range or a SNAPSHOT dependency needs; lein-purifier locks fixed versions only"
  fi
  if [ ${#untracked[@]} -gt 0 ]; then
    printf '  %s\n' "${untracked[@]}" >&2
    die "Maven Resolver recorded no repository for the files above"
  fi
  if [ ${#unknown[@]} -gt 0 ]; then
    printf '  %s\n' "${unknown[@]}" >&2
    die "the files above came from repositories that the POM of the project does not list, such as a mirror"
  fi

  jq -n \
    --argjson version "$LEIN_PURIFIER_FORMAT" \
    --arg leinVersion "${versions%% *}" \
    --arg javaVersion "${versions#* }" \
    --arg definitionHash "$(definitionHash "$root")" \
    --arg group "$group" --arg name "$name" --arg projectVersion "$version" \
    --argjson mainClass "$mainClass" \
    --argjson uberjar "$uberjar" \
    --argjson outputs "$outputs" \
    --slurpfile artifacts "$artifacts" \
    '{
      version: $version,
      leinVersion: $leinVersion,
      javaVersion: $javaVersion,
      definitionHash: $definitionHash,
      project: { group: $group, name: $name, version: $projectVersion, mainClass: $mainClass },
      uberjar: $uberjar,
      outputs: $outputs,
      artifacts: $artifacts
    }' >"$lockFile.tmp"
  mv "$lockFile.tmp" "$lockFile"
  echo "lein-purifier: wrote $lockFile ($(jq '.artifacts | length' "$lockFile") artifacts)"
}

cmdLein() {
  local root lockFile
  root=$(projectRoot)
  lockFile="$root/$lockName"
  [ -f "$lockFile" ] || die "$lockFile does not exist; run lein-purifier lock"
  if ! lockIsCurrent "$root" "$lockFile"; then
    echo "lein-purifier: $lockFile is out of date; Leiningen resolves the usual way until lein-purifier lock renews it" >&2
    exec lein "$@"
  fi

  # The locked files are fetched into the store, and one GC root on the
  # manifest keeps them there.
  local state="$root/target/lein-purifier" manifest
  mkdir -p "$state"
  nix-build "$LEIN_PURIFIER_LIB/realize.nix" --arg lockFile "$lockFile" -A fetches --no-out-link >/dev/null
  # Without --read-write-mode, the evaluation would name the manifest file
  # without writing it to the store.
  manifest=$(nix-instantiate --eval --read-write-mode --json "$LEIN_PURIFIER_LIB/realize.nix" --arg lockFile "$lockFile" -A manifest | jq -r .)
  nix-store --realise "$manifest" --add-root "$state/manifest" --indirect >/dev/null

  # The local repository is a writable tree of links into the store, made
  # anew when the manifest changes.
  local home="$state/home" m2="$state/home/.m2/repository"
  if [ "$(cat "$state/manifest.path" 2>/dev/null || true)" != "$manifest" ]; then
    rm -rf "$home"
    mkdir -p "$m2"
    local rel target
    while IFS=$'\t' read -r rel target; do
      mkdir -p "$m2/$(dirname "$rel")"
      ln -s "$target" "$m2/$rel"
    done <"$manifest"
    echo "$manifest" >"$state/manifest.path"
  fi

  # The JVM of Leiningen finds the local repository through user.home. The
  # Leiningen home directory of the user, with its profiles, stays in
  # effect.
  export LEIN_HOME="${LEIN_HOME:-$HOME/.lein}"
  export LEIN_JVM_OPTS="-Duser.home=$home ${LEIN_JVM_OPTS:-}"
  exec lein -o "$@"
}

case ${1:-} in
lock)
  shift
  cmdLock "$@"
  ;;
lein)
  shift
  cmdLein "$@"
  ;;
-h | --help | help)
  usage
  ;;
*)
  usage >&2
  exit 1
  ;;
esac
