"""Offline validation with immutable, checksum-verified upstream schemas.

kubeconform validates the fake worker fixture's resources (ticket 29). The
chart's render is validated by `chart.py render`, which calls validate() here
(Decision 0015).
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "scripts/schemas/kubernetes"
FAKE_WORKER = ROOT / "fixtures/fake_worker/deploy/resources.json"


def verify(source=SCHEMAS):
    provenance = json.loads((source / "sources.json").read_text())
    for name, hashes in provenance["files"].items():
        content = (source / name).read_bytes()
        if hashlib.sha256(content).hexdigest() != hashes["sha256"]:
            raise ValueError(f"upstream schema checksum mismatch: {name}")


def validate(content):
    subprocess.run(
        [
            "kubeconform",
            "-strict",
            "-summary",
            "-schema-location",
            str(SCHEMAS / "{{.ResourceKind}}{{.KindSuffix}}.json"),
        ],
        input=content,
        text=True,
        check=True,
    )


def main():
    verify()
    if sys.argv[1:]:
        raise ValueError("usage: deployment.py")
    validate(FAKE_WORKER.read_text())


if __name__ == "__main__":
    main()
