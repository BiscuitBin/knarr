#!/bin/sh
# Ticket 35 evidence, 08's `/version` claim that a managed cluster's `minor`
# may carry a `+`, from the versioned source rather than memory. Fetches only
# hack/lib/version.sh and apimachinery's version/types.go at tag v1.35.8, the
# release ticket 10's kind node runs (its /version gitCommit is the tag's
# commit), and prints their provenance and the lines that decide the claim.
# Then it evaluates version.sh's own major/minor lines, byte for byte, against
# a plain release and GKE's documented X.Y.Z-gke.N form; gke-versioning.sh
# checks that form, and the example below, against GKE's versioning page.
# Needs network and bash. Writes only to <work>.
# Usage: sh kubernetes-source.sh <empty-work-dir> > kubernetes-v1.35.8.txt
set -eu
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
tag=v1.35.8
work=${1:?usage: kubernetes-source.sh <empty-work-dir>}
mkdir -p "$work"; work=$(cd "$work" && pwd)
[ -z "$(ls -A "$work")" ] || fail "work dir $work is not empty"
src=$work/kubernetes
version_sh=hack/lib/version.sh
types_go=staging/src/k8s.io/apimachinery/pkg/version/types.go
numbered() { awk -F: '{ printf "%4d  %s\n", $1, substr($0, length($1) + 2) }'; } # grep -n output
GIT_LFS_SKIP_SMUDGE=1 git clone -q --depth 1 --branch "$tag" --filter=blob:none --sparse \
  https://github.com/kubernetes/kubernetes "$src" 2> /dev/null
git -C "$src" sparse-checkout set --no-cone "/$version_sh" "/$types_go"
printf 'date: %s\nsource: https://github.com/kubernetes/kubernetes tag %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$tag"
printf 'tag object: %s, %s\n' "$(git -C "$src" rev-parse "$tag")" "$(git -C "$src" cat-file -p "$tag" | sed -n 's/^tagger \(.*\) <.*/tagged by \1/p')"
printf 'commit: %s\n' "$(git -C "$src" rev-parse "$tag^{commit}")"
for file in "$version_sh" "$types_go"; do
  printf 'blob %s: %s\n' "$(git -C "$src" rev-parse "HEAD:$file")" "$file"
done

echo; echo "== $version_sh: how the build derives gitMajor and gitMinor"
# The block that matches KUBE_GIT_VERSION, and the ldflags it feeds.
start=$(grep -n 'Try to match the "git describe" output' "$src/$version_sh" | cut -d: -f1)
[ -n "$start" ] || fail "the major/minor block moved in $version_sh"
sed -n "$start,$((start + 9))p" "$src/$version_sh" | awk -v n="$start" '{ printf "%4d  %s\n", n + NR - 1, $0 }'
echo '...'
grep -n -E 'add_ldflag "git(Major|Minor)"' "$src/$version_sh" | numbered

echo; echo "== $types_go: the fields as JSON sees them"
grep -n -E '^type Info struct|json:"(major|minor|gitVersion)"' "$src/$types_go" | numbered

echo; echo '== version.sh'"'"'s own lines, evaluated'
block=$(sed -n "$((start + 3)),$((start + 9))p" "$src/$version_sh")
case $block in *'KUBE_GIT_MINOR+="+"'*) ;; *) fail 'the evaluated block has no KUBE_GIT_MINOR+="+"' ;; esac
# A plain release, and the example GKE's versioning page gives for 1.35.6;
# gke-versioning.sh reads the example from the next line and checks the page.
for case in 'v1.35.8 major=1 minor=35' 'v1.35.6-gke.1638000 major=1 minor=35+'; do
  version=${case%% *}; want=${case#* }
  got=$(KUBE_GIT_VERSION=$version bash -c "$block"'
printf "major=%s minor=%s" "$KUBE_GIT_MAJOR" "$KUBE_GIT_MINOR"')
  [ "$got" = "$want" ] || fail "KUBE_GIT_VERSION=$version gives $got, not $want"
  printf 'ok   KUBE_GIT_VERSION=%s gives %s\n' "$version" "$got"
done
echo; echo 'kubernetes-source.sh: done'
