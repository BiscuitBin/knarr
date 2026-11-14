# knarr's toolchain (Decision 0017). Beside pixi until ticket 13: recipes use it
# with KNARR_TOOLS=nix, through the out-links `just initialize` builds.
#
# The flake reads pins.toml, the held versions, and asserts each held package
# against it, so a lock move that loses a held version fails evaluation instead
# of changing it. Every file it reads must be tracked (staged is enough), and
# it never refers to its own source, so evaluation copies nothing into the
# store. Every Nix command a recipe runs carries --no-update-lock-file.
{
  description = "knarr's toolchain: the gate's tools and the Erlang runtime the images ship";

  inputs = {
    # Every tool but two, and Erlang, rebar3 and OpenSSL.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Gleam alone, pinned by revision: the last nixpkgs-unstable channel head
    # that carried the held Gleam, so Hydra built it. No revision carries both
    # it and the held OTP.
    nixpkgs-gleam.url = "github:NixOS/nixpkgs/8edc0c72e3a38faf5434e40d1f19431125fe4b30";

    # kubectl alone, held to the minor that reaches the pinned cluster.
    nixpkgs-kubectl.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-gleam,
      nixpkgs-kubectl,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # The held versions: flat [exact], [minor] and [floor] tables of strings.
      pins = builtins.fromTOML (builtins.readFile ./pins.toml);

      exactly =
        name: package:
        assert lib.assertMsg (package.version == pins.exact.${name})
          "held ${name}: the locked input has ${package.version}, pins.toml holds ${pins.exact.${name}}";
        package;
      minor =
        name: package:
        assert lib.assertMsg (lib.versions.majorMinor package.version == pins.minor.${name})
          "held ${name}: the locked input has ${package.version}, pins.toml holds minor ${pins.minor.${name}}";
        package;
      floor =
        name: package:
        assert lib.assertMsg (lib.versionAtLeast package.version pins.floor.${name})
          "held ${name}: the locked input has ${package.version}, below the floor ${pins.floor.${name}} pins.toml holds";
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
          # wxWidgets and systemd. The top-level rebar3 is built with OTP 28.
          erlang = exactly "erlang" pkgs.beam_minimal.interpreters.erlang_29;
          rebar3 = floor "rebar3" pkgs.beam_minimal.packages.erlang_29.rebar3;

          # OpenSSL is not held: it is whatever the held Erlang is built
          # against, asserted below to be the OpenSSL the environments ship,
          # the openssl command included.
          openssl = pkgs.openssl;
          erlangOpenssl = lib.findFirst (input: (input.pname or "") == "openssl") null erlang.buildInputs;

          gleam = exactly "gleam" nixpkgs-gleam.legacyPackages.${system}.gleam;
          kubectl = minor "kubectl" nixpkgs-kubectl.legacyPackages.${system}.kubectl;

          # The interpreter carries its own pytest: the checker suite runs
          # `sys.executable -m pytest`.
          python = pkgs.python314.withPackages (packages: [ packages.pytest ]);

          allium =
            let
              asset = alliumAssets.${system};
            in
            pkgs.stdenv.mkDerivation {
              pname = "allium";
              version = pins.exact.allium;
              src = pkgs.fetchurl {
                url = "https://github.com/juxt/allium-tools/releases/download/v${pins.exact.allium}/allium-${asset.triple}.tar.gz";
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
          # The environment check reads opensslVersion: pins.toml names no
          # OpenSSL, so the version Erlang is built against comes from here.
          environment =
            name: paths:
            pkgs.buildEnv {
              inherit name paths;
              pathsToLink = [
                "/bin"
                "/lib/node_modules"
              ];
              passthru.opensslVersion = erlangOpenssl.version;
            };
        in
        assert lib.assertMsg (
          erlangOpenssl != null && erlangOpenssl.version == openssl.version
        ) "erlang is not built against the openssl the environments ship";
        {
          # Everything the gate runs. perl is for the release scripts, which
          # conda's Erlang brought into pixi's environment.
          default = environment "knarr-tools" [
            gleam
            erlang
            rebar3
            openssl.bin
            python
            pkgs.perl
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

          # The local-cluster tools, optional as pixi's cluster environment
          # is. Ticket 08 gives them recipes.
          cluster = environment "knarr-cluster-tools" [
            (exactly "kind" pkgs.kind)
            kubectl
            (exactly "kwokctl" pkgs.kwok)
          ];

          # The image scan, optional as pixi's audit environment is.
          audit = environment "knarr-audit-tools" [ pkgs.grype ];

          # What the images ship: Erlang, and the openssl command the TLS
          # proof generates its certificates with. Ticket 09 builds it.
          runtime = environment "knarr-runtime" [
            erlang
            openssl.bin
          ];

          inherit allium;
        };
    in
    {
      packages = lib.genAttrs systems groups;
    };
}
