# SPDX-License-Identifier: MIT
#
# What `lein-purifier deploy` builds: the packages of a project, by
# buildLeinProject (build-lein-project.nix, called with the nixpkgs package
# set), from arguments that the command passes as strings.
#
#   nixpkgs  a nixpkgs source directory, the one the command was built with
#   src      the project root
{
  nixpkgs,
  src,
}:
let
  pkgs = import nixpkgs { };
in
pkgs.callPackage ./build-lein-project.nix { } { src = /. + src; }
