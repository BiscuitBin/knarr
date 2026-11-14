"""Refuse installed tools that pixi.lock or tools.txt no longer pins, without writing.

lock-check proves that pixi.lock agrees with pixi.toml, but nothing in it reads
what is installed. After a pull that moves a pin, every recipe would still run
the old binaries through PATH, and the gate could pass without the pinned
compiler, OTP or lint rules. This compares, without running pixi:

- the packages pixi.lock pins for the default environment, on the platform pixi
    installed it for, with the package records in that environment's conda-meta/;
- each of that platform's tools.txt lines with the pin install-tools.sh recorded
    beside the binary in .tools/bin/.pins/, and each pin recorded there with a
    line that still names the tool for that platform (ticket 13 left a removed
    pin to 27).

No YAML parser is pinned, so pixi.lock is read line by line. The reader knows
lock version 7 and `- conda:` entries only, and refuses anything else rather
than guess.

Under KNARR_TOOLS=nix it proves three things instead, as Decision 0017's
environment check names them, with one evaluation that neither fetches nor
touches flake.lock:

- the default group's out-link resolves into the store;
- it is the environment this commit's flake.nix and flake.lock describe;
- gleam, erlang and allium report the versions pins.toml holds exactly, rebar3
    one at or above its floor, and openssl the version the flake built Erlang
    against.

When the optional cluster group is installed (`just cluster-install`), it
proves the same of that group's out-link, with a second evaluation: it is the
group this commit describes, kind and kwokctl report the versions pins.toml
holds exactly, and kubectl one in the minor it holds. Without the group it
asks nothing more. The audit group's grype is not held, so it is not checked.

Usage: python3 scripts/checks/env_check.py [project-directory]

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

import _pins
import _tools

ENVIRONMENT = "default"
CLUSTER = "cluster"
LOCK_VERSION = 7
ARCHIVES = (".conda", ".tar.bz2")
NIX_EVAL = ("nix", "eval", "--json", "--offline", "--no-update-lock-file")
# What the check needs from the flake: the out path this commit describes, and
# the OpenSSL its Erlang is built with, which pins.toml does not name.
DESCRIBE = "environment: { out = environment.outPath; openssl = environment.opensslVersion; }"
# The full OTP version is in a file; erlang:system_info(otp_release) is the major only.
OTP_VERSION = (
    '{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", '
    'erlang:system_info(otp_release), "OTP_VERSION"])), io:put_chars(string:trim(V)), halt().'
)


def _refuse(message: str) -> NoReturn:
    print(f"env-check: {message}", file=sys.stderr)
    raise SystemExit(2)


def _platform(prefix: Path) -> str:
    """The platform pixi installed the environment for, from its own record."""
    record = prefix / "conda-meta" / "pixi"
    if not record.is_file():
        _refuse(f"{record} is missing; run just initialize")
    try:
        subdir = json.loads(record.read_text(encoding="utf-8"))["resolved_platform"]["subdir"]
    except ValueError, KeyError, TypeError:
        subdir = None
    if not isinstance(subdir, str):
        _refuse(f"{record} names no resolved platform; run just initialize")
    return subdir


def _record_name(url: str) -> str:
    basename = url.rsplit("/", 1)[-1]
    for suffix in ARCHIVES:
        if basename.endswith(suffix):
            return basename.removesuffix(suffix)
    return _refuse(f"pixi.lock entry {url} is not a {' or '.join(ARCHIVES)} archive")


def locked(lock: Path, platform: str) -> set[str]:
    """`name-version-build` of every package pixi.lock pins for ENVIRONMENT on `platform`."""
    if not lock.is_file():
        _refuse(f"{lock} is missing")
    lines = lock.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != f"version: {LOCK_VERSION}":
        _refuse(f"{lock} is not lock version {LOCK_VERSION}, the only one this reader knows")
    target = ["environments:", f"{ENVIRONMENT}:", "packages:", f"{platform}:"]
    keys: dict[int, str] = {}
    found: set[str] = set()
    for number, line in enumerate(lines[1:], start=2):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        # pixi writes list items at their key's own indent, so the entries of
        # the target platform sit at indent 6 and nothing in it sits deeper.
        inside = [keys.get(level) for level in (0, 2, 4, 6)] == target
        if inside and (indent > 6 or (indent == 6 and text.startswith("- "))):
            entry = re.fullmatch(r"- conda: (\S+)", text)
            if indent > 6 or entry is None:
                _refuse(f"{lock}:{number}: an entry this reader cannot check: {text}")
            found.add(_record_name(entry[1]))
            continue
        if text.startswith("- "):
            continue
        keys = {level: key for level, key in keys.items() if level < indent}
        keys[indent] = text
    if not found:
        _refuse(f"{lock} pins no packages for the {ENVIRONMENT} environment on {platform}")
    return found


def _package_drift(project: Path, prefix: Path, platform: str) -> list[str]:
    pinned = locked(project / "pixi.lock", platform)
    installed = {path.stem for path in (prefix / "conda-meta").glob("*.json")}
    return [
        *(f"  {name}: pinned by pixi.lock, not installed" for name in sorted(pinned - installed)),
        *(f"  {name}: installed, not pinned by pixi.lock" for name in sorted(installed - pinned)),
    ]


def _tool_drift(project: Path, platform: str) -> list[str]:
    pins = project / "tools.txt"
    if not pins.is_file():
        _refuse(f"{pins} is missing")
    tools = project / ".tools" / "bin"
    drift = []
    named = set()
    for line in pins.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        if len(fields) != 6:
            _refuse(f"{pins}: malformed line for {fields[0]}")
        name, version, pinned_for = fields[:3]
        if pinned_for != platform:
            continue
        named.add(name)
        stamp = tools / ".pins" / name
        recorded = stamp.read_text(encoding="utf-8").split() if stamp.is_file() else []
        if not os.access(tools / name, os.X_OK) or recorded != fields:
            have = recorded[1] if len(recorded) > 1 else "nothing"
            drift.append(f"  {name}: tools.txt pins {version}, .tools/bin holds {have}")
    # A stamp is what install-tools.sh left beside a binary it installed, so a
    # stamp no line names is a tool whose pin was removed. Its `*` glob skips
    # hidden files, so they are not stamps.
    stamps = tools / ".pins"
    for stamp in sorted(stamps.iterdir()) if stamps.is_dir() else []:
        if stamp.is_file() and not stamp.name.startswith(".") and stamp.name not in named:
            try:
                recorded = stamp.read_text(encoding="utf-8").split()
            except UnicodeDecodeError:
                recorded = []
            have = recorded[1] if len(recorded) > 1 else "an unreadable pin"
            drift.append(f"  {stamp.name}: tools.txt pins nothing, .tools/bin holds {have}")
    return drift


def _reported(command: list[str], field: int) -> str | None:
    """The version a tool prints about itself, or None when it cannot run."""
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
    except OSError:
        return None
    fields = result.stdout.split()
    return fields[field] if result.returncode == 0 and len(fields) > field else None


def _numbers(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", version))


def _held(project: Path) -> dict[str, dict[str, str]]:
    try:
        return _pins.held(project)
    except _pins.PinsError as error:
        _refuse(str(error))


def _held_drift(project: Path, tools: Path, openssl: str) -> list[str]:
    held = _held(project)
    exact = held["exact"]
    reported = {
        "gleam": _reported([str(tools / "gleam"), "--version"], 1),
        "erlang": _reported([str(tools / "erl"), "-noshell", "-eval", OTP_VERSION], 0),
        "allium": _reported([str(tools / "allium"), "--version"], 1),
        "rebar3": _reported([str(tools / "rebar3"), "--version"], 1),
        "openssl": _reported([str(tools / "openssl"), "version"], 1),
    }
    drift = [f"  {name} cannot run" for name, have in reported.items() if have is None]
    for name in ("gleam", "erlang", "allium"):
        have = reported[name]
        if have is not None and have != exact[name]:
            drift.append(f"  {name} reports {have}, pins.toml holds {exact[name]}")
    floor = held["floor"]["rebar3"]
    if reported["rebar3"] is not None and _numbers(reported["rebar3"]) < _numbers(floor):
        drift.append(f"  rebar3 reports {reported['rebar3']}, below {floor}")
    if reported["openssl"] is not None and reported["openssl"] != openssl:
        drift.append(f"  openssl reports {reported['openssl']}, Erlang is built with {openssl}")
    return drift


def _describe(project: Path, group: str) -> tuple[str, str] | str:
    """The out path and OpenSSL version this commit's flake gives `group`, or why
    it could not say."""
    result = subprocess.run(
        [*NIX_EVAL, f"{project}#{group}", "--apply", DESCRIBE],
        check=False,
        capture_output=True,
        text=True,
    )
    try:
        described = json.loads(result.stdout) if result.returncode == 0 else None
        return described["out"], described["openssl"]
    except ValueError, KeyError, TypeError:
        return f"  this commit's flake does not evaluate offline: {result.stderr.strip()}"


def _cluster_drift(project: Path) -> tuple[list[str], str | None]:
    """The installed cluster group's drift, and its out-link's target when it has one.

    Nothing is asked when the group is not installed: it is optional."""
    link = _tools.prefix(project, CLUSTER)
    if not os.path.lexists(link):
        return [], None
    try:
        have = link.readlink()
    except OSError:
        return [f"  {link} is not an out-link"], None
    if not (have / "bin").is_dir():
        return [f"  {link} points at {have}, which is not in the store"], None
    described = _describe(project, CLUSTER)
    if isinstance(described, str):
        return [described], None
    if str(have) != described[0]:
        return [f"  {link} is {have}, but this commit describes {described[0]}"], None
    held = _held(project)
    tools = have / "bin"
    reported = {
        "kind": _reported([str(tools / "kind"), "version"], 1),
        "kubectl": _reported([str(tools / "kubectl"), "version", "--client"], 2),
        "kwokctl": _reported([str(tools / "kwokctl"), "--version"], 2),
    }
    drift = []
    for name, have_version in reported.items():
        if have_version is None:
            drift.append(f"  {name} cannot run")
            continue
        version = have_version.removeprefix("v")
        if name == "kubectl":
            minor = held["minor"][name]
            if ".".join(version.split(".")[:2]) != minor:
                drift.append(f"  {name} reports {version}, pins.toml holds minor {minor}")
        elif version != held["exact"][name]:
            drift.append(f"  {name} reports {version}, pins.toml holds {held['exact'][name]}")
    return drift, str(have)


def _nix(project: Path) -> int:
    project = project.resolve()
    link = _tools.prefix(project, ENVIRONMENT)
    try:
        have = link.readlink()
    except OSError:
        _refuse(f"{link} is not an out-link; run just initialize")
    if not (have / "bin").is_dir():
        _refuse(f"{link} points at {have}, which is not in the store; run just initialize")
    described = _describe(project, ENVIRONMENT)
    if isinstance(described, str):
        drift = [described]
    elif str(have) != described[0]:
        drift = [f"  {link} is {have}, but this commit describes {described[0]}"]
    else:
        drift = _held_drift(project, have / "bin", described[1])
    cluster_drift, cluster = _cluster_drift(project)
    if not drift and not cluster_drift:
        print(f"env-check: {link} is {have}, and the held versions match")
        if cluster is not None:
            print(
                f"env-check: {_tools.prefix(project, CLUSTER)} is {cluster}, and the held versions match"
            )
        return 0
    if drift:
        print("\n".join(drift))
        print(
            "the installed tools differ from this commit's flake.lock or pins.toml; run just "
            "initialize (it needs network for anything not already cached)"
        )
    if cluster_drift:
        print("\n".join(cluster_drift))
        print(
            "the installed cluster group differs from this commit's flake.lock or pins.toml; "
            "run just cluster-install (it needs network for anything not already cached)"
        )
    return 1


def main() -> int:
    project = Path(sys.argv[1]) if len(sys.argv) > 1 else Path()
    try:
        backend = _tools.backend()
    except _tools.SelectorError as error:
        _refuse(str(error))
    if backend == "nix":
        return _nix(project)
    prefix = project / ".pixi" / "envs" / ENVIRONMENT
    platform = _platform(prefix)
    drift = [*_package_drift(project, prefix, platform), *_tool_drift(project, platform)]
    if not drift:
        print(f"the {ENVIRONMENT} environment and .tools/bin match the pins ({platform})")
        return 0
    print("\n".join(drift))
    print(
        "the installed tools differ from pixi.lock or tools.txt; run just initialize "
        "(it needs network for anything not already cached)"
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
