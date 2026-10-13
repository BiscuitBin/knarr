"""Remove conda packages from an installed pixi environment, by their conda-meta records.

The Dockerfile's build stage runs this on the runtime environment before the
runtime stage copies it, so the image ships without perl, which erlang's
conda-forge build depends on and nothing the image runs uses (Decision 0003,
ticket 45). `just image-check` reruns 0003's TLS check in the pruned image.

For each package it finds the one conda-meta/<name>-<version>-<build>.json
record whose "name" is the package, deletes every path the record's "files"
lists, and then the record. A listed path already gone is fine. It refuses a
package with no record or several, and a listed path that leaves the
environment, and it checks every package before it deletes anything.

Usage: prune_runtime.py <env-dir> <package>...

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

import json
import sys
from pathlib import Path, PurePosixPath


def owned(env: Path, package: str) -> tuple[Path, list[Path]]:
    """The package's one conda-meta record and the paths it lists, or SystemExit."""
    records = [
        path
        for path in sorted((env / "conda-meta").glob(f"{package}-*.json"))
        if json.loads(path.read_text(encoding="utf-8")).get("name") == package
    ]
    if len(records) != 1:
        sys.exit(f"prune_runtime: {len(records)} conda-meta records for {package} in {env}")
    files = json.loads(records[0].read_text(encoding="utf-8"))["files"]
    for listed in files:
        relative = PurePosixPath(listed)
        # Lexical, so an in-environment symlink is never followed out of it.
        if relative.is_absolute() or ".." in relative.parts:
            sys.exit(f"prune_runtime: {records[0].name} lists {listed}, outside {env}")
    return records[0], [env / listed for listed in files]


def main(arguments: list[str]) -> None:
    if not arguments[1:]:
        sys.exit("usage: prune_runtime.py <env-dir> <package>...")
    env = Path(arguments[0])
    pruned = {package: owned(env, package) for package in arguments[1:]}
    for package, (record, files) in pruned.items():
        for path in files:
            path.unlink(missing_ok=True)
        record.unlink()
        print(f"prune_runtime: removed {package} ({record.name}, {len(files)} files)")


if __name__ == "__main__":
    main(sys.argv[1:])
