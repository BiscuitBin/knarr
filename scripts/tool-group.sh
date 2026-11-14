#!/bin/sh
# The optional tool groups: cluster (kind, kubectl and kwokctl, Decision 0007)
# and audit (grype, Decision 0014). `just initialize` installs the default
# group only; these stay optional, as pixi's environments are (Decision 0017,
# "Layout: tool groups, out-links and PATH"). Where a group lives comes from
# scripts/tool-dirs.sh, which also refuses an unknown KNARR_TOOLS.
#
#   install <group>  `just cluster-install` and `just audit-install` (network).
#                    pixi installs the locked environment; Nix builds the
#                    flake's group into its gitignored out-link with
#                    --no-update-lock-file, which refuses a lock that disagrees
#                    with flake.nix rather than rewriting it.
#   check <group>    The guard of every cluster and audit recipe: exit 0
#                    silently when the group holds each of its tools, else
#                    exit 2 naming the install recipe. It looks in the group
#                    only. A CI runner ships its own kind and kubectl, which
#                    PATH would find after the tool directories, so a command
#                    lookup would pass with the wrong versions.
#
# Under pixi, kwokctl is a tools.txt download `just initialize` installs, so
# the pixi cluster environment is checked for kind and kubectl only.
# Usage: sh scripts/tool-group.sh install|check cluster|audit
set -eu
usage() {
  printf '%s\n' 'usage: tool-group.sh install|check cluster|audit' >&2
  exit 2
}
[ "$#" -eq 2 ] || usage
verb=$1
group=$2
case $verb in install | check) ;; *) usage ;; esac
case $group in cluster | audit) ;; *) usage ;; esac

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
backend=$(sh "$root/scripts/tool-dirs.sh" backend)
prefix=$(sh "$root/scripts/tool-dirs.sh" prefix "$group" "$root")

case $verb in
  check)
    case $backend:$group in
      pixi:cluster) members='kind kubectl' ;;
      nix:cluster) members='kind kubectl kwokctl' ;;
      *:audit) members=grype ;;
    esac
    for tool in $members; do
      [ -f "$prefix/bin/$tool" ] && [ -x "$prefix/bin/$tool" ] || {
        printf 'the %s %s group is not installed; run just %s-install\n' "$backend" "$group" "$group" >&2
        exit 2
      }
    done
    ;;
  install)
    cd "$root"
    case $backend in
      pixi)
        command -v pixi > /dev/null ||
          { printf '%s\n' 'pixi is not installed; see CONTRIBUTING.md, Getting started' >&2; exit 2; }
        pixi install --locked -e "$group"
        ;;
      nix)
        command -v nix > /dev/null ||
          { printf '%s\n' 'Nix is not installed; see Decision 0017, Host prerequisites' >&2; exit 2; }
        mkdir -p "${prefix%/*}"
        nix build --no-update-lock-file --out-link "$prefix" ".#$group"
        ;;
    esac
    ;;
esac
