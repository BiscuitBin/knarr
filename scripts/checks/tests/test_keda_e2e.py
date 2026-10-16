"""The KEDA end-to-end harness (ticket 33): its judges, and one round against a fake.

The real run is `just keda-e2e` on kind, in the gated keda-e2e workflow; these
pin what the harness accepts as a pass, what it calls a failure or a void run,
and the order in which one scale-in round drives the cluster.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import urllib.parse
from pathlib import Path

import pytest

import cluster
import keda_e2e
from conftest import REPOSITORY


def test_a_download_whose_hash_differs_from_the_pin_is_refused() -> None:
    body = b"kind: Namespace\n"
    pin = hashlib.sha256(body).hexdigest()
    assert keda_e2e.verify_download(body, pin) == body
    with pytest.raises(ValueError, match="sha256 mismatch"):
        keda_e2e.verify_download(body + b"#", pin)


def test_the_harness_refuses_kwok(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    # Before it names the cluster or touches a kubeconfig.
    monkeypatch.setenv("KNARR_CLUSTER", "kwok")
    with pytest.raises(ValueError, match="keda-e2e requires kind"):
        cluster.environment("keda-e2e", tmp_path)


def test_the_scaled_object_scales_only_the_worker_and_without_delay() -> None:
    scaled = json.loads((REPOSITORY / "fixtures/keda_e2e/scaledobject.json").read_text())
    spec = scaled["spec"]
    # Never the collector: its records are the count.
    assert spec["scaleTargetRef"] == {"name": "fake-worker"}
    # Replicas follow the bounds alone: equal bounds, and a cron window that
    # opens for one minute a year.
    assert spec["minReplicaCount"] == spec["maxReplicaCount"] == keda_e2e.PODS
    assert [trigger["type"] for trigger in spec["triggers"]] == ["cron"]
    assert spec["triggers"][0]["metadata"]["start"] == "0 0 1 1 *"
    behavior = spec["advanced"]["horizontalPodAutoscalerConfig"]["behavior"]
    for direction in ("scaleDown", "scaleUp"):
        assert behavior[direction] == {
            "stabilizationWindowSeconds": 0,
            "policies": [{"type": "Percent", "value": 100, "periodSeconds": 15}],
        }


def test_the_keda_pins_name_a_release_and_both_core_images() -> None:
    pins = json.loads((REPOSITORY / "fixtures/keda_e2e/keda.json").read_text())
    version = pins["version"]
    assert pins["url"] == (
        f"https://github.com/kedacore/keda/releases/download/v{version}/keda-{version}-core.yaml"
    )
    assert len(pins["sha256"]) == 64
    assert [pin.split("@")[0] for pin in pins["images"]] == [
        f"ghcr.io/kedacore/keda:{version}",
        f"ghcr.io/kedacore/keda-metrics-apiserver:{version}",
    ]


OPERATOR = "ghcr.io/kedacore/keda:2.21.0@sha256:" + "a" * 64
METRICS = "ghcr.io/kedacore/keda-metrics-apiserver:2.21.0@sha256:" + "b" * 64
WEBHOOKS = "ghcr.io/kedacore/keda-admission-webhooks:2.21.0@sha256:" + "c" * 64
MANIFEST = """\
kind: CustomResourceDefinition
                                image:
                                    description: Container image name.
---
kind: Deployment
        image: ghcr.io/kedacore/keda-metrics-apiserver:2.21.0
---
kind: Deployment
        image: "ghcr.io/kedacore/keda:2.21.0"
"""
# A container whose first key is its image.
LIST_ITEM = (
    MANIFEST
    + """---
kind: Deployment
        - image: ghcr.io/kedacore/keda-admission-webhooks:2.21.0
"""
)


def test_the_kustomization_pins_every_image_the_release_names_to_its_digest() -> None:
    text = keda_e2e.keda_kustomization([OPERATOR, METRICS], MANIFEST, "keda-core.yaml")
    assert text == (
        "apiVersion: kustomize.config.k8s.io/v1beta1\n"
        "kind: Kustomization\n"
        "resources:\n"
        "  - keda-core.yaml\n"
        "images:\n"
        "  - name: ghcr.io/kedacore/keda\n"
        f"    digest: sha256:{'a' * 64}\n"
        "  - name: ghcr.io/kedacore/keda-metrics-apiserver\n"
        f"    digest: sha256:{'b' * 64}\n"
    )


def test_an_image_written_as_a_list_item_must_be_pinned_too() -> None:
    with pytest.raises(
        ValueError, match=r"unpinned image ghcr\.io/kedacore/keda-admission-webhooks"
    ):
        keda_e2e.keda_kustomization([OPERATOR, METRICS], LIST_ITEM, "keda-core.yaml")
    assert "keda-admission-webhooks" in keda_e2e.keda_kustomization(
        [OPERATOR, METRICS, WEBHOOKS], LIST_ITEM, "keda-core.yaml"
    )


@pytest.mark.parametrize(
    ("pins", "refusal"),
    [
        ([OPERATOR], "unpinned image ghcr.io/kedacore/keda-metrics-apiserver:2.21.0"),
        (
            [OPERATOR, METRICS.replace(":2.21.0@", ":2.20.2@")],
            "unpinned image ghcr.io/kedacore/keda-metrics-apiserver:2.21.0",
        ),
        (
            [OPERATOR, METRICS, WEBHOOKS],
            "pinned image not in the release: ghcr.io/kedacore/keda-admission-webhooks:2.21.0",
        ),
        ([OPERATOR, METRICS.split("@", maxsplit=1)[0]], "not name:tag@sha256"),
    ],
    ids=["missing", "other-tag", "extra", "no-digest"],
)
def test_the_kustomization_refuses_pins_that_do_not_match_the_release(
    pins: list[str], refusal: str
) -> None:
    with pytest.raises(ValueError, match=refusal):
        keda_e2e.keda_kustomization(pins, MANIFEST, "keda-core.yaml")


def test_the_bounds_patch_sets_both_replica_counts() -> None:
    assert keda_e2e.scaled_object_bounds(3, 3) == {
        "spec": {"minReplicaCount": 3, "maxReplicaCount": 3}
    }
    with pytest.raises(ValueError, match="minimum 4 above maximum 3"):
        keda_e2e.scaled_object_bounds(4, 3)


PODS = [f"fake-worker-{suffix}" for suffix in ("a1", "b2", "c3", "d4", "e5", "f6")]


def test_the_busy_split_is_seeded_and_ignores_listing_order() -> None:
    busy, idle = keda_e2e.pick_busy(PODS, 33, 1)
    assert len(busy) == len(idle) == 3
    assert sorted(busy + idle) == PODS
    assert keda_e2e.pick_busy(list(reversed(PODS)), 33, 1) == (busy, idle)
    # Each round, and each seed, draws its own split.
    splits = {tuple(keda_e2e.pick_busy(PODS, seed, n)[0]) for seed in (33, 34) for n in (1, 2, 3)}
    assert len(splits) > 1


def record(pod: str, *, busy: bool) -> dict[str, object]:
    return {"pod": pod, "busy": busy, "cost": 1800 if busy else 0, "accepting": True}


def test_busy_kills_count_only_the_rounds_victims() -> None:
    records = [
        record("w-a", busy=True),
        record("w-b", busy=False),
        record("w-c", busy=True),
        # A pod the round did not scale away; round_victims refuses the round
        # before this count, but the count itself ignores it.
        record("w-z", busy=True),
    ]
    assert keda_e2e.busy_kills(records, {"w-a", "w-b", "w-c"}) == 2
    assert keda_e2e.busy_kills(records, {"w-b"}) == 0


def test_a_victim_without_a_kill_record_fails_the_count() -> None:
    with pytest.raises(RuntimeError, match="no kill record for w-d"):
        keda_e2e.busy_kills([record("w-a", busy=True)], {"w-a", "w-d"})


COHORT = [f"w-{n:02d}" for n in range(1, 7)]


def test_the_victims_are_the_cohort_less_the_survivors() -> None:
    victims = keda_e2e.round_victims(COHORT, ["w-01", "w-03", "w-05"], ["w-02", "w-04", "w-06"])
    assert victims == ["w-02", "w-04", "w-06"]


def test_a_replaced_survivor_makes_the_round_invalid() -> None:
    # w-01 died and w-07 replaced it: four of the cohort are gone, and the
    # round no longer removed the step it is judged against.
    with pytest.raises(RuntimeError, match="survivor w-07 was not among the 6"):
        keda_e2e.round_victims(COHORT, ["w-03", "w-05", "w-07"], ["w-01", "w-02", "w-04", "w-06"])


def test_a_kill_outside_the_scale_in_makes_the_round_invalid() -> None:
    # w-01 died, and its replacement was among those the scale-in removed.
    with pytest.raises(RuntimeError, match="kill record for w-01, which the scale-in did not"):
        keda_e2e.round_victims(COHORT, ["w-01", "w-03", "w-05"], ["w-01", "w-02", "w-04", "w-06"])


def rounds(*busy: int, idle: int = 3) -> list[keda_e2e.Round]:
    return [keda_e2e.Round(victims=3, busy=count, idle=idle) for count in busy]


@pytest.mark.parametrize(
    ("baseline", "knarr", "outcome", "line"),
    [
        (
            rounds(2, 0, 2),
            rounds(0, 0, 0),
            "PASS",
            (
                "busy kills: baseline 4 of 9 victims over 3 rounds, knarr 0 of 9; "
                "threshold knarr 0 per round and baseline >= 1: PASS"
            ),
        ),
        (
            rounds(1, 1, 1),
            rounds(0, 1, 0),
            "FAIL",
            (
                "busy kills: baseline 3 of 9 victims over 3 rounds, knarr 1 of 9; "
                "threshold knarr 0 per round and baseline >= 1: FAIL"
            ),
        ),
        (
            rounds(0, 0, 0),
            rounds(0, 0, 0),
            "VOID",
            (
                "busy kills: baseline 0 of 9 victims over 3 rounds, knarr 0 of 9; "
                "threshold knarr 0 per round and baseline >= 1: VOID"
            ),
        ),
    ],
    ids=["pass", "fail", "void"],
)
def test_the_verdict_line(
    baseline: list[keda_e2e.Round], knarr: list[keda_e2e.Round], outcome: str, line: str
) -> None:
    assert keda_e2e.verdict(baseline, knarr) == (line, outcome)


def test_a_busy_kill_with_knarr_fails_even_when_the_baseline_is_void() -> None:
    # A void baseline makes the comparison inconclusive, never knarr's kill.
    _, outcome = keda_e2e.verdict(rounds(0, 0, 0), rounds(0, 2, 0))
    assert outcome == "FAIL"


def test_a_round_with_fewer_idle_pods_than_victims_is_refused_rather_than_exempt() -> None:
    # The split always covers the step, so four victims mean churn; exempting
    # the round would let a busy kill pass.
    knarr = [keda_e2e.Round(victims=4, busy=1, idle=3), *rounds(0, 0)]
    with pytest.raises(ValueError, match="knarr round 1 removed 4 pods with 3 idle"):
        keda_e2e.verdict(rounds(1, 1, 1), knarr)


def test_the_verdict_needs_the_same_rounds_in_both_phases() -> None:
    with pytest.raises(ValueError, match="3 baseline rounds and 2 knarr rounds"):
        keda_e2e.verdict(rounds(1, 1, 1), rounds(0, 0))


SCRAPE = """\
# at 1760000000.5
# HELP knarr_patches_total Patches sent, by purpose and the response's result.
# TYPE knarr_patches_total counter
knarr_patches_total{deployment="fake-worker",purpose="write",result="accepted"} 7
knarr_patches_total{result="accepted",deployment="fake-worker",purpose="cleanup"} 2.0
knarr_patches_total{deployment="fake-worker-optout",purpose="cleanup",result="accepted"} 1
knarr_patches_pending{deployment="fake-worker"} 0
knarr_paused{scope="patch"} 0
knarr_paused{scope="list"} 0
knarr_events_total{reason="a \\"quoted\\", comma"} 3
knarr_targets 2
knarr_build_info{version="0.1.0"} 1
"""


def test_metrics_are_summed_by_name_and_label_filter() -> None:
    samples = keda_e2e.parse_metrics(SCRAPE)
    assert samples is not None
    total = keda_e2e.total
    assert total(samples, "knarr_patches_total") == 10
    assert total(samples, "knarr_patches_total", deployment="fake-worker") == 9
    assert total(samples, "knarr_patches_total", deployment="fake-worker", purpose="cleanup") == 2
    assert total(samples, "knarr_patches_total", deployment="fake-worker-untouched") == 0
    assert total(samples, "knarr_events_total", reason='a "quoted", comma') == 3
    assert total(samples, "knarr_targets") == 2


def test_a_failed_scrape_parses_to_none() -> None:
    assert keda_e2e.parse_metrics("# at 1760000000.5\n# scrape failed: connection reset\n") is None


def test_an_unreadable_scrape_counts_as_failed_rather_than_ending_the_run() -> None:
    # Parsing runs after a phase ends; one cut-off body must not discard it.
    assert keda_e2e.parse_metrics(SCRAPE + 'knarr_patches_total{deployment="fake-wor') is None


@pytest.mark.parametrize(
    "body",
    ["", "# at 1760000000.5\n", "# at 1760000000.5\nknarr_targets 2\n"],
    ids=["empty", "comments", "no-build-info"],
)
def test_a_body_without_knarr_build_info_counts_as_failed(body: str) -> None:
    # knarr sets knarr_build_info at startup, so every scrape of it holds the
    # series; a 200 without it is not evidence of knarr's counts.
    assert keda_e2e.parse_metrics(body) is None


def scrape(*series: tuple[str, float]) -> list[keda_e2e.Sample]:
    return [
        keda_e2e.Sample("knarr_patches_total", {"deployment": d, "result": "accepted"}, v)
        for d, v in series
    ]


def test_patches_accumulate_per_series_through_a_retired_deployment() -> None:
    # knarr retires a departed Deployment's counters once its cleanup is
    # done (observability SeriesLife), so the sum of the series falls; the
    # patches it counted still count, and a later series counts from 0.
    scrapes = [
        (0.0, scrape(("a", 2))),
        (1.0, None),
        (2.0, scrape(("a", 3), ("optout", 2))),
        (3.0, scrape(("a", 4))),
        (4.0, scrape(("a", 4), ("optout", 1))),
    ]
    assert keda_e2e.cumulative_patches(scrapes) == [
        (0.0, 2),
        (2.0, 5),
        (3.0, 6),
        (4.0, 7),
    ]


def test_the_patch_rate_holds_within_five_per_second_and_a_burst_of_ten() -> None:
    # The bucket starts full: 10 at once, then 5 a second.
    samples = [(0.0, 0), (0.5, 10), (1.5, 15), (2.5, 20), (62.5, 320)]
    assert keda_e2e.rate_violations(samples, 5, 10) == []
    # The 60 s from 2.5 to 62.5 hold 300 of them.
    assert keda_e2e.peak_count(samples, 60) == 300


def answered(*times: float) -> list[tuple[float, list[keda_e2e.Sample] | None]]:
    return [(t, scrape(("a", 0))) for t in times]


def test_scrapes_cover_a_segment_with_no_gap_over_the_bound() -> None:
    parsed = [(0.0, None), *answered(1.0, 2.0), (3.0, None), *answered(31.0, 32.0)]
    assert keda_e2e.judge_coverage(parsed, 30, "deploy/e2e-fast") == (
        True,
        "ok   coverage, deploy/e2e-fast: 4 of 6 scrapes answered, longest gap 29.0 s of 30 s",
    )


@pytest.mark.parametrize(
    ("parsed", "line"),
    [
        ([], "0 of 0 scrapes answered, fewer than 2"),
        ([(0.0, None), *answered(1.0), (2.0, None)], "1 of 3 scrapes answered, fewer than 2"),
        ([*answered(0.0, 1.0), (20.0, None), *answered(32.0)], "longest gap 31.0 s of 30 s"),
        ([(0.0, None), (31.5, None), *answered(32.0, 33.0)], "longest gap 32.0 s of 30 s"),
        ([*answered(0.0, 1.0), (2.0, None), (40.0, None)], "longest gap 39.0 s of 30 s"),
    ],
    ids=["none", "one", "interior-outage", "leading-outage", "trailing-outage"],
)
def test_a_segment_the_scrapes_do_not_cover_is_invalid(
    parsed: list[tuple[float, list[keda_e2e.Sample] | None]], line: str
) -> None:
    ok, got = keda_e2e.judge_coverage(parsed, 30, "deploy/e2e-fast")
    assert ok is False
    assert got.startswith("INVALID coverage, deploy/e2e-fast: ")
    assert line in got


def test_the_patch_rate_fails_a_segment_without_two_answered_scrapes() -> None:
    assert keda_e2e.patch_rate([("deploy/e2e-fast", [(0.0, None), *answered(1.0)])]) is False
    assert keda_e2e.patch_rate([("deploy/e2e-fast", answered(0.0, 1.0))]) is True


def test_a_window_over_the_bound_is_a_violation() -> None:
    # 21 patches within 1.9 s, where the bound is 5 x ceil(1.9) + 10 = 20.
    samples = [(0.0, 0), (1.2, 16), (1.9, 21)]
    assert keda_e2e.rate_violations(samples, 5, 10) == [(0.0, 1.9, 21, 20)]


def test_an_untouched_deployment_passes_with_no_patch_for_the_whole_window() -> None:
    # An absent series sums to 0, and a failed scrape (None) is skipped.
    reads = [(100.0 + t, 0) for t in range(0, 301, 1)]
    reads[50] = (150.0, None)
    assert keda_e2e.judge_untouched(reads, 100.0, 300) == (
        True,
        "ok   (a) untouched: knarr_patches_total 0 for 300 s after readiness, 300 scrapes",
    )


def test_one_patch_of_an_untouched_deployment_fails_it() -> None:
    reads = [(100.0 + t, 0 if t < 42 else 1) for t in range(301)]
    assert keda_e2e.judge_untouched(reads, 100.0, 300) == (
        False,
        "FAIL (a) untouched: knarr_patches_total 1 at 42.0 s after readiness",
    )


def test_an_untouched_window_cut_short_fails() -> None:
    reads = [(100.0 + t, 0) for t in range(200)]
    assert keda_e2e.judge_untouched(reads, 100.0, 300) == (
        False,
        "FAIL (a) untouched: the last scrape was 199.0 s after readiness, short of 300 s",
    )


def test_a_cleanup_within_two_list_intervals_passes() -> None:
    reads = [(10.0, False), (40.0, False), (64.5, True), (70.0, None), (90.0, True)]
    assert keda_e2e.judge_cleanup(reads, 0.0, 120) == (
        True,
        "ok   (b) opt-out: annotation and marker gone 64.5 s after readiness, bound 120 s",
    )


@pytest.mark.parametrize(
    ("reads", "line"),
    [
        (
            [(10.0, False), (130.0, True)],
            "FAIL (b) opt-out: annotation and marker gone 130.0 s after readiness, bound 120 s",
        ),
        (
            [(10.0, True), (20.0, False), (30.0, False)],
            "FAIL (b) opt-out: annotation and marker not gone by 30.0 s after readiness",
        ),
    ],
    ids=["late", "came-back"],
)
def test_a_late_or_undone_cleanup_fails(reads: list[tuple[float, object]], line: str) -> None:
    assert keda_e2e.judge_cleanup(reads, 0.0, 120) == (False, line)


def test_a_rewrite_within_one_poll_interval_its_jitter_and_one_patch_interval_passes() -> None:
    reads = [(5.0, None), (20.0, ""), (61.0, "1800"), (95.0, "1800")]
    assert keda_e2e.judge_rewrite(reads, 0.0, 93) == (
        True,
        "ok   (c) changed: pod-deletion-cost=1800 61.0 s after readiness, bound 93 s",
    )
    late = [(20.0, ""), (94.0, "1800")]
    assert keda_e2e.judge_rewrite(late, 0.0, 93)[0] is False


def samples(text: str) -> list[keda_e2e.Sample]:
    parsed = keda_e2e.parse_metrics(text)
    assert parsed is not None
    return parsed


def test_preconditions_hold_with_no_throttled_result_and_no_pause() -> None:
    scrapes = [samples(SCRAPE), None, samples(SCRAPE)]
    assert keda_e2e.judge_preconditions(scrapes) == (
        True,
        "ok   preconditions: no throttled result and knarr_paused 0 in 2 scrapes",
    )


@pytest.mark.parametrize(
    ("line", "why"),
    [
        (
            'knarr_patches_total{deployment="fake-worker",purpose="write",result="throttled"} 1',
            'knarr_patches_total{deployment="fake-worker",purpose="write",result="throttled"} 1',
        ),
        (
            'knarr_lists_total{kind="pods",result="throttled"} 2',
            'knarr_lists_total{kind="pods",result="throttled"} 2',
        ),
        ('knarr_paused{scope="patch"} 1', 'knarr_paused{scope="patch"} 1'),
    ],
    ids=["throttled-patch", "throttled-list", "paused"],
)
def test_a_throttle_or_a_pause_makes_the_run_invalid(line: str, why: str) -> None:
    scrape = samples(SCRAPE + line + "\n")
    assert keda_e2e.judge_preconditions([scrape]) == (
        False,
        f"INVALID preconditions: {why} at scrape 1",
    )


def fixture_worker() -> dict:
    data = json.loads((REPOSITORY / "fixtures/fake_worker/deploy/resources.json").read_text())
    return next(item for item in data["items"] if item["metadata"]["name"] == "fake-worker")


def test_the_restart_deployments_are_three_opted_in_clones_with_disjoint_selectors() -> None:
    worker = fixture_worker()
    before = json.dumps(worker, sort_keys=True)
    clones = keda_e2e.restart_deployments(worker)
    assert json.dumps(worker, sort_keys=True) == before
    names = ["fake-worker-untouched", "fake-worker-changed", "fake-worker-optout"]
    assert [clone["metadata"]["name"] for clone in clones] == names
    for name, clone in zip(names, clones, strict=True):
        assert clone["metadata"]["labels"] == {
            "app.kubernetes.io/name": name,
            "app.kubernetes.io/part-of": "knarr-fixtures",
            "knarr.io/enabled": "true",
        }
        assert clone["spec"]["replicas"] == 2
        assert clone["spec"]["selector"] == {"matchLabels": {"app.kubernetes.io/name": name}}
        template = clone["spec"]["template"]
        assert template["metadata"]["labels"] == {
            "app.kubernetes.io/name": name,
            "app.kubernetes.io/part-of": "knarr-fixtures",
        }
        assert template["spec"] == worker["spec"]["template"]["spec"]


class FakeCluster:
    """A KEDA-scaled fake-worker Deployment, its collector, and optionally knarr.

    Raising the ScaledObject's bounds adds pods; lowering them removes the
    lowest pod-deletion-cost first and, among equals, the newest, as the
    ReplicaSet controller does, and each removed worker posts its kill record.
    With knarr, a cost set through control lands on the pod's annotation.
    """

    def __init__(self, names: list[str], *, knarr: bool, replace: str | None = None) -> None:
        self.knarr = knarr
        # A pod that dies during the scale-in, and its ReplicaSet replaces.
        self.replace = replace
        self.pods: dict[str, dict] = {name: {"cost": 0, "annotations": {}} for name in names}
        self.created = len(names)
        self.kills: list[dict] = [record("stale", busy=True)]
        self.forwards: dict[int, tuple[str, int]] = {}
        self.events: list[tuple] = []

    def output(self, *arguments: str) -> str:
        assert arguments == ("kubectl", "get", "pods", "-l", cluster.WORKERS, "-o", "json")
        items = [
            {
                "metadata": {"name": name, "annotations": dict(pod["annotations"])},
                "status": {"conditions": [{"type": "Ready", "status": "True"}]},
            }
            for name, pod in self.pods.items()
        ]
        return json.dumps({"items": items})

    def run(self, *arguments: str, **_: object) -> None:
        assert arguments[:4] == ("kubectl", "patch", "scaledobject", "fake-worker")
        bounds = json.loads(arguments[-1])["spec"]
        assert bounds["minReplicaCount"] == bounds["maxReplicaCount"]
        wanted = bounds["maxReplicaCount"]
        self.events.append(("bounds", wanted))
        shrinking = len(self.pods) > wanted
        while len(self.pods) < wanted:
            self.created += 1
            self.pods[f"w-{self.created:02d}"] = {"cost": 0, "annotations": {}}
        while len(self.pods) > wanted:
            # Ascending cost, then newest first.
            victim = min(
                reversed(list(self.pods)),
                key=lambda name: int(self.pods[name]["annotations"].get(keda_e2e.COST, "0")),
            )
            pod = self.pods.pop(victim)
            self.kills.append(record(victim, busy=pod["cost"] > 0))
        if shrinking and self.replace in self.pods:
            pod = self.pods.pop(self.replace)
            self.kills.append(record(self.replace, busy=pod["cost"] > 0))
            self.created += 1
            self.pods[f"w-{self.created:02d}"] = {"cost": 0, "annotations": {}}
            self.replace = None

    @contextlib.contextmanager
    def port_forward(self, _state: Path, target: str, port: int):
        local = 40000 + len(self.forwards)
        self.forwards[local] = (target, port)
        yield local

    def http(self, method: str, url: str, body: str | None = None) -> tuple[int, str]:
        target, _ = self.forwards[urllib.parse.urlsplit(url).port]
        if target == "service/fake-worker-collector":
            self.events.append(("kills", method))
            if method == "DELETE":
                self.kills = []
                return 204, ""
            return 200, json.dumps({"kills": self.kills})
        assert method == "PUT"
        pod = target.removeprefix("pod/")
        state = json.loads(body or "{}")
        assert state == {
            "cost": state["cost"],
            "accepting": True,
            "failure": "none",
            "latency_ms": 0,
        }
        self.events.append(("control", pod, state["cost"]))
        self.pods[pod]["cost"] = state["cost"]
        if self.knarr and state["cost"] >= 300:
            self.pods[pod]["annotations"] = {
                keda_e2e.COST: str(state["cost"]),
                keda_e2e.MARKER: "{}",
            }
        elif self.knarr:
            self.pods[pod]["annotations"].pop(keda_e2e.COST, None)
        return 200, "{}"


def scale_round(
    monkeypatch: pytest.MonkeyPatch, fake: FakeCluster, tmp_path: Path, phase: str
) -> keda_e2e.Round:
    for name in ("output", "run", "port_forward", "http"):
        monkeypatch.setattr(cluster, name, getattr(fake, name))
    for name in ("POLL", "SETTLE"):
        monkeypatch.setattr(keda_e2e, name, 0)
    monkeypatch.setattr(keda_e2e, "GATE", 1)
    monkeypatch.setattr(keda_e2e, "SCALE", 1)
    return keda_e2e.scale_round(tmp_path, tmp_path / "out", 1, 33, phase)


def test_a_knarr_round_sets_the_load_gates_on_it_scales_in_and_kills_no_busy_pod(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    fake = FakeCluster([f"w-{n:02d}" for n in range(1, 4)], knarr=True)
    result = scale_round(monkeypatch, fake, tmp_path, "knarr")
    assert result == keda_e2e.Round(victims=3, busy=0, idle=3)
    busy, idle = keda_e2e.pick_busy([f"w-{n:02d}" for n in range(1, 7)], 33, 1)
    assert sorted(fake.pods) == busy
    assert fake.events == [
        ("bounds", 6),
        ("kills", "DELETE"),
        *[("control", pod, 1800 if pod in busy else 0) for pod in sorted(busy + idle)],
        ("bounds", 3),
        ("kills", "GET"),
        *[("control", pod, 0) for pod in busy],
    ]
    kept = json.loads((tmp_path / "out/knarr-round-1.json").read_text())
    assert kept["victims"] == idle
    assert {r["pod"] for r in kept["kills"]} == set(idle)


def test_a_baseline_round_counts_the_busy_pods_the_replicaset_chose(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # Without knarr the newest three go, whatever they were doing.
    fake = FakeCluster([f"w-{n:02d}" for n in range(1, 4)], knarr=False)
    busy, _ = keda_e2e.pick_busy([f"w-{n:02d}" for n in range(1, 7)], 33, 1)
    newest = {"w-04", "w-05", "w-06"}
    result = scale_round(monkeypatch, fake, tmp_path, "baseline")
    assert result == keda_e2e.Round(victims=3, busy=len(newest & set(busy)), idle=3)
    assert sorted(fake.pods) == ["w-01", "w-02", "w-03"]


def test_a_knarr_round_with_a_replaced_pod_is_invalid_rather_than_judged(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # A busy survivor dies during the scale-in: four of the cohort are gone,
    # one of them busy, and a replacement stands in the survivors.
    busy, _ = keda_e2e.pick_busy([f"w-{n:02d}" for n in range(1, 7)], 33, 1)
    fake = FakeCluster([f"w-{n:02d}" for n in range(1, 4)], knarr=True, replace=busy[0])
    with pytest.raises(RuntimeError, match="survivor w-07 was not among the 6"):
        scale_round(monkeypatch, fake, tmp_path, "knarr")
    assert not (tmp_path / "out/knarr-round-1.json").exists()


def test_a_baseline_pod_with_a_knarr_annotation_fails_the_round(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    fake = FakeCluster([f"w-{n:02d}" for n in range(1, 4)], knarr=False)
    fake.pods["w-02"]["annotations"][keda_e2e.MARKER] = "{}"
    with pytest.raises(RuntimeError, match=r"baseline pod w-02 carries knarr\.io/applied"):
        scale_round(monkeypatch, fake, tmp_path, "baseline")


def test_a_knarr_round_whose_annotations_never_land_fails_at_the_gate(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # knarr is not running, so no annotation lands.
    fake = FakeCluster([f"w-{n:02d}" for n in range(1, 4)], knarr=False)
    with pytest.raises(RuntimeError, match="every busy pod at pod-deletion-cost=1800"):
        scale_round(monkeypatch, fake, tmp_path, "knarr")
    assert ("bounds", 3) not in fake.events


def test_the_worst_window_is_the_one_with_the_least_headroom() -> None:
    samples = [(0.0, 0), (0.5, 10), (1.5, 15), (2.5, 20), (62.5, 320)]
    # Four windows leave 5 to spare; of those, 0 to 62.5 counts the most:
    # 320 of 5 x 63 + 10 = 325 allowed.
    assert keda_e2e.worst_window(samples, 5, 10) == (0.0, 62.5, 320, 325)
    assert keda_e2e.worst_window([(0.0, 0)], 5, 10) is None
