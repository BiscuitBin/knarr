#!/bin/sh
# Ticket 35 evidence, 04's intermittent checker test. Runs the gate checkers'
# own suite (`just test-checkers` without its build step, which must already
# have run) <runs> times in sequence in an initialized clone, with the PATH the
# Justfile exports. Each run keeps its JUnit XML and full output in <work>, so a
# failure's name and message survive; the summary prints one line per run and
# every failing test's message. Exits 1 if any run failed.
# Usage: sh checkers.sh <initialized-clone> <runs> <empty-work-dir>
set -eu
fail() { printf 'FAIL: %s\n' "$*"; exit 2; }
clone=$(cd "${1:?usage: checkers.sh <initialized-clone> <runs> <empty-work-dir>}" && pwd)
runs=${2:?usage: checkers.sh <initialized-clone> <runs> <empty-work-dir>}
work=${3:?usage: checkers.sh <initialized-clone> <runs> <empty-work-dir>}
mkdir -p "$work"; work=$(cd "$work" && pwd)
[ -z "$(ls -A "$work")" ] || fail "work dir $work is not empty"
[ -x "$clone/.pixi/envs/default/bin/python3" ] || fail "$clone has no pixi environment; run just initialize there"
[ -d "$clone/build/dev" ] || fail "$clone has no build; run just build there"
PATH="$clone/.pixi/envs/default/bin:$clone/.pixi/envs/cluster/bin:$clone/.tools/bin:$PATH"
PYTHONDONTWRITEBYTECODE=1
export PATH PYTHONDONTWRITEBYTECODE

printf 'date: %s\nhost: %s, %s cpus\nclone: <clone> at %s\n%s\n%s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(uname -sm)" "$(nproc)" "$(git -C "$clone" rev-parse HEAD)" "$(python3 --version)" "$(python3 -m pytest --version 2>&1)"
failed=0
i=1
while [ "$i" -le "$runs" ]; do
  n=$(printf '%02d' "$i")
  set +e
  ( cd "$clone" && python3 -m pytest --junitxml="$work/run-$n.xml" > "$work/run-$n.log" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || failed=$((failed + 1))
  python3 -c '
import sys
import xml.etree.ElementTree as ET
n, rc, path, at = sys.argv[1:5]
root = ET.parse(path).getroot()
suite = root if root.tag == "testsuite" else root[0]
tests, failures, errors, skipped = (suite.get(k) for k in ("tests", "failures", "errors", "skipped"))
seconds = float(suite.get("time"))
print(f"run {n}: exit {rc}, {tests} tests, {failures} failed, {errors} errors, {skipped} skipped, {seconds:.1f} s, ended {at}")
for case in suite.iter("testcase"):
    for kind in ("failure", "error"):
        for node in case.findall(kind):
            print(f"  {kind}: {case.get("classname")}::{case.get("name")}")
            message = node.get("message") or ""
            print("    " + message.replace("\n", "\n    "))
' "$n" "$rc" "$work/run-$n.xml" "$(date -u +%H:%M:%SZ)"
  i=$((i + 1))
done
printf '\n%s of %s runs failed\n' "$failed" "$runs"
[ "$failed" -eq 0 ] || exit 1
