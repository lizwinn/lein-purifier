# SPDX-License-Identifier: MIT
#
# The `lein-purifier` library namespace. It holds nothing, because the
# builder needs a package set: it is the package `buildLeinProject` that
# the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    lein-purifier = prev.lein-purifier or { };
  };

}
