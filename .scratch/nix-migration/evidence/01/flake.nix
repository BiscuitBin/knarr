# Prototype for nix-migration ticket 01. It is evidence, not the repository's
# flake: ticket 07 writes that one at the root. README.md beside this file says
# what each choice here was measured against.
{
  description = "knarr toolchain prototype (nix-migration ticket 01 evidence)";

  inputs = {
    # The candidate revision. flake.lock pins the commit: nixpkgs-unstable's
    # head on 2026-11-12.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Hold: Gleam 1.19.0. The candidate has 1.19.2, and no revision has both
    # Gleam 1.19.0 and OTP 29.1.2. This is the last nixpkgs-unstable channel
    # head that carried 1.19.0 (nixpkgs-26.11pre1088030), so Hydra built it.
    nixpkgs-gleam.url = "github:NixOS/nixpkgs/8edc0c72e3a38faf5434e40d1f19431125fe4b30";

    # Hold: kubectl 1.36, the newest minor that reaches a 1.35 server. The
    # candidate has 1.37.2. nixos-26.05 stays on 1.36 and takes its patches.
    nixpkgs-kubectl.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-gleam,
      nixpkgs-kubectl,
    }:
    let
      inherit (nixpkgs) lib;

      # The exact versions the repository holds. Ticket 07 moves these into a
      # tracked file that stdlib Python can read; the flake then reads that
      # file with builtins.fromJSON. Evaluation fails when a locked input no
      # longer carries a held version, so a lock move cannot change one
      # silently.
      held = {
        erlang = "29.1.2";
        openssl = "3.5.9";
        gleam = "1.19.0";
        rebar3 = "3.28.0";
        allium = "3.6.1";
        kwok = "0.8.0";
        kind = "0.33.0";
        kubectlMinor = "1.36";
      };

      exactly =
        name: want: package:
        assert lib.assertMsg (package.version == want)
          "held ${name}: the locked input has ${package.version}, the hold is ${want}";
        package;

      # allium-tools is not in nixpkgs. These are the upstream release assets:
      # the x86_64-linux and aarch64-darwin digests are the ones tools.txt
      # pins, and the aarch64-linux one is GitHub's recorded asset digest.
      alliumAssets = {
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

      systems = builtins.attrNames alliumAssets;

      groups =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # One Erlang for everything: the interpreter the gate and the image
          # run, and the rebar3 built with it. It is the minimal build
          # (ncurses, openssl and zlib only): beam.interpreters.erlang_29 adds
          # wxWidgets and systemd, a 1.2 GB closure on Linux. The top-level
          # rebar3 is built with OTP 28.
          erlang = exactly "erlang" held.erlang pkgs.beam_minimal.interpreters.erlang_29;
          rebar3 = exactly "rebar3" held.rebar3 pkgs.beam_minimal.packages.erlang_29.rebar3;
          # The OpenSSL that Erlang's crypto is linked against, checked below
          # against Erlang's own build inputs, with its command for the TLS
          # proof's certificates.
          openssl = exactly "openssl" held.openssl pkgs.openssl;
          erlangOpenssl = lib.findFirst (input: (input.pname or "") == "openssl") null erlang.buildInputs;

          gleam = exactly "gleam" held.gleam nixpkgs-gleam.legacyPackages.${system}.gleam;

          kubectl =
            let
              package = nixpkgs-kubectl.legacyPackages.${system}.kubectl;
            in
            assert lib.assertMsg (lib.versions.majorMinor package.version == held.kubectlMinor)
              "held kubectl: the locked input has ${package.version}, the hold is ${held.kubectlMinor}";
            package;

          # The interpreter carries its own pytest: the checker suite runs
          # `sys.executable -m pytest`.
          python = pkgs.python314.withPackages (packages: [ packages.pytest ]);

          allium =
            let
              asset = alliumAssets.${system};
            in
            pkgs.stdenv.mkDerivation {
              pname = "allium";
              version = held.allium;
              src = pkgs.fetchurl {
                url = "https://github.com/juxt/allium-tools/releases/download/v${held.allium}/allium-${asset.triple}.tar.gz";
                inherit (asset) sha256;
              };
              sourceRoot = ".";
              # The Linux binaries are dynamically linked against glibc and
              # libgcc_s, so the loader path is patched to the store's.
              nativeBuildInputs = lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.autoPatchelfHook;
              buildInputs = lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.stdenv.cc.cc.lib;
              dontConfigure = true;
              dontBuild = true;
              installPhase = "install -D -m 0755 allium $out/bin/allium";
            };

          # lib/node_modules is linked beside bin because nixpkgs'
          # bin/markdownlint-cli2 is a wrapper script: the docs checker finds
          # the bundled markdown-it from the module directory, not from bin.
          environment =
            name: paths:
            pkgs.buildEnv {
              inherit name paths;
              pathsToLink = [
                "/bin"
                "/lib/node_modules"
              ];
            };
        in
        assert lib.assertMsg (
          erlangOpenssl != null && erlangOpenssl.version == openssl.version
        ) "erlang is not built against the held openssl";
        {
          # Everything the gate runs.
          default = environment "knarr-tools" [
            gleam
            erlang
            rebar3
            openssl.bin
            python
            pkgs.just
            pkgs.prek
            pkgs.typos
            pkgs.lychee
            pkgs.taplo
            pkgs.markdownlint-cli2
            # Node without npm: the node markdownlint-cli2's wrapper runs.
            pkgs.nodejs-slim
            pkgs.actionlint
            pkgs.shellcheck
            pkgs.ruff
            pkgs.kubernetes-helm
            pkgs.kustomize
            pkgs.ripsecrets
            pkgs.editorconfig-checker
            pkgs.kubeconform
            pkgs.hadolint
            allium
          ];

          # The local-cluster tools, optional as pixi's cluster environment is.
          cluster = environment "knarr-cluster-tools" [
            (exactly "kind" held.kind pkgs.kind)
            kubectl
            (exactly "kwok" held.kwok pkgs.kwok)
          ];

          # The image scan, optional as pixi's audit environment is.
          audit = environment "knarr-audit-tools" [ pkgs.grype ];

          # What the image ships: Erlang, and the openssl command the TLS
          # proof generates its certificates with.
          runtime = environment "knarr-runtime" [
            erlang
            openssl.bin
          ];

          inherit allium;
        };
    in
    {
      packages = lib.genAttrs systems groups;
      inherit held;
    };
}
