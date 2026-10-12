"""Offline validation with immutable, checksum-verified upstream schemas.

With no arguments, kubeconform validates the base resources and the fake worker
fixture's (ticket 29), which is not a deploy/ variant. With --render, kustomize
renders every variant under deploy/ and kubeconform validates each; the release
overlay may then differ from the base only in the container image, to the
published one pinned by digest, and its pull policy (Decision 0012). With
--render <variant>, it renders and validates that one.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "scripts/schemas/kubernetes"
DEPLOY = ROOT / "deploy"
FAKE_WORKER = ROOT / "fixtures/fake_worker/deploy/resources.json"
# What each line the release overlay changes must become.
RELEASE_VALUES = {
    "image": re.compile(r"ghcr\.io/steven-cutting/knarr@sha256:[0-9a-f]{64}"),
    "imagePullPolicy": re.compile(r"IfNotPresent"),
}


def variants():
    """Every deployable directory under deploy/: the base and its variants."""
    return sorted(
        path.name for path in DEPLOY.iterdir() if (path / "kustomization.yaml").is_file()
    )


def render(variant):
    if variant not in variants():
        raise ValueError(f"unknown deployment variant: {variant}")
    return subprocess.check_output(["kustomize", "build", str(DEPLOY / variant)], text=True)


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


def overlay_difference(base, release):
    """The release render's image, if it differs from the base render in exactly
    the image and pull-policy lines, as overlay-render.sh in ticket 28 required."""
    base_lines, release_lines = base.splitlines(), release.splitlines()
    if len(release_lines) != len(base_lines):
        raise ValueError(
            f"the release render has {len(release_lines)} lines and the base"
            f" {len(base_lines)}: the overlay adds or removes something"
        )
    changed = {}
    for index, (before, after) in enumerate(zip(base_lines, release_lines, strict=True)):
        if before == after:
            continue
        match = re.fullmatch(r"(\s*(?:- )?)(image|imagePullPolicy): (\S+)", after)
        if (
            not match
            or not before.startswith(f"{match.group(1)}{match.group(2)}: ")
            or match.group(2) in changed
            or not RELEASE_VALUES[match.group(2)].fullmatch(match.group(3))
        ):
            raise ValueError(f"the overlay changes {before.strip()!r} to {after.strip()!r}")
        changed[match.group(2)] = (index, len(match.group(1)), match.group(3))
    missing = [key for key in RELEASE_VALUES if key not in changed]
    if missing:
        raise ValueError(f"the overlay does not change {' or '.join(missing)}")
    # kustomize sorts each container's keys, so its imagePullPolicy is the line
    # after its image, at the same depth.
    image_at, image_depth, image = changed["image"]
    policy_at, policy_depth, _ = changed["imagePullPolicy"]
    if (policy_at, policy_depth) != (image_at + 1, image_depth):
        raise ValueError(
            "the overlay pins the image of one container and the pull policy of another"
        )
    return image


def main():
    verify()
    arguments = sys.argv[1:]
    if not arguments:
        validate((DEPLOY / "base/resources.json").read_text())
        validate(FAKE_WORKER.read_text())
    elif arguments == ["--render"]:
        renders = {}
        for variant in variants():
            print(f"rendering deploy/{variant}")
            renders[variant] = render(variant)
            validate(renders[variant])
        image = overlay_difference(renders["base"], renders["release"])
        print(f"release overlay: image {image}, imagePullPolicy IfNotPresent, nothing else")
    elif len(arguments) == 2 and arguments[0] == "--render":
        validate(render(arguments[1]))
    else:
        raise ValueError("usage: deployment.py [--render [variant]]")


if __name__ == "__main__":
    main()
