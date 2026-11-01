# SPDX-License-Identifier: MIT
#
# Reads a lein-purifier lockfile, which `lein-purifier lock` writes at the
# project root, and refuses one that cannot be used (see lock-problem.nix).
{ lockFile }:
let
  problem = import ./lock-problem.nix { inherit lockFile; };
in
if problem != null then throw problem else builtins.fromJSON (builtins.readFile lockFile)
