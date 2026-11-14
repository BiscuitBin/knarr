#!/bin/sh
# The one owner of a checkout's tool directories (Decision 0003, "How recipes
# reach the environment"). The Justfile, with-env.sh, initialize.sh, the
# ripsecrets wrapper and scripts/checks/_tools.py all ask here, so none of them
# spells out a directory or a tool's path.
#
#   dirs          The tool directories, joined with colons in PATH order: the
#                 default, cluster and audit environments, then the tools.txt
#                 downloads. The default environment comes first, so gleam and
#                 the shared tools always resolve from it; the cluster and
#                 audit tools resolve only once each environment is installed.
#                 This verb only builds a string. It uses shell builtins alone
#                 and lists a directory whether or not it exists, because the
#                 Justfile evaluates it before `just initialize` has ever run.
#   tool <name>   The absolute path of <name> in the first of those directories
#                 that holds it as an executable file. A copy elsewhere on PATH
#                 is never used: without one in the directories this prints
#                 nothing and exits 2, and the caller says what to run.
#
# <checkout> is an absolute path, used as written. It defaults to the checkout
# this script is in.
# Usage: sh scripts/tool-dirs.sh dirs [<checkout>]
#        sh scripts/tool-dirs.sh tool <name> [<checkout>]
set -eu
usage() { printf '%s\n' 'usage: tool-dirs.sh dirs [<checkout>] | tool <name> [<checkout>]' >&2; exit 2; }

[ "$#" -ge 1 ] || usage
verb=$1
shift
case $verb in
  dirs) [ "$#" -le 1 ] || usage ;;
  tool)
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
    name=$1
    shift
    case $name in '' | */*) usage ;; esac
    ;;
  *) usage ;;
esac

# dirname is a command, so this script's directory comes from parameter
# expansion and the checkout from the cd and pwd builtins.
if [ "$#" -eq 0 ]; then
  case $0 in */*) here=${0%/*} ;; *) here=. ;; esac
  root=$(CDPATH='' cd -- "$here/.." && pwd -P)
else
  case $1 in /*) root=$1 ;; *) usage ;; esac
fi

# The only list of the directories. Both verbs read it.
tool_dirs=$root/.pixi/envs/default/bin:$root/.pixi/envs/cluster/bin:$root/.pixi/envs/audit/bin:$root/.tools/bin

case $verb in
  dirs) printf '%s\n' "$tool_dirs" ;;
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
