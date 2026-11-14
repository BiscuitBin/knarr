# Everything the flake exposes for one system. One Erlang derivation is bound
# here and handed to the tools, both shipment builds and the image runtime, so
# what the gate proves about OTP and TLS holds for the image (Decision 0017).
{ pkgs, nixpkgsRevision }:
let
  inherit (pkgs) lib;
  beam = pkgs.beamMinimal29Packages;
  inherit (beam) erlang rebar3;
  inherit (pkgs) gleam openssl;

  tools = import ./tools.nix {
    inherit
      pkgs
      erlang
      rebar3
      gleam
      openssl
      nixpkgsRevision
      ;
  };

  shipment =
    args:
    import ./gleam-shipment.nix (
      {
        inherit
          pkgs
          erlang
          rebar3
          gleam
          ;
      }
      // args
    );

  image = import ./image.nix { inherit pkgs erlang openssl; };

  # Everything a rootfs build needs that no project source decides: the
  # compiler, OTP, rebar3 and the runtime closure. Each Dockerfile builds this
  # first, so only a pin move invalidates that layer and a source edit
  # rebuilds from a warm store.
  image-toolchain =
    pkgs.runCommand "knarr-image-toolchain"
      {
        nativeBuildInputs = [
          gleam
          erlang
          rebar3
        ];
        closure = pkgs.closureInfo { rootPaths = [ image.runtime ]; };
        inherit (pkgs.dockerTools) fakeNss;
      }
      ''
        mkdir "$out"
      '';

  knarr-shipment = shipment {
    name = "knarr";
    root = ../.;
  };
  fake-worker-shipment = shipment {
    name = "fake_worker";
    root = ../fixtures/fake_worker;
  };
in
{
  inherit
    tools
    image-toolchain
    knarr-shipment
    fake-worker-shipment
    ;
  inherit (image) runtime;
  knarr-rootfs = image.rootfs {
    name = "knarr";
    shipment = knarr-shipment;
  };
  fake-worker-rootfs = image.rootfs {
    name = "fake_worker";
    shipment = fake-worker-shipment;
  };
}
