#!/bin/sh
# The one owner of a checkout's tool directories (Decision 0017, "Layout: tool
# groups, out-links and PATH"), and the only reader of KNARR_TOOLS. The
# Justfile, with-env.sh, initialize.sh, the ripsecrets wrapper and
# scripts/checks/_tools.py all ask here, so none of them spells out a directory
# or a tool's path, or reads the selector.
#
# KNARR_TOOLS=pixi|nix selects a backend for a whole command, never a mix
# (Decision 0017, "The selector while both backends exist"). Unset or empty, it
# is the tracked default below.
#
#   backend       The selected backend's name.
#   dirs          The tool directories, joined with colons in PATH order: the
#                 default, cluster and audit groups' bin directories, then, for
#                 pixi only, the tools.txt downloads. The default group comes
#                 first, so gleam and the shared tools always resolve from it;
#                 the cluster and audit tools resolve only once each group is
#                 installed. This verb only builds a string. It uses shell
#                 builtins alone and lists a directory whether or not it exists,
#                 because the Justfile evaluates it before `just initialize`
#                 has ever run. For the same reason it never refuses: given an
#                 unknown KNARR_TOOLS it prints the tracked default's
#                 directories and exits 0, so `just --list` still works.
#   tool <name>   The absolute path of <name> in the first of those directories
#                 that holds it as an executable file. A copy elsewhere on PATH
#                 is never used: without one in the directories this prints
#                 nothing and exits 2, and the caller says what to run.
#   module <name> The Node module <name> beside the default group's bin. Under
#                 Nix bin/markdownlint-cli2 is a wrapper script, so the docs
#                 checker finds markdown-it from the module, not from bin.
#   prefix <group>  Where a group is installed: pixi's environment directory,
#                 or the gitignored Nix out-link `just initialize` builds.
#
# Every verb but dirs refuses an unknown KNARR_TOOLS with exit 2 and a message
# naming the variable and its two values.
#
# <checkout> is an absolute path, used as written. It defaults to the checkout
# this script is in.
# Usage: sh scripts/tool-dirs.sh backend
#        sh scripts/tool-dirs.sh dirs [<checkout>]
#        sh scripts/tool-dirs.sh tool|module <name> [<checkout>]
#        sh scripts/tool-dirs.sh prefix default|cluster|audit [<checkout>]
set -eu
usage() {
  printf '%s\n' 'usage: tool-dirs.sh backend | dirs [<checkout>] | tool <name> [<checkout>] | module <name> [<checkout>] | prefix default|cluster|audit [<checkout>]' >&2
  exit 2
}

# The tracked default: pixi until ticket 10 makes it nix.
default=pixi

[ "$#" -ge 1 ] || usage
verb=$1
shift
case $verb in
  backend) [ "$#" -eq 0 ] || usage ;;
  dirs) [ "$#" -le 1 ] || usage ;;
  tool | module | prefix)
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
    name=$1
    shift
    case $name in '' | */*) usage ;; esac
    case $verb:$name in prefix:default | prefix:cluster | prefix:audit | tool:* | module:*) ;; *) usage ;; esac
    ;;
  *) usage ;;
esac

backend=${KNARR_TOOLS:-$default}
case $backend in
  pixi | nix) ;;
  *)
    if [ "$verb" != dirs ]; then
      printf "KNARR_TOOLS is '%s'; set it to pixi or nix, or leave it unset for %s\n" "$backend" "$default" >&2
      exit 2
    fi
    backend=$default
    ;;
esac
if [ "$verb" = backend ]; then
  printf '%s\n' "$backend"
  exit 0
fi

# dirname is a command, so this script's directory comes from parameter
# expansion and the checkout from the cd and pwd builtins.
if [ "$#" -eq 0 ]; then
  case $0 in */*) here=${0%/*} ;; *) here=. ;; esac
  root=$(CDPATH='' cd -- "$here/.." && pwd -P)
else
  case $1 in /*) root=$1 ;; *) usage ;; esac
fi

# The only list of the directories. Every verb reads it.
case $backend in
  pixi)
    groups=$root/.pixi/envs
    tool_dirs=$groups/default/bin:$groups/cluster/bin:$groups/audit/bin:$root/.tools/bin
    ;;
  nix)
    groups=$root/.nix
    tool_dirs=$groups/default/bin:$groups/cluster/bin:$groups/audit/bin
    ;;
esac

case $verb in
  dirs) printf '%s\n' "$tool_dirs" ;;
  prefix) printf '%s\n' "$groups/$name" ;;
  module)
    [ -d "$groups/default/lib/node_modules/$name" ] || exit 2
    printf '%s\n' "$groups/default/lib/node_modules/$name"
    ;;
  tool)
    rest=$tool_dirs:
    while [ -n "$rest" ]; do
      dir=${rest%%:*}
      rest=${rest#*:}
      if [ -f "$dir/$name" ] && [ -x "$dir/$name" ]; then
        printf '%s\n' "$dir/$name"
        exit 0
      fi
    done
    exit 2
    ;;
esac
