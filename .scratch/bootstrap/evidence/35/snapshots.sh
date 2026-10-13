#!/bin/sh
# Ticket 35 evidence: the three snapshot commands ticket 08 only dry-ran, run
# for real in a disposable clone of the committed branch. `just
# snapshots-review` goes through birdie's interactive review step on a pending
# change, answered "a" through a pseudo-terminal (review_pty.py); `just birdie
# reject` removes a pending change; `just birdie stale delete` removes an
# orphan. Each case asserts the accepted file's bytes by sha256, the pending
# file's removal and a clean worktree, and the run ends by checking that this
# checkout and the system TMPDIR were untouched.
# As in 08's birdie-check.sh, the clone borrows this checkout's .pixi and
# .tools (symlinked) and a copy of build/packages, and every just command runs
# with the network denied: a fresh network namespace (unshare -rn) whose only
# interface, lo, is brought up for knarr's loopback tests. Linux only. Writes
# only to the work directory. Exits non-zero on any unexpected result.
# Usage: sh snapshots.sh <empty-work-dir> > snapshots.txt 2>&1
set -eu
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: snapshots.sh <empty-work-dir>}
mkdir -p "$work"; work=$(cd "$work" && pwd)
[ -z "$(ls -A "$work")" ] || fail "work dir $work is not empty"
[ "$(uname -s)" = Linux ] || fail "the network-denied runner is Linux's; this is $(uname -s)"
source=$(git -C "$here" rev-parse --show-toplevel)
branch=$(git -C "$source" rev-parse --abbrev-ref HEAD)
clone=$work/clone
just=$clone/.pixi/envs/default/bin/just
lo_up='
import fcntl, os, socket, struct, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
req = struct.pack("16sH14x", b"lo", 0)
flags = struct.unpack("16sH14x", fcntl.ioctl(s, 0x8913, req))[1]
fcntl.ioctl(s, 0x8914, struct.pack("16sH14x", b"lo", flags | 0x1))
os.execvp(sys.argv[1], sys.argv[1:])
'
offline() { unshare -rn python3 -c "$lo_up" "$@"; }
esc=$(printf '\033')
plain() { sed -e "s/${esc}\[[0-9;?]*[A-Za-z]//g" -e "s/${esc}[@-~]//g"; }
show() { plain < "$1" | grep -E "$2" | sed 's/^/     /'; }
run() { # run <log> <just argument...>: output to <work>/<log>, exit status in rc
  log=$work/$1; shift
  set +e; offline "$just" "$@" > "$log" 2>&1; rc=$?; set -e
}
porcelain() { git status --porcelain --untracked-files=all; }
clean() { [ -z "$(porcelain)" ] || { porcelain; fail "$1: worktree not clean"; }; }
sha() { sha256sum "$1" | cut -c1-64; }
tree_hashes() { (cd "$1" && find . -type f -name '*.accepted' | sort | xargs sha256sum); }

snapshots=test/birdie_snapshots
accepted=$snapshots/version_request_sent_by_fetch_version.accepted
new=$snapshots/version_request_sent_by_fetch_version.new

# What must not change: this checkout's status, snapshots and referenced list,
# and the shared list in the system's temporary directory.
git -C "$source" status --porcelain --untracked-files=all > "$work/source-status.before"
tree_hashes "$source/$snapshots" > "$work/source-snapshots.before"
touch "$work/started"
untouched() { [ -z "$(find "$1" -newer "$work/started" 2> /dev/null)" ] || fail "$1 changed during the run"; }

git clone -q --branch "$branch" --single-branch "$source" "$clone"
cd "$clone"
printf 'date: %s\nhost: %s\ncommit: %s (%s)\n\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(uname -sm)" \
  "$(git rev-parse HEAD)" "$branch"

echo '== setup: the clone borrows this checkout'"'"'s tools'
[ -x "$source/.pixi/envs/default/bin/just" ] || fail "$source has no pixi environment; run just initialize there"
[ -d "$source/build/packages" ] || fail "$source has no build/packages; run just initialize there"
ln -s "$source/.pixi" .pixi
ln -s "$source/.tools" .tools
mkdir build && cp -R "$source/build/packages" build/packages
printf '%s\n' .pixi .tools >> .git/info/exclude
clean 'after setup'
echo 'ok   .pixi and .tools symlinked, build/packages copied; the worktree is clean'
if offline curl -fsS --max-time 10 -o /dev/null https://github.com > /dev/null 2>&1; then fail 'curl reached github.com inside the namespace'; fi
echo 'ok   curl https://github.com fails inside the namespace every just command runs in'
committed=$(git show "HEAD:$accepted" | sha256sum | cut -c1-64)
printf 'ok   committed %s: sha256 %s\n' "$accepted" "$committed"

echo; echo '== just snapshots-review, answered "a" at the interactive prompt'
sed 's/^accept: application\/json$/accept: application\/jsom/' "$accepted" > "$work/edited" && cp "$work/edited" "$accepted"
edited=$(sha "$accepted")
[ "$edited" != "$committed" ] || fail 'the edit did not change the accepted file'
printf 'ok   one character of the accepted file changed: sha256 %s\n' "$edited"
set +e
python3 "$here/review_pty.py" "$work/review.log" a unshare -rn python3 -c "$lo_up" "$just" snapshots-review > "$work/review.status"
rc=$?
set -e
[ "$rc" -eq 0 ] || { cat "$work/review.log"; fail "just snapshots-review exited $rc"; }
sed 's/^/     /' "$work/review.status"
grep -q 'Reviewing 1st out of 1' "$work/review.log" || { cat "$work/review.log"; fail 'no review prompt'; }
grep -q 'Reviewed one snapshot' "$work/review.log" || { cat "$work/review.log"; fail 'the review did not finish'; }
echo 'ok   the session as the terminal showed it, from the recipe'"'"'s test run to the review:'
grep -E '^==> |error: recipe|title: |accept: application|Reviewing|^ +a accept|^> |Reviewed' "$work/review.log" | sed 's/^/     /'
[ "$(sha "$accepted")" = "$committed" ] || fail "the accepted file is $(sha "$accepted"), not the committed bytes"
[ ! -e "$new" ] || fail 'a .new remains after the review'
clean 'after the review'
printf 'ok   accepting wrote the committed bytes back (sha256 %s), removed the .new and left the worktree clean\n' "$committed"

echo; echo '== just birdie reject, on a pending change'
cp "$work/edited" "$accepted"
run reject-test.log test
[ "$rc" -ne 0 ] || fail 'just test passed with a changed snapshot'
[ -f "$new" ] || fail 'just test left no .new'
pending=$(sha "$new")
# A .new lacks the file: and test_name: lines that accepting writes.
picture=$(git show "HEAD:$accepted" | grep -v -E '^(file|test_name): ' | sha256sum | cut -c1-64)
[ "$pending" = "$picture" ] || fail "the pending picture $pending is not the committed one without its file: and test_name: lines"
printf 'ok   just test exit %s left %s, sha256 %s:\n     the committed file without its file: and test_name: lines, which accepting adds\n' "$rc" "$new" "$pending"
run reject.log birdie reject
[ "$rc" -eq 0 ] || { plain < "$work/reject.log"; fail "just birdie reject exited $rc"; }
show "$work/reject.log" 'Rejecting'
[ ! -e "$new" ] || fail 'the .new survived the reject'
[ "$(sha "$accepted")" = "$edited" ] || fail 'reject changed the accepted file'
[ "$(porcelain)" = " M $accepted" ] || { porcelain; fail 'Git sees more than the deliberate edit'; }
printf 'ok   the .new is gone; the accepted file keeps the edited bytes (sha256 %s); Git sees only the edit\n' "$edited"
git checkout -q -- "$accepted"
clean 'after restoring the accepted file'

echo; echo '== just birdie stale delete, on an orphan'
printf '%s\n' '---' 'version: 2.0.2' 'title: orphan' '---' 'no test refers to this' > "$snapshots/orphan.accepted"
tree_hashes "$snapshots" | grep -v ' ./orphan.accepted$' > "$work/others.before"
run stale-test.log test
[ "$rc" -eq 0 ] || { plain < "$work/stale-test.log"; fail 'just test failed with an orphan'; }
echo 'ok   just test passes with the orphan present'
run stale-delete.log birdie stale delete
[ "$rc" -eq 0 ] || { plain < "$work/stale-delete.log"; fail "just birdie stale delete exited $rc"; }
show "$work/stale-delete.log" '^Checking stale|Done!'
[ ! -e "$snapshots/orphan.accepted" ] || fail 'the orphan survived stale delete'
tree_hashes "$snapshots" > "$work/others.after"
cmp -s "$work/others.before" "$work/others.after" || { diff "$work/others.before" "$work/others.after"; fail 'stale delete changed another snapshot'; }
clean 'after stale delete'
printf 'ok   the orphan is gone; the other %s accepted snapshots hash as before; the worktree is clean\n' "$(wc -l < "$work/others.after" | tr -d ' ')"
run final-check.log snapshots-check
[ "$rc" -eq 0 ] || { plain < "$work/final-check.log"; fail 'snapshots-check failed at the end'; }
echo 'ok   just snapshots-check passes: nothing pending, nothing stale'

echo; echo '== isolation'
referenced=build/birdie/knarr_referenced.txt
[ -f "$referenced" ] || fail "no $referenced"
printf 'ok   birdie kept its referenced list in this clone, %s\n' "$referenced"
untouched "$source/build/birdie/knarr_referenced.txt"
untouched "${TMPDIR:-/tmp}/knarr_referenced.txt"
echo 'ok   neither the source checkout'"'"'s build/birdie list nor the one in the system TMPDIR changed'
git -C "$source" status --porcelain --untracked-files=all | cmp -s - "$work/source-status.before" || fail 'the source checkout status changed'
tree_hashes "$source/$snapshots" | cmp -s - "$work/source-snapshots.before" || fail 'the source checkout snapshots changed'
echo 'ok   the source checkout'"'"'s status and accepted snapshots are unchanged'

echo; echo 'snapshots.sh: all cases passed'
