# SPDX-License-Identifier: MIT
#
# The lein-purifier command, with `lein-purifier lock`, `prefetch` and
# `publish`, and `lein`, the Leiningen of the everyday loop, which is the
# same script run under that name. It calls the `nix` and `nix-store` of
# the Nix installation it runs on.
{
  stdenv,
  runCommand,
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
let
  script = writeShellApplication {
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
      # The source of this flake, with its flake.lock, which the command
      # evaluates to build with the same library and nixpkgs as a Nix
      # build does.
      LEIN_PURIFIER_FLAKE = ../..;
      LEIN_PURIFIER_SYSTEM = stdenv.hostPlatform.system;
      LEIN_PURIFIER_FORMAT = toString (import ../../nix/lib/lock-version.nix);
      LEIN_PURIFIER_LEIN_VERSION = leiningen.version;
      LEIN_PURIFIER_INIT = ./init.clj;
      LEIN_PURIFIER_ENTRIES = ./entries.sh;
    };
    text = builtins.readFile ./lein-purifier.sh;
  };
in
runCommand "lein-purifier"
  {
    meta.mainProgram = "lein-purifier";
    passthru = { inherit script; };
  }
  ''
    mkdir -p $out/bin
    ln -s ${script}/bin/lein-purifier $out/bin/lein-purifier
    ln -s ${script}/bin/lein-purifier $out/bin/lein
  ''
