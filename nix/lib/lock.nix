# SPDX-License-Identifier: MIT
#
# Reads a lein-purifier lockfile, which `lein-purifier lock` writes at the
# project root.
#
# It needs no nixpkgs, because `lein-purifier lein` evaluates it with
# nothing but the Nix installation it runs on.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # A store path name from a file name. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters, so every other character becomes "_". The interactive mode
  # and the sandboxed build both name their fetches with this function, so
  # they share store paths.
  storeName =
    fileName:
    let
      # builtins.split alternates the text between matches with a list per
      # match.
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (
          builtins.split "[^A-Za-z0-9+._?=-]" fileName
        )
      );
      undotted = builtins.head (builtins.match "\\.*(.*)" replaced);
      nonEmpty = if undotted == "" then "file" else undotted;
    in
    builtins.substring 0 200 nonEmpty;
in
assert
  lock.version == supportedVersion
  || throw "lein-purifier: ${toString lockFile} has lock format version ${toString lock.version}, and this library reads version ${toString supportedVersion}. Run `lein-purifier lock --force` with the lein-purifier revision that provides this library.";
lock
// {
  inherit storeName;

  # The fetch name of an artifact: its file name, made a valid store name.
  artifactName = artifact: storeName (builtins.baseNameOf artifact.path);
}
