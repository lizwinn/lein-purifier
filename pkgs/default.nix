# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The lein-purifier command, with the Leiningen of this package set.
  cli = callPackage ./lein-purifier { };
}
