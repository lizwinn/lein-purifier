# SPDX-License-Identifier: MIT
#
# The local Maven repository of a lockfile: every locked file at its path
# in the repository, as a link into the store. It is a package for
# callPackage, with the lockfile among its arguments, and it is the
# `dependencies` of buildLeinProject.
#
# The tree holds no `_remote.repositories` tracking files. Maven Resolver
# treats an artifact without a tracking record as installed locally, and
# so as available, which is what lets Leiningen resolve offline from it.
{
  lib,
  runCommand,
  lockFile,
  # Replaces the built-in fetcher; see fetch.nix.
  fetchurl ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix { inherit lock fetchurl; };
in
# The manifest goes to the builder as a file, because a large project
# locks hundreds of artifacts and the list would not fit in an environment
# variable.
runCommand "lein-purifier-repository"
  {
    manifest = lib.concatMapStrings (a: "${a.path}\t${fetch a}\n") lock.artifacts;
    passAsFile = [ "manifest" ];
    preferLocalBuild = true;
    allowSubstitutes = false;
    passthru = { inherit lock; };
  }
  ''
    mkdir -p $out
    while IFS=$'\t' read -r rel target; do
      mkdir -p "$out/$(dirname "$rel")"
      ln -s "$target" "$out/$rel"
    done < "$manifestPath"
  ''
