#!/bin/sh
# Ticket 01 evidence: prepare the clone the gate runs in. Needs the network:
# it builds the prototype's default group and downloads the hex packages.
#
# The Justfile, with-env.sh, the docs checker, the Allium runner and the
# ripsecrets wrapper each name pixi's directories (ticket 02 puts one seam in
# front of them). So that no tracked file changes, the prototype environment is
# built straight into the path they name: the out-link is .pixi/envs/default,
# and .tools/bin is a link to its bin. Both paths are gitignored.
# Usage (host): sh nix.sh sh /evidence/gate-setup.sh > gate-setup.txt
# lib.sh sets rev, systems and flake, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
# shellcheck source=lib.sh disable=SC1091
. /evidence/lib.sh
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(nix config show system)"
git config --global user.name 'ticket 01' && git config --global user.email ticket01@example.invalid
git config --global advice.detachedHead false

rm -rf /work/gate
mkdir -p /work/gate
git clone --quiet --branch 01-nix-container-spike /bundle/knarr.bundle /work/gate/clone
cd /work/gate/clone || exit 1
printf 'clone of %s at %s\n' "$(git branch --show-current)" "$(git rev-parse --short HEAD)"

printf '\n== The environment, built from the flake this branch tracks in its evidence directory\n'
proto=./.scratch/nix-migration/evidence/01
start=$(date +%s)
nix build "$proto#default" --no-update-lock-file --out-link .pixi/envs/default 2> /dev/null
printf 'nix build %s#default --out-link .pixi/envs/default: %s seconds (store already populated)\n' "$proto" "$(($(date +%s) - start))"
mkdir -p .tools
ln -s ../.pixi/envs/default/bin .tools/bin
printf '.pixi/envs/default -> %s\n.tools/bin -> %s\n' "$(readlink .pixi/envs/default)" "$(readlink .tools/bin)"
printf 'closure: %s\n' "$(nix path-info -Sh .pixi/envs/default | cut -f2-)"
printf 'git status --short: %s\n' "$(git status --short | wc -l) lines"

printf '\n== Hex packages, with only the environment directories prefixed\n'
PATH=/work/gate/clone/.pixi/envs/default/bin:$PATH
export PATH
python3 scripts/checks/manifest_check.py
before=$(cksum < manifest.toml)
gleam deps download 2>&1 | tail -n 1
(cd fixtures/fake_worker && gleam deps download 2>&1 | tail -n 1)
[ "$(cksum < manifest.toml)" = "$before" ] && echo 'manifest.toml unchanged'
printf 'git status --short: %s\n' "$(git status --short | wc -l) lines"

printf '\n== Tool versions from the prefix\n'
for tool in gleam just prek typos lychee taplo markdownlint-cli2 actionlint ruff \
  ripsecrets editorconfig-checker hadolint allium node python3; do
  printf '%-22s %s\n' "$tool" "$("$tool" --version 2>&1 | head -n 1)"
done
printf '%-22s %s\n' shellcheck "$(shellcheck --version | sed -n 2p)"
printf '%-22s %s\n' kustomize "$(kustomize version 2>&1)"
printf '%-22s %s\n' pytest "$(python3 -m pytest --version 2>&1)"
printf '%-22s %s\n' helm "$(helm version --short 2>&1)"
printf '%-22s %s\n' kubeconform "$(kubeconform -v 2>&1)"
printf '%-22s %s\n' rebar3 "$(rebar3 --version 2>&1)"
printf '%-22s %s\n' erl "$(erl -noshell -eval 'io:format("OTP ~s, erts ~s", [erlang:system_info(otp_release), erlang:system_info(version)]), halt().')"
printf '%-22s %s\n' openssl "$(openssl version)"

printf '\n== A second environment for the hook case: the same flake after a lock move\n'
# nixpkgs-26.11pre1115905, a nixpkgs-unstable head a few days older than the
# candidate: the held versions are the same, so the assertions pass, and prek
# is 0.5.7 there, so its store path moves.
moved=9ac0edc06bfb33e6c0000be79d98ef8d89e26503
nix build "$proto#default" --no-write-lock-file --override-input nixpkgs "github:NixOS/nixpkgs/$moved" \
  --out-link /work/gate/moved 2> /dev/null
printf 'locked:  %s\n  prek %s\n' "$(readlink .pixi/envs/default)" "$(readlink -f .pixi/envs/default/bin/prek)"
printf 'moved:   %s\n  prek %s\n' "$(readlink /work/gate/moved)" "$(readlink -f /work/gate/moved/bin/prek)"
