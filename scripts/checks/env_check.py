"""Refuse installed tools that flake.lock no longer pins, without writing.

lock-check proves that flake.lock agrees with flake.nix, but nothing in it
reads what is installed. After a pull that moves a pin, every recipe would
still run the old tools through PATH, and the gate could pass without the
pinned compiler, OTP or lint rules. This compares:

- the store path the flake's `tools` output evaluates to now, which names
    every tool and version in the environment by hash;
- the store path the .nix/tools out-link points at, which is what `just
    initialize` last built and what PATH reaches.

The evaluation is read-only and offline, and it refuses a flake.lock that
would need rewriting, so the check writes nothing and fetches nothing
(Decision 0017).

Usage: python3 scripts/checks/env_check.py [project-directory]
Exit status: 0 they match, 1 they differ, 2 cannot decide.

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

LINK = Path(".nix") / "tools"
EVALUATE = (
    "nix",
    "--extra-experimental-features",
    "nix-command flakes",
    "eval",
    "--raw",
    "--read-only",
    "--offline",
    "--no-update-lock-file",
    ".#tools",
)


def _refuse(message: str) -> NoReturn:
    print(f"env-check: {message}", file=sys.stderr)
    raise SystemExit(2)


def pinned(project: Path) -> str:
    """The store path of the tool environment flake.nix and flake.lock describe."""
    try:
        result = subprocess.run(EVALUATE, cwd=project, check=False, capture_output=True, text=True)
    except OSError as error:
        _refuse(f"nix cannot run: {error}")
    path = result.stdout.strip()
    if result.returncode != 0 or not path.startswith("/"):
        detail = result.stderr.strip().splitlines()
        _refuse(
            "nix could not evaluate the tool environment offline"
            + (f": {detail[-1].strip()}" if detail else "")
        )
    return path


def installed(project: Path) -> str:
    """The store path the out-link `just initialize` built points at."""
    link = project / LINK
    if not link.is_symlink():
        _refuse(f"{link} is missing; run just initialize")
    target = os.path.realpath(link)
    if not Path(target).is_dir():
        _refuse(f"{link} points at {target}, which is gone; run just initialize")
    return target


def main() -> int:
    project = Path(sys.argv[1]) if len(sys.argv) > 1 else Path()
    have = installed(project)
    want = pinned(project)
    if have == want:
        print(f"{LINK} is the tool environment flake.lock pins ({want})")
        return 0
    print(f"  flake.lock pins {want}")
    print(f"  {LINK} holds  {have}")
    print(
        "the installed tools differ from flake.lock; run just initialize "
        "(it needs network for anything not already in the Nix store)"
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
