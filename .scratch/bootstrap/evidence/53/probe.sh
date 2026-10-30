#!/bin/sh
# Ticket 53 evidence: why the rebar3 pin moved, live.
#
#   1. OSV.dev's querybatch, asked as hex_audit.py asks about OTP: the rebar3
#      repository in the GIT ecosystem. The pinned tag must list no advisory,
#      and 3.27.1, the control, must list at least one.
#   2. OSV.dev's record of CVE-2026-96596, the advisory ticket 52 found, and of
#      each advisory step 1 lists for 3.27.1: the rebar3 clause of its details,
#      the numeric rebar3 range it records, if any, and whether its enumerated
#      tags hold 3.27.1 and the pinned tag. A record that states no rebar3 fix,
#      fixes rebar3 after the pin, lists the pinned tag, or does not list
#      3.27.1 fails the run. Whether step 1 returned CVE-2026-96596 is printed.
#   3. The release: the pin must be erlang/rebar3's newest release by version. The
#      escript's sha256 must equal GitHub's asset digest and the pin in
#      tools.txt and both Dockerfiles, and its Sigstore bundle must verify with
#      install-tools.sh's flags. As a control, 3.27.1's digest must differ.
#
# Needs network, curl, git, an authenticated gh, and the pixi default
# environment (just initialize).
# Usage: sh probe.sh <empty-work-dir>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
wt=$(cd "$here/../../../.." && pwd)
py=$wt/.pixi/envs/default/bin/python3
previous=3.27.1
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$py" ] || fail "$py is missing; run just initialize"
gh auth status > /dev/null 2>&1 || fail 'gh is not authenticated'
mkdir -p "${1:?usage: probe.sh <empty-work-dir>}"
work=$(cd "$1" && pwd)
[ -z "$(ls -A "$work")" ] || fail "work dir $work is not empty"
printf 'date: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
printf 'revision: %s\n' "$(git -C "$wt" rev-parse --short HEAD)"
mkdir "$work/head"
git -C "$wt" archive HEAD | tar -x -C "$work/head"
[ "$(grep -c '^rebar3 [^ ]* linux-64 ' "$work/head/tools.txt")" = 1 ] || fail 'want one rebar3 linux-64 line in tools.txt'
line=$(sed -n 's/^rebar3 \([^ ]*\) linux-64 \([^ ]*\) \([0-9a-f]\{64\}\) rebar3$/\1 \2 \3/p' "$work/head/tools.txt")
[ -n "$line" ] || fail 'the rebar3 linux-64 line has no sha256'
pin=${line%% *} sha=${line##* } url=${line#* } url=${url% *}
grep -q "^rebar3 $pin osx-arm64 $url $sha rebar3\$" "$work/head/tools.txt" || fail 'the osx-arm64 rebar3 line differs'
for dockerfile in Dockerfile fixtures/fake_worker/Dockerfile; do
  grep -q "^ADD --checksum=sha256:$sha $url " "$work/head/$dockerfile" || fail "$dockerfile does not ADD the pin"
done
printf 'rebar3 pin: %s, %s\n' "$pin" "$sha"
printf '  tools.txt (linux-64, osx-arm64), Dockerfile and fixtures/fake_worker/Dockerfile agree\n'

echo '== 1. OSV.dev querybatch, GIT ecosystem'
printf '{"queries": [%s, %s]}' \
  "{\"package\": {\"ecosystem\": \"GIT\", \"name\": \"https://github.com/erlang/rebar3\"}, \"version\": \"$pin\"}" \
  "{\"package\": {\"ecosystem\": \"GIT\", \"name\": \"https://github.com/erlang/rebar3\"}, \"version\": \"$previous\"}" \
  > "$work/query.json"
curl -fsS --max-time 60 -H 'Content-Type: application/json' --data @"$work/query.json" \
  -o "$work/answer.json" https://api.osv.dev/v1/querybatch
"$py" -I - "$work/answer.json" "$pin" "$previous" "$work/listed" <<'EOF'
import json
import sys

results = json.load(open(sys.argv[1], encoding="utf-8"))["results"]
pin, previous = sys.argv[2], sys.argv[3]
listed = {}
for tag, result in zip((pin, previous), results, strict=True):
    if "next_page_token" in result:
        sys.exit(f"FAIL: OSV has a further page for rebar3 {tag}")
    listed[tag] = sorted(v["id"] for v in result.get("vulns", []))
    print(f"  rebar3 {tag}: {', '.join(listed[tag]) or 'no advisory'}")
if listed[pin]:
    sys.exit(f"FAIL: OSV lists advisories for rebar3 {pin}")
if not listed[previous]:
    sys.exit(f"FAIL: the control {previous} lists no advisory")
# Ticket 52's advisory is read whether or not the querybatch returns it.
print(f"  CVE-2026-96596 is {'' if 'CVE-2026-96596' in listed[previous] else 'not '}among them")
records = ["CVE-2026-96596"] + [i for i in listed[previous]
                                if i != "CVE-2026-96596" and not i.startswith("EEF-")]
with open(sys.argv[4], "w", encoding="utf-8") as out:
    out.write("".join(f"{i}\n" for i in records))
EOF

echo '== 2. OSV.dev records'
while read -r id <&3; do
  curl -fsS --max-time 60 -o "$work/$id.json" "https://api.osv.dev/v1/vulns/$id"
  "$py" -I - "$work/$id.json" "$pin" "$previous" <<'EOF'
import json
import re
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
pin, previous = sys.argv[2], sys.argv[3]
details = record["details"].replace("\xa0", " ")
# A record may name more than one rebar3 branch; every one is read.
clauses = list(re.finditer(r"rebar3:? from \S+ before ([0-9]+(?:\.[0-9]+)*)", details))
ranges = [r["range"] for a in record.get("affected", []) for rg in a.get("ranges", [])
          if rg.get("repo") == "https://github.com/erlang/rebar3"
          for r in rg.get("database_specific", {}).get("extracted_events", [])
          if r.get("source") == "AFFECTED_FIELD" and r.get("strategy") == "StandardRange"
          and all(re.fullmatch(r"[0-9]+(\.[0-9]+)*(-rc[0-9]+)?", v) for e in r["range"] for v in e.values())]
tags = {v for a in record.get("affected", []) for v in a.get("versions", [])}
rebar_tags = [t for t in tags if re.fullmatch(r"3\.[0-9.]+(-rc[0-9]+)?", t)]
print(f"-- {record['id']} ({', '.join(record.get('aliases', []))})")
print(f"  {record['summary']}")
print(f"  published {record['published'][:10]}, modified {record['modified'][:10]}")
for severity in record.get("severity", []):
    print(f"  {severity['type']} {severity['score']}")
print(f"  details: {'; '.join(c.group(0) for c in clauses) or 'no rebar3 clause'}")
for r in ranges:
    print(f"  rebar3 range: {', '.join(f'{k} {v}' for e in r for k, v in e.items())}")
print(f"  enumerated rebar3 tags: {len(rebar_tags)}; {previous} "
      f"{'listed' if previous in tags else 'not listed'}, {pin} {'listed' if pin in tags else 'not listed'}")
# "3.28" and "3.28.0" are one release; an -rc suffix sorts before its release.
def version(v):
    numbers, _, rc = v.partition("-rc")
    parts = tuple(int(n) for n in numbers.split("."))
    return parts + (0,) * (3 - len(parts)) + ((0, int(rc)) if rc else (1, 0))
if not clauses:
    sys.exit(f"FAIL: {record['id']} states no rebar3 fix")
fixes = {version(c.group(1)) for c in clauses}
if any(version(e["fixed"]) not in fixes for r in ranges for e in r if "fixed" in e):
    sys.exit(f"FAIL: {record['id']}'s details and range disagree on the fix")
if max(fixes) > version(pin):
    sys.exit(f"FAIL: {record['id']} fixes rebar3 after {pin}")
if pin in tags:
    sys.exit(f"FAIL: {record['id']} lists {pin}")
if previous not in tags:
    sys.exit(f"FAIL: {record['id']} does not list {previous}")
EOF
done 3< "$work/listed"

echo '== 3. the release'
gh api 'repos/erlang/rebar3/releases?per_page=100' > "$work/releases.json"
"$py" -I - "$work/releases.json" "$pin" "$previous" "$sha" > "$work/release" <<'EOF'
import json
import re
import sys

releases = [r for r in json.load(open(sys.argv[1], encoding="utf-8"))
            if not r["draft"] and not r["prerelease"]]
pin, previous, sha = sys.argv[2], sys.argv[3], sys.argv[4]
by_tag = {r["tag_name"]: r for r in releases}
for tag in (pin, previous):
    if tag not in by_tag:
        sys.exit(f"FAIL: no release {tag} among the newest 100")
def digest(release):
    found = [a.get("digest") for a in release["assets"] if a["name"] == "rebar3"]
    if len(found) != 1 or not found[0]:
        sys.exit(f"FAIL: release {release['tag_name']} has no one rebar3 asset with a digest")
    return found[0]
# The newest by version, not by publication: a backport may be published later.
numeric = [r for r in releases if re.fullmatch(r"[0-9]+(\.[0-9]+)*", r["tag_name"])]
newest = max(numeric, key=lambda r: tuple(int(n) for n in r["tag_name"].split(".")))
print(f"newest release: {newest['tag_name']}, published {newest['published_at'][:10]}")
if newest["tag_name"] != pin:
    sys.exit(f"FAIL: the newest release is {newest['tag_name']}, not the pin {pin}")
print(f"{pin} asset digest: {digest(by_tag[pin])}")
print(f"{previous} asset digest: {digest(by_tag[previous])}")
if digest(by_tag[pin]) != f"sha256:{sha}":
    sys.exit(f"FAIL: the {pin} asset digest is not the pin")
if digest(by_tag[previous]) == digest(by_tag[pin]):
    sys.exit(f"FAIL: the control {previous} has the pin's digest")
EOF
sed 's/^/  /' "$work/release"
mkdir "$work/download"
curl -fsSL --proto '=https' --proto-redir '=https' -o "$work/download/rebar3" "$url"
curl -fsSL --proto '=https' --proto-redir '=https' -o "$work/download/bundle.json" "$url.sigstore"
got=$("$py" -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$work/download/rebar3")
printf '  downloaded escript sha256: %s\n' "$got"
[ "$got" = "$sha" ] || fail "the download's sha256 is $got, not the pin"
gh attestation verify "$work/download/rebar3" --bundle "$work/download/bundle.json" --repo erlang/rebar3 \
  --signer-workflow erlang/rebar3/.github/workflows/publish.yml --source-ref "refs/tags/$pin" > /dev/null ||
  fail "rebar3 $pin failed Sigstore verification"
printf '  Sigstore bundle verified: erlang/rebar3/.github/workflows/publish.yml@refs/tags/%s\n' "$pin"
