# SPDX-License-Identifier: MIT
#
# What `lein-purifier lein` builds for an interactive Leiningen.
#
# `fetches` is every locked artifact, and `nix-build -A fetches` downloads
# them in parallel. `manifest` is then a store file with one line per
# artifact: its path in the local repository, a tab, and its store path.
# The file refers to every artifact, so one GC root on it keeps them all
# alive, and the command builds its writable repository from it.
#
# A file made with builtins.toFile may refer to store paths but not to
# derivation outputs, so the manifest names each artifact through
# builtins.fetchurl. With the same name and hash, it is the same
# fixed-output store path a fetch derivation produces, and it is already
# valid once `fetches` is built, so nothing downloads twice.
{ lockFile }:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix { inherit lock; };
in
{
  fetches = map fetch lock.artifacts;
  manifest = builtins.toFile "lein-purifier-repository.tsv" (
    builtins.concatStringsSep "" (
      map (
        artifact:
        "${artifact.path}\t${
          builtins.fetchurl {
            inherit (artifact) url;
            name = lock.artifactName artifact;
            sha256 = artifact.hash;
          }
        }\n"
      ) lock.artifacts
    )
  );
}
