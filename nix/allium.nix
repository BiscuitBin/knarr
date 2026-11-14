# The Allium CLI (Decision 0005): nixpkgs does not carry it, so this takes the
# upstream release binary for each host, pinned by version and sha256. The
# x86_64-linux and aarch64-darwin hashes are the ones Decision 0005 verified;
# the aarch64-linux hash is a first-use pin computed on 2026-11-14.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
}:
let
  version = "3.6.1";
  assets = {
    x86_64-linux = {
      triple = "x86_64-unknown-linux-gnu";
      sha256 = "e00c99ae234b10207719257a70e7c2dcad73060864468cd293fb7ad40524e970";
    };
    aarch64-linux = {
      triple = "aarch64-unknown-linux-gnu";
      sha256 = "e5ce96393db198b4f7d23ccd2494573e753936cc7b03ca1ecbac3cb20f993ff4";
    };
    aarch64-darwin = {
      triple = "aarch64-apple-darwin";
      sha256 = "ecfae02fcf8e60475a014944183158ccde4104f6f0223e1bf91f98519fcb19eb";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  asset = assets.${system} or (throw "nix/allium.nix pins no Allium for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "allium";
  inherit version;
  src = fetchurl {
    url = "https://github.com/juxt/allium-tools/releases/download/v${version}/allium-${asset.triple}.tar.gz";
    inherit (asset) sha256;
  };
  sourceRoot = ".";
  # The Linux binary names the system loader and libgcc_s; patch both to the
  # store. Stripping would break the macOS binary's ad-hoc signature.
  nativeBuildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [ stdenv.cc.cc.lib ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  installPhase = ''
    runHook preInstall
    install -D -m 0755 allium "$out/bin/allium"
    runHook postInstall
  '';
  meta.platforms = lib.attrNames assets;
}
