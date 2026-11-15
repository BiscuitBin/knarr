# One Gleam project's `gleam export erlang-shipment`, built with no network.
# manifest.toml is the lock: each hex package is fetched as a fixed-output
# derivation keyed on the manifest's outer_checksum, which is the sha256 of the
# tarball hex serves, and unpacked where `gleam deps download` would put it.
# The build then finds every package present and downloads nothing.
{
  pkgs,
  erlang,
  rebar3,
  gleam,
  name,
  root,
}:
let
  inherit (pkgs) lib;
  project = builtins.fromTOML (builtins.readFile (root + "/gleam.toml"));
  manifest = builtins.fromTOML (builtins.readFile (root + "/manifest.toml"));
  packages = map (
    package:
    assert lib.assertMsg (
      package.source == "hex"
    ) "nix/gleam-shipment.nix fetches hex packages only, and ${package.name} is not one";
    package
    // {
      tarball = pkgs.fetchurl {
        url = "https://repo.hex.pm/tarballs/${package.name}-${package.version}.tar";
        sha256 = lib.toLower package.outer_checksum;
      };
    }
  ) manifest.packages;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "${name}-shipment";
  inherit (project) version;
  # Only what the build reads, so an edit elsewhere in the repository does not
  # rebuild the shipment.
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/gleam.toml")
      (root + "/manifest.toml")
      (root + "/src")
    ];
  };
  nativeBuildInputs = [
    gleam
    erlang
    rebar3
  ];
  dontConfigure = true;
  # The shipment's entrypoint.sh keeps its `#!/bin/sh`: the image supplies it.
  dontFixup = true;
  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" build/packages
    ${lib.concatMapStrings (package: ''
      mkdir build/packages/${package.name}
      tar -xOf ${package.tarball} contents.tar.gz | tar -xz -C build/packages/${package.name}
    '') packages}
    {
      echo '[packages]'
      ${lib.concatMapStrings (package: ''
        echo '${package.name} = "${package.version}"'
      '') packages}
    } > build/packages/packages.toml
    # gleam rewrites a manifest.toml that disagrees with gleam.toml and exits
    # 0, so compare it across the build as the Justfile recipes do.
    before=$(cksum < manifest.toml)
    gleam export erlang-shipment
    [ "$(cksum < manifest.toml)" = "$before" ] ||
      { echo 'gleam rewrote manifest.toml; run just manifest-check' >&2; exit 1; }
    erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().' > build-otp
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir "$out"
    cp -R build/erlang-shipment "$out/shipment"
    cp build-otp "$out/build-otp"
    runHook postInstall
  '';
}
