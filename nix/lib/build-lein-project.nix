# SPDX-License-Identifier: MIT
#
# buildLeinProject: the sandboxed build of a Leiningen project, from the
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
#   dependencies   the local Maven repository of every locked artifact
#   package        the project's jars and POM in share/java, and for an
#                  uberjar with a main class, a launcher in bin
#   packages.<name>  the same package, under the project's name
#   lock           the lockfile, as lock.nix reads it
#   jdk            the JDK the build runs on
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
  # The JDK that runs Leiningen and the project's JVM.
  jdk ? null,
  # Replaces the built-in fetcher; see fetch.nix.
  fetchurl ? null,
  # Runs the project's tests (`lein test`) after the build.
  doCheck ? false,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out build outputs and
  # editor state.
  srcFilter ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };

  # The lock records a hash of project.clj and profiles.clj. A project
  # whose definition changed after locking would resolve artifacts the lock
  # does not hold, so the build stops before it starts.
  definitionFiles = builtins.filter builtins.pathExists [
    (src + "/project.clj")
    (src + "/profiles.clj")
  ];
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
        && (name == "target" || name == ".cpcache" || name == ".lsp" || name == ".clj-kondo")
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

  project = lock.project;

  # The tasks of the lock run after `deps`, in the same order.
  tasks = [ "jar" ] ++ lib.optional lock.uberjar "uberjar" ++ [ "pom" ];
  leinDo = "lein -o do " + lib.concatStringsSep ", " tasks;

  uberjarOutput = lib.findFirst (lib.hasSuffix "-standalone.jar") null lock.outputs;
  launcher = project.mainClass != null && uberjarOutput != null;

  javaDirectory = "share/java";
  outputFile = package: output: "${package}/${javaDirectory}/${baseNameOf output}";

  package = stdenvNoCC.mkDerivation (finalAttrs: {
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
    # it holds what this needs: the local repository is the only one, it is
    # read offline, and no user profile applies.
    preBuild = ''
      export HOME="$TMPDIR/home"
      export LEIN_HOME="$HOME/.lein"
      mkdir -p "$HOME/.m2/repository" "$LEIN_HOME" "$TMPDIR/java-tmp"
      # Maven Resolver writes next to what it reads, so the repository is
      # a writable tree of links into the store.
      cp -rs --no-preserve=mode ${dependencies}/. "$HOME/.m2/repository"
      # Leiningen's JVM takes its local repository from user.home, which
      # HOME does not set. The project's JVMs take their temporary
      # directory from JAVA_TOOL_OPTIONS.
      export LEIN_JVM_OPTS="-Duser.home=$HOME -Djava.io.tmpdir=$TMPDIR/java-tmp"
      export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$TMPDIR/java-tmp"
    '';
    buildPhase = ''
      runHook preBuild
      ${leinDo}
      runHook postBuild
    '';
    checkPhase = ''
      runHook preCheck
      lein -o test
      runHook postCheck
    '';
    dontFixup = !launcher;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/${javaDirectory}"
      for output in ${lib.escapeShellArgs lock.outputs}; do
        if [ ! -f "$output" ]; then
          echo "lein-purifier: the lock names $output, which this build of ${project.name} did not produce; run lein-purifier lock --force" >&2
          exit 1
        fi
        cp "$output" "$out/${javaDirectory}/"
      done
      cp pom.xml "$out/${javaDirectory}/${project.name}-${project.version}.pom"
      ${lib.optionalString launcher ''
        makeWrapper ${jdk'}/bin/java "$out/bin/${project.name}" \
          --add-flags "-jar $out/${javaDirectory}/${baseNameOf uberjarOutput}"
      ''}
      runHook postInstall
    '';
    passthru = {
      inherit dependencies lock;
      jdk = jdk';
      # The files of the package by file name, such as
      # artifacts."hello-1.0.0-standalone.jar". They are known from the
      # lock alone, before the package is built.
      artifacts = builtins.listToAttrs (
        map (output: {
          name = baseNameOf output;
          value = outputFile finalAttrs.finalPackage output;
        }) lock.outputs
      );
    };
    meta = {
      description = "${project.group}/${project.name}, built by lein-purifier";
    }
    // lib.optionalAttrs launcher { mainProgram = project.name; };
  });
in
assert
  definitionHash == lock.definitionHash
  || throw "lein-purifier: project.clj or profiles.clj in ${toString src} changed after ${toString lockFile} was made; run `lein-purifier lock`.";
assert
  leiningen'.version == lock.leinVersion
  || throw "lein-purifier: the lock was made with Leiningen ${lock.leinVersion}, and this package set has Leiningen ${leiningen'.version}. Re-lock with the lein-purifier of this package set, or pass a `leiningen` of version ${lock.leinVersion} through buildLeinProject.override.";
{
  inherit lock dependencies package;
  packages.${project.name} = package;
  jdk = jdk';
}
