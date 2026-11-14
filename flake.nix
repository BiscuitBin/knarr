{
  description = "knarr: the pinned tools, and everything its container images hold";

  # The one pin (Decision 0017): every tool takes the version this nixpkgs
  # revision carries, and flake.lock holds the revision and its hash. The
  # channel URL answers with an immutable link, which is what the lock records.
  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      # The hosts a contributor or CI runs on, and the systems an image runs on.
      # An image is always Linux, whatever host builds it through Docker.
      toolSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      imageSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      knarrFor =
        system:
        import ./nix {
          pkgs = nixpkgs.legacyPackages.${system};
          nixpkgsRevision = nixpkgs.rev or "unknown";
        };
    in
    {
      packages = lib.genAttrs toolSystems (
        system:
        let
          knarr = knarrFor system;
        in
        {
          default = knarr.tools;
          inherit (knarr) tools;
        }
        // lib.optionalAttrs (lib.elem system imageSystems) {
          inherit (knarr)
            runtime
            image-toolchain
            knarr-shipment
            knarr-rootfs
            fake-worker-shipment
            fake-worker-rootfs
            ;
        }
      );

      # A convenience only: recipes and hooks reach the tools through the
      # .nix/tools out-link `just initialize` builds, never through this shell.
      devShells = lib.genAttrs toolSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [ (knarrFor system).tools ];
            PYTHONDONTWRITEBYTECODE = "1";
          };
        }
      );

      formatter = lib.genAttrs toolSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
