"""Scan the conda runtime environment an image ships, as a directory, with grype.

`just image-scan` reads an image's OS packages only: syft runs
conda-meta-cataloger on a directory source and never on an image (Decision 0014,
ticket 45). So this copies /opt/knarr/.pixi/envs/runtime out of the image into
build/runtime-scan/ and scans the copy with image-scan's `--only-fixed
--fail-on high`. grype's table goes to stdout and its `-vv` log to
build/runtime-scan/grype.log.

It fails closed: a scan whose log shows conda-meta-cataloger catalogued no
package read the wrong directory, or one without conda-meta, and is "cannot
decide" whatever grype returned.

Usage: python3 scripts/checks/runtime_scan.py <image>
Exit status: 0 nothing qualifies, 2 a finding (grype's own), 1 cannot decide:
no conda package catalogued, or a docker or grype error.

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = "/opt/knarr/.pixi/envs/runtime"
# The line grype 0.120.1 logs at -vv, as grype-probe.sh part 3 reads it.
CATALOGUED = re.compile(r"discovered (\d+) packages cataloger=conda-meta-cataloger")


def catalogued(log: str) -> int:
    """How many conda packages the scan's log says it catalogued; 0 when it says nothing."""
    found = CATALOGUED.search(log)
    return int(found[1]) if found else 0


def cannot_decide(reason: str) -> int:
    print(f"runtime-scan: cannot decide: {reason}", file=sys.stderr)
    return 1


def main(
    argv: list[str] | None = None,
    run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
    target: Path = ROOT / "build/runtime-scan",
) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 1:
        print("usage: runtime_scan.py <image>", file=sys.stderr)
        return 1
    image = arguments[0]
    copy = target / "runtime"
    log = target / "grype.log"
    shutil.rmtree(target, ignore_errors=True)
    target.mkdir(parents=True)
    created = run(
        ["docker", "create", "--pull=never", image], capture_output=True, text=True, check=False
    )
    if created.returncode != 0:
        return cannot_decide(f"docker create {image}: {created.stderr.strip()}")
    container = created.stdout.strip()
    try:
        copied = run(["docker", "cp", f"{container}:{RUNTIME}", str(copy)], check=False)
    finally:
        run(["docker", "rm", "--force", container], capture_output=True, check=False)
    if copied.returncode != 0:
        return cannot_decide(f"docker cp of {RUNTIME} from {image} exited {copied.returncode}")
    with log.open("w", encoding="utf-8") as stderr:
        scanned = run(
            ["grype", "-vv", f"dir:{copy}", "--only-fixed", "--fail-on", "high"],
            stderr=stderr,
            check=False,
        )
    packages = catalogued(log.read_text(encoding="utf-8"))
    if packages == 0:
        return cannot_decide(f"grype catalogued no conda package in {copy}; see {log}")
    if scanned.returncode not in {0, 2}:
        return cannot_decide(f"grype exited {scanned.returncode}; see {log}")
    verdict = "a fixable high or critical" if scanned.returncode else "no fixable high or critical"
    print(
        f"runtime-scan: grype catalogued {packages} conda packages in {RUNTIME} of {image}, "
        f"with {verdict} vulnerability"
    )
    return scanned.returncode


if __name__ == "__main__":
    raise SystemExit(main())
