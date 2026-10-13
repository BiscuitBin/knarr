"""Remove conda packages from an installed pixi environment, by their conda-meta records.

The Dockerfile's build stage runs this on the runtime environment before the
runtime stage copies it, so the image ships without perl, which erlang's
conda-forge build depends on and nothing the image runs uses (Decision 0003,
ticket 45). `just image-check` reruns 0003's TLS check in the pruned image.

For each package it finds the one conda-meta/<name>-<version>-<build>.json
record whose "name" is the package, deletes every path the record's "files"
lists, and then the record. A listed path already gone is fine. It refuses a
package with no record or several, a listed path that leaves the environment,
directly or through a symlinked directory, and a file another record also
lists. It checks every package before it deletes anything.

Usage: prune_runtime.py <env-dir> <package>...

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

import json
import sys
from pathlib import Path, PurePosixPath


def owned(env: Path, package: str) -> tuple[Path, list[Path]]:
    """The package's one conda-meta record and the paths it lists, or SystemExit."""
    records = {
        path: json.loads(path.read_text(encoding="utf-8"))
        for path in sorted((env / "conda-meta").glob("*.json"))
    }
    mine = [path for path, data in records.items() if data.get("name") == package]
    if len(mine) != 1:
        sys.exit(f"prune_runtime: {len(mine)} conda-meta records for {package} in {env}")
    record = mine[0]
    files = records[record]["files"]
    inside = env.resolve()
    for listed in files:
        relative = PurePosixPath(listed)
        if (
            relative.is_absolute()
            or not relative.parts
            or ".." in relative.parts
            or not (env / listed).parent.resolve().is_relative_to(inside)
        ):
            sys.exit(f"prune_runtime: {record.name} lists {listed}, outside {env}")
    for other, data in records.items():
        shared = sorted(set(files) & set(data.get("files", []))) if other != record else []
        if shared:
            sys.exit(f"prune_runtime: {other.name} also lists {', '.join(shared)}")
    return record, [env / listed for listed in files]


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
