{
  description = "Nix packaging for Sure — self-hosted personal finance manager (we-promise/sure)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { pkgs, system, ... }: {
        packages.default = pkgs.callPackage ./package.nix { };
        packages.sure    = pkgs.callPackage ./package.nix { };
      };

      flake = {
        nixosModules.sure    = import ./module.nix self;
        nixosModules.default = self.nixosModules.sure;

        # Overlay exposing `pkgs.sure`
        overlays.default = final: prev: {
          sure = final.callPackage ./package.nix { };
        };
      };
    };
}
