# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked artifacts.
{
  pkgs,
  # The flake's default package overlay, which adds buildLeinProject.
  overlay,
  # The lein-purifier command.
  cli,
}:
let
  # Every fixture builds the way a consumer's package does: through
  # buildLeinProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildLeinProject;

  # An application with dependencies from Maven Central and Clojars, a
  # plugin, a test profile and an uberjar with a main class. Its tests run
  # in the build.
  hello = buildLeinProject {
    src = ./fixtures/hello;
    doCheck = true;
  };

  # Dependencies from a version range, a SNAPSHOT and a repository inside
  # the project, with Maven Central reached through a mirror that
  # profiles.clj configures.
  sources = buildLeinProject { src = ./fixtures/sources; };

  # Subprojects: lein-sub names them in :sub, lein-monolith in its
  # :project-dirs. In each, the application depends on the library.
  multi-sub = buildLeinProject { src = ./fixtures/multi-sub; };
  monolith = buildLeinProject { src = ./fixtures/monolith; };

  # A check that runs a launcher and compares its output with one line.
  runs =
    name: package: expected:
    pkgs.runCommand name { } ''
      ${pkgs.lib.getExe package} > output
      if ! grep -qxF ${pkgs.lib.escapeShellArg expected} output; then
        echo "${name}: expected ${expected}, got:" >&2
        cat output >&2
        exit 1
      fi
      touch $out
    '';

  helloLock = builtins.fromJSON (builtins.readFile ./fixtures/hello/lein-purifier.lock.json);
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

  # The hello lock without the Clojars jar of hiccup.
  withoutHiccupJar = {
    artifacts = builtins.filter (a: a.path != "hiccup/hiccup/1.0.5/hiccup-1.0.5.jar") helloLock.artifacts;
  };

  # Whether buildLeinProject refuses the hello project with this lockfile
  # when the package is evaluated.
  refuses =
    lockFile:
    !(builtins.tryEval
      (buildLeinProject {
        src = ./fixtures/hello;
        inherit lockFile;
      }).package.drvPath
    ).success;
in
{
  inherit cli;

  hello = hello.package;

  # The launcher runs the uberjar, which holds both dependencies.
  hello-runs = runs "hello-runs" hello.package ''{"hello":"world"}'';

  # The lock names every file of the package before it is built, and each
  # one is in the package.
  hello-artifacts = pkgs.runCommand "hello-artifacts" { } ''
    test -f ${hello.package.artifacts."hello-1.0.0.jar"}
    test -f ${hello.package.artifacts."hello-1.0.0-standalone.jar"}
    test -f ${hello.package}/share/java/hello-1.0.0.pom
    touch $out
  '';

  sources-runs =
    runs "sources-runs" sources.package
      ''{"greeting":"Hello from the in-project repository, sources","snapshot":true}'';

  multi-sub-runs = runs "multi-sub-runs" multi-sub.packages.multi-app "MULTI-SUB!";
  multi-sub-library = multi-sub.packages.multi-lib;

  monolith-runs =
    runs "monolith-runs" monolith.packages.mono-tool
      "mono-tool is built from a monolith";
  monolith-library = monolith.packages.mono-core;

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

  # The builder refuses, at evaluation, a lockfile that does not describe
  # what the build resolves or that was changed by hand.
  bad-locks-refused =
    let
      edited = helloLockWith {
        artifacts = map (
          a: if a ? hash then a // { hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; } else a
        ) helloLock.artifacts;
      };
      conflicted = builtins.toFile "lein-purifier.lock.json" ''
        <<<<<<< HEAD
        ${builtins.readFile ./fixtures/hello/lein-purifier.lock.json}
        =======
        { }
        >>>>>>> other
      '';
    in
    # A tampered hash, a removed entry and merge conflict markers.
    assert refuses edited;
    assert refuses (helloLockWith withoutHiccupJar);
    assert refuses conflicted;
    # A file that is not a lockfile.
    assert refuses (builtins.toFile "lein-purifier.lock.json" "{ }");
    # A lock made from another project definition, with another Leiningen
    # or in another format.
    assert refuses (helloLockRewritten {
      definitionHash = "0000";
    });
    assert refuses (helloLockRewritten {
      leinVersion = "0.0.0";
    });
    assert refuses (helloLockRewritten {
      version = 1;
    });
    pkgs.runCommand "bad-locks-refused" { } "touch $out";

  # A lock that lacks an artifact the build needs, but is otherwise sound,
  # fails offline, and the build says to relock.
  missing-entry-explained =
    let
      failure = pkgs.testers.testBuildFailure
        (buildLeinProject {
          src = ./fixtures/hello;
          lockFile = helloLockRewritten withoutHiccupJar;
        }).package;
    in
    pkgs.runCommand "missing-entry-explained" { } ''
      grep -q 'in offline mode' ${failure}/testBuildFailure.log
      grep -q 'run lein-purifier lock --force' ${failure}/testBuildFailure.log
      touch $out
    '';
}
