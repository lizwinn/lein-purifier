# SPDX-License-Identifier: MIT
#
# buildLeinProject: the sandboxed builds of a Leiningen project, from the
# lockfile `lein-purifier lock` writes at the project root.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# lein-purifier overlay (`overlays.default`) adds it to the package set as
# `buildLeinProject`, so a package written for callPackage takes it like
# any other dependency:
#
#   { buildLeinProject }: (buildLeinProject { src = ./.; }).package
#
# and `buildLeinProject.override` replaces what it takes from the set. The
# builder returns
#
#   dependencies     the local Maven repository of every locked entry
#   packages.<name>  the package of each project of the lock, named as the
#                    project is: the root project, or each subproject that
#                    lein-sub or lein-monolith names. A package holds the
#                    jar, the uberjar and the POM in share/java, and for an
#                    uberjar with a main class, a launcher in bin.
#   package          the package of a lock with one project
#   lock             the lockfile, as lock.nix reads it
#   jdk              the JDK the builds run on
{
  lib,
  stdenvNoCC,
  callPackage,
  makeWrapper,
  # The JDKs a build can run on. The default JDK of a build is the headless
  # one of the major version its lock was made with.
  javaPackages,
  leiningen,
}:
{
  # The project root, which holds project.clj.
  src,
  # The lockfile. The default is the one `lein-purifier lock` writes at the
  # project root.
  lockFile ? src + "/lein-purifier.lock.json",
  # The JDK that runs Leiningen and the JVMs of the project.
  jdk ? null,
  # Replaces the built-in fetcher; see fetch.nix.
  fetchurl ? null,
  # Runs the tests of each project (`lein test`) after its build.
  doCheck ? false,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out build outputs, editor
  # state and Leiningen checkouts.
  srcFilter ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };

  # The lock records a hash of project.clj and profiles.clj of the root and
  # of each project, in the order of the lock. A project whose definition
  # changed after locking would resolve artifacts the lock does not hold,
  # so the build stops before it starts.
  definitionDirectories = lib.unique ([ "." ] ++ map (p: p.dir) lock.projects);
  definitionFiles = builtins.filter builtins.pathExists (
    lib.concatMap (dir: [
      (src + "/${dir}/project.clj")
      (src + "/${dir}/profiles.clj")
    ]) definitionDirectories
  );
  definitionHash = builtins.hashString "sha256" (
    lib.concatMapStrings builtins.readFile definitionFiles
  );

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(
      (
        type == "directory"
        && (
          name == "target"
          || name == "checkouts"
          || name == ".cpcache"
          || name == ".lsp"
          || name == ".clj-kondo"
        )
      )
      || name == ".git"
      || name == ".idea"
      || name == ".nrepl-port"
      || lib.hasPrefix "result" name
    );

  filteredSrc = builtins.path {
    path = src;
    name = "lein-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  javaMajor = builtins.head (lib.splitString "." lock.javaVersion);
  defaultJdk =
    javaPackages.compiler."openjdk${javaMajor}".headless
      or (throw "lein-purifier: javaPackages has no openjdk${javaMajor} for the Java ${lock.javaVersion} the lock was made with; pass `jdk`.");
  jdk' = if jdk != null then jdk else defaultJdk;

  # The nixpkgs leiningen wrapper exports the JAVA_CMD it was built with,
  # so the JDK is chosen through the override.
  leiningen' = leiningen.override { jdk = jdk'; };

  dependencies = callPackage ./tree.nix { inherit lockFile fetchurl; };

  # The tasks of the lock run. A lock with subprojects installs each one
  # into the local repository, and `install` builds the jar it installs.
  # Each task that builds a jar first empties target/ (:auto-clean), so
  # `uberjar` comes after it.
  multi = lock.projects != [ ] && (builtins.head lock.projects).dir != ".";
  tasks = [
    (if multi then "install" else "jar")
  ]
  ++ lib.optional lock.uberjar "uberjar"
  ++ [ "pom" ];
  leinDo = "lein -o do " + lib.concatStringsSep ", " tasks;

  javaDirectory = "share/java";
  groupPath = group: lib.replaceStrings [ "." ] [ "/" ] group;
  coordinate = project: "${project.group}/${project.name}";
  jarOutput =
    project:
    lib.findFirst (
      o: lib.hasSuffix ".jar" o && !lib.hasSuffix "-standalone.jar" o
    ) null project.outputs;
  uberjarOutput = project: lib.findFirst (lib.hasSuffix "-standalone.jar") null project.outputs;

  projectsByCoordinate = builtins.listToAttrs (
    map (p: {
      name = coordinate p;
      value = p;
    }) lock.projects
  );

  # Links the jar and the POM of a project built before this one into the
  # local repository, at the paths `lein install` puts them.
  linkProject =
    dependency:
    let
      project = projectsByCoordinate.${dependency};
      package = packages.${project.name};
      directory = "$HOME/.m2/repository/${groupPath project.group}/${project.name}/${project.version}";
      base = "${project.name}-${project.version}";
    in
    ''
      mkdir -p "${directory}"
      ln -s ${package}/${javaDirectory}/${baseNameOf (jarOutput project)} "${directory}/${base}.jar"
      ln -s ${package}/${javaDirectory}/${base}.pom "${directory}/${base}.pom"
    '';

  mkPackage =
    project:
    let
      uberjar = uberjarOutput project;
      launcher = project.mainClass != null && uberjar != null;
    in
    stdenvNoCC.mkDerivation (finalAttrs: {
      pname = project.name;
      inherit (project) version;
      src = filteredSrc;
      nativeBuildInputs = [
        jdk'
        leiningen'
      ]
      ++ lib.optional launcher makeWrapper;
      dontConfigure = true;
      inherit doCheck;

      # `lein-purifier lock` runs Leiningen the same way, so a lock made with
      # it holds what this needs: the local repository is the only one, it
      # is read offline, and no user profile applies.
      preBuild = ''
        leinOffline() {
          if ! "$@" 2> >(tee "$TMPDIR/lein-errors" >&2); then
            wait
            if grep -q 'in offline mode' "$TMPDIR/lein-errors"; then
              echo "lein-purifier: Leiningen needs an artifact that the lockfile does not hold; run lein-purifier lock --force" >&2
            fi
            return 1
          fi
        }
        export HOME="$TMPDIR/home"
        export LEIN_HOME="$HOME/.lein"
        mkdir -p "$HOME/.m2/repository" "$LEIN_HOME" "$TMPDIR/java-tmp"
        # Maven Resolver writes next to what it reads, so the repository is
        # a writable tree of links into the store.
        cp -rs --no-preserve=mode ${dependencies}/. "$HOME/.m2/repository"
        # Offline, Maven Resolver reads no repository but the local one, so
        # the files of each repository inside the project join it.
        ${lib.concatMapStrings (repository: ''
          cp -rs --no-preserve=mode "$PWD/${repository}/." "$HOME/.m2/repository"
        '') lock.projectRepositories}
        ${lib.concatMapStrings linkProject project.dependsOn}
        # The JVM of Leiningen takes its local repository from user.home,
        # which HOME does not set. The JVMs of the project take their
        # temporary directory from JAVA_TOOL_OPTIONS.
        export LEIN_JVM_OPTS="-Duser.home=$HOME -Djava.io.tmpdir=$TMPDIR/java-tmp"
        export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$TMPDIR/java-tmp"
        cd ${lib.escapeShellArg project.dir}
      '';
      # A dependency the lock does not hold fails offline with "in offline
      # mode"; the build then says what to do about it.
      buildPhase = ''
        runHook preBuild
        leinOffline ${leinDo}
        runHook postBuild
      '';
      checkPhase = ''
        runHook preCheck
        leinOffline lein -o test
        runHook postCheck
      '';
      dontFixup = !launcher;
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/${javaDirectory}"
        for output in ${lib.escapeShellArgs project.outputs}; do
          if [ ! -f "$output" ]; then
            echo "lein-purifier: the lock names $output, which this build of ${project.name} did not produce; run lein-purifier lock --force" >&2
            exit 1
          fi
          cp "$output" "$out/${javaDirectory}/"
        done
        cp pom.xml "$out/${javaDirectory}/${project.name}-${project.version}.pom"
        ${lib.optionalString launcher ''
          makeWrapper ${jdk'}/bin/java "$out/bin/${project.name}" \
            --add-flags "-jar $out/${javaDirectory}/${baseNameOf uberjar}"
        ''}
        runHook postInstall
      '';
      passthru = {
        inherit dependencies lock;
        leinProject = project;
        jdk = jdk';
        # The files of the package by file name, such as
        # artifacts."hello-1.0.0-standalone.jar". They are known from the
        # lock alone, before the package is built.
        artifacts = builtins.listToAttrs (
          map (output: {
            name = baseNameOf output;
            value = "${finalAttrs.finalPackage}/${javaDirectory}/${baseNameOf output}";
          }) project.outputs
        );
      };
      meta = {
        description = "${project.group}/${project.name}, built by lein-purifier";
      }
      // lib.optionalAttrs launcher { mainProgram = project.name; };
    });

  packages = builtins.listToAttrs (
    map (project: {
      inherit (project) name;
      value = mkPackage project;
    }) lock.projects
  );
in
assert
  definitionHash == lock.definitionHash
  || throw "lein-purifier: project.clj or profiles.clj in ${toString src} changed after ${toString lockFile} was made; run `lein-purifier lock`.";
assert
  leiningen'.version == lock.leinVersion
  || throw "lein-purifier: the lock was made with Leiningen ${lock.leinVersion}, and this package set has Leiningen ${leiningen'.version}. Re-lock with the lein-purifier of this package set, or pass a `leiningen` of version ${lock.leinVersion} through buildLeinProject.override.";
{
  inherit lock dependencies packages;
  package =
    if builtins.length lock.projects == 1 then
      packages.${(builtins.head lock.projects).name}
    else
      throw "lein-purifier: the lock of ${toString src} builds ${toString (builtins.length lock.projects)} projects; take one from `packages` (${builtins.concatStringsSep ", " (builtins.attrNames packages)}).";
  jdk = jdk';
}
