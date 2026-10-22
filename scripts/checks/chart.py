"""Gate checks for the Helm chart under charts/knarr (Decision 0015).

lint: `helm lint --strict`, with the default values and each values file
under the chart's ci/. render: `helm template` with the same values,
validated by kubeconform -strict against the vendored schemas. version:
Chart.yaml's version and appVersion equal gleam.toml's. With no argument, all
three run.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

import deployment

ROOT = Path(__file__).resolve().parents[2]
CHART = ROOT / "charts/knarr"
# 03 installs the chart as release knarr, so its instance label is knarr too.
RELEASE = "knarr"


def values_files():
    """The extra values each render and lint uses, beside the defaults."""
    return sorted((CHART / "ci").glob("*.yaml"))


def render(*arguments, namespace="default", release=RELEASE):
    """`helm template` of the chart, as release knarr unless told otherwise;
    raises CalledProcessError with helm's stderr, for instance when the values
    fail the schema."""
    return subprocess.run(
        ["helm", "template", release, str(CHART), "--namespace", namespace, *arguments],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def canonical(rendered, patches=(), annotations=None):
    """`kustomize build` of a temporary kustomization holding the render and
    the given patch files: kustomize sorts keys and drops helm's `# Source:`
    comments, so the text is stable to compare.

    A JSON patch file targets its own kind and name, so it lands in whatever
    namespace the render is in. `annotations` join the metadata of every
    resource, never a pod template's (03's wrong-ca install marks the release's
    resources this way).
    """
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / "rendered.yaml").write_text(rendered)
        lines = [
            "apiVersion: kustomize.config.k8s.io/v1beta1",
            "kind: Kustomization",
            "resources:",
            "  - rendered.yaml",
        ]
        if patches or annotations:
            lines.append("patches:")
        for index, patch in enumerate(patches):
            name = f"patch-{index}{Path(patch).suffix}"
            text = Path(patch).read_text()
            (work / name).write_text(text)
            lines.append(f"  - path: {name}")
            if Path(patch).suffix == ".json":
                target = json.loads(text)
                lines += [
                    "    target:",
                    f"      kind: {json.dumps(target['kind'])}",
                    f"      name: {json.dumps(target['metadata']['name'])}",
                ]
        if annotations:
            # A strategic merge patch with a target takes the target's kind and
            # name, so its own are placeholders; `.*` matches every resource.
            marks = {"metadata": {"name": "any", "annotations": annotations}}
            patch = {"apiVersion": "v1", "kind": "Any", **marks}
            (work / "annotations.json").write_text(json.dumps(patch))
            lines += ["  - path: annotations.json", "    target:", '      name: ".*"']
        (work / "kustomization.yaml").write_text("\n".join(lines) + "\n")
        return subprocess.check_output(["kustomize", "build", str(work)], text=True)


def field(text, name):
    match = re.search(rf"^{name}:\s*[\"']?([^\"'\s#]+)[\"']?\s*(#.*)?$", text, re.MULTILINE)
    return match.group(1) if match else None


def version(chart_yaml, gleam_toml):
    """The shared version, if Chart.yaml's version and appVersion equal
    gleam.toml's; otherwise ValueError."""
    expected = tomllib.loads(gleam_toml)["version"]
    for name in ("version", "appVersion"):
        actual = field(chart_yaml, name)
        if actual != expected:
            raise ValueError(f"Chart.yaml {name} is {actual}, and gleam.toml's version {expected}")
    return expected


def validate(rendered):
    deployment.validate(rendered)


def lint():
    for values in [None, *values_files()]:
        extra = ["--values", str(values)] if values else []
        subprocess.run(["helm", "lint", "--strict", str(CHART), *extra], check=True)


def check_render():
    for values in [None, *values_files()]:
        validate(render(*(["--values", str(values)] if values else [])))


def check_version():
    version((CHART / "Chart.yaml").read_text(), (ROOT / "gleam.toml").read_text())


CHECKS = {
    "lint": lint,
    "render": check_render,
    "version": check_version,
}


def main(arguments):
    if not set(arguments) <= CHECKS.keys():
        raise ValueError(f"usage: chart.py [{'|'.join(CHECKS)}]...")
    deployment.verify()
    for name in arguments or CHECKS:
        try:
            CHECKS[name]()
        except subprocess.CalledProcessError as error:
            # render() captures helm's output; without this its message is lost.
            sys.stderr.write(error.stderr or "")
            sys.exit(f"chart {name}: {error}")
        print(f"chart {name}: ok")


if __name__ == "__main__":
    main(sys.argv[1:])
