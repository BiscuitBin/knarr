"""The GitHub workflows: every action pinned, and what release.yml may do.

The YAML is read line by line, as test_hook_configs.py reads the prek configs:
the standard library has no YAML parser and knarr installs no PyPI package.
The rules for release.yml are Decision 0012's: it runs on a version tag only,
its token can write packages only in the job behind the release environment,
and the existence guard pushes only when the tag is absent. publish also builds
only the commit verify checked, and stops if the tag has moved since, and attests
each push it makes, the image and then the chart, with one pinned action
(helm-chart ticket 07, Decision 0015).
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


def arms_after(lines: list[str], start: int) -> list[tuple[str, str]]:
    """The arms of the `case $verdict in` at lines[start], as (pattern, body)."""
    arms: list[tuple[str, str]] = []
    for line in lines[start + 1 :]:
        if line.strip() == "esac":
            return arms
        pattern, _, body = line.strip().partition(")")
        arms.append((pattern, body))
    msg = "no esac after case $verdict in"
    raise ValueError(msg)


def guards(text: str) -> list[list[tuple[str, str]]]:
    """Every existence guard's `case $verdict in` arms, in order."""
    lines = text.splitlines()
    return [
        arms_after(lines, i) for i, line in enumerate(lines) if line.strip() == "case $verdict in"
    ]


def guard_arms(text: str) -> list[tuple[str, str]]:
    """The first existence guard's arms, as (pattern, body)."""
    lines = text.splitlines()
    return arms_after(
        lines, next(i for i, line in enumerate(lines) if line.strip() == "case $verdict in")
    )


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
    # id-token and attestations are attest-build-provenance's, and no more: storage
    # records would need artifact-metadata too, so both attest steps turn them off.
    assert permissions(found["publish"]) == {
        "contents": "read",
        "packages": "write",
        "id-token": "write",
        "attestations": "write",
    }
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


def push_target(line: str) -> str | None:
    """The repository variable a push line's guard must probe: the image's buildx
    `--push` probes "$repo", a `helm push` of the chart probes "$chart_repo"."""
    if "--push" in line:
        return '"$repo"'
    if re.search(r"\bhelm push\b", line):
        return '"$chart_repo"'
    return None


def probes_before_it_pushes(lines: list[str]) -> bool:
    """Every push has its own guard: a probe of its own repository at $VERSION, then
    `case $verdict in`, both after the previous push and before this one. Other
    complete guards may stand between, as the chart's first guard stands before the
    image push. So an earlier guard that refuses stops the job before any later push."""
    steps = [line.strip() for line in lines]
    probe: str | None = None
    guarded: list[str] = []
    pushes = 0
    for line in steps:
        if line.startswith("probe_tag "):
            if probe is not None:
                return False
            probe = line
        elif line == "case $verdict in":
            if probe is None:
                return False
            guarded.append(probe)
            probe = None
        elif target := push_target(line):
            own = f'probe_tag https://ghcr.io {target} "$VERSION" '
            if probe is not None or not any(g.startswith(own) for g in guarded):
                return False
            guarded = []
            pushes += 1
    return pushes > 0 and probe is None


IMAGE_GUARD = [
    'probe_tag https://ghcr.io "$repo" "$VERSION" -H x',
    "case $verdict in",
    "docker buildx build --push .",
]
CHART_GUARD = [
    'probe_tag https://ghcr.io "$chart_repo" "$VERSION" -H x',
    "case $verdict in",
    'out=$(helm push "$package" oci://ghcr.io/biscuitbin/charts 2>&1)',
]


@pytest.mark.parametrize(
    "steps",
    [
        [IMAGE_GUARD[2], *IMAGE_GUARD[:2]],
        ['probe_tag https://ghcr.io "$repo" 0.1.0 -H x', *IMAGE_GUARD[1:]],
        [IMAGE_GUARD[1], IMAGE_GUARD[0], IMAGE_GUARD[2]],
        [],
        [*IMAGE_GUARD, CHART_GUARD[2]],
        [*IMAGE_GUARD, CHART_GUARD[2], *CHART_GUARD[:2]],
        [*IMAGE_GUARD, 'probe_tag https://ghcr.io "$repo" "$VERSION" -H x', *CHART_GUARD[1:]],
        [*IMAGE_GUARD, CHART_GUARD[0], *CHART_GUARD[2:]],
        [*IMAGE_GUARD[:2], CHART_GUARD[2], IMAGE_GUARD[2], *CHART_GUARD[:2]],
        [*CHART_GUARD[:2], IMAGE_GUARD[2]],
        [*IMAGE_GUARD[:2], *CHART_GUARD[:2], IMAGE_GUARD[2], CHART_GUARD[2]],
    ],
    ids=[
        "push first",
        "a fixed tag",
        "verdict before the probe",
        "no push at all",
        "a chart push with no probe",
        "a chart push before its guard",
        "a chart guard that probes the image",
        "a chart push with no verdict",
        "a chart push before the image is pushed",
        "an image guard that probes the chart",
        "a chart push guarded only before the image push",
    ],
)
def test_the_order_rule_refuses_a_guard_that_does_not_guard(steps: list[str]) -> None:
    assert not probes_before_it_pushes(steps)


@pytest.mark.parametrize(
    "steps",
    [
        IMAGE_GUARD,
        [*IMAGE_GUARD, *CHART_GUARD],
        [*CHART_GUARD[:2], *IMAGE_GUARD, *CHART_GUARD],
        [*IMAGE_GUARD[:2], *CHART_GUARD[:2], IMAGE_GUARD[2], *CHART_GUARD],
    ],
    ids=[
        "the image",
        "the image and chart",
        "the chart probed first",
        "the chart probed after the image's guard",
    ],
)
def test_the_order_rule_accepts_each_push_behind_its_own_guard(steps: list[str]) -> None:
    assert probes_before_it_pushes(steps)


def test_release_probes_the_version_before_it_pushes() -> None:
    assert probes_before_it_pushes(jobs(RELEASE.read_text())["publish"])


def probes_the_chart_before_any_push(lines: list[str]) -> bool:
    """The chart's version is probed, and its verdict read, before the first push of
    any kind, so a chart that exists or cannot be probed stops the job with nothing
    published (Decision 0015)."""
    steps = [line.strip() for line in lines]
    pushes = [i for i, line in enumerate(steps) if push_target(line)]
    probes = [
        i
        for i, line in enumerate(steps)
        if line.startswith('probe_tag https://ghcr.io "$chart_repo" "$VERSION" ')
    ]
    if not pushes or not probes or probes[0] > pushes[0]:
        return False
    after = [
        line
        for line in steps[probes[0] + 1 : pushes[0]]
        if line.startswith("probe_tag ") or line == "case $verdict in"
    ]
    return bool(after) and after[0] == "case $verdict in"


@pytest.mark.parametrize(
    "steps",
    [
        [*IMAGE_GUARD, *CHART_GUARD],
        [CHART_GUARD[0], *IMAGE_GUARD, *CHART_GUARD],
        [*CHART_GUARD[:2]],
    ],
    ids=["the chart probed only after the image push", "no verdict on the chart", "no push"],
)
def test_the_chart_first_rule_refuses_a_chart_probed_late(steps: list[str]) -> None:
    assert not probes_the_chart_before_any_push(steps)


def test_release_probes_the_chart_before_the_image_push() -> None:
    publish = jobs(RELEASE.read_text())["publish"]
    assert probes_the_chart_before_any_push([*CHART_GUARD[:2], *IMAGE_GUARD, *CHART_GUARD])
    assert probes_the_chart_before_any_push(publish)


def test_release_pushes_only_when_the_tag_is_absent() -> None:
    for arms in guards(RELEASE.read_text()):
        assert [pattern for pattern, _ in arms] == ["absent", "present", "*"]
        assert proceeds_only_on_absent(arms)


def test_release_pushes_the_image_and_then_the_chart() -> None:
    publish = [line.strip() for line in jobs(RELEASE.read_text())["publish"]]
    targets = [target for line in publish if (target := push_target(line))]
    assert targets == ['"$repo"', '"$chart_repo"']
    # The chart's first guard, the image's, and the chart's again before its push.
    assert len(guards(RELEASE.read_text())) == 3


def stops_at_the_image_guard(lines: list[str]) -> bool:
    """A rerun of a run that pushed the image and not the chart meets `present` at the
    image's guard, whose present arm exits 1, before any chart push; and no step of
    the job runs on after a failure (no `continue-on-error`, no `if:` at all)."""
    steps = [line.strip() for line in lines]
    if not probes_before_it_pushes(steps):
        return False
    if any(re.match(r"(- )?(continue-on-error|if):", line) for line in steps):
        return False
    probe = next(
        i for i, line in enumerate(steps) if line.startswith('probe_tag https://ghcr.io "$repo" ')
    )
    image_guard = steps.index("case $verdict in", probe)
    arms = arms_after(steps, image_guard)
    charts = [i for i, line in enumerate(steps) if push_target(line) == '"$chart_repo"']
    return (
        bool(charts)
        and image_guard < charts[0]
        and re.search(r"\bexit 1\b", dict(arms).get("present", "")) is not None
    )


IMAGE_ARMS = ["absent) echo pushing ;;", "present) exit 1 ;;", "*) exit 1 ;;", "esac"]


@pytest.mark.parametrize(
    "steps",
    [
        [
            *IMAGE_GUARD[:2],
            "absent) echo pushing ;;",
            "present) echo published ;;",
            "*) exit 1 ;;",
            "esac",
            IMAGE_GUARD[2],
            *CHART_GUARD,
        ],
        ["continue-on-error: true", *IMAGE_GUARD[:2], *IMAGE_ARMS, IMAGE_GUARD[2], *CHART_GUARD],
        [*IMAGE_GUARD[:2], *IMAGE_ARMS, IMAGE_GUARD[2], "- if: always()", *CHART_GUARD],
        [*CHART_GUARD, *IMAGE_GUARD[:2], *IMAGE_ARMS, IMAGE_GUARD[2]],
    ],
    ids=[
        "present does not stop",
        "the guard's failure is ignored",
        "the chart runs after a failure",
        "the chart first",
    ],
)
def test_the_rerun_rule_refuses_a_job_that_would_push_the_chart(steps: list[str]) -> None:
    assert not stops_at_the_image_guard(steps)


def test_a_rerun_after_a_partial_publish_stops_at_the_image_guard() -> None:
    # Decision 0015: the image present and the chart absent is recovered by a
    # version bump, never by a chart-only push of an existing version.
    assert stops_at_the_image_guard(
        [
            *IMAGE_GUARD[:2],
            *IMAGE_ARMS,
            IMAGE_GUARD[2],
            *CHART_GUARD[:2],
            *IMAGE_ARMS,
            CHART_GUARD[2],
        ]
    )
    assert stops_at_the_image_guard(jobs(RELEASE.read_text())["publish"])


def attestations(lines: list[str]) -> list[tuple[int, str, dict[str, str]]]:
    """Each attest-build-provenance step in a job's unstripped lines, as (index, its
    `uses:` value, its `with:` inputs), whether `uses:` opens the step or follows its
    `- name:`. The step's keys sit at the depth of `uses:`, and it ends at the first
    line shallower than them."""
    found: list[tuple[int, str, dict[str, str]]] = []
    for index, line in enumerate(lines):
        match = re.fullmatch(r"( *)(- )?uses: (actions/attest-build-provenance@.*)", line)
        if not match:
            continue
        key = len(match.group(1)) + len(match.group(2) or "")
        inputs: dict[str, str] = {}
        within = False
        for later in lines[index + 1 :]:
            depth = len(later) - len(later.lstrip())
            if depth < key:
                break
            if depth == key:
                within = later.strip() == "with:"
            elif within:
                name, _, value = later.strip().partition(":")
                inputs[name] = value.strip()
        found.append((index, match.group(3), inputs))
    return found


# The subject each push's attestation names, by the repository its guard probes.
SUBJECTS = {
    '"$repo"': ("${{ env.IMAGE }}", "${{ env.DIGEST }}"),
    '"$chart_repo"': ("${{ env.CHART }}", "${{ env.CHART_DIGEST }}"),
}


def attests_each_push(lines: list[str]) -> bool:
    """After the last push, one attest step per push, in push order, each on that
    push's name and digest, pushing the attestation to the registry and creating no
    storage record (that needs artifact-metadata: write, a scope 38 does not add).
    Attesting only once both are pushed means a failed attestation never leaves an
    image with no chart. Every attest step uses the same pin, so the image and the
    chart are attested one way (Decision 0015)."""
    pushes = [(i, target) for i, line in enumerate(lines) if (target := push_target(line))]
    steps = attestations(lines)
    if not pushes or len({uses for _, uses, _ in steps}) != 1:
        return False
    if any(at < pushes[-1][0] for at, _, _ in steps):
        return False
    expected = [
        {
            "subject-name": SUBJECTS[target][0],
            "subject-digest": SUBJECTS[target][1],
            "push-to-registry": "true",
            "create-storage-record": "false",
        }
        for _, target in pushes
    ]
    return [inputs for _, _, inputs in steps] == expected


ATTEST_PIN = "actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2"
REGISTRY_ONLY = ("push-to-registry: true", "create-storage-record: false")


def attest_step(
    name: str,
    digest: str,
    *,
    inputs: tuple[str, ...] = REGISTRY_ONLY,
    pin: str = ATTEST_PIN,
    named: bool = False,
) -> list[str]:
    """An attest step as release.yml writes it, or, `named`, with `- name:` first."""
    opening = (
        ["      - name: Attest", f"        uses: {pin}"] if named else [f"      - uses: {pin}"]
    )
    return [
        *opening,
        "        with:",
        f"          subject-name: ${{{{ env.{name} }}}}",
        f"          subject-digest: ${{{{ env.{digest} }}}}",
        *(f"          {line}" for line in inputs),
    ]


IMAGE_PUSH = [
    "      - name: Build and push",
    "        run: |",
    "          docker buildx build --push .",
]
CHART_PUSH = [
    "      - name: Push the chart",
    "        run: |",
    f"          {CHART_GUARD[2]}",
]
IMAGE_ATTEST = attest_step("IMAGE", "DIGEST")
CHART_ATTEST = attest_step("CHART", "CHART_DIGEST")
IMAGE_INPUTS = {
    "subject-name": "${{ env.IMAGE }}",
    "subject-digest": "${{ env.DIGEST }}",
    "push-to-registry": "true",
    "create-storage-record": "false",
}


@pytest.mark.parametrize(
    ("lines", "uses_at"),
    [
        ([*IMAGE_ATTEST, "      - name: next", "        with:", "          other: input"], 0),
        ([*attest_step("IMAGE", "DIGEST", named=True), "      - name: next", "        with:"], 1),
    ],
    ids=["uses first", "name first"],
)
def test_the_attestations_reader_reads_one_step(lines: list[str], uses_at: int) -> None:
    assert attestations(lines) == [(uses_at, ATTEST_PIN, IMAGE_INPUTS)]


@pytest.mark.parametrize(
    "steps",
    [
        [*IMAGE_PUSH, *CHART_PUSH, *IMAGE_ATTEST],
        [*IMAGE_PUSH, *CHART_PUSH, *CHART_ATTEST],
        [*IMAGE_PUSH, *CHART_PUSH, *CHART_ATTEST, *IMAGE_ATTEST],
        [*IMAGE_PUSH, *IMAGE_ATTEST, *CHART_PUSH, *CHART_ATTEST],
        [*IMAGE_ATTEST, *IMAGE_PUSH, *CHART_PUSH, *CHART_ATTEST],
        [*IMAGE_PUSH, *CHART_PUSH, *IMAGE_ATTEST, *IMAGE_ATTEST, *CHART_ATTEST],
        [*IMAGE_PUSH, *CHART_PUSH, *IMAGE_ATTEST, *attest_step("IMAGE", "CHART_DIGEST")],
        [*IMAGE_PUSH, *CHART_PUSH, *IMAGE_ATTEST, *attest_step("CHART", "DIGEST")],
        [
            *IMAGE_PUSH,
            *CHART_PUSH,
            *IMAGE_ATTEST,
            *attest_step("CHART", "CHART_DIGEST", inputs=("create-storage-record: false",)),
        ],
        [
            *IMAGE_PUSH,
            *CHART_PUSH,
            *IMAGE_ATTEST,
            *attest_step("CHART", "CHART_DIGEST", inputs=("push-to-registry: true",)),
        ],
        [
            *IMAGE_PUSH,
            *CHART_PUSH,
            *IMAGE_ATTEST,
            *attest_step(
                "CHART",
                "CHART_DIGEST",
                pin="actions/attest-build-provenance@e8998f949152b193b063cb0ec769d69d929409be # v2.4.0",
            ),
        ],
        [
            *IMAGE_PUSH,
            *CHART_PUSH,
            *IMAGE_ATTEST,
            *CHART_ATTEST,
            *attest_step("CHART", "CHART_DIGEST", inputs=(), named=True),
        ],
        [*IMAGE_ATTEST, *CHART_ATTEST],
    ],
    ids=[
        "no chart attestation",
        "no image attestation",
        "the chart attested first",
        "the image attested before the chart is pushed",
        "the image attested before its push",
        "the image attested twice",
        "a chart attestation naming the image",
        "a chart attestation on the image digest",
        "no push to the registry",
        "storage records left on",
        "two pins",
        "a third step under a name",
        "no push at all",
    ],
)
def test_the_attest_rule_refuses_a_push_it_does_not_attest(steps: list[str]) -> None:
    assert not attests_each_push(steps)


@pytest.mark.parametrize(
    "steps",
    [
        [*IMAGE_PUSH, *CHART_PUSH, *IMAGE_ATTEST, *CHART_ATTEST],
        [*IMAGE_PUSH, *CHART_PUSH, *attest_step("IMAGE", "DIGEST", named=True), *CHART_ATTEST],
    ],
    ids=["as release.yml writes them", "one step under a name"],
)
def test_the_attest_rule_accepts_both_attested_after_both_pushes(steps: list[str]) -> None:
    assert attests_each_push(steps)


def test_release_attests_the_image_and_then_the_chart() -> None:
    found = jobs(RELEASE.read_text())
    assert attests_each_push(found["publish"])
    assert attestations(found["verify"]) == []


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
    difference stops the job, before the first push."""
    steps = [line.strip() for line in lines]
    push = [i for i, line in enumerate(steps) if push_target(line)]
    if not push or not all(line in steps for line in MOVED_TAG_GUARD):
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


def test_release_publishes_under_the_biscuitbin_org() -> None:
    text = RELEASE.read_text()
    assert "  IMAGE: ghcr.io/biscuitbin/knarr" in top_level(text, "env")
    assert "  CHART: ghcr.io/biscuitbin/charts/knarr" in top_level(text, "env")
    assert '--label "org.opencontainers.image.source=https://github.com/biscuitbin/knarr"' in text
