# Ticket 01 evidence: one row for every tool pixi.toml and tools.txt pin, as
# nixpkgs names it. packages.sh evaluates this for each system and asks the
# binary cache about each output path. A null attribute path means nixpkgs has
# no such package at the revision.
#
# Each row: the pin's name in pixi.toml or tools.txt, the pinned version, the
# attribute path below legacyPackages.<system>, and the floor the repository
# depends on, if any.
pkgs:
let
  inherit (pkgs) lib;
  row =
    pin: pinned: path: floor:
    let
      found = lib.attrByPath path null pkgs;
      # Evaluating a package that is unsupported on a system throws.
      tried = builtins.tryEval (
        if found == null then
          null
        else
          {
            version = found.version or "?";
            out = found.outPath;
          }
      );
    in
    {
      inherit pin pinned floor;
      attr = lib.concatStringsSep "." path;
      version =
        if !tried.success then
          "unsupported"
        else if tried.value == null then
          "absent"
        else
          tried.value.version;
      out = if tried.success && tried.value != null then tried.value.out else null;
    };
in
[
  # pixi.toml [dependencies]
  (row "gleam" "1.19.0" [ "gleam" ] "held: exactly 1.19.0")
  (row "just" "1.58.0" [ "just" ] "")
  (row "prek" "0.5.5" [ "prek" ] "")
  (row "typos" "1.51.1" [ "typos" ] "")
  (row "lychee" "0.24.2" [ "lychee" ] "")
  (row "taplo" "0.10.0" [ "taplo" ] "")
  (row "markdownlint-cli2" "0.23.3" [ "markdownlint-cli2" ] "its bundled markdown-it, under Node")
  (row "(nodejs, markdownlint-cli2's dependency)" "26.10.0" [ "nodejs-slim" ] "runs render_markdown.mjs")
  (row "actionlint" "1.7.12" [ "actionlint" ] "")
  (row "shellcheck" "0.11.0" [ "shellcheck" ] "")
  (row "python" "3.14.8" [ "python314" ] "3.14 or later")
  (row "pytest" "9.1.1" [ "python314Packages" "pytest" ] "major 9")
  (row "ruff" "0.16.10" [ "ruff" ] "")
  (row "kubernetes-helm" "4.3.0" [ "kubernetes-helm" ] "major 4")
  (row "kustomize" "5.8.2" [ "kustomize" ] "")
  # pixi.toml [feature.otp.dependencies]
  (row "erlang" "29.1.2" [ "beam_minimal" "interpreters" "erlang_29" ] "held: exactly 29.1.2")
  (row "(erlang with wxWidgets and systemd)" "29.1.2" [ "beam" "interpreters" "erlang_29" ] "not used: 1.2 GB closure")
  (row "(openssl, erlang's dependency)" "3.6.5" [ "openssl" ] "held with erlang")
  (row "(openssl 3.6 by name)" "3.6.5" [ "openssl_3_6" ] "held with erlang")
  # pixi.toml [feature.cluster.dependencies]
  (row "kubernetes-kind" "0.33.0" [ "kind" ] "skew cap: node image 1.35")
  (row "kubernetes-client" "1.36.0" [ "kubectl" ] "skew cap: 1.34 to 1.36 for the 1.35 cluster")
  (row "tilt" "0.37.8" [ "tilt" ] "unused; not carried forward")
  # pixi.toml [feature.audit.dependencies]
  (row "grype" "0.120.1" [ "grype" ] "")
  # tools.txt
  (row "rebar3" "3.28.0" [ "beam_minimal" "packages" "erlang_29" "rebar3" ] "3.28.0 or later")
  (row "ripsecrets" "0.1.11" [ "ripsecrets" ] "")
  (row "editorconfig-checker" "4.0.2" [ "editorconfig-checker" ] "")
  (row "allium" "3.6.1" [ "allium" ] "exactly 3.6.1")
  (row "kubeconform" "0.8.0" [ "kubeconform" ] "")
  (row "hadolint" "2.15.1" [ "hadolint" ] "")
  (row "kwokctl" "0.8.0" [ "kwok" ] "0.8.0")
]
