# SPDX-License-Identifier: MIT
#
# lein-purifier: locks the downloads of a Leiningen project, runs
# Leiningen on the locked downloads, and deploys the jars Nix builds.
#
# The package sets LEIN_PURIFIER_LIB (the Nix library, nix/lib),
# LEIN_PURIFIER_FORMAT (the lock format version it reads),
# LEIN_PURIFIER_INIT (the init.clj of a lock run) and LEIN_PURIFIER_NIXPKGS
# (the nixpkgs that deploy builds the packages with).

lockName=lein-purifier.lock.json

# LEIN_PURIFIER_TRACE=1 prints each command of this script as it runs.
if [ -n "${LEIN_PURIFIER_TRACE:-}" ]; then set -x; fi

usage() {
  cat <<'EOF'
Usage:
  lein-purifier lock [--force] [--no-uberjar]
      Runs the build of the project, and of each subproject that lein-sub
      or lein-monolith names, with an empty local Maven repository, and
      records every file Leiningen downloads in lein-purifier.lock.json.
      Without --force, an up-to-date lockfile is left as it is.
  lein-purifier lein ARGS...
      Runs Leiningen offline in the current directory, with a local
      repository that holds exactly the locked files.
  lein-purifier deploy REPOSITORY [NAME...]
      Builds the packages of the lockfile with Nix and deploys their jar
      and POM with `lein deploy` to REPOSITORY, a repository name the
      project or the user profile defines, or a URL. Without NAME, every
      project of the lockfile is deployed, in build order.
EOF
}

die() {
  echo "lein-purifier: $*" >&2
  exit 1
}

# The project root: the nearest directory, from here upwards, that holds a
# lockfile, or else the nearest that holds project.clj.
projectRoot() {
  local dir
  for marker in "$lockName" project.clj; do
    dir=$(pwd)
    while [ "$dir" != / ]; do
      if [ -f "$dir/$marker" ]; then
        echo "$dir"
        return
      fi
      dir=$(dirname "$dir")
    done
  done
  die "no project.clj in $(pwd) or above it"
}

# The SHA-256, in hex, of project.clj and then profiles.clj of the root and
# of each project directory given, in that order, each directory once. The
# Nix builder hashes the same files in the same order.
definitionHash() {
  local root=$1 dir seen=" "
  shift
  {
    for dir in . "$@"; do
      case $seen in *" $dir "*) continue ;; esac
      seen="$seen$dir "
      cat "$root/$dir/project.clj"
      if [ -f "$root/$dir/profiles.clj" ]; then cat "$root/$dir/profiles.clj"; fi
    done
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
  local root=$1 lockFile=$2 versions dirs
  [ -f "$lockFile" ] || return 1
  [ "$(jq -r .version "$lockFile")" = "$LEIN_PURIFIER_FORMAT" ] || return 1
  versions=$(leinVersion)
  mapfile -t dirs < <(jq -r '.projects[].dir' "$lockFile")
  [ "$(jq -r .definitionHash "$lockFile")" = "$(definitionHash "$root" "${dirs[@]}")" ] &&
    [ "$(jq -r .leinVersion "$lockFile")" = "${versions%% *}" ]
}

# The Maven repository path of a group, such as org/clojure for
# org.clojure.
groupPath() {
  echo "${1//.//}"
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
  # Build outputs, version control and Leiningen checkouts (links to other
  # projects on this machine) stay out of the copy, as they stay out of a
  # sandboxed build.
  tar -C "$root" --exclude=target --exclude=.git --exclude=checkouts -cf - . | tar -C "$work/project" -xf -
  cp "$LEIN_PURIFIER_INIT" "$work/home/.lein/init.clj"

  # The lock run sees what a sandboxed build sees: an empty local
  # repository, no user profile, and none of the files in the home
  # directory. The JVM of Leiningen takes its local repository from
  # user.home, which HOME does not set. LEIN_JVM_OPTS from the caller stays
  # in effect, for proxy settings. init.clj logs every download to the
  # transfer log.
  local project="$work/project" m2="$work/home/.m2/repository" transfers="$work/transfers" versions
  export HOME="$work/home"
  export LEIN_HOME="$work/home/.lein"
  export LEIN_JVM_OPTS="-Duser.home=$work/home -Djava.io.tmpdir=$work/java-tmp ${LEIN_JVM_OPTS:-}"
  export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$work/java-tmp ${JAVA_TOOL_OPTIONS:-}"
  export LEIN_PURIFIER_TRANSFER_LOG="$transfers"
  : >"$transfers"
  versions=$(leinVersion)
  echo "lein-purifier: locking $root"

  # The root names its subprojects, if it has any. Its plugins, such as
  # lein-sub or lein-monolith, are locked too.
  local info globs=()
  info=$(cd "$project" && lein purifier-info) || die "Leiningen could not read $root/project.clj"
  mapfile -t globs < <(awk -F'\t' '$1 == "subproject" { print $2 }' <<<"$info")

  local dirs=()
  if [ ${#globs[@]} -eq 0 ]; then
    dirs=(.)
  else
    local glob dir
    mapfile -t dirs < <(
      cd "$project" &&
        shopt -s nullglob &&
        for glob in "${globs[@]}"; do
          # The pattern is expanded as a glob, relative to the root.
          # shellcheck disable=SC2086
          printf '%s\n' $glob
        done | while IFS= read -r dir; do
          dir=${dir%/}
          dir=${dir#./}
          if [ -f "$dir/project.clj" ]; then echo "$dir"; fi
        done | awk '!seen[$0]++'
    )
    [ ${#dirs[@]} -gt 0 ] || die "the subprojects ${globs[*]} of $root match no directory with a project.clj"
  fi

  # What each project is, and which of the other projects it depends on.
  declare -A group name version main coordinates dependencies
  local dir projectInfo
  for dir in "${dirs[@]}"; do
    if [ "$dir" = . ]; then
      projectInfo=$info
    else
      projectInfo=$(cd "$project/$dir" && lein purifier-info) || die "Leiningen could not read $dir/project.clj"
    fi
    group[$dir]=$(awk -F'\t' '$1 == "project" { print $2 }' <<<"$projectInfo")
    name[$dir]=$(awk -F'\t' '$1 == "project" { print $3 }' <<<"$projectInfo")
    version[$dir]=$(awk -F'\t' '$1 == "project" { print $4 }' <<<"$projectInfo")
    main[$dir]=$(awk -F'\t' '$1 == "main" { print $2 }' <<<"$projectInfo")
    dependencies[$dir]=$(awk -F'\t' '$1 == "dependency" { print $2 "/" $3 }' <<<"$projectInfo")
    coordinates["${group[$dir]}/${name[$dir]}"]=$dir
  done

  # The build order: each project after the projects it depends on.
  local ordered=() remaining=("${dirs[@]}") next placed dependency ready
  declare -A dependsOn
  while [ ${#remaining[@]} -gt 0 ]; do
    next=()
    placed=0
    for dir in "${remaining[@]}"; do
      ready=1
      dependsOn[$dir]=""
      while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        if [ -n "${coordinates[$dependency]:-}" ]; then
          dependsOn[$dir]+="$dependency"$'\n'
          case " ${ordered[*]} " in
          *" ${coordinates[$dependency]} "*) ;;
          *) ready=0 ;;
          esac
        fi
      done <<<"${dependencies[$dir]}"
      if [ $ready = 1 ]; then
        ordered+=("$dir")
        placed=1
      else
        next+=("$dir")
      fi
    done
    [ $placed = 1 ] || die "the projects ${next[*]} depend on each other in a cycle"
    remaining=("${next[@]}")
  done

  # Each project builds the way a sandboxed build builds it. In a project
  # with subprojects, each one is installed into the local repository, so
  # the projects after it resolve it from there.
  # Each task that builds a jar first empties target/ (:auto-clean), so
  # `install`, which builds the jar it installs, comes before `uberjar`.
  # The builder runs the same tasks.
  local tasks multi=false
  if [ ${#globs[@]} -gt 0 ]; then multi=true; fi
  if [ $multi = true ]; then tasks="install,"; else tasks="jar,"; fi
  if [ "$uberjar" = true ]; then tasks="$tasks uberjar,"; fi
  tasks="$tasks pom"
  local projects="$work/projects.jsonl" log canonical outputs mainClass standalone
  : >"$projects"
  for dir in "${ordered[@]}"; do
    log="$work/log-${dir//\//_}"
    echo "lein-purifier: building $dir"
    # Inside an if condition, errexit does not apply, so the steps are
    # joined with &&. The task list splits into words, and `do` is the
    # Leiningen task.
    # shellcheck disable=SC2086,SC1010
    if ! (cd "$project/$dir" && lein with-profile +test deps && lein do $tasks) 2>&1 | tee "$log"; then
      die "the lock run of $dir failed; see the output above"
    fi
    canonical=$(cd "$project/$dir" && pwd)
    outputs=$(sed -n "s|^Created $canonical/||p" "$log" | sort -u | jq -R . | jq -s .)
    # The main class is the one the uberjar manifest names, for a project
    # with :main. Without :main, the manifest names clojure.main, which
    # would make the launcher of a library a Clojure REPL.
    mainClass=null
    standalone=$(jq -r '.[] | select(endswith("-standalone.jar"))' <<<"$outputs")
    if [ -n "$standalone" ] && [ -n "${main[$dir]}" ]; then
      # unzip exits nonzero on warnings, and a jar without a manifest has no
      # main class, so its status does not count.
      mainClass=$({ unzip -p "$project/$dir/$standalone" META-INF/MANIFEST.MF 2>/dev/null || true; } |
        tr -d '\r' | sed -n 's/^Main-Class: *//p' | jq -R . | jq -s 'first // null')
    fi
    jq -cn --arg dir "$dir" --arg group "${group[$dir]}" --arg name "${name[$dir]}" \
      --arg version "${version[$dir]}" --argjson mainClass "$mainClass" --argjson outputs "$outputs" \
      --argjson dependsOn "$(printf '%s' "${dependsOn[$dir]}" | jq -R . | jq -s 'map(select(. != ""))')" \
      '{ dir: $dir, group: $group, name: $name, version: $version, mainClass: $mainClass,
         outputs: $outputs, dependsOn: $dependsOn }' >>"$projects"
  done

  # Every logged download becomes an entry: a file with the URL it came
  # from, or, for repository metadata, whose content changes over time at
  # its URL, the content the lock run read. A Maven repository serves a
  # released file at one URL, so the list of fallback URLs is empty. Files from a `file:`
  # repository inside the project are not downloads; the build takes them
  # from the project source.
  local artifacts="$work/artifacts.jsonl" repository resource file cwd rel path
  declare -A recorded projectRepositories
  : >"$artifacts"
  while IFS=$'\t' read -r repository resource file cwd; do
    case $resource in *.sha1 | *.md5 | *.sha256 | *.sha512 | *.asc) continue ;; esac
    rel=${file#"$m2"/}
    if [[ $repository == file:* ]]; then
      path=${repository#file:}
      path=${path#//}
      if [[ $path != /* ]]; then path="$cwd/$path"; fi
      path=$(realpath -m "$path")
      case $path in
      "$project"/*) projectRepositories[${path#"$project"/}]=1 ;;
      "$project") die "the project root is itself a file: repository" ;;
      *) die "$rel came from $repository, a file: repository outside the project; move it into the project" ;;
      esac
      recorded[$rel]=1
      continue
    fi
    [ -z "${recorded[$rel]:-}" ] || continue
    recorded[$rel]=1
    case $(basename "$rel") in
    maven-metadata*.xml)
      jq -cn --arg path "$rel" --rawfile contents "$m2/$rel" '{ path: $path, contents: $contents }' >>"$artifacts"
      ;;
    *)
      jq -cn --arg path "$rel" --arg url "${repository%/}/$resource" \
        --arg hash "$(nix-hash --type sha256 --flat --sri "$m2/$rel")" \
        '{ path: $path, url: $url, mirrors: [], hash: $hash }' >>"$artifacts"
      ;;
    esac
  done <"$transfers"

  # Every other file in the local repository must be one Maven Resolver
  # made itself: its records, the -SNAPSHOT copies of timestamped SNAPSHOT
  # files, or a file of a project of this build that the lock run
  # installed, which includes the maven-metadata-local.xml beside its
  # versions.
  local installed=() unexplained=()
  if [ $multi = true ]; then
    for dir in "${ordered[@]}"; do
      installed+=("$(groupPath "${group[$dir]}")/${name[$dir]}/")
    done
  fi
  local prefix explained
  while IFS= read -r rel; do
    [ -z "${recorded[$rel]:-}" ] || continue
    case $(basename "$rel") in
    _remote.repositories | *.lastUpdated | resolver-status.properties | *.sha1 | *.md5 | *.sha256 | *.sha512)
      continue
      ;;
    esac
    if [[ $(dirname "$rel") == *-SNAPSHOT && $(basename "$rel") == *-SNAPSHOT* ]]; then continue; fi
    explained=0
    for prefix in "${installed[@]}"; do
      if [[ $rel == "$prefix"* ]]; then explained=1; fi
    done
    [ $explained = 1 ] || unexplained+=("$rel")
  done < <(cd "$m2" && find . -type f -printf '%P\n' | LC_ALL=C sort)
  if [ ${#unexplained[@]} -gt 0 ]; then
    printf '  %s\n' "${unexplained[@]}" >&2
    die "the files above are in the local repository, but no download of them was logged"
  fi

  jq -n \
    --argjson version "$LEIN_PURIFIER_FORMAT" \
    --arg leinVersion "${versions%% *}" \
    --arg javaVersion "${versions#* }" \
    --arg definitionHash "$(definitionHash "$root" "${ordered[@]}")" \
    --argjson uberjar "$uberjar" \
    --argjson projectRepositories "$(printf '%s\n' "${!projectRepositories[@]}" | LC_ALL=C sort | jq -R . | jq -s 'map(select(. != ""))')" \
    --slurpfile projects "$projects" \
    --slurpfile artifacts "$artifacts" \
    '{
      version: $version,
      leinVersion: $leinVersion,
      javaVersion: $javaVersion,
      definitionHash: $definitionHash,
      uberjar: $uberjar,
      projects: $projects,
      projectRepositories: $projectRepositories,
      artifacts: ($artifacts | sort_by(.path))
    }' >"$lockFile.tmp"
  mv "$lockFile.tmp" "$lockFile"
  echo "lein-purifier: wrote $lockFile ($(jq '.projects | length' "$lockFile") projects, $(jq '.artifacts | length' "$lockFile") entries)"
}

# Makes $state/home/.m2/repository the local repository of the lockfile:
# links to the locked files in the store, and links to the files of the
# repositories inside the project. Sets `home`.
prepareRepository() {
  local root=$1 lockFile=$2 state=$3 manifest
  mkdir -p "$state"
  # The locked files are fetched into the store, and one GC root on the
  # manifest keeps them there. Without --read-write-mode, the evaluation
  # would name the manifest file without writing it to the store.
  nix-build "$LEIN_PURIFIER_LIB/realize.nix" --arg lockFile "$lockFile" -A fetches --no-out-link >/dev/null
  manifest=$(nix-instantiate --eval --read-write-mode --json "$LEIN_PURIFIER_LIB/realize.nix" --arg lockFile "$lockFile" -A manifest | jq -r .)
  nix-store --realise "$manifest" --add-root "$state/manifest" --indirect >/dev/null

  # The local repository is a writable tree of links into the store, made
  # anew when the manifest changes.
  home="$state/home"
  local m2="$home/.m2/repository" rel target repository
  if [ "$(cat "$state/manifest.path" 2>/dev/null || true)" != "$manifest" ]; then
    rm -rf "$home"
    mkdir -p "$m2"
    while IFS=$'\t' read -r rel target; do
      mkdir -p "$m2/$(dirname "$rel")"
      ln -s "$target" "$m2/$rel"
    done <"$manifest"
    echo "$manifest" >"$state/manifest.path"
  fi
  # Offline, Maven Resolver reads no repository but the local one, so the
  # files of each repository inside the project are linked into it, anew
  # on every run.
  while IFS= read -r repository; do
    while IFS= read -r rel; do
      mkdir -p "$m2/$(dirname "$rel")"
      ln -sfn "$root/$repository/$rel" "$m2/$rel"
    done < <(cd "$root/$repository" && find . -type f -printf '%P\n')
  done < <(jq -r '.projectRepositories[]' "$lockFile")
}

cmdLein() {
  local root lockFile home
  root=$(projectRoot)
  lockFile="$root/$lockName"
  [ -f "$lockFile" ] || die "$lockFile does not exist; run lein-purifier lock"
  if ! lockIsCurrent "$root" "$lockFile"; then
    echo "lein-purifier: $lockFile is out of date; Leiningen resolves the usual way until lein-purifier lock renews it" >&2
    exec lein "$@"
  fi
  prepareRepository "$root" "$lockFile" "$root/target/lein-purifier"

  # The JVM of Leiningen finds the local repository through user.home. The
  # Leiningen home directory of the user, with its profiles, stays in
  # effect.
  export LEIN_HOME="${LEIN_HOME:-$HOME/.lein}"
  export LEIN_JVM_OPTS="-Duser.home=$home ${LEIN_JVM_OPTS:-}"
  exec lein -o "$@"
}

cmdDeploy() {
  [ $# -ge 1 ] || die "deploy: name the repository to deploy to"
  local repository=$1
  shift
  local root lockFile home
  root=$(projectRoot)
  lockFile="$root/$lockName"
  [ -f "$lockFile" ] || die "$lockFile does not exist; run lein-purifier lock"
  lockIsCurrent "$root" "$lockFile" || die "$lockFile is out of date; run lein-purifier lock"

  local state="$root/target/lein-purifier" names
  if [ $# -gt 0 ]; then
    names=("$@")
  else
    mapfile -t names < <(jq -r '.projects[].name' "$lockFile")
  fi
  prepareRepository "$root" "$lockFile" "$state"
  export LEIN_HOME="${LEIN_HOME:-$HOME/.lein}"
  export LEIN_JVM_OPTS="-Duser.home=$home ${LEIN_JVM_OPTS:-}"

  local name record dir group version jar package
  for name in "${names[@]}"; do
    record=$(jq -c --arg name "$name" '.projects[] | select(.name == $name)' "$lockFile")
    [ -n "$record" ] || die "the lockfile has no project $name"
    dir=$(jq -r .dir <<<"$record")
    group=$(jq -r .group <<<"$record")
    version=$(jq -r .version <<<"$record")
    jar=$(jq -r '.outputs[] | select(endswith(".jar") and (endswith("-standalone.jar") | not))' <<<"$record" | head -n1)
    [ -n "$jar" ] || die "the lockfile names no jar of $name"
    # The package is the one buildLeinProject builds, with the nixpkgs of
    # this command, so its Leiningen is the one the lock was made with.
    echo "lein-purifier: building $name with Nix"
    package=$(nix-build "$LEIN_PURIFIER_LIB/package.nix" \
      --argstr nixpkgs "$LEIN_PURIFIER_NIXPKGS" --argstr src "$root" \
      -A "packages.\"$name\"" -o "$state/package-$name")
    echo "lein-purifier: deploying $group/$name $version to $repository"
    (cd "$root/$dir" && lein deploy "$repository" "$group/$name" "$version" \
      "$package/share/java/$(basename "$jar")" "$package/share/java/$name-$version.pom")
  done
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
deploy)
  shift
  cmdDeploy "$@"
  ;;
-h | --help | help)
  usage
  ;;
*)
  usage >&2
  exit 1
  ;;
esac
