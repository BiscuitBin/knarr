#!/bin/sh
# Ticket 05 evidence: Renovate's nix manager against a scratch repository state
# with ticket 01's prototype flake at the root, after bootstrap ticket 27's
# renovate.sh. Renovate runs on the local platform, which extracts and looks up
# and stops: it creates no branch and runs no lock file update. So whether
# lock maintenance moves flake.lock is shown by running, in ticket 01's pinned
# Nix image, the exact command Renovate's nix manager builds.
#
#   1. The scratch tree: the committed branch, flake.nix and flake.lock as
#      ticket 01 committed them at the root, and the prototype's
#      image/Dockerfile as the root Dockerfile, its build stage pinned by digest
#      alone. A lookup with "nix" added to enabledManagers and nothing else.
#   2. renovate-config-validator --strict and a lookup, with the nix manager
#      also switched on ("nix": {"enabled": true}).
#   3. The same on a stale copy: flake.lock's two channel inputs rolled back to
#      real older revisions, and the build stage pinned as tag plus digest at
#      the previous Nix release. Then a copy whose kubectl input follows the
#      previous release channel, nixos-25.11, to see whether the ref moves.
#   4. Whether the Renovate images carry nix, and whether the default image
#      installs it at run time without a token.
#   5. The lock file update itself, on the stale copy, in the pinned Nix image.
#   6. Every pin in flake.nix that Renovate did not extract.
#
# No token or credential reaches Renovate or any container: Renovate's
# github.com lookups run anonymously, and the transcript says what that cost.
# Needs docker, git, the network and the pixi default environment.
# Usage: sh renovate.sh <empty-work-dir>
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$here/../../../.." && pwd -P)
proto=$root/.scratch/nix-migration/evidence/01
py=$root/.pixi/envs/default/bin/python3
branch=05-nix-ci-renovate-spike
# 44.239.1 was the newest release on 2026-11-14; each digest is an OCI index.
renovate_image='ghcr.io/renovatebot/renovate:44.239.1@sha256:7dba1a3b916a2cf302ba0df458ddcc8fcbac3c92d0fe9882ac13ba0363de656b'
renovate_full='ghcr.io/renovatebot/renovate:44.239.1-full@sha256:4731f8527b03404ab59c1af030a912b1451be7ad7f05f070d619e50603cd19e2'
# Ticket 01's Nix image: nixos/nix 2.35.6, the multi-arch index.
nix_image='nixos/nix@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed'
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$py" ] || fail "$py is missing; run just initialize"
mkdir -p "${1:?usage: renovate.sh <empty-work-dir>}"
work=$(CDPATH='' cd -- "$1" && pwd -P)
[ -z "$(ls -A "$work")" ] || fail "work dir $work is not empty"
[ -z "${GITHUB_COM_TOKEN:-}${GITHUB_TOKEN:-}${RENOVATE_TOKEN:-}" ] || fail 'a token is set in this shell; unset it'
for image in "$renovate_image" "$renovate_full" "$nix_image"; do
  docker pull --quiet "$image" > /dev/null
done

printf 'date: %s\nrevision: %s (%s)\nimage: %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" \
  "$(git -C "$root" rev-parse --short "$branch")" "$branch" "$renovate_image"

configure() { # tree, then what to add: enabledManagers, or both
  "$py" -I - "$1/.github/renovate.json" "$2" << 'EOF'
import json
import sys

path, add = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as stream:
    config = json.load(stream)
if "nix" not in config["enabledManagers"]:
    config["enabledManagers"] = sorted(config["enabledManagers"] + ["nix"])
if add == "both":
    config["nix"] = {"enabled": True}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(config, stream, indent=2)
EOF
}
lookup() { # tree, log
  docker run --rm -v "$1:/usr/src/app" -w /usr/src/app \
    -e LOG_LEVEL=debug -e LOG_FORMAT=json "$renovate_image" --platform=local > "$2" 2>&1 ||
    fail "renovate exited non-zero; see $2"
}

echo '-- 1. the scratch tree, with "nix" in enabledManagers and nothing else'
git -C "$root" archive "$branch" | (mkdir -p "$work/listed" && tar -x -C "$work/listed")
cp "$proto/flake.nix" "$proto/flake.lock" "$work/listed/"
cp "$proto/image/Dockerfile" "$work/listed/Dockerfile"
configure "$work/listed" enabledManagers
lookup "$work/listed" "$work/listed.log"
grep -E '"msg":"(nix is disabled|Manager explicitly enabled)' "$work/listed.log" |
  sed -E 's/.*"msg":"([^"]*(\\"[^"]*)*)".*/  \1/; s/\\"/"/g'

echo '-- 2. the same tree with "nix": {"enabled": true} as well'
cp -R "$work/listed" "$work/head"
configure "$work/head" both
docker run --rm -v "$work/head:/usr/src/app:ro" -w /usr/src/app \
  --entrypoint renovate-config-validator "$renovate_image" --strict > "$work/validate.log" 2>&1 ||
  { cat "$work/validate.log"; fail 'the config does not validate'; }
sed 's/^ */  /' "$work/validate.log"
lookup "$work/head" "$work/head.log"

cp -R "$work/head" "$work/stale"
"$py" -I - "$work/stale" << 'EOF'
import sys
from pathlib import Path

stale = Path(sys.argv[1])
# path, the live text, the older text. Each older value is real: nixpkgs-unstable
# at nixpkgs-26.11pre1115905 (the lock move ticket 01's gate-setup.sh builds),
# a nixos-26.05 commit of 2026-11-04, and nixos/nix 2.35.5's index. The
# narHash and lastModified beside each rolled-back rev are left as they were:
# Renovate reads neither, and the lock update below rewrites both.
ROLLBACKS = [
    ("flake.lock", "2074cc672349f14240fb7ea90d509e0b643e9dd4", "9ac0edc06bfb33e6c0000be79d98ef8d89e26503"),
    ("flake.lock", "f1e5c356f35d07e7b71a6b5e6c9338e0b029e0c0", "f7e804372523bedd74d273b173de45c8e02c6d9a"),
    ("Dockerfile",
     "FROM nixos/nix@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed",
     "FROM nixos/nix:2.35.5@sha256:9305de534abed691d0f569502a4962a3a072ea8e888502c453ecfe35ae182867"),
]
for path, live, older in ROLLBACKS:
    file = stale / path
    text = file.read_text(encoding="utf-8")
    if text.count(live) != 1:
        sys.exit(f"FAIL: {path} holds {live!r} {text.count(live)} times, want 1")
    file.write_text(text.replace(live, older), encoding="utf-8")
EOF
echo '-- 3. the stale copy'
lookup "$work/stale" "$work/stale.log"
cp -R "$work/head" "$work/release"
"$py" -I - "$work/release" << 'EOF'
import sys
from pathlib import Path

release = Path(sys.argv[1])
for path, live, older in (
    ("flake.lock", '"ref": "nixos-26.05"', '"ref": "nixos-25.11"'),
    ("flake.nix", '"github:NixOS/nixpkgs/nixos-26.05"', '"github:NixOS/nixpkgs/nixos-25.11"'),
):
    file = release / path
    text = file.read_text(encoding="utf-8")
    if text.count(live) != 1:
        sys.exit(f"FAIL: {path} holds {live!r} {text.count(live)} times, want 1")
    file.write_text(text.replace(live, older), encoding="utf-8")
EOF
lookup "$work/release" "$work/release.log"

"$py" -I - "$work/head.log" "$work/stale.log" "$proto/flake.nix" "$work/release.log" << 'EOF'
import json
import re
import sys
from collections import Counter

SHOWN = ("nix", "dockerfile")


def records(path):
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            if line.startswith("{"):
                yield json.loads(line)


def read(path):
    stats = deps = version = None
    warnings = Counter()
    branches = []
    for record in records(path):
        message = record.get("msg", "")
        if message == "Dependency extraction complete":
            stats = record["stats"]
        if message == "packageFiles with updates":
            deps = [
                (manager, package_file["packageFile"], dep)
                for manager, files in record["config"].items()
                for package_file in files
                for dep in package_file["deps"]
            ]
        if message.startswith("branches info extended"):
            branches = record.get("branchesInformation", [])
        if record.get("level", 0) >= 40:
            text = message
            if record.get("err", {}).get("message"):
                text += f": {record['err']['message']}"
            warnings[text[:160]] += 1
        version = version or record.get("renovateVersion")
    if stats is None or deps is None:
        sys.exit(f"FAIL: {path} has no extraction or lookup result")
    return version, stats, deps, warnings, branches


def show(dep, package_file, manager):
    fields = [f"{manager}:{package_file}", dep["depName"]]
    for key in ("packageName", "datasource", "versioning", "currentValue", "currentDigest", "lockedVersion", "skipReason"):
        if dep.get(key):
            fields.append(f"{key}={dep[key]}")
    print("  " + " ".join(fields))
    for update in dep.get("updates", []):
        new = update.get("newValue") or ""
        if update.get("newDigest"):
            new += f"@{update['newDigest']}"
        locked = f" lockedVersion->{update['newVersion']}" if update.get("isLockfileUpdate") else ""
        print(f"    proposes {update.get('updateType')} -> {new}{locked} in {update.get('branchName')}")
    if not dep.get("updates"):
        print("    proposes nothing")
    for warning in dep.get("warnings", []):
        print(f"    warning: {warning.get('message', '')[:140]}")


def report(label, path):
    version, stats, deps, warnings, branches = read(path)
    print(f"[{label}] renovate {version}: {stats['total']['depCount']} dependencies in {stats['total']['fileCount']} files")
    for manager, counts in sorted(stats["managers"].items()):
        print(f"  {manager:<15} {counts['depCount']:>3} in {counts['fileCount']} files")
    for manager, package_file, dep in deps:
        if manager in SHOWN:
            show(dep, package_file, manager)
    unlookedup = Counter(
        (m, d.get("datasource"), d.get("skipReason") or "no updates and no result")
        for m, _, d in deps
        if d.get("skipReason") or d.get("warnings")
    )
    print("  dependencies skipped or warned about, by manager and datasource:")
    for (manager, datasource, reason), count in sorted(unlookedup.items(), key=str):
        print(f"    {count:>3} {manager} {datasource} {reason}")
    print("  warnings in the log:")
    for text, count in sorted(warnings.items()):
        print(f"    {count:>3} {text}")
    lock_branches = [b.get("branchName") for b in branches if "lock" in (b.get("branchName") or "")]
    print(f"  lock-file branches in the branch summary: {lock_branches or 'none'}")
    return deps


report("scratch tree", sys.argv[1])
deps = report("stale copy", sys.argv[2])
print("[release-channel copy] nixpkgs-kubectl follows nixos-25.11 in flake.nix and flake.lock")
for manager, package_file, dep in read(sys.argv[4])[2]:
    if manager == "nix":
        show(dep, package_file, manager)

flake = open(sys.argv[3], encoding="utf-8").read()
held = re.search(r"held = \{(.*?)\};", flake, re.S).group(1)
pins = [(f"held.{name}", value) for name, value in re.findall(r"(\w+) = \"([^\"]+)\";", held)]
pins += [("allium asset URL", re.search(r'url = "(https://[^"]+)"', flake).group(1))]
pins += [(f"allium sha256 ({system})", digest) for system, digest in
         re.findall(r"(\w+-\w+) = \{\s*triple = \"[^\"]+\";\s*sha256 = \"([0-9a-f]{64})\"", flake)]
pins += [(f"input {name}", url) for name, url in re.findall(r"([\w-]+)\.url = \"([^\"]+)\";", flake)]
carried = set()
for manager, _, dep in deps:
    if manager == "nix":
        carried.update(str(dep.get(key)) for key in ("currentValue", "currentDigest", "lockedVersion", "depName"))
print("-- 6. every pin in flake.nix, and whether an extracted nix dependency carries it")
for label, value in pins:
    name = label.removeprefix("input ")
    hit = value in carried or (label.startswith("input ") and name in carried)
    print(f"  {'extracted' if hit else 'NOT extracted':<14} {label:<28} {value}")
EOF

echo '-- what git-refs reads for nixpkgs now: the default branch and the two channels'
git ls-remote https://github.com/NixOS/nixpkgs HEAD refs/heads/nixpkgs-unstable refs/heads/nixos-26.05 | sed 's/^/  /'

echo '-- 4. nix in the Renovate images'
for image in "$renovate_image" "$renovate_full"; do
  printf '%s: %s\n' "${image%%@*}" \
    "$(docker run --rm --entrypoint sh "$image" -c 'command -v nix || echo "no nix on PATH"')"
done
printf 'install-tool nix 2.35.6 in %s, no token:\n' "${renovate_image%%@*}"
docker run --rm --entrypoint sh "$renovate_image" -c \
  'install-tool nix 2.35.6 > /tmp/install.log 2>&1; status=$?; tail -n 3 /tmp/install.log; echo "exit $status"; nix --version 2>&1 || true' |
  sed 's/^/  /'

echo '-- 5. the lock file update Renovate runs, on the stale copy, in the pinned Nix image'
mkdir -p "$work/lock"
cp "$work/stale/flake.nix" "$work/stale/flake.lock" "$work/lock/"
cp "$work/stale/flake.lock" "$work/lock/flake.lock.before"
docker run --rm -v "$work/lock:/flake" -w /flake --entrypoint sh "$nix_image" -c '
  set -e
  cp flake.lock.before flake.lock
  echo "lockFileMaintenance: nix --extra-experimental-features '"'"'nix-command flakes'"'"' flake update"
  nix --extra-experimental-features "nix-command flakes" flake update 2>&1 | grep -E "^(warning|error|•|  )" | cut -c1-140 || true
  cp flake.lock flake.lock.maintenance
  cp flake.lock.before flake.lock
  echo "an input update for nixpkgs-kubectl: nix --extra-experimental-features '"'"'nix-command flakes'"'"' flake update nixpkgs-kubectl"
  nix --extra-experimental-features "nix-command flakes" flake update nixpkgs-kubectl 2>&1 | grep -E "^(warning|error|•|  )" | cut -c1-140 || true
  cp flake.lock flake.lock.input
  cp flake.lock.maintenance flake.lock
  echo "the held versions after lock maintenance, by evaluating every group for x86_64-linux:"
  if out=$(nix --extra-experimental-features "nix-command flakes" eval --no-update-lock-file --raw \
      .#packages.x86_64-linux.default.outPath 2>&1); then
    echo "  evaluates: the held versions survive the move"
  else
    printf "%s\n" "$out" | grep -E "error:|held" | head -n 3 | sed "s/^/  /"
  fi'
"$py" -I - "$work/lock" << 'EOF'
import json
import sys
from pathlib import Path

lock = Path(sys.argv[1])


def revs(name):
    nodes = json.loads((lock / name).read_text(encoding="utf-8"))["nodes"]
    return {k: (v["locked"]["rev"], v["locked"]["narHash"]) for k, v in nodes.items() if k != "root"}


before = revs("flake.lock.before")
for label, name in (("lockFileMaintenance", "flake.lock.maintenance"), ("input update", "flake.lock.input")):
    after = revs(name)
    print(f"{label}: flake.lock {'moved' if after != before else 'unchanged'}")
    for input_name in sorted(before):
        old, new = before[input_name][0], after[input_name][0]
        print(f"  {input_name:<16} {old} -> {new}" if old != new else f"  {input_name:<16} {old} unchanged")
EOF
