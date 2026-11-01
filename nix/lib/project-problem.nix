# SPDX-License-Identifier: MIT
#
# Why a sound lockfile does not fit the project at `src`, as a message that
# names the command that fixes it, or null when it fits. buildLeinProject
# throws the message, and the conformance checks read it.
#
# The lock records a hash of project.clj and profiles.clj of the root and
# of each project, in the order of the lock. A project whose definition
# changed after locking would resolve artifacts the lock does not hold.
# Each Leiningen version adds its own nREPL dependencies to every project,
# so a lock made with another Leiningen does not hold them either.
{
  lib,
  src,
  lockFile,
  lock,
  leinVersion,
}:
let
  directories = lib.unique ([ "." ] ++ map (p: p.dir) lock.projects);
  files = builtins.filter builtins.pathExists (
    lib.concatMap (dir: [
      (src + "/${dir}/project.clj")
      (src + "/${dir}/profiles.clj")
    ]) directories
  );
  definitionHash = builtins.hashString "sha256" (lib.concatMapStrings builtins.readFile files);
in
if definitionHash != lock.definitionHash then
  "lein-purifier: project.clj or profiles.clj in ${toString src} changed after ${toString lockFile} was made; run `lein-purifier lock`."
else if leinVersion != lock.leinVersion then
  "lein-purifier: ${toString lockFile} was made with Leiningen ${lock.leinVersion}, and this nixpkgs has Leiningen ${leinVersion}; run `lein-purifier lock` with the lein-purifier of this nixpkgs, or use the nixpkgs input of lein-purifier."
else
  null
