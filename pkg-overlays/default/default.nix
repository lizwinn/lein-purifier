# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.lein-purifier`: `.cli`, the lein-purifier command with its `lein`
# wrapper. A consumer that lists this flake in `projects` holds it as
# `lein-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "lein-purifier";
}
