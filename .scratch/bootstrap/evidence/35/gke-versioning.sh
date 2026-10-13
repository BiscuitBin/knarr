#!/bin/sh
# Ticket 35 evidence, the GKE premise of 08's `/version` claim: that GKE's
# versions take the X.Y.Z-gke.N form, and that the GKE example
# kubernetes-source.sh evaluates is one GKE's versioning page gives. It reads
# that example from kubernetes-source.sh's own `for case in` line, so the
# version evaluated and the version checked cannot drift apart. It fetches the
# page once, prints its HTTP status, size, sha256 and "Last updated" line, and
# fails unless the page's visible text carries the cited sentence and the
# example as a whole version. It also counts the distinct X.Y.Z-gke.N versions
# the page gives. The text filter is 28's sources.sh text() with one change:
# inline tags (a, b, code, em, i, kbd, span, strong, var) are dropped without
# a space, so "(<code>X.Y.Z-gke.N</code>)" reads "(X.Y.Z-gke.N)". The page
# stays in <work>. Needs network, curl, git and perl. Writes only to <work>.
# Usage: sh gke-versioning.sh <empty-work-dir> > gke-versioning.txt
set -eu
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
here=$(cd "$(dirname "$0")" && pwd -P)
work=${1:?usage: gke-versioning.sh <empty-work-dir>}
mkdir -p "$work"; work=$(cd "$work" && pwd -P)
[ -z "$(ls -A "$work")" ] || fail "work dir $work is not empty"
url=https://docs.cloud.google.com/kubernetes-engine/versioning
sentence='GKE appends a GKE patch version number to the Kubernetes version (X.Y.Z-gke.N)'
sha() { if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
text() { # html on stdin: visible text, one line
  perl -0777 -pe 's/<script.*?<\/script>//gs; s/<style.*?<\/style>//gs; s/<\/?(?:a|b|code|em|i|kbd|span|strong|var)\b[^>]*>//gi; s/<[^>]*>/ /g; s/&quot;/"/g; s/&#x27;|&rsquo;|&lsquo;/\x27/g; s/&ldquo;|&rdquo;/"/g; s/&amp;/&/g; s/&lt;/</g; s/&gt;/>/g; s/\s+/ /g'
}

# kubernetes-source.sh's GKE case, 'v1.35.6-gke.1638000 major=1 minor=35+', without its v.
example=$(sed -n "/^for case in /s/.*'v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-gke\.[0-9][0-9]*\) .*/\1/p" "$here/kubernetes-source.sh")
case $example in '' | *[!0-9a-z.-]*) fail 'kubernetes-source.sh has no single X.Y.Z-gke.N case' ;; esac
printf 'date: %s\nhost: %s\ncheckout: <checkout> at %s\ngke-versioning.sh sha256: %s\nkubernetes-source.sh sha256: %s\nexample: %s, from kubernetes-source.sh\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(uname -sm)" "$(git -C "$here" rev-parse HEAD)" \
  "$(sha "$here/gke-versioning.sh")" "$(sha "$here/kubernetes-source.sh")" "$example"

echo; echo "== $url"
out=$(curl -sSL -A 'Mozilla/5.0 (compatible; knarr evidence 35)' --max-time 60 -o "$work/versioning.html" \
  -w '%{http_code} %{url_effective}' "$url") || fail "curl could not fetch $url"
code=${out%% *}; final=${out#* }
printf 'http %s  %s bytes  sha256 %s\n' "$code" "$(wc -c < "$work/versioning.html" | tr -d ' ')" "$(sha "$work/versioning.html")"
[ "$final" = "$url" ] || printf 'redirected to %s\n' "$final"
[ "$code" = 200 ] || fail "http $code from $url"
text < "$work/versioning.html" > "$work/versioning.txt"
updated=$(grep -o -E 'Last updated [0-9]{4}-[0-9]{2}-[0-9]{2} UTC' "$work/versioning.txt" | head -n 1)
printf '%s\n' "${updated:-the page has no Last updated line}"

echo; echo "== the page's text"
grep -qF -- "$sentence" "$work/versioning.txt" || fail "the page does not say \"$sentence\""
printf 'ok   it says "%s"\n' "$sentence"
grep -o -E '[0-9]+\.[0-9]+\.[0-9]+-gke\.[0-9]+' "$work/versioning.txt" | sort -u > "$work/versions.txt"
grep -qxF -- "$example" "$work/versions.txt" || fail "the page does not give $example as a version"
printf 'ok   it gives %s as a version\n' "$example"
printf '%s distinct X.Y.Z-gke.N versions on the page\n' "$(wc -l < "$work/versions.txt" | tr -d ' ')"
echo; echo 'gke-versioning.sh: done'
