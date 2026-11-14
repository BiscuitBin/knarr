#!/bin/sh
# Ticket 01 evidence: flakes and git. What a flake at the repository root sees,
# what each evaluation copies to the store, and what happens in a linked
# worktree, in a subdirectory, and in a directory with no .git.
# The repository is a clone of the bundle the host made from this branch
# (git bundle create ai_tmp/knarr.bundle HEAD 01-nix-container-spike).
# Usage (host): sh nix.sh sh /evidence/git.sh > git.txt
# lib.sh sets rev, systems and flake, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
# SC2218 is a false positive of shellcheck 0.11.0 here: every function below
# is defined before its first call.
# shellcheck disable=SC2218
# shellcheck source=lib.sh disable=SC1091
. /evidence/lib.sh
printf 'date: %s\n%s on %s, git %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(nix config show system)" "$(git --version | cut -d' ' -f3)"
git config --global user.name 'ticket 01' && git config --global user.email ticket01@example.invalid
git config --global advice.detachedHead false && git config --global init.defaultBranch main

show() { # command...: run it, print exit status and the first lines it wrote
  status=0
  "$@" > /work/git/.out 2>&1 || status=$?
  printf '$ %s\n  exit %s\n' "$*" "$status"
  grep -v '^ *$' /work/git/.out | head -n "${lines:-4}" | cut -c1-230 | sed 's/^/  /'
}
timed() { # command...
  start=$(date +%s.%N)
  "$@" > /dev/null 2>&1
  echo "$(date +%s.%N) $start" | awk '{ printf "%.2fs", $1 - $2 }'
}
source_path() { nix flake metadata --json 2> /dev/null | jq -r .path; }
stored() { find /nix/store -maxdepth 1 | wc -l; }
metadata() { # the lines of `nix flake metadata` that say where the flake came from
  nix flake metadata "$@" 2> /dev/null | sed 's/\x1b\[[0-9;]*m//g' |
    grep -E '^(Resolved URL|Locked URL|Path|Revision)' | sed 's/^/  /'
}
exists() { if [ -e "$1" ]; then echo "$2"; else echo "$3"; fi; }

rm -rf /work/git
mkdir -p /work/git
git clone --quiet --branch 01-nix-container-spike /bundle/knarr.bundle /work/git/clone
cd /work/git/clone || exit 1
printf 'clone: %s tracked files, %s\n' "$(git ls-files | wc -l)" "$(git ls-files -z | du -ch --files0-from=- | tail -n 1 | cut -f1)"

printf '\n== 1. An untracked flake.nix is invisible\n'
cp "$flake/flake.nix" "$flake/flake.lock" .
git status --short
show nix eval .#held.gleam
printf '\n== 2. Staged is enough; it need not be committed\n'
git add flake.nix flake.lock
git status --short
show nix eval .#held.gleam

printf '\n== 3. A file the flake reads is invisible until it is tracked too\n'
sed -i 's/      inherit held;/      inherit held;\n      probe = builtins.pathExists .\/probe.txt;/' flake.nix
echo probe > probe.txt
lines=2 show nix eval .#probe
git add --intent-to-add probe.txt
lines=2 show nix eval .#probe
git rm --quiet --cached probe.txt
rm probe.txt
cp "$flake/flake.nix" . && git add flake.nix

printf '\n== 4. What an evaluation copies to the store\n'
mkdir -p build && head -c 20000000 /dev/urandom > build/ignored-junk.bin
head -c 5000000 /dev/urandom > untracked-junk.bin
before=$(stored)
copied=$(source_path)
printf 'nix flake metadata names the source %s: %s\n' "$copied" "$(exists "$copied" 'it is in the store' 'no such path in the store')"
nix eval .#held.gleam > /dev/null 2>&1
nix eval --raw .#packages.aarch64-linux.default.outPath > /dev/null 2>&1
printf 'store paths before: %s, after metadata and two evaluations: %s\n' "$before" "$(stored)"
echo '# an edit to a tracked file' >> README.md
nix eval --raw .#packages.aarch64-linux.default.outPath > /dev/null 2>&1
printf 'after editing one tracked file and evaluating again: %s\n' "$(stored)"
printf 'A flake that uses its own source in a derivation does copy it; this output only asks for it:\n'
# shellcheck disable=SC2016 # Nix's ${self}, not shell's
sed -i 's/      inherit held;/      inherit held;\n      probe = "${self}";/' flake.nix
copied=$(nix eval --raw .#probe 2> /dev/null)
printf '  %s: %s files, %s\n' "$copied" "$(find "$copied" -type f | wc -l)" "$(du -sh "$copied" | cut -f1)"
printf '  (the clone has %s tracked files, with the two staged flake files)\n' "$(git ls-files | wc -l)"
printf '  build/ignored-junk.bin (ignored, 20 MB): %s; untracked-junk.bin (untracked, 5 MB): %s; .git: %s\n' \
  "$(exists "$copied/build/ignored-junk.bin" copied absent)" \
  "$(exists "$copied/untracked-junk.bin" copied absent)" "$(exists "$copied/.git" copied absent)"
echo '# another edit' >> README.md
again=$(nix eval --raw .#probe 2> /dev/null)
printf '  after another edit: %s, a second copy; store paths now %s\n' "$again" "$(stored)"
git checkout --quiet README.md
cp "$flake/flake.nix" . && git add flake.nix
rm -f untracked-junk.bin

printf '\n== 5. Evaluation time: a dirty tree against a committed one\n'
out='.#packages.aarch64-linux.default.outPath'
printf 'dirty (flake staged, not committed): first %s, again %s, again %s\n' \
  "$(timed nix eval --raw $out)" "$(timed nix eval --raw $out)" "$(timed nix eval --raw $out)"
lines=1 show nix eval --raw $out
git commit --quiet -m 'scratch: the prototype flake at the root'
printf 'committed (clean tree): first %s, again %s, again %s\n' \
  "$(timed nix eval --raw $out)" "$(timed nix eval --raw $out)" "$(timed nix eval --raw $out)"
lines=1 show nix eval --raw $out
printf 'the lock check, clean tree: %s\n' "$(timed nix flake lock --no-update-lock-file --offline)"
metadata

printf '\n== 6. A linked worktree\n'
git worktree add --quiet /work/git/linked -b probe-linked
cd /work/git/linked || exit 1
printf '.git is a %s: %s\n' "$(stat -c %F .git)" "$(cat .git)"
show nix eval .#held.gleam
metadata
show nix build .#runtime --out-link /work/git/linked/.nix-probe/runtime
printf 'out-link: %s\n' "$(readlink .nix-probe/runtime)"
git status --short
echo '# an edit in the linked worktree' >> README.md
show nix eval .#held.gleam
show nix flake lock --no-update-lock-file --offline
git checkout --quiet README.md
rm -rf .nix-probe

printf '\n== 7. A worktree whose .git points at a path that is not there (a bind-mounted linked worktree)\n'
cp -a /work/git/linked /work/git/orphan
cd /work/git/orphan || exit 1
echo 'gitdir: /Users/somebody/repo/.git/worktrees/linked' > .git
show git status --short
lines=6 show nix eval .#held.gleam

printf '\n== 8. The flake in a subdirectory of the repository (where this prototype is tracked)\n'
cd /work/git/clone || exit 1
metadata ./.scratch/nix-migration/evidence/01
show nix eval ./.scratch/nix-migration/evidence/01#held.gleam

printf '\n== 9. No .git at all (a Docker build context)\n'
mkdir -p /work/git/plain
git archive HEAD | tar -x -C /work/git/plain
cd /work/git/plain || exit 1
head -c 20000000 /dev/urandom > junk.bin
show nix eval .#held.gleam
metadata
copied=$(source_path)
printf '  %s files, %s; junk.bin (20 MB, never tracked): %s\n' "$(find "$copied" -type f | wc -l)" \
  "$(du -sh "$copied" | cut -f1)" "$(exists "$copied/junk.bin" copied absent)"
before=$(stored)
echo edit >> README.md
nix eval .#held.gleam > /dev/null 2>&1
printf '  after one edit and one evaluation: %s more store path, %s\n' "$(($(stored) - before))" "$(du -sh "$(source_path)" | cut -f1)"
mkdir -p /work/git/context && cp flake.nix flake.lock /work/git/context/
cd /work/git/context || exit 1
show nix eval .#held.gleam
printf '  a context of flake.nix and flake.lock alone: %s files copied\n' "$(find "$(source_path)" -type f | wc -l)"
