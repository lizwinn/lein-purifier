# SPDX-License-Identifier: MIT
#
# The `lein-purifier` library namespace, which holds the builder
# `buildLeinProject` (nix/lib/build-lein-project.nix). The builder uses the
# shared library, which this flake lists in `projects`, as `lib.purifier`.
{ ... }:
{

  overlay = final: prev: {
    lein-purifier = (prev.lein-purifier or { }) // {
      buildLeinProject = import ../../nix/lib/build-lein-project.nix { lib = final; };
    };
  };

}
