"""Scan the Nix store an image ships, as a directory, with grype.

An image holds no OS package database: everything it runs is a Nix store path
(Decision 0017). syft's nix-cataloger reads the packages from the store paths'
names, so this copies /nix out of the image into build/runtime-scan/ and scans
the copy with image-scan's `--only-fixed --fail-on high`. grype's table goes to
stdout and its `-vv` log to build/runtime-scan/grype.log.

It fails closed (ticket 45): a scan whose log shows nix-cataloger catalogued
no package read the wrong directory, or an image without a store, and is
"cannot decide" whatever grype returned.

Usage: python3 scripts/checks/runtime_scan.py <image>
Exit status: 0 nothing qualifies, 2 a finding (grype's own), 1 cannot decide:
no store package catalogued, or a docker or grype error.

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

ROOT = Path(__file__).resolve().parents[2]
STORE = "/nix"
# The line grype 0.120.0 logs at -vv for a directory that holds nix/store.
CATALOGUED = re.compile(r"discovered (\d+) packages cataloger=nix-cataloger")


def catalogued(log: str) -> int:
    """How many store packages the scan's log says it catalogued; 0 when it says nothing."""
    found = CATALOGUED.search(log)
    return int(found[1]) if found else 0


def writable(directory: Path) -> None:
    """Give the owner write access to every directory under `directory`.

    Store directories are read-only, and `docker cp` keeps their modes, so
    without this neither the next scan nor `rm -r build` could remove the copy.
    """
    for parent, _, _ in os.walk(directory):
        path = Path(parent)
        path.chmod(path.stat().st_mode | 0o700)


def cannot_decide(reason: str, shown: list[str] | None = None) -> int:
    """Exit 1, after the log lines that explain it, since CI keeps no copy of the log."""
    print("\n".join([*(shown or []), f"runtime-scan: cannot decide: {reason}"]), file=sys.stderr)
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
    # The cataloger recognises a store by its path, so the copy keeps it:
    # build/runtime-scan/image/nix/store/<hash>-<name>-<version>.
    copy = target / "image"
    log = target / "grype.log"
    if target.exists():
        writable(target)
        shutil.rmtree(target)
    copy.mkdir(parents=True)
    created = run(
        ["docker", "create", "--pull=never", image], capture_output=True, text=True, check=False
    )
    if created.returncode != 0:
        return cannot_decide(f"docker create {image}: {created.stderr.strip()}")
    container = created.stdout.strip()
    try:
        copied = run(["docker", "cp", f"{container}:{STORE}", str(copy / "nix")], check=False)
    finally:
        run(["docker", "rm", "--force", container], capture_output=True, check=False)
    writable(target)
    if copied.returncode != 0:
        return cannot_decide(f"docker cp of {STORE} from {image} exited {copied.returncode}")
    with log.open("w", encoding="utf-8") as stderr:
        scanned = run(
            ["grype", "-vv", f"dir:{copy}", "--only-fixed", "--fail-on", "high"],
            stderr=stderr,
            check=False,
        )
    text = log.read_text(encoding="utf-8")
    lines = text.splitlines()
    if scanned.returncode not in {0, 2}:
        return cannot_decide(f"grype exited {scanned.returncode}; see {log}", lines[-40:])
    packages = catalogued(text)
    if packages == 0:
        counts = [line for line in lines if " packages cataloger=" in line]
        return cannot_decide(f"grype catalogued no store package in {copy}; see {log}", counts)
    # grype runs every directory cataloger, so a finding may be in a binary or an
    # OTP application rather than a store path; the table's TYPE column says.
    verdict = "a fixable high or critical" if scanned.returncode else "no fixable high or critical"
    print(
        f"runtime-scan: grype catalogued {packages} store packages in {STORE} of {image} "
        f"and found {verdict} vulnerability in the copy"
    )
    return scanned.returncode


if __name__ == "__main__":
    raise SystemExit(main())
