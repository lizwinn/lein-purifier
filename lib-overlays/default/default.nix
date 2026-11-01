# SPDX-License-Identifier: MIT
#
# The `lein-purifier` library namespace, which holds the builder
# `buildLeinProject` (nix/lib/build-lein-project.nix) and `readLock`, which
# reads a lockfile into the lock in memory of the purifier contract
# (nix/lib/read-lock.nix). Both use the shared library, which this flake
# lists in `projects`, as `lib.purifier`.
{ ... }:
{

  overlay = final: prev: {
    lein-purifier = (prev.lein-purifier or { }) // {
      buildLeinProject = import ../../nix/lib/build-lein-project.nix { lib = final; };
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
