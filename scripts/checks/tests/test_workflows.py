"""The GitHub workflows: every action pinned, and what release.yml may do.

The YAML is read line by line, as test_hook_configs.py reads the prek configs:
the standard library has no YAML parser and knarr installs no PyPI package.
The rules for release.yml are Decision 0012's: it runs on a version tag only,
its token can write packages only in the job behind the release environment,
and the existence guard pushes only when the tag is absent. publish also builds
only the commit verify checked, and stops if the tag has moved since.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from conftest import REPOSITORY

GITHUB = REPOSITORY / ".github"
WORKFLOWS = sorted(
    [*GITHUB.glob("workflows/*.y*ml"), *GITHUB.glob("actions/*/action.y*ml")],
)
RELEASE = GITHUB / "workflows/release.yml"
AUDIT = GITHUB / "workflows/audit.yml"
PINNED_USES = re.compile(r"[^@\s]+@[0-9a-f]{40} # v\d+\.\d+\.\d+")
VERSION_TAGS = [
    "on:",
    "  push:",
    "    tags:",
    '      - "v[0-9]+.[0-9]+.[0-9]+"',
    '      - "v[0-9]+.[0-9]+.[0-9]+-rc.[0-9]+"',
]


def unpinned_uses(text: str) -> list[str]:
    """Every remote `uses:` that is not `@<40 hex> # vX.Y.Z`. Comments are skipped."""
    uses = [re.match(r"^\s*(?:-\s+)?uses:\s*(.*?)\s*$", line) for line in text.splitlines()]
    return [
        match.group(1)
        for match in uses
        if match
        and not match.group(1).startswith("./")
        and not PINNED_USES.fullmatch(match.group(1))
    ]


def top_level(text: str, key: str) -> list[str]:
    """The lines of one top-level key's block, comments and blank lines left out."""
    block: list[str] = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            if block:
                break
            if line.split(":", 1)[0] == key:
                block.append(line)
        elif block:
            block.append(line)
    return block


def jobs(text: str) -> dict[str, list[str]]:
    """Each job's lines under `jobs:`, comments and blank lines left out."""
    found: dict[str, list[str]] = {}
    current: list[str] = []
    for line in top_level(text, "jobs")[1:]:
        if match := re.fullmatch(r"  ([\w-]+):", line):
            current = found[match.group(1)] = []
        else:
            current.append(line)
    return found


def mapping(job: list[str], name: str) -> dict[str, str] | str | None:
    """A job's `name:` mapping, its inline value (such as write-all), or None."""
    for index, line in enumerate(job):
        if match := re.fullmatch(rf"    {name}:\s*(.*?)", line):
            if match.group(1):
                return match.group(1)
            entries: dict[str, str] = {}
            for later in job[index + 1 :]:
                if not later.startswith("      "):
                    break
                key, _, value = later.strip().partition(":")
                entries[key] = value.strip()
            return entries
    return None


def permissions(job: list[str]) -> dict[str, str] | str | None:
    """A job's `permissions:` scopes, its inline value (such as write-all), or None."""
    return mapping(job, "permissions")


def environment(job: list[str]) -> str | None:
    return next(
        (m.group(1) for line in job if (m := re.fullmatch(r"    environment:\s*(.*?)", line))),
        None,
    )


def guard_arms(text: str) -> list[tuple[str, str]]:
    """The existence guard's `case $verdict in` arms, as (pattern, body)."""
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "case $verdict in")
    arms: list[tuple[str, str]] = []
    for line in lines[start + 1 :]:
        if line.strip() == "esac":
            return arms
        pattern, _, body = line.strip().partition(")")
        arms.append((pattern, body))
    msg = "no esac after case $verdict in"
    raise ValueError(msg)


def proceeds_only_on_absent(arms: list[tuple[str, str]]) -> bool:
    patterns = [pattern for pattern, _ in arms]
    return (
        patterns.count("absent") == 1
        and "*" in patterns
        and not re.search(r"\bexit\b", dict(arms)["absent"])
        and all(re.search(r"\bexit 1\b", body) for pattern, body in arms if pattern != "absent")
    )


@pytest.mark.parametrize(
    ("workflow", "unpinned"),
    [
        (
            "steps:\n  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n",
            [],
        ),
        ("steps:\n  - uses: ./.github/actions/setup\n", []),
        ("steps:\n  # - uses: actions/attest@v4\n", []),
        ("steps:\n  - uses: actions/checkout@v7\n", ["actions/checkout@v7"]),
        (
            "steps:\n  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n",
            ["actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"],
        ),
        (
            "    - uses: a/b@3d3c42e5aac5ba805825da76410c181273ba90b1 # main\n",
            ["a/b@3d3c42e5aac5ba805825da76410c181273ba90b1 # main"],
        ),
    ],
)
def test_the_pin_rule_itself(workflow: str, unpinned: list[str]) -> None:
    assert unpinned_uses(workflow) == unpinned


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: str(p.relative_to(GITHUB)))
def test_every_remote_action_is_pinned_to_a_full_commit_sha(path: Path) -> None:
    assert unpinned_uses(path.read_text()) == []


def test_the_pin_rule_reads_the_release_workflow() -> None:
    assert RELEASE in WORKFLOWS


@pytest.mark.parametrize(
    "extra",
    [
        "  workflow_dispatch:\n",
        "  pull_request:\n",
        "    branches: [main]\n",
        '      - "v*"\n',
    ],
)
def test_the_trigger_rule_refuses_any_other_trigger(extra: str) -> None:
    workflow = "\n".join([*VERSION_TAGS, ""]) + extra + "permissions: {}\n"
    assert top_level(workflow, "on") != VERSION_TAGS


def test_release_runs_on_version_tags_only() -> None:
    assert top_level(RELEASE.read_text(), "on") == VERSION_TAGS


def test_release_grants_nothing_at_the_top() -> None:
    text = RELEASE.read_text()
    assert top_level(text, "permissions") == ["permissions: {}"]
    assert top_level("permissions: write-all\n", "permissions") != ["permissions: {}"]


@pytest.mark.parametrize(
    ("job", "scopes"),
    [
        ("    permissions:\n      contents: read\n", {"contents": "read"}),
        ("    permissions: write-all\n", "write-all"),
        ("    runs-on: ubuntu-24.04\n", None),
        (
            "    permissions:\n      contents: read\n      id-token: write\n    steps: []\n",
            {"contents": "read", "id-token": "write"},
        ),
    ],
)
def test_the_permissions_reader_itself(job: str, scopes: object) -> None:
    assert permissions(job.splitlines()) == scopes


def test_release_jobs_get_only_the_scopes_they_need() -> None:
    found = jobs(RELEASE.read_text())
    assert set(found) == {"verify", "publish"}
    assert permissions(found["verify"]) == {"contents": "read"}
    assert environment(found["verify"]) is None
    assert permissions(found["publish"]) == {"contents": "read", "packages": "write"}
    assert environment(found["publish"]) == "release"


@pytest.mark.parametrize(
    "arms",
    [
        "absent) echo pushing ;;\npresent) exit 1 ;;\n",
        "absent) echo pushing ;;\npresent) exit 1 ;;\nunknown) echo hm ;;\n*) exit 1 ;;\n",
        "absent|unknown) echo pushing ;;\n*) exit 1 ;;\n",
        "absent) echo pushing; exit 1 ;;\n*) exit 1 ;;\n",
        "present) exit 1 ;;\n*) echo pushing ;;\n",
    ],
    ids=["no catch-all", "an arm that proceeds", "absent or unknown", "absent stops", "no absent"],
)
def test_the_guard_rule_refuses_any_other_way_through(arms: str) -> None:
    case = f"          case $verdict in\n{arms}          esac\n"
    assert not proceeds_only_on_absent(guard_arms(case))


def probes_before_it_pushes(lines: list[str]) -> bool:
    """The existence guard probes $VERSION and reads the verdict before the one push."""
    steps = [line.strip() for line in lines]
    probe = [
        i
        for i, line in enumerate(steps)
        if line.startswith('probe_tag https://ghcr.io "$repo" "$VERSION" ')
    ]
    guard = [i for i, line in enumerate(steps) if line == "case $verdict in"]
    push = [i for i, line in enumerate(steps) if "--push" in line]
    return len(probe) == len(guard) == len(push) == 1 and probe[0] < guard[0] < push[0]


@pytest.mark.parametrize(
    "steps",
    [
        [
            "docker buildx build --push .",
            'probe_tag https://ghcr.io "$repo" "$VERSION" -H x',
            "case $verdict in",
        ],
        [
            'probe_tag https://ghcr.io "$repo" 0.1.0 -H x',
            "case $verdict in",
            "docker buildx build --push .",
        ],
        [
            "case $verdict in",
            'probe_tag https://ghcr.io "$repo" "$VERSION" -H x',
            "docker buildx build --push .",
        ],
    ],
    ids=["push first", "a fixed tag", "verdict before the probe"],
)
def test_the_order_rule_refuses_a_guard_that_does_not_guard(steps: list[str]) -> None:
    assert not probes_before_it_pushes(steps)


def test_release_probes_the_version_before_it_pushes() -> None:
    assert probes_before_it_pushes(jobs(RELEASE.read_text())["publish"])


def test_release_pushes_only_when_the_tag_is_absent() -> None:
    arms = guard_arms(RELEASE.read_text())
    assert [pattern for pattern, _ in arms] == ["absent", "present", "*"]
    assert proceeds_only_on_absent(arms)


def test_verify_hands_publish_the_commit_it_checked() -> None:
    verify = jobs(RELEASE.read_text())["verify"]
    assert mapping(verify, "outputs") == {
        "version": "${{ steps.guards.outputs.version }}",
        "commit": "${{ steps.guards.outputs.commit }}",
    }
    assert 'echo "commit=$commit" >> "$GITHUB_OUTPUT"' in [line.strip() for line in verify]


# The lines, in order, by which publish refuses a tag that no longer names the
# commit verify checked: the checkout's copy of the tag may be the one the run
# was triggered with, so the tag is fetched again before it is compared.
MOVED_TAG_GUARD = [
    "COMMIT: ${{ needs.verify.outputs.commit }}",
    'git fetch --depth=1 --no-tags origin "+refs/tags/$TAG:refs/tags/$TAG"',
    'tagged=$(git rev-parse "refs/tags/$TAG^{commit}")',
    "head=$(git rev-parse HEAD)",
    'if [ "$tagged" != "$COMMIT" ] || [ "$head" != "$COMMIT" ]; then',
]


def refuses_a_moved_tag_before_it_pushes(lines: list[str]) -> bool:
    """The tag, fetched again, and HEAD are both compared with verify's commit, and a
    difference stops the job, before the one push."""
    steps = [line.strip() for line in lines]
    push = [i for i, line in enumerate(steps) if "--push" in line]
    if len(push) != 1 or not all(line in steps for line in MOVED_TAG_GUARD):
        return False
    at = [steps.index(line) for line in MOVED_TAG_GUARD]
    stops = at[-1] + 1 < len(steps) and re.search(r"\bexit 1\b", steps[at[-1] + 1])
    return at == sorted(at) and bool(stops) and at[-1] < push[0]


GUARDED = [*MOVED_TAG_GUARD, 'echo "::error::moved"; exit 1', "fi"]


@pytest.mark.parametrize(
    "steps",
    [
        ["docker buildx build --push .", *GUARDED],
        [*GUARDED[:4], 'if [ "$tagged" != "$COMMIT" ]; then', *GUARDED[5:], "--push ."],
        [*GUARDED[:4], 'if [ "$head" != "$COMMIT" ]; then', *GUARDED[5:], "--push ."],
        [GUARDED[0], *GUARDED[2:], "docker buildx build --push ."],
        [*GUARDED[:5], 'echo "::warning::moved"', "fi", "docker buildx build --push ."],
    ],
    ids=[
        "push first",
        "only the tag compared",
        "only HEAD compared",
        "the checkout's tag",
        "a difference that does not stop",
    ],
)
def test_the_moved_tag_rule_refuses_a_check_that_does_not_check(steps: list[str]) -> None:
    assert not refuses_a_moved_tag_before_it_pushes(steps)


def test_the_moved_tag_rule_accepts_the_guard_before_the_push() -> None:
    assert refuses_a_moved_tag_before_it_pushes([*GUARDED, "docker buildx build --push ."])


def test_release_builds_only_the_commit_verify_checked() -> None:
    publish = jobs(RELEASE.read_text())["publish"]
    assert refuses_a_moved_tag_before_it_pushes(publish)
    steps = [line.strip() for line in publish]
    assert 'for t in $(tags_for "$TAG" "$COMMIT"); do set -- "$@" --tag "$IMAGE:$t"; done' in steps
    assert '--label "org.opencontainers.image.revision=$COMMIT" \\' in steps
    assert not any("git rev-parse" in line for line in steps[steps.index(MOVED_TAG_GUARD[-1]) :])


def test_audit_scans_the_runtime_environment_after_a_red_image_scan_but_not_without_an_image() -> (
    None
):
    # The OS-package scan is red until Ubuntu republishes libssl3t64 (Decision
    # 0014), and a step after a failed one is skipped unless its `if:` says so.
    steps = [line.strip() for line in jobs(AUDIT.read_text())["image-scan"]]
    build = steps.index("- id: build")
    assert steps[build + 1] == "run: just image-build"
    guard = steps.index("- if: ${{ !cancelled() && steps.build.outcome == 'success' }}")
    assert steps[guard + 1] == "run: just runtime-scan"
    assert build < steps.index("- run: just image-scan") < guard
