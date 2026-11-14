"""Run the pinned Allium binary and judge its JSON reports.

Copied from github.com/steven-cutting/biscuit_games_tooling at v0.3.0
(6c5c07f6bec86e86b3930dfa41392e4b440e8c85),
src/biscuit_games_tooling/run_allium.py. Adapted per Decision 0004:
checks.toml owns the specs path, tools.txt owns the version pin.

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
from pathlib import Path
from typing import Any

import _project
import _tools

COMMANDS = ("check", "analyse", "plan")

# allium's own documented status. 2 means it resolved no `.allium` file at all,
# which is a gate that checked nothing rather than a gate that passed.
NO_INPUTS = 2

REPORTED = ("diagnostics", "findings")


def _relative(name: str, project_root: Path) -> str:
    """Name a module the way the report does, whichever way the tool spelled it."""
    path = Path(name)
    if path.is_absolute():
        try:
            return str(path.relative_to(project_root))
        except ValueError:
            return str(path)
    return str(path)


def _modules(project_root: Path, specs: str) -> set[str]:
    """Every `.allium` file under the configured specs directory, as allium's own recursive walk should find them."""
    return {
        str(path.relative_to(project_root)) for path in (project_root / specs).rglob("*.allium")
    }


def _blocks(output: str) -> list[dict[str, Any]]:
    """Read allium's back-to-back JSON objects, which are not one document."""
    decoder = json.JSONDecoder()
    blocks: list[dict[str, Any]] = []
    index = 0
    while index < len(output):
        if output[index].isspace():
            index += 1
            continue
        value, index = decoder.raw_decode(output, index)
        blocks.append(value)
    return blocks


def _where(entry: dict[str, Any]) -> str:
    location = entry.get("location") or {}
    return f"{location.get('file', '?')}:{location.get('line', '?')}:{location.get('col', '?')}"


def _diagnostic_line(entry: dict[str, Any]) -> str:
    # `code` is null on a parse failure, the one diagnostic that carries no name
    # -- and so the one that can never be waived, since a waiver names a code.
    code = entry.get("code") or "parse error"
    severity = entry.get("severity", "?")
    return f"  {_where(entry)}: {severity}: {code}: {entry.get('message', '')}"


def _finding_line(entry: dict[str, Any]) -> str:
    entities = ", ".join(entry.get("affected_entities") or []) or "?"
    rule = (entry.get("requires") or {}).get("rule")
    return (
        f"  {entry.get('type', '?')}: {entry.get('summary', '')}"
        f" [{entities}{f', rule {rule}' if rule else ''}]"
    )


RENDER = {"diagnostics": _diagnostic_line, "findings": _finding_line}


def _count(total: int, kind: str) -> str:
    """Say `1 diagnostic` rather than `1 diagnostics`."""
    return f"{total} {kind if total != 1 else kind.removesuffix('s')}"


def _report(blocks: list[dict[str, Any]]) -> dict[str, int]:
    """Print every diagnostic and finding, and count them by kind."""
    counts = dict.fromkeys(REPORTED, 0)
    for block in blocks:
        module = block.get("spec_file", "an unnamed module")
        for kind in REPORTED:
            entries = block.get(kind) or []
            if not entries:
                continue
            counts[kind] += len(entries)
            print(f"\n{module}: {_count(len(entries), kind)}", file=sys.stderr)
            for entry in entries:
                print(RENDER[kind](entry), file=sys.stderr)
    return counts


def _read(
    command: str, status: int, output: str, project_root: Path, specs: str
) -> list[dict[str, Any]]:
    """Turn allium's output into one block per module, or say why it cannot be judged.

    Every failure here is the tool behaving unlike itself rather than a
    specification being wrong, so each is raised rather than counted: a report
    this gate cannot read is not a report it may pass.
    """
    if status == NO_INPUTS:
        raise RuntimeError(f"allium {command} resolved no specification under {specs}")
    try:
        blocks = _blocks(output)
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"allium {command} printed something this gate cannot read: {error}"
        ) from error
    if not blocks:
        raise RuntimeError(f"allium {command} reported on no specification at all")

    # A block missing either array would otherwise read as an empty one, and so
    # as a clean module. Absence is not emptiness: demand the keys.
    for block in blocks:
        if (
            not isinstance(block, dict)
            or not isinstance(block.get("spec_file"), str)
            or any(not isinstance(block.get(kind), list) for kind in REPORTED)
        ):
            raise RuntimeError(f"allium {command} printed a block that is not a report")

    # allium decides for itself which files to walk, so ask what it read rather
    # than assuming it read everything. A module it drops in silence would
    # otherwise pass the gate inside a reassuring count.
    reported = sorted(_relative(block["spec_file"], project_root) for block in blocks)
    present = sorted(_modules(project_root, specs))
    if reported != present:
        raise RuntimeError(f"allium {command} reported on {reported}, but {specs} holds {present}")
    return blocks


def _binary(project_root: Path) -> Path:
    """Only run the project-managed binary, at the host platform's pinned version."""
    host = {("Darwin", "arm64"): "osx-arm64", ("Linux", "x86_64"): "linux-64"}.get(
        (platform.system(), platform.machine())
    )
    if host is None:
        raise RuntimeError("tools.txt pins no Allium for this platform")
    pins = []
    for line in (project_root / "tools.txt").read_text().splitlines():
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        if len(fields) != 6:
            raise RuntimeError("tools.txt contains a malformed pin")
        if fields[0] == "allium" and fields[2] == host:
            pins.append(fields[1])
    if len(pins) != 1:
        raise RuntimeError(f"tools.txt must contain exactly one allium pin for {host}")
    try:
        binary = _tools.tool(project_root, "allium")
        result = subprocess.run(
            [str(binary), "--version"], check=False, capture_output=True, text=True
        )
    except OSError as error:
        raise RuntimeError("Allium is missing or cannot run; run just initialize") from error
    fields = result.stdout.split()
    if result.returncode or len(fields) < 2 or fields[:2] != ["allium", pins[0]]:
        raise RuntimeError(f"Allium does not match tools.txt ({pins[0]}); run just initialize")
    return binary


def _verify(command: str, project_root: Path) -> int:
    """Run one subcommand and decide whether the specifications are clean."""
    specs = _project.table(project_root, "allium").get("specs")
    if not isinstance(specs, str) or not specs.strip():
        raise RuntimeError("checks.toml: [allium] specs must be a non-empty path")
    if Path(specs).is_absolute() or ".." in Path(specs).parts:
        raise RuntimeError("checks.toml: [allium] specs must be relative to the project")
    binary = _binary(project_root)

    result = subprocess.run(
        [str(binary), command, specs],
        cwd=project_root,
        check=False,
        capture_output=True,
    )
    output = result.stdout.decode(errors="backslashreplace")
    errors = result.stderr.decode(errors="backslashreplace")
    print(output, end="")
    if errors:
        print(errors, end="", file=sys.stderr)

    blocks = _read(command, result.returncode, output, project_root, specs)
    counts = _report(blocks)
    if sum(counts.values()):
        tally = " and ".join(_count(counts[kind], kind) for kind in REPORTED if counts[kind])
        print(
            f"\nallium {command} reported {tally}; the specifications must report none.\n"
            "Fix each diagnostic and finding at its root.",
            file=sys.stderr,
        )
        return 1

    # An empty report and a non-zero status disagree. The status is not what this
    # gate trusts, so it cannot pass on one it did not expect either.
    if result.returncode != 0:
        raise RuntimeError(f"allium {command} reported nothing but exited {result.returncode}")

    print(f"allium {command}: {len(blocks)} specifications, no diagnostics and no findings.")
    return 0


def _plan(project_root: Path, module: str) -> int:
    binary = _binary(project_root)
    result = subprocess.run(
        [str(binary), "plan", module],
        cwd=project_root,
        check=False,
        capture_output=True,
        text=True,
    )
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"allium plan printed an unreadable report: {error}") from error
    if not isinstance(report, dict) or any(
        not isinstance(report.get(key), list) for key in ("diagnostics", "obligations")
    ):
        raise RuntimeError("allium plan printed a block that is not a plan")
    if report["diagnostics"] or result.returncode:
        raise RuntimeError("allium plan failed or reported diagnostics")
    print(f"allium plan: {module}: {_count(len(report['obligations']), 'obligations')}.")
    return 0


def main() -> int:
    """Run the named allium subcommand over the specifications."""
    parser = argparse.ArgumentParser(
        description="Check configured Allium specs or count a module's test obligations."
    )
    parser.add_argument("command", choices=COMMANDS, help="the allium subcommand to run")
    parser.add_argument("module", nargs="?", help="module path (required for plan)")
    arguments = parser.parse_args()
    if (arguments.command == "plan") != (arguments.module is not None):
        parser.error("plan requires a module path; check and analyse use checks.toml")
    project_root = _project.root()
    try:
        if arguments.command == "plan":
            return _plan(project_root, arguments.module)
        return _verify(arguments.command, project_root)
    except (RuntimeError, OSError) as error:
        # OSError is the binary passing its version check and then refusing to
        # run: a race with `just initialize`, or a filesystem that moved
        # underneath. RuntimeError is a report this gate could not judge.
        print(f"\nrun_allium: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
