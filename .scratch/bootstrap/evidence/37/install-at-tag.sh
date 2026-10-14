#!/bin/sh
# Ticket 37 evidence, offline, from pull request #35's review: an install at a
# release's own tag. The pin lands on main after the run has pushed, so at the
# tag deploy/release still holds the previous digest, or for v0.1.0 the
# all-zero placeholder. An install checks out the tag, runs
# `just release-pin <digest from the run>` there, then `kubectl apply -k`.
# This does the same on a copy: git archive puts the tag's deploy/ and
# scripts/release/ in a temporary directory, the overlay is rendered as tagged,
# the archived pin-digest.sh pins the copy, and the overlay is rendered again,
# with the cluster environment's kustomize and with kubectl's bundled one. The
# worktree's overlay is checksummed before and after. The local tag is checked
# against the object run.txt read from the remote first: the ruleset locks the
# remote tag, not a clone's. Needs the cluster environment (just
# cluster-install). Exits non-zero on any unexpected result.
# Usage: sh install-at-tag.sh <sha256:digest> <commit> > install-at-tag.txt 2>&1
set -eu
usage='usage: install-at-tag.sh <sha256:digest> <commit>'
digest=${1:?$usage}
commit=${2:?$usage}
tag=v0.1.0
tag_object=ab3a17c57918bfa55e9611e8efc912d884c548b9 # run.txt: the remote's v0.1.0
zeros=sha256:0000000000000000000000000000000000000000000000000000000000000000
image=ghcr.io/steven-cutting/knarr
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(git -C "$here" rev-parse --show-toplevel)
bin=$root/.pixi/envs/cluster/bin
overlay=deploy/release/kustomization.yaml
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { # label actual wanted
  [ "$2" = "$3" ] || fail "$1: read '$2', wanted '$3'"
  printf 'ok   %s: %s\n' "$1" "${2:-(empty)}"
}
{ [ -x "$bin/kustomize" ] && [ -x "$bin/kubectl" ]; } || fail "no kustomize or kubectl in $bin: run just cluster-install"
PATH=$bin:$PATH
export PATH
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
images() { # render command...: the image lines the render names
  out=$("$@") || fail "$* failed"
  printf '%s\n' "$out" | sed -nE 's/^ *(- )?image: //p'
}
sum() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
printf 'date: %s\ntag: %s\ndigest: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$digest"
v=$(kustomize version) || fail 'kustomize version failed'
printf 'kustomize: %s\n' "$v"
v=$(kubectl version --client) || fail 'kubectl version failed'
printf 'kubectl: %s\n' "$(printf '%s\n' "$v" | paste -s -d ' ' -)"
before=$(sum "$root/$overlay")
printf "the worktree's %s: sha256 %s\n" "$overlay" "$before"

echo; echo "== the local $tag"
v=$(git -C "$root" cat-file -t "refs/tags/$tag") || fail "no local $tag"
expect "git cat-file -t $tag" "$v" tag
v=$(git -C "$root" rev-parse "refs/tags/$tag") || fail "no local $tag"
expect "$tag object, as run.txt read it on the remote" "$v" "$tag_object"
v=$(git -C "$root" rev-parse "refs/tags/$tag^{commit}") || fail "no local $tag"
expect "$tag^{commit}" "$v" "$commit"
# The archived pin-digest.sh is the one that runs, so a later edit to the
# worktree's copy is reported, not refused.
v=$(git -C "$root" rev-parse "refs/tags/$tag:scripts/release/pin-digest.sh") || fail "no pin-digest.sh at $tag"
w=$(git -C "$root" hash-object scripts/release/pin-digest.sh) || fail 'hashing pin-digest.sh failed'
printf 'info pin-digest.sh blob: %s at %s, %s in the worktree\n' "$v" "$tag" "$w"

echo; echo "== git archive $tag deploy scripts/release, into a temporary directory"
git -C "$root" archive "$tag" deploy scripts/release | tar -x -C "$work" || fail 'git archive failed'
cp "$work/$overlay" "$work/tagged.yaml"
v=$(sed -nE 's/^ *digest: //p' "$work/$overlay")
expect "$overlay at $tag: digest" "$v" "$zeros"
v=$(images kustomize build "$work/deploy/release")
expect "kustomize build, as tagged: image" "$v" "$image@$zeros"

echo; echo "== sh scripts/release/pin-digest.sh $digest, in the copy"
v=$(sh "$work/scripts/release/pin-digest.sh" "$digest") || fail 'pin-digest.sh failed'
expect 'pin-digest.sh prints' "$v" "$image@$digest"
echo "-- diff $overlay, as tagged and pinned"
v=$(diff "$work/tagged.yaml" "$work/$overlay" || [ "$?" -eq 1 ]) || fail 'diff failed'
printf '%s\n' "$v"
expect 'lines removed, added' "$(printf '%s\n' "$v" | grep -c '^<' || true), $(printf '%s\n' "$v" | grep -c '^>' || true)" '1, 1'
v=$(images kustomize build "$work/deploy/release")
expect 'kustomize build, pinned: image' "$v" "$image@$digest"
v=$(images kubectl kustomize "$work/deploy/release")
expect 'kubectl kustomize, pinned: image' "$v" "$image@$digest"

echo; echo '== the worktree'
expect "the worktree's $overlay: sha256" "$(sum "$root/$overlay")" "$before"
echo; echo "at $tag the overlay names the placeholder; pinned in place, it names 0.1.0's digest"
