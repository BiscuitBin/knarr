"""Compare the hand-written /version fixture with captured replies (ticket 35).

Usage: python3 version_fixture.py <repository root>

Ticket 08 cut the `kind_version_body` constant in
test/sans_io_example_test.gleam down from a kind v1.35.8 reply by hand. Ticket
14 later captured two real replies from that node version: version.json from
the local kind cluster (linux/arm64), and the one-line reply in s1-kind.txt
from the cluster-s1 CI job (native linux/amd64). For every field the fixture
holds, this prints its JSON type and value beside both captures. Exits 1 if a
type differs, or if any value but `platform`, which follows the machine,
differs.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

DECODED = ("major", "minor", "gitVersion")
MAY_DIFFER = {"platform"}


def fixture(root: Path) -> dict[str, object]:
    """Return the fixture body the Gleam test decodes, as JSON."""
    source = (root / "test/sans_io_example_test.gleam").read_text()
    found = re.search(r'const kind_version_body =\n  "((?:[^"\\]|\\.)*)"', source)
    if found is None:
        sys.exit("kind_version_body not found in test/sans_io_example_test.gleam")
    return json.loads(found.group(1).replace('\\"', '"'))


def ci_capture(root: Path) -> dict[str, object]:
    """Return the /version reply the cluster-s1 CI job printed on one line."""
    lines = (root / ".scratch/bootstrap/evidence/14/s1-kind.txt").read_text().splitlines()
    marker = next(i for i, line in enumerate(lines) if line.startswith("--- /version, one line"))
    return json.loads(lines[marker + 1])


def kind(value: object) -> str:
    """Name a value's JSON type."""
    return {str: "string", bool: "boolean", int: "number", float: "number"}.get(
        type(value), type(value).__name__
    )


def main() -> int:
    """Print the comparison and return 1 on a disagreement."""
    root = Path(sys.argv[1])
    body = fixture(root)
    captures = {
        "local kind, linux/arm64 (14 version.json)": json.loads(
            (root / ".scratch/bootstrap/evidence/14/version.json").read_text()
        ),
        "CI kind, linux/amd64 (14 s1-kind.txt)": ci_capture(root),
    }
    bad = 0
    print(f"fixture fields: {', '.join(body)}; the decoder reads {', '.join(DECODED)}")
    for name, reply in captures.items():
        print(f"\n== {name}: {len(reply)} fields, gitCommit {reply.get('gitCommit')}")
        for key, value in body.items():
            got = reply.get(key)
            same_type = key in reply and kind(got) == kind(value)
            same_value = got == value
            if not same_type:
                verdict = "FAIL type"
            elif same_value:
                verdict = "ok"
            elif key in MAY_DIFFER:
                verdict = "ok   (value differs with the machine)"
            else:
                verdict = "FAIL value"
            bad += verdict.startswith("FAIL")
            print(
                f"{verdict:<4} {key}: fixture {kind(value)} {value!r}, captured {kind(got)} {got!r}"
            )
    print(
        f"\nversion_fixture: {'every field type matches' if bad == 0 else f'{bad} disagreement(s)'}"
    )
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
