# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.lein-purifier`, made with lib.makeScope from the
# packages of pkgs/, with `buildLeinProject` and `cli`. A package written
# for callPackage takes the scope by name. A consumer that lists this flake
# in `projects` holds the overlay as `lein-purifier/default`, which its
# package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "lein-purifier";
}
