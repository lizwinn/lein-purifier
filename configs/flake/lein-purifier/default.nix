# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The `default` entry of this flake's package overlay registry
    # (pkg-overlays/) is exported as `pkgOverlays` and as the plain
    # `overlays.default`, and the package set applies it by default. The
    # flake publishes as `packages` the derivations of the scope
    # `lein-purifier` below, and caisson's export would add
    # `buildLeinProject`, which is a function and not a package.
    nixpkgs = {
      packages.export.enabled = false;
    };
  };

  # `nix run github:nix-purifiers/lein-purifier -- lock` locks the project in
  # the current directory, and `nix shell github:nix-purifiers/lein-purifier`
  # puts lein-purifier and its `lein` on the PATH.
  perSystem =
    { pkgs, ... }:
    {
      packages = lib.filterAttrs (_: lib.isDerivation) pkgs.lein-purifier // {
        default = pkgs.lein-purifier.cli;
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              inherit (self) lib;
              overlay = self.overlays.default;
              inherit (self.packages.${system}) cli;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
