# SPDX-License-Identifier: MIT
#
# The lein-purifier command: `lein-purifier lock` writes a project's
# lockfile, and `lein-purifier lein` runs Leiningen offline on the locked
# downloads. It calls the nix-build, nix-instantiate, nix-store and
# nix-hash of the Nix installation it runs on.
{
  # The nixpkgs source of this package set, which `deploy` builds with.
  path,
  writeShellApplication,
  leiningen,
  jq,
  unzip,
  gnutar,
  coreutils,
  findutils,
  gnused,
  gawk,
}:
writeShellApplication {
  name = "lein-purifier";
  runtimeInputs = [
    leiningen
    jq
    unzip
    gnutar
    coreutils
    findutils
    gnused
    gawk
  ];
  runtimeEnv = {
    LEIN_PURIFIER_LIB = ../../nix/lib;
    LEIN_PURIFIER_FORMAT = toString (import ../../nix/lib/lock-version.nix);
    LEIN_PURIFIER_INIT = ./init.clj;
    LEIN_PURIFIER_ENTRIES = ./entries.sh;
    LEIN_PURIFIER_NIXPKGS = path;
  };
  text = builtins.readFile ./lein-purifier.sh;
}
