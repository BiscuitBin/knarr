# kubectl is supported within one minor of the API server, and the local
# clusters run 1.35 (scripts/checks/cluster.py). nixpkgs moves kubectl with the
# newest Kubernetes, so this pins the upstream static binary instead; the
# sha256 values are the ones dl.k8s.io publishes beside each binary. A gate
# test holds the minor to the kind node's.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  version = "1.36.0";
  assets = {
    x86_64-linux = {
      platform = "linux/amd64";
      sha256 = "123d8c8844f46b1244c547fffb3c17180c0c26dac9890589fe7e67763298748e";
    };
    aarch64-linux = {
      platform = "linux/arm64";
      sha256 = "9f9d9c44a7b5264515ac9da5991584e2395bd50662e651132337e7b4d0c56f8f";
    };
    aarch64-darwin = {
      platform = "darwin/arm64";
      sha256 = "4bcf268eacdc1d2df74e37d86f639f27ca7dea3ae185b7b452b73b9fb5ddc14e";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  asset = assets.${system} or (throw "nix/kubectl.nix pins no kubectl for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "kubectl";
  inherit version;
  src = fetchurl {
    url = "https://dl.k8s.io/release/v${version}/bin/${asset.platform}/kubectl";
    inherit (asset) sha256;
  };
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  installPhase = ''
    runHook preInstall
    install -D -m 0755 "$src" "$out/bin/kubectl"
    runHook postInstall
  '';
  meta.platforms = lib.attrNames assets;
}
