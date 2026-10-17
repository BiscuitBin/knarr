"""Gate checks for the Helm chart under charts/knarr (Decision 0015).

lint: `helm lint --strict`, with the default values and each values file
under the chart's ci/. render: `helm template` with the same values,
validated by kubeconform -strict against the vendored schemas. drift: the
render with the local values, canonicalised by kustomize, may differ from
`kustomize build deploy/base` only by inserted lines on an allowlist: the
namespace of each resource and of the RoleBinding's subject, and Helm's
labels outside the Deployment's selector. version: Chart.yaml's version and
appVersion equal gleam.toml's. With no argument, all four run.
"""

from __future__ import annotations

import difflib
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
BASE = ROOT / "deploy/base"
# 03 installs the chart as release knarr, so its instance label is knarr too.
RELEASE = "knarr"
# Helm's recommended labels, the only label keys the chart adds to the base.
LABEL = re.compile(r"(app\.kubernetes\.io/(name|instance|version|managed-by)|helm\.sh/chart)")


def values_files():
    """The extra values each render and lint uses, beside the defaults."""
    return sorted((CHART / "ci").glob("*.yaml"))


def render(*arguments, namespace="default"):
    """`helm template` of the chart as release knarr; raises CalledProcessError
    with helm's stderr, for instance when the values fail the schema."""
    return subprocess.run(
        ["helm", "template", RELEASE, str(CHART), "--namespace", namespace, *arguments],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def canonical(rendered, patches=(), annotations=None):
    """`kustomize build` of a temporary kustomization holding the render and
    the given patch files: the same key order and layout as the base's build.

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


def paths(text):
    """For each line of a kustomize render, its key and the keys enclosing it.

    kustomize writes block YAML with two-space indents and list items at their
    parent key's indent, so a key's depth is its indent plus two for each
    `- ` before it, and its parents are the keys open at a lesser depth.
    """
    stack: list[tuple[int, str]] = []
    for line in text.splitlines():
        if line == "---":
            stack = []
            yield line, (), ""
            continue
        body = line.lstrip(" ")
        depth = len(line) - len(body)
        while body.startswith("- "):
            body = body[2:]
            depth += 2
        key = body.split(":", 1)[0] if re.match(r"[^\s\"'{\[][^:]*:( |$)", body) else ""
        while stack and stack[-1][0] >= depth:
            stack.pop()
        yield line, tuple(name for _, name in stack), key
        if key:
            stack.append((depth, key))


def allowed(parents, key):
    if key == "namespace":
        return parents in (("metadata",), ("subjects",))
    if key == "labels":
        return parents == ("metadata",)
    return (
        bool(LABEL.fullmatch(key))
        and parents[-1:] == ("labels",)
        and "metadata" in parents
        and "selector" not in parents
    )


def drift(base, rendered):
    """The lines the canonical chart render inserts into the base's build, if
    every difference is an inserted line the allowlist names; otherwise
    ValueError naming the first other difference."""
    base_lines = base.splitlines()
    located = list(paths(rendered))
    chart_lines = [line for line, _, _ in located]
    inserted = []
    matcher = difflib.SequenceMatcher(a=base_lines, b=chart_lines, autojunk=False)
    for tag, low, high, chart_low, chart_high in matcher.get_opcodes():
        if tag == "equal":
            continue
        if tag != "insert":
            removed = "\n".join(base_lines[low:high])
            added = "\n".join(chart_lines[chart_low:chart_high])
            raise ValueError(f"the chart's render changes {removed!r} to {added!r}")
        for line, parents, key in located[chart_low:chart_high]:
            if not allowed(parents, key):
                where = ".".join((*parents, key)) or line.strip()
                raise ValueError(f"the chart's render inserts {line.strip()!r} at {where}")
            inserted.append(line)
    return inserted


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


def check_drift():
    base = subprocess.check_output(["kustomize", "build", str(BASE)], text=True)
    drift(base, canonical(render()))


def check_version():
    version((CHART / "Chart.yaml").read_text(), (ROOT / "gleam.toml").read_text())


CHECKS = {
    "lint": lint,
    "render": check_render,
    "drift": check_drift,
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
