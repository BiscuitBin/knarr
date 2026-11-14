#!/bin/sh
# Install the read-only prek config as the pre-commit hook, from the primary
# checkout only. Every linked worktree shares the primary checkout's .git/hooks,
# and prek writes a shim naming an absolute path into whichever worktree ran it,
# so a hook installed from a linked worktree runs that worktree's prek for
# commits made anywhere, and fails every commit once the worktree is deleted.
# The test is the one git uses: in a linked worktree the git directory and the
# common directory differ. A linked worktree still reaches a green `just check`
# without hooks; the gate does not depend on them.
#
# The path prek writes is the resolved path of the prek that ran. Under Nix
# that is a store path: after a lock move the hook keeps running the old prek,
# and once that path is garbage-collected every commit fails (Decision 0017,
# "The prek hook"). So `just initialize` passes the out-link's prek as <prek>,
# and the hook's PREK line is rewritten to name it, which follows every
# `just initialize` and keeps no store path in the hook.
# Usage: sh scripts/install-hooks.sh [<prek>]
set -eu
git_dir=$(git rev-parse --path-format=absolute --git-dir)
common_dir=$(git rev-parse --path-format=absolute --git-common-dir)
if [ "$git_dir" != "$common_dir" ]; then
  printf '%s\n' 'This is a linked worktree: skipping hook installation.' >&2
  printf '%s\n' 'Hooks are shared by every worktree; run just initialize once from the primary checkout to install them.' >&2
  exit 0
fi
prek install --overwrite --hook-type pre-commit
[ "$#" -eq 1 ] || exit 0

hook=$(git rev-parse --path-format=absolute --git-path hooks/pre-commit)
[ "$(grep -c '^PREK=' "$hook")" = 1 ] ||
  { printf '%s\n' "install-hooks: $hook has no single PREK= line to point at $1" >&2; exit 1; }
rewritten=$(sed "s|^PREK=.*|PREK=\"$1\"|" "$hook")
# Written through the existing file, so the hook keeps the mode prek gave it.
printf '%s\n' "$rewritten" > "$hook"
if grep -q '/nix/store/' "$hook"; then
  printf '%s\n' "install-hooks: $hook still names a store path" >&2
  exit 1
fi
