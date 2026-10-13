#!/bin/sh
# Ticket 35 evidence, 03's primary hook: the pre-commit hook installed in the
# primary checkout runs that checkout's prek and refuses an unformatted Gleam
# file. Run it from the maintainer's primary checkout, with their authorization.
# It refuses to start, exit 2 with nothing touched, unless this is a primary
# checkout whose hook is executable and names <checkout>/.pixi/envs/default/bin/prek,
# with a clean index, no unstaged change to a tracked file and no
# src/hook_probe.gleam. It then stages that file unformatted and commits it with
# the bare environment git gives hooks. A trap unstages and removes the file on
# any exit, and undoes the commit if the hook let it through; it resets HEAD
# only when HEAD is the probe's own commit on top of the recorded one. Exits 0
# only if gleam format refused the commit and HEAD, the index and the status
# are as they were.
# Usage: sh primary-hook.sh > <outside-path>/primary-hook.txt 2>&1
set -eu
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
refuse() { printf 'FAIL: %s; nothing was touched\n' "$*"; exit 2; }
probe=src/hook_probe.gleam
msg='hook probe (must be refused)'

root=$(git rev-parse --show-toplevel) || refuse 'not inside a git checkout'
cd "$root"
redact() { awk -v r="$root" '{ while ((i = index($0, r)) > 0) $0 = substr($0, 1, i - 1) "<checkout>" substr($0, i + length(r)); print }'; }
head=$(git rev-parse HEAD)
printf 'date: %s\nhost: %s\nbare git: %s\ncheckout: <checkout> at %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(uname -sm)" "$(env -i PATH=/usr/bin:/bin git --version)" "$head"

[ "$(git rev-parse --path-format=absolute --git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ] ||
  refuse 'this is a linked worktree; run from the primary checkout'
echo 'ok   <checkout> is a primary checkout'
hook=$(git rev-parse --path-format=absolute --git-path hooks/pre-commit)
shown=$(printf '%s\n' "$hook" | redact)
[ -x "$hook" ] || refuse "no executable hook at $shown"
printf 'ok   the hook %s is executable\n' "$shown"
# prek's shim writes PREK="<path>"; its indented fallback line is not matched.
prek=$(sed -n 's/^PREK=//p' "$hook" | tr -d '"')
want=$root/.pixi/envs/default/bin/prek
[ "$prek" = "$want" ] || refuse "the hook runs PREK=$(printf '%s\n' "$prek" | redact), not <checkout>/.pixi/envs/default/bin/prek"
[ -x "$prek" ] || refuse 'the hook names <checkout>/.pixi/envs/default/bin/prek, which is not executable'
echo 'ok   the hook runs PREK="<checkout>/.pixi/envs/default/bin/prek", which is executable'
git diff --cached --quiet || refuse 'the index has staged changes'
# prek stashes unstaged changes around a hook run; with none it has nothing to stash.
git diff --quiet || refuse 'a tracked file has unstaged changes'
[ ! -e "$probe" ] || refuse "$probe already exists"
echo "ok   the index and the tracked files are clean, and $probe does not exist"
before=$(git status --porcelain --untracked-files=all)

# Undo only what the probe did: its own commit on top of the recorded HEAD, the
# staged file and the file. Any other HEAD is left alone and fails the run.
cleanup() {
  now=$(git rev-parse HEAD)
  if [ "$now" != "$head" ]; then
    if [ "$(git rev-parse -q --verify 'HEAD^')" = "$head" ] && [ "$(git log -1 --format=%s)" = "$msg" ]; then
      if git reset -q --soft "$head"; then
        printf 'ok   undid the probe commit %s\n' "$now"
      else
        printf 'FAIL: could not reset HEAD to %s\n' "$head"
      fi
    else
      printf 'FAIL: HEAD moved to %s, which is not the probe commit; HEAD, the index and %s were left as they are\n' "$now" "$probe"
      exit 1
    fi
  fi
  git rm --cached -q --ignore-unmatch -- "$probe" || printf 'FAIL: could not unstage %s\n' "$probe"
  rm -f -- "$probe"
}
restored() {
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "HEAD is $(git rev-parse HEAD), not $head"
  printf 'ok   HEAD is %s, as it was\n' "$head"
  git diff --cached --quiet || fail 'the index is not clean'
  echo 'ok   the index is clean'
  [ ! -e "$probe" ] || fail "$probe is still there"
  echo "ok   $probe is gone"
  [ "$(git status --porcelain --untracked-files=all)" = "$before" ] || { git status --short; fail 'git status changed'; }
  echo 'ok   git status is as it was'
}
# The EXIT trap runs once; an exit inside it does not run it again.
trap 'cleanup; restored' EXIT
trap 'echo "FAIL: interrupted"; exit 130' INT
trap 'echo "FAIL: terminated"; exit 143' TERM

echo; echo "== commit an unformatted $probe with a bare environment"
printf 'pub fn probe( ) { Nil }\n' > "$probe"
git add -- "$probe"
show() { if [ -n "$out" ]; then printf '%s\n' "$out" | redact | sed '/./s/^/     /'; else echo '     (no output)'; fi; }
if out=$(env -i HOME="$HOME" PATH=/usr/bin:/bin git -c commit.gpgsign=false commit -m "$msg" 2>&1); then
  show
  fail 'the hook accepted the probe; undoing its commit'
fi
show
trap - EXIT INT TERM
cleanup
restored
printf '%s\n' "$out" | grep -q 'gleam format check.*Failed' || fail 'the commit was refused, but not by gleam format'
printf '%s\n' "$out" | grep -q 'hook_probe\.gleam' || fail 'gleam format refused the commit without naming the probe'
echo "ok   gleam format refused the commit, naming $probe"

echo; echo 'primary-hook.sh: the hook refused the probe'
