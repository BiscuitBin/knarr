# What a knarr image holds. The Dockerfiles only run `nix build` on a rootfs
# from here and copy the result into an empty image (Decision 0017), so this
# file, not a base image, decides every byte the container ships.
{
  pkgs,
  erlang,
  openssl,
}:
let
  # Everything a container runs besides the shipment: the OTP the tools built
  # and tested with, a shell for the two entrypoint scripts, and the openssl
  # CLI and coreutils `just image-check` reruns the TLS evidence with.
  runtime = pkgs.buildEnv {
    name = "knarr-runtime";
    paths = [
      erlang
      pkgs.bashNonInteractive
      pkgs.coreutils
      openssl.bin
    ];
    pathsToLink = [ "/bin" ];
  };

  # A complete root filesystem except /tmp, which needs a mode the store
  # cannot hold; each Dockerfile adds it. The paths the chart and
  # scripts/checks/image.py name stay where the Dockerfile-built image had
  # them: /opt/<name>/shipment, /opt/<name>/container-entrypoint.sh and
  # /opt/build-otp.
  rootfs =
    { name, shipment }:
    pkgs.runCommand "${name}-rootfs"
      {
        closure = pkgs.closureInfo { rootPaths = [ runtime ]; };
        entrypoint = ../scripts/container-entrypoint.sh;
        inherit (pkgs.dockerTools) fakeNss;
      }
      ''
        mkdir -p "$out/nix/store" "$out/opt/${name}" "$out/usr/bin" "$out/etc"
        while read -r path; do
          cp -a "$path" "$out/nix/store/"
        done < "$closure/store-paths"
        ln -s ${runtime}/bin "$out/bin"
        ln -s ${runtime}/bin/env "$out/usr/bin/env"
        ln -s ${runtime} "$out/opt/${name}/runtime"
        cp -R ${shipment}/shipment "$out/opt/${name}/shipment"
        cp ${shipment}/build-otp "$out/opt/build-otp"
        install -m 0755 "$entrypoint" "$out/opt/${name}/container-entrypoint.sh"
        cp "$fakeNss"/etc/passwd "$fakeNss"/etc/group "$fakeNss"/etc/nsswitch.conf "$out/etc/"
      '';
in
{
  inherit runtime rootfs;
}
