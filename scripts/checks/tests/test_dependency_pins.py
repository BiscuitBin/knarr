"""The pins Renovate proposes updates for, kept in the shapes its managers read (Decision 0014).

Renovate does not run in the gate. These tests hold the files it reads to the
shapes its managers match, so a pin that a manager would stop seeing fails the
gate instead of going quiet.
"""

from __future__ import annotations

import json
import re
import tomllib
from pathlib import Path

import pytest

from conftest import REPOSITORY

RENOVATE = REPOSITORY / ".github" / "renovate.json"
DOCKERFILE = REPOSITORY / "Dockerfile"
FROM = re.compile(r"^FROM (?P<image>\S+?):(?P<tag>[^\s@]+)@sha256:[0-9a-f]{64}(?: AS \w+)?$")
WORKFLOWS = sorted(
    [
        *(REPOSITORY / ".github" / "workflows").glob("*.y*ml"),
        *(REPOSITORY / ".github" / "actions").rglob("action.y*ml"),
    ]
)
# Renovate skips an action pinned to a bare SHA: it cannot tell which tag the
# SHA belongs to without the comment.
PINNED_ACTION = re.compile(r"[\w.-]+/[\w./-]+@[0-9a-f]{40} # v\d+(?:\.\d+)*")


def test_every_base_image_is_pinned_by_digest() -> None:
    lines = [line for line in DOCKERFILE.read_text().splitlines() if line.startswith("FROM ")]
    assert len(lines) == 2
    assert [line for line in lines if not FROM.match(line)] == []


def unpinned_actions(text: str) -> list[str]:
    """Every remote `uses:` that is not a full commit SHA followed by a version comment."""
    uses = [
        match["target"]
        for match in re.finditer(r"^\s*(?:-\s+)?uses:\s*(?P<target>.+?)\s*$", text, re.MULTILINE)
    ]
    return [
        target
        for target in uses
        if not target.startswith("./") and not PINNED_ACTION.fullmatch(target)
    ]


@pytest.mark.parametrize(
    ("workflow", "unpinned"),
    [
        ("steps:\n  - uses: ./.github/actions/setup\n", []),
        (
            "steps:\n  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n",
            [],
        ),
        (
            "steps:\n  - uses: actions/checkout@v7\n",
            ["actions/checkout@v7"],
        ),
        (
            "steps:\n  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n",
            ["actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"],
        ),
        (
            "    - uses: prefix-dev/setup-pixi@d3f436a425481402e6a95a1d1fc10331c708cd9e # main\n",
            ["prefix-dev/setup-pixi@d3f436a425481402e6a95a1d1fc10331c708cd9e # main"],
        ),
    ],
)
def test_the_action_pin_rule_itself(workflow: str, unpinned: list[str]) -> None:
    assert unpinned_actions(workflow) == unpinned


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: str(p.relative_to(REPOSITORY)))
def test_every_remote_action_is_pinned_to_a_sha_with_its_version(path: Path) -> None:
    assert unpinned_actions(path.read_text()) == []


def config() -> dict:
    return json.loads(RENOVATE.read_text())


def settings(value: object, key: str) -> list[object]:
    """Every value `key` takes anywhere in the configuration, however deep."""
    if isinstance(value, dict):
        own = [value[key]] if key in value else []
        return own + [found for item in value.values() for found in settings(item, key)]
    if isinstance(value, list):
        return [found for item in value for found in settings(item, key)]
    return []


def test_nothing_merges_without_a_review() -> None:
    renovate = config()
    assert renovate["automerge"] is False
    assert renovate["platformAutomerge"] is False
    assert settings(renovate, "automerge") == [False]
    assert settings(renovate, "platformAutomerge") == [False]


# RE2, which Renovate's regex manager uses, has no lookaround and no
# backreferences, and spells a named group `(?<name>...)`.
NOT_RE2 = re.compile(r"\(\?(?:=|!|<=|<!)|\\[1-9]")


def regex_managers() -> list[dict]:
    managers = config()["customManagers"]
    assert managers
    assert {manager["customType"] for manager in managers} == {"regex"}
    return managers


def applies_to(manager: dict, path: str) -> bool:
    patterns = manager["managerFilePatterns"]
    assert all(p.startswith("/") and p.endswith("/") for p in patterns), patterns
    return any(re.search(pattern[1:-1], path) for pattern in patterns)


def dependencies(path: str) -> list[dict[str, str]]:
    """What the regex managers extract from one repository file, as Renovate would."""
    text = (REPOSITORY / path).read_text()
    found = []
    for manager in regex_managers():
        if not applies_to(manager, path):
            continue
        for match_string in manager["matchStrings"]:
            assert not NOT_RE2.search(match_string), match_string
            pattern = re.compile(match_string.replace("(?<", "(?P<"))
            for match in pattern.finditer(text):
                dependency = {
                    field.removesuffix("Template"): value
                    for field, value in manager.items()
                    if field in {"depNameTemplate", "datasourceTemplate", "versioningTemplate"}
                }
                dependency.update({k: v for k, v in match.groupdict().items() if v is not None})
                assert {"depName", "currentValue", "datasource"} <= set(dependency), dependency
                found.append(dependency)
    return found


def test_every_image_in_the_cluster_adapter_is_matched() -> None:
    path = "scripts/checks/cluster.py"
    pinned = set(re.findall(r'"([^"\s]+@sha256:[0-9a-f]{64})"', (REPOSITORY / path).read_text()))
    assert len(pinned) == 6
    extracted = dependencies(path)
    assert {d["datasource"] for d in extracted} == {"docker"}
    assert {
        f"{d['depName']}:{d['currentValue']}@{d['currentDigest']}" for d in extracted
    } == pinned


# Where the pixi version is written, and the one value each place holds.
PIXI_SITES = {
    "pixi.toml": r'^requires-pixi = ">=(\S+)"$',
    ".github/actions/setup/action.yml": r"^\s+pixi-version: v(\S+)$",
    ".github/actions/setup/action.yml cache": r"^\s+cache-key: knarr-pixi-v(\S+?)-$",
    "Dockerfile": r"^FROM ghcr\.io/prefix-dev/pixi:([^\s@]+)@",
    "README.md": r"\[pixi\]\(https://pixi\.sh\) (\S+) or later",
}


def pixi_versions() -> dict[str, str]:
    versions = {}
    for site, pattern in PIXI_SITES.items():
        found = re.findall(pattern, (REPOSITORY / site.split()[0]).read_text(), re.MULTILINE)
        assert len(found) == 1, (site, found)
        versions[site] = found[0]
    return versions


def test_the_pixi_version_agrees_everywhere_it_is_written() -> None:
    versions = pixi_versions()
    floor = tomllib.loads((REPOSITORY / "pixi.toml").read_text())["workspace"]["requires-pixi"]
    assert floor == f">={versions['pixi.toml']}"
    assert len(set(versions.values())) == 1, versions


@pytest.mark.parametrize(
    ("path", "sites"),
    [("pixi.toml", 1), (".github/actions/setup/action.yml", 2), ("README.md", 1)],
)
def test_every_pixi_version_but_the_build_stage_is_read_against_the_image_tags(
    path: str, sites: int
) -> None:
    # The Dockerfile's FROM has the dockerfile manager. The floor, the cache key
    # and the README have no manager of their own, and setup-pixi's input is
    # read here too, because its native reading proposes nothing (renovate.txt).
    version = next(iter(set(pixi_versions().values())))
    assert (
        dependencies(path)
        == [
            {"depName": "ghcr.io/prefix-dev/pixi", "datasource": "docker", "currentValue": version}
        ]
        * sites
    )


def test_setup_pixis_native_reading_of_the_pixi_version_is_off() -> None:
    native = {
        "manager": "github-actions",
        "packageName": "prefix-dev/pixi",
        "packageFile": ".github/actions/setup/action.yml",
        "depType": "uses-with",
        "datasource": "github-releases",
    }
    assert effective(native).get("enabled") is False


def test_the_dev_dependencies_use_the_spelling_renovate_reads() -> None:
    # Gleam accepts [dev_dependencies] and [dev-dependencies] alike, and
    # manifest_check.py reads both; Renovate's gleam manager reads only the
    # second, so the first would hide every dev dependency from it.
    gleam = tomllib.loads((REPOSITORY / "gleam.toml").read_text())
    assert "dev_dependencies" not in gleam
    assert gleam["dev-dependencies"]


# The match fields the rules use, and the property of a dependency each reads.
MATCHERS = {
    "matchManagers": "manager",
    "matchPackageNames": "packageName",
    "matchFileNames": "packageFile",
    "matchDepTypes": "depType",
    "matchDatasources": "datasource",
}


def effective(dependency: dict[str, str]) -> dict[str, object]:
    """The packageRules settings one dependency ends up with.

    Renovate's own semantics, narrowed to what this configuration uses: every
    match field of a rule must hold, a list holds when it names the value
    exactly, and a later rule overrides an earlier one. A pattern or a match
    field outside MATCHERS is refused rather than modelled.
    """
    settings: dict[str, object] = {}
    for rule in config()["packageRules"]:
        fields = {key for key in rule if key.startswith("match")}
        assert fields <= set(MATCHERS), fields
        for key in fields:
            assert all(re.fullmatch(r"[\w./@-]+", value) for value in rule[key]), rule[key]
        if all(dependency.get(MATCHERS[key]) in rule[key] for key in fields):
            settings.update({k: v for k, v in rule.items() if k not in fields})
    return settings


def test_every_rule_and_custom_manager_says_why() -> None:
    renovate = config()
    for item in [*renovate["packageRules"], *renovate["customManagers"]]:
        assert item.get("description"), item


LOCAL_CLUSTER = [
    {"manager": "pixi", "packageName": name, "packageFile": "pixi.toml", "datasource": "conda"}
    for name in ("kubernetes-kind", "kubernetes-client", "kustomize")
] + [
    {
        "manager": "custom.regex",
        "packageName": d["depName"],
        "packageFile": "scripts/checks/cluster.py",
        "datasource": "docker",
    }
    for d in dependencies("scripts/checks/cluster.py")
]
PIXI = [
    {
        "manager": "dockerfile",
        "packageName": "ghcr.io/prefix-dev/pixi",
        "packageFile": "Dockerfile",
        "depType": "stage",
        "datasource": "docker",
    },
] + [
    {
        "manager": "custom.regex",
        "packageName": "ghcr.io/prefix-dev/pixi",
        "packageFile": path,
        "datasource": "docker",
    }
    for path in ("pixi.toml", ".github/actions/setup/action.yml", "README.md")
]
CONDA = {
    "manager": "pixi",
    "packageName": "erlang",
    "packageFile": "pixi.toml",
    "depType": "feature-otp",
    "datasource": "conda",
}


@pytest.mark.parametrize(
    ("dependencies_", "group"),
    [(LOCAL_CLUSTER, "local cluster"), (PIXI, "pixi"), ([CONDA], None)],
    ids=["local cluster", "pixi", "conda"],
)
def test_what_the_hosted_app_has_not_proved_stays_held_after_activation(
    dependencies_: list[dict[str, str]], group: str | None
) -> None:
    # Ticket 44 drops the landing hold, :dependencyDashboardApproval, from
    # extends; these rules keep their own. pixi.lock needs a relock the
    # hosted app may not run, and the cluster pins move together or not at all.
    for dependency in dependencies_:
        settings = effective(dependency)
        assert settings.get("dependencyDashboardApproval") is True, dependency
        assert settings.get("groupName") == group, dependency


def test_the_cluster_images_stay_on_the_kubernetes_minor_kubectl_and_the_schemas_support() -> None:
    kubernetes = [
        d
        for d in LOCAL_CLUSTER
        if d["manager"] == "custom.regex"
        and "kwok" not in d["packageName"]
        and "etcd" not in d["packageName"]
    ]
    assert len(kubernetes) == 4
    for dependency in kubernetes:
        assert effective(dependency).get("allowedVersions") == "/^v1\\.35\\./", dependency


def test_etcd_stays_on_the_minor_kwok_and_kubernetes_pair_with() -> None:
    # kwok 0.8 runs Kubernetes 1.35 on etcd 3.6; etcd 3.7 is not that pairing.
    etcd = [d for d in LOCAL_CLUSTER if d["packageName"] == "registry.k8s.io/etcd"]
    assert len(etcd) == 1
    assert effective(etcd[0]).get("allowedVersions") == "/^3\\.6\\./"


def test_the_kwok_image_moves_only_by_hand() -> None:
    # kwokctl's tools.txt line names the release the controller image comes
    # from, and no bot can rehash that line, so no bot moves the image either.
    kwok = "registry.k8s.io/kwok/kwok"
    assert [d["packageName"] for d in LOCAL_CLUSTER].count(kwok) == 1
    for dependency in LOCAL_CLUSTER:
        off = effective(dependency).get("enabled") is False
        assert off == (dependency["packageName"] == kwok), dependency


def test_a_pixi_version_without_a_digest_is_never_given_one() -> None:
    # docker:pinDigests would otherwise propose a digest for a version string
    # that has nowhere to put it.
    for dependency in PIXI:
        if dependency["manager"] == "custom.regex":
            assert effective(dependency).get("pinDigests") is False, dependency


@pytest.mark.parametrize(
    ("dependency", "group"),
    [
        (
            {
                "manager": "gleam",
                "packageName": "mist",
                "packageFile": "gleam.toml",
                "depType": "dependencies",
                "datasource": "hex",
            },
            "hex packages",
        ),
        (
            {
                "manager": "gleam",
                "packageName": "birdie",
                "packageFile": "gleam.toml",
                "depType": "devDependencies",
                "datasource": "hex",
            },
            "hex packages",
        ),
        (
            {
                "manager": "github-actions",
                "packageName": "actions/checkout",
                "packageFile": ".github/workflows/ci.yml",
                "depType": "action",
                "datasource": "github-tags",
            },
            "GitHub Actions",
        ),
        (
            {
                "manager": "github-actions",
                "packageName": "ubuntu",
                "packageFile": ".github/workflows/ci.yml",
                "depType": "github-runner",
                "datasource": "github-runners",
            },
            "GitHub Actions",
        ),
        (
            {
                "manager": "dockerfile",
                "packageName": "ubuntu",
                "packageFile": "Dockerfile",
                "depType": "final",
                "datasource": "docker",
            },
            None,
        ),
    ],
    ids=["hex", "hex dev", "actions", "runner label", "runtime base"],
)
def test_the_routine_updates_are_grouped_and_wait_only_for_the_landing_hold(
    dependency: dict[str, str], group: str | None
) -> None:
    # The runner label and the runtime base are both named ubuntu, and would
    # otherwise share one pull request.
    settings = effective(dependency)
    assert settings.get("groupName") == group
    assert "dependencyDashboardApproval" not in settings


def test_keda_moves_only_by_hand() -> None:
    # fixtures/keda_e2e/keda.json pins the release YAML by sha256 and its
    # images by digest; they move together, and no bot can rehash the YAML.
    for image in ("ghcr.io/kedacore/keda", "ghcr.io/kedacore/keda-metrics-apiserver"):
        dependency = {"manager": "custom.regex", "packageName": image, "datasource": "docker"}
        assert effective(dependency).get("enabled") is False, image
