# SPDX-License-Identifier: MIT
#
# Reads a lein-purifier lockfile, which `lein-purifier lock` writes at the
# project root.
#
# It needs no nixpkgs, because `lein-purifier lein` evaluates it with
# nothing but the Nix installation it runs on.
{ lockFile }:
let
  raw = builtins.readFile lockFile;

  # A merge conflict leaves markers in the file, which builtins.fromJSON
  # would report as a bare syntax error.
  conflicted = builtins.length (builtins.split "\n<<<<<<< " ("\n" + raw)) > 1;

  lock =
    if conflicted then
      throw "lein-purifier: ${toString lockFile} has merge conflict markers in it; run `lein-purifier lock --force` to write it anew."
    else
      builtins.fromJSON raw;

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
  builtins.isAttrs lock && lock ? version
  || throw "lein-purifier: ${toString lockFile} is not a lein-purifier lockfile; run `lein-purifier lock --force` to write one.";
assert
  lock.version == supportedVersion
  || throw "lein-purifier: ${toString lockFile} has lock format version ${toString lock.version}, and this library reads version ${toString supportedVersion}. Run `lein-purifier lock --force` with the lein-purifier revision that provides this library.";
assert
  (lock.integrity or null) == import ./integrity.nix lock
  || throw "lein-purifier: ${toString lockFile} was changed after `lein-purifier lock` wrote it; run `lein-purifier lock --force` to write it anew.";
lock
// {
  inherit storeName;

  # The store name of an entry: its file name, made a valid store name.
  artifactName = entry: storeName (builtins.baseNameOf entry.path);
}
