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

  # A copy of the hello lock with some fields changed.
  helloLockWith =
    attrs:
    builtins.toFile "lein-purifier.lock.json" (
      builtins.toJSON (
        builtins.fromJSON (builtins.readFile ./fixtures/hello/lein-purifier.lock.json) // attrs
      )
    );

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

  # A lock made from another project definition, with another Leiningen
  # or in another format would not hold what the build resolves, so the
  # builder refuses it at evaluation.
  stale-lock-refused =
    assert refuses (helloLockWith {
      definitionHash = "0000";
    });
    assert refuses (helloLockWith {
      leinVersion = "0.0.0";
    });
    assert refuses (helloLockWith {
      version = 1;
    });
    pkgs.runCommand "stale-lock-refused" { } "touch $out";
}
