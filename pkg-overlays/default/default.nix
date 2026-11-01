# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.lein-purifier` (`.cli`), and the builder `pkgs.buildLeinProject`
# (nix/lib/build-lein-project.nix) beside them, where nixpkgs keeps its own
# builders, so a package written for callPackage takes it by name. The
# builder takes the shared purifier library from this flake's library. A
# consumer that lists this flake in `projects` holds the overlay as
# `lein-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "lein-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildLeinProject = final.callPackage ../../nix/lib/build-lein-project.nix {
        purifier = closure-lib.purifier;
      };
    };
}
