"""Explicit checker-test ownership and conservative, offline CI selection."""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "scripts/checks/tests"
# Each module belongs to exactly one group. Inputs name implementation dependencies,
# not documents/configuration the actual gate already validates on every run.
GROUPS = {
    "policy": ("dependency_pins hook_configs workflows fake_worker_manifest checker_suite", ()),
    "docs": (
        "validate_docs",
        ("scripts/checks/validate_docs.py", "scripts/checks/render_markdown.mjs"),
    ),
    "agents": ("validate_agents", ("scripts/checks/validate_agents.py",)),
    "environment": (
        "env_check install_tools install_hooks with_env",
        (
            "scripts/initialize.sh",
            "scripts/install-*.sh",
            "scripts/with-env.sh",
            "scripts/checks/env_check.py",
        ),
    ),
    "manifest": ("manifest_check", ("scripts/checks/manifest_check.py",)),
    "allium": ("run_allium", ("scripts/checks/run_allium.py",)),
    "gate": (
        "project run_project_check run_glinter lint_cold_build",
        (
            "scripts/checks/_project.py",
            "scripts/checks/run_project_check.py",
            "scripts/checks/run_glinter.sh",
        ),
    ),
    "coverage": (
        "coverage",
        (
            "scripts/checks/coverage*",
            "scripts/checks/manifest_check.py",
            "src/knarr/application_ffi.erl",
            "test/knarr_test.gleam",
        ),
    ),
    "packaging": (
        "image prune_runtime container_entrypoint",
        (
            "Dockerfile",
            ".dockerignore",
            "scripts/checks/image.py",
            "scripts/prune_runtime.py",
            "scripts/container-entrypoint.sh",
        ),
    ),
    "deployment": (
        "deployment fake_worker_manifests",
        (
            "deploy/**",
            "fixtures/fake_worker/deploy/**",
            "scripts/schemas/**",
            "scripts/checks/deployment.py",
        ),
    ),
    "cluster": (
        "cluster_commands cluster_name fake_worker_cluster",
        ("scripts/checks/cluster.py", "scripts/cluster-name.sh"),
    ),
    "release": (
        "release_lib release_pin",
        ("scripts/release/**", ".github/workflows/release.yml"),
    ),
    "audit": (
        "hex_audit runtime_scan ripsecrets_redacted",
        (
            "scripts/checks/hex_audit.py",
            "scripts/checks/runtime_scan.py",
            "scripts/checks/ripsecrets-redacted.sh",
            ".github/workflows/audit.yml",
        ),
    ),
    "controller-process": (
        "application",
        ("src/**", "test/**", "Dockerfile", "scripts/container-entrypoint.sh"),
    ),
    "worker-process": ("fake_worker_process", ("fixtures/fake_worker/**",)),
}
RUNTIME = {"controller-process", "worker-process"}
SHARED = (
    "justfile",
    "Justfile",
    "pixi.*",
    "tools*.txt",
    "gleam.toml",
    "manifest.toml",
    "fixtures/fake_worker/gleam.toml",
    "fixtures/fake_worker/manifest.toml",
    "pytest.toml",
    "checks.toml",
    "scripts/checks/checker_suite.py",
    "scripts/checks/tests/conftest.py",
    "scripts/checks/_project.py",
    "scripts/initialize.sh",
    "scripts/install-tools.sh",
    ".github/actions/**",
    ".github/workflows/ci.yml",
)
PASSIVE = (
    "docs/**",
    "*.md",
    ".scratch/**",
    ".agents/**",
    ".claude/**",
    "skills-lock.json",
    "LICENSE*",
    ".github/ISSUE_TEMPLATE/**",
    ".github/renovate.json",
    ".gitignore",
    ".gitattributes",
    ".editorconfig",
    ".pre-commit*.yaml",
    "*ruff.toml",
    "*taplo.toml",
    "_typos.toml",
    ".markdownlint*",
    ".lychee*",
    "test/**",
    "src/**",
    "fixtures/fake_worker/**",
)
CLUSTERS = {
    "kind": (
        "src/**",
        "Dockerfile",
        ".dockerignore",
        "deploy/**",
        "scripts/checks/image.py",
        "scripts/prune_runtime.py",
        "scripts/container-entrypoint.sh",
        "scripts/checks/deployment.py",
        "scripts/schemas/**",
    ),
    "worker": (
        "fixtures/fake_worker/**",
        "scripts/checks/image.py",
        "scripts/prune_runtime.py",
        "scripts/container-entrypoint.sh",
        "scripts/checks/deployment.py",
        "scripts/schemas/**",
    ),
    "kwok": ("deploy/**", "scripts/checks/deployment.py", "scripts/schemas/**"),
}


def matches(path: str, patterns: tuple[str, ...]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def modules(groups: set[str]) -> list[str]:
    return sorted(
        f"scripts/checks/tests/test_{name}.py"
        for group in groups
        for name in GROUPS[group][0].split()
    )


def validate() -> None:
    expected = modules(set(GROUPS))
    actual = {str(p.relative_to(ROOT)) for p in TESTS.glob("test_*.py")}
    if len(expected) != len(set(expected)) or set(expected) != actual:
        raise ValueError(f"test ownership mismatch: {sorted(set(expected) ^ actual)}")


def select(paths: list[str] | None) -> dict:
    groups: set[str] = set()
    clusters: set[str] = set()
    if paths is None:
        groups.update(GROUPS)
        clusters.update(CLUSTERS)
    else:
        for path in paths:
            if matches(path, SHARED):
                return select(None)
            owned = False
            for group, (_, patterns) in GROUPS.items():
                if path in modules({group}) or matches(path, patterns):
                    groups.add(group)
                    owned = True
            for cluster, patterns in CLUSTERS.items():
                if matches(path, patterns):
                    clusters.add(cluster)
                    owned = True
            if path in ("scripts/checks/cluster.py", "scripts/cluster-name.sh"):
                clusters.update(CLUSTERS)
            if not owned and not matches(path, PASSIVE):
                return select(None)
    return {
        "regressions": sorted(groups - RUNTIME - {"policy"}),
        "runtime": sorted(groups & RUNTIME),
        **{name: name in clusters for name in CLUSTERS},
    }


def changed_paths(base: str, head: str, pull_request: bool) -> list[str] | None:
    """Missing history is an all-tests fallback; rename detection includes both names."""
    try:
        for ref in (base, head):
            subprocess.run(
                ["git", "rev-parse", "--verify", f"{ref}^{{commit}}"],
                cwd=ROOT,
                check=True,
                capture_output=True,
            )
        if pull_request:
            base = subprocess.check_output(
                ["git", "merge-base", base, head], cwd=ROOT, text=True
            ).strip()
        result = subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", base, head, "--"], cwd=ROOT
        )
        return [os.fsdecode(p) for p in result.split(b"\0") if p]
    except subprocess.CalledProcessError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["fast", "all", "selected", "ci"])
    parser.add_argument("groups", nargs="*")
    args = parser.parse_args()
    if not set(args.groups) <= GROUPS.keys():
        parser.error("unknown checker group")
    validate()
    if args.mode == "ci":
        result = select(
            changed_paths(
                os.environ.get("CI_BASE", ""),
                os.environ.get("CI_HEAD", ""),
                os.environ.get("CI_EVENT") == "pull_request",
            )
        )
        print(json.dumps(result, sort_keys=True))
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.writelines(f"{key}={json.dumps(value)}\n" for key, value in result.items())
        return 0
    if args.mode == "selected":
        groups = set(args.groups or json.loads(os.environ.get("CHECKER_GROUPS", "[]")))
        if not groups <= GROUPS.keys():
            parser.error("unknown checker group")
    else:
        groups = {"policy"} if args.mode == "fast" else set(GROUPS)
    if not groups:
        print("No checker groups selected.")
        return 0
    if groups & {"coverage", "gate", "controller-process"}:
        subprocess.run(["just", "build"], cwd=ROOT, check=True)
    if "worker-process" in groups:
        subprocess.run(["just", "fake-worker-build"], cwd=ROOT, check=True)
    return subprocess.call([sys.executable, "-m", "pytest", *modules(groups)], cwd=ROOT)


if __name__ == "__main__":
    raise SystemExit(main())
