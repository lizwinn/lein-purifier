# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked artifacts. The conformance
# checks of the purifier contract that need Nix or the network outside
# the sandbox (conformance-relock, conformance-rebuild and
# conformance-offline) are CI jobs; see .github/workflows/check.yml.
{
  pkgs,
  # The flake's library, with `lein-purifier` and the shared `purifier`.
  lib,
  # The lein-purifier command.
  cli,
}:
let
  # Every fixture builds the way a consumer's package does: through the
  # builder of the flake's library.
  build = args: lib.lein-purifier.buildLeinProject ({ inherit pkgs; } // args);

  # An application with dependencies from Maven Central and Clojars, a
  # plugin, a test profile and an uberjar with a main class.
  hello = build { src = ./fixtures/hello; };

  # Dependencies from a version range, a SNAPSHOT and a repository inside
  # the project, with Maven Central reached through a mirror that
  # profiles.clj configures.
  sources = build { src = ./fixtures/sources; };

  # Subprojects: lein-sub names them in :sub, lein-monolith in its
  # :project-dirs. In each, the application depends on the library.
  multi-sub = build { src = ./fixtures/multi-sub; };
  monolith = build { src = ./fixtures/monolith; };

  # A check that runs a launcher and compares its output with one line.
  runs =
    name: package: expected:
    pkgs.runCommand name { } ''
      ${lib.getExe package} > output
      if ! grep -qxF ${lib.escapeShellArg expected} output; then
        echo "${name}: expected ${expected}, got:" >&2
        cat output >&2
        exit 1
      fi
      touch $out
    '';

  # A check that every message is a refusal naming the command to run.
  namesCommand =
    name: messages:
    assert lib.all (message: message != null && lib.hasInfix "lein-purifier lock" message) messages;
    pkgs.runCommand name { } "touch $out";

  helloLockFile = ./fixtures/hello/lein-purifier.lock.json;
  helloLock = builtins.fromJSON (builtins.readFile helloLockFile);
  writeLock = lock: builtins.toFile "lein-purifier.lock.json" (builtins.toJSON lock);

  # A copy of the hello lock with some fields changed, which keeps the old
  # integrity, as an edit by hand would.
  helloLockWith = attrs: writeLock (helloLock // attrs);

  # The same, with the integrity of the changed lock, as `lein-purifier
  # lock` would write it.
  helloLockRewritten =
    attrs:
    let
      lock = helloLock // attrs;
    in
    writeLock (lock // { integrity = import ../nix/lib/integrity.nix lock; });

  lockProblem = lockFile: import ../nix/lib/lock-problem.nix { inherit lockFile; };
  projectProblem =
    lockFile:
    import ../nix/lib/project-problem.nix {
      inherit (pkgs) lib;
      inherit lockFile;
      src = ./fixtures/hello;
      lock = builtins.fromJSON (builtins.readFile lockFile);
      leinVersion = pkgs.leiningen.version;
    };

  # Whether the builder refuses the hello project with this lockfile when
  # it is evaluated.
  refuses =
    lockFile:
    !(builtins.tryEval
      (build {
        src = ./fixtures/hello;
        inherit lockFile;
      }).packages.hello.drvPath
    ).success;

  # The hello lock without the Clojars jar of hiccup.
  withoutHiccupJar = {
    artifacts = builtins.filter (
      a: a.path != "hiccup/hiccup/1.0.5/hiccup-1.0.5.jar"
    ) helloLock.artifacts;
  };
in
{
  inherit cli;

  # The unit tests of the lock run's parsing.
  unit =
    pkgs.runCommand "unit"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.findutils
          pkgs.gnused
          pkgs.gawk
        ];
      }
      ''
        bash ${./unit.sh} ${../pkgs/lein-purifier/entries.sh}
        touch $out
      '';

  # The package of each fixture project, which tests/rebuild.sh rebuilds.
  hello = hello.packages.hello;
  sources = sources.packages.sources;
  multi-lib = multi-sub.packages.multi-lib;
  multi-app = multi-sub.packages.multi-app;
  mono-core = monolith.packages.mono-core;
  mono-tool = monolith.packages.mono-tool;

  hello-tests = hello.tests;
  hello-runs = runs "hello-runs" hello.packages.hello ''{"hello":"world"}'';

  # The lock names every file of the package before it is built, each one
  # is in the package, and the release holds the jar and the POM in Maven
  # repository layout.
  hello-artifacts = pkgs.runCommand "hello-artifacts" { } ''
    test -f ${hello.packages.hello.artifacts."hello-1.0.0.jar"}
    test -f ${hello.packages.hello.artifacts."hello-1.0.0-standalone.jar"}
    test -f ${hello.packages.hello}/share/java/hello-1.0.0.pom
    test -f ${hello.release}/example/hello/1.0.0/hello-1.0.0.jar
    test -f ${hello.release}/example/hello/1.0.0/hello-1.0.0.pom
    ${lib.optionalString (
      builtins.length hello.fetches != builtins.length helloLock.artifacts
    ) "exit 1"}
    touch $out
  '';

  sources-runs =
    runs "sources-runs" sources.packages.sources
      ''{"greeting":"Hello from the in-project repository, sources","snapshot":true}'';

  multi-sub-runs = runs "multi-sub-runs" multi-sub.packages.multi-app "MULTI-SUB!";
  multi-sub-tests = multi-sub.tests;

  monolith-runs =
    runs "monolith-runs" monolith.packages.mono-tool
      "mono-tool is built from a monolith";
  monolith-release = monolith.release;

  # A lockfile older than the project fails, naming the command to run:
  # one made from another project definition or with another Leiningen.
  conformance-stale =
    let
      stale = helloLockRewritten { definitionHash = "0000"; };
      otherLein = helloLockRewritten { leinVersion = "0.0.0"; };
    in
    assert refuses stale && refuses otherLein;
    namesCommand "conformance-stale" [
      (projectProblem stale)
      (projectProblem otherLein)
    ];

  # A lockfile with a changed hash fails, naming the command to run.
  conformance-tampered =
    let
      tampered = helloLockWith {
        artifacts = map (
          a: if a ? hash then a // { hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; } else a
        ) helloLock.artifacts;
      };
    in
    assert refuses tampered;
    namesCommand "conformance-tampered" [ (lockProblem tampered) ];

  # A lockfile without a needed entry fails, naming the command to run:
  # an edited one at evaluation, and one that is otherwise sound when
  # Leiningen fails offline.
  conformance-missing =
    let
      failure =
        pkgs.testers.testBuildFailure
          (build {
            src = ./fixtures/hello;
            lockFile = helloLockRewritten withoutHiccupJar;
          }).packages.hello;
    in
    assert (lockProblem (helloLockWith withoutHiccupJar)) != null;
    pkgs.runCommand "conformance-missing" { } ''
      grep -q 'in offline mode' ${failure}/testBuildFailure.log
      grep -q 'run lein-purifier lock --force' ${failure}/testBuildFailure.log
      touch $out
    '';

  # A lockfile that is not valid fails, naming the command to run: one
  # with merge conflict markers, one that is not a lockfile, and one of
  # another format.
  conformance-malformed =
    let
      conflicted = builtins.toFile "lein-purifier.lock.json" ''
        <<<<<<< HEAD
        ${builtins.readFile helloLockFile}
        =======
        { }
        >>>>>>> other
      '';
      notALock = builtins.toFile "lein-purifier.lock.json" "{ }";
      otherFormat = helloLockRewritten { version = 1; };
    in
    assert refuses conflicted && refuses notALock && refuses otherFormat;
    namesCommand "conformance-malformed" [
      (lockProblem conflicted)
      (lockProblem notALock)
      (lockProblem otherFormat)
    ];

  # A project whose source holds no lockfile builds from a lockfile kept
  # outside it.
  conformance-external =
    let
      external = build {
        src = builtins.path {
          name = "hello-without-lockfile";
          path = ./fixtures/hello;
          filter = path: _: baseNameOf path != "lein-purifier.lock.json";
        };
        lockFile = helloLockFile;
      };
    in
    runs "conformance-external" external.packages.hello ''{"hello":"world"}'';
}
