# The tool environment `just initialize` builds to the .nix/tools out-link:
# the compiler, OTP, Python and every tool a recipe, a hook or a checker runs.
# It is one environment. The store is shared between worktrees, so the cluster
# and audit tools cost a worktree nothing extra.
{
  pkgs,
  erlang,
  rebar3,
  gleam,
  openssl,
  nixpkgsRevision,
}:
let
  allium = pkgs.callPackage ./allium.nix { };
  kubectl = pkgs.callPackage ./kubectl.nix { };
  # The gate checkers in scripts/checks/ and their tests (Decision 0004).
  python = pkgs.python314.withPackages (packages: [ packages.pytest ]);

  # What the checkers read: the version of each tool a check depends on, and
  # the nixpkgs revision behind them. Naming the nixpkgs source keeps it in
  # this environment's closure, so a store collection cannot take what the
  # offline gate evaluates.
  pins = pkgs.writeTextDir "share/knarr/pins.json" (
    builtins.toJSON {
      nixpkgs_revision = nixpkgsRevision;
      nixpkgs_source = "${pkgs.path}";
      otp = erlang.version;
      gleam = gleam.version;
      rebar3 = rebar3.version;
      openssl = openssl.version;
      python = pkgs.python314.version;
      nodejs = pkgs.nodejs.version;
      allium = allium.version;
      kubectl = kubectl.version;
      kwokctl = pkgs.kwok.version;
      kind = pkgs.kind.version;
      helm = pkgs.kubernetes-helm.version;
      kustomize = pkgs.kustomize.version;
      grype = pkgs.grype.version;
      just = pkgs.just.version;
      prek = pkgs.prek.version;
      ruff = pkgs.ruff.version;
      typos = pkgs.typos.version;
      taplo = pkgs.taplo.version;
      lychee = pkgs.lychee.version;
      markdownlint-cli2 = pkgs.markdownlint-cli2.version;
      actionlint = pkgs.actionlint.version;
      shellcheck = pkgs.shellcheck.version;
      hadolint = pkgs.hadolint.version;
      kubeconform = pkgs.kubeconform.version;
      ripsecrets = pkgs.ripsecrets.version;
      editorconfig-checker = pkgs.editorconfig-checker.version;
      nixfmt = pkgs.nixfmt.version;
    }
  );
in
pkgs.buildEnv {
  name = "knarr-tools";
  paths = [
    # The compiler and the one OTP every build, test and image uses.
    gleam
    erlang
    rebar3
    # The Erlang this OTP links, for the TLS evidence scripts' openssl CLI.
    openssl.bin

    pkgs.just
    pkgs.prek
    python
    pkgs.ruff
    pkgs.typos
    pkgs.lychee
    pkgs.taplo
    # markdownlint-cli2 also lends the docs checker its Node and markdown-it.
    pkgs.markdownlint-cli2
    pkgs.nodejs
    pkgs.actionlint
    pkgs.shellcheck
    pkgs.hadolint
    pkgs.ripsecrets
    pkgs.editorconfig-checker
    pkgs.nixfmt
    allium

    # The chart, the manifests and the local clusters (Decisions 0007, 0015).
    pkgs.kubernetes-helm
    pkgs.kustomize
    pkgs.kubeconform
    pkgs.kind
    pkgs.kwok
    kubectl

    # The audit workflow's scanner (Decision 0014).
    pkgs.grype

    pins
  ];
  pathsToLink = [
    "/bin"
    "/share/knarr"
    "/lib/node_modules"
  ];
}
