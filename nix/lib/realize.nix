# SPDX-License-Identifier: MIT
#
# What `lein-purifier lein` and `lein-purifier deploy` build for a
# Leiningen that runs outside the sandbox.
#
# `fetches` is every downloaded file of the lock, and `nix-build -A
# fetches` downloads them in parallel. `manifest` is then a store file with
# one line per entry: its path in the local repository, a tab, and its
# store path. The file refers to every entry, so one GC root on it keeps
# them all alive, and the command builds its writable repository from it.
#
# A file made with builtins.toFile may refer to store paths but not to
# derivation outputs, so the manifest names each download through
# builtins.fetchurl. With the same name and hash, it is the same
# fixed-output store path a fetch derivation produces, and it is already
# valid once `fetches` is built, so nothing downloads twice. An entry with
# `contents` is a builtins.toFile path already.
{ lockFile }:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix { inherit lock; };
  downloads = builtins.filter (entry: entry ? url) lock.artifacts;
  storePath =
    entry:
    if entry ? contents then
      fetch entry
    else
      builtins.fetchurl {
        inherit (entry) url;
        name = lock.artifactName entry;
        sha256 = entry.hash;
      };
in
{
  fetches = map fetch downloads;
  manifest = builtins.toFile "lein-purifier-repository.tsv" (
    builtins.concatStringsSep "" (map (entry: "${entry.path}\t${storePath entry}\n") lock.artifacts)
  );
}
