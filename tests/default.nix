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

  # A copy of the hello lock with one field changed.
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
  hello-runs = pkgs.runCommand "hello-runs" { } ''
    ${hello.package}/bin/hello you > output
    grep -qx '{"hello":"you"}' output
    grep -qx '<p>Hello, you</p>' output
    touch $out
  '';

  # The lock names every file of the package before it is built, and each
  # one is in the package.
  hello-artifacts = pkgs.runCommand "hello-artifacts" { } ''
    test -f ${hello.package.artifacts."hello-1.0.0.jar"}
    test -f ${hello.package.artifacts."hello-1.0.0-standalone.jar"}
    test -f ${hello.package}/share/java/hello-1.0.0.pom
    touch $out
  '';

  # A lock made from another project definition, or with another
  # Leiningen, would not hold what the build resolves, so the builder
  # refuses it at evaluation.
  stale-lock-refused =
    assert refuses (helloLockWith {
      definitionHash = "0000";
    });
    assert refuses (helloLockWith {
      leinVersion = "0.0.0";
    });
    assert refuses (helloLockWith {
      version = 0;
    });
    pkgs.runCommand "stale-lock-refused" { } "touch $out";
}
