"""Ticket 33's KEDA end-to-end harness on this worktree's kind cluster, run by
`just keda-e2e` and never by `just check`.

It measures the three §3 success criteria in one run. It installs KEDA at the
version fixtures/keda_e2e/keda.json pins, deploys the fake worker under a
ScaledObject, and scales it from 6 to 3 replicas a few times: first without
knarr, then with deploy/e2e-fast, with three busy and three idle workers each
round, counting busy kills from the collector. Then it restarts knarr at the
defaults over three Deployments and judges lifecycle's `Restart` `Threshold`,
and judges budget's `Threshold` over every scrape of /metrics. Each phase
prints `ok` or `FAIL` lines; the scrapes, pod reads and kill records are kept
under build/keda-e2e/. The judges are pure and take recorded values; the
orchestration below them drives the cluster through cluster.py's helpers.
"""

from __future__ import annotations

import contextlib
import copy
import hashlib
import itertools
import json
import math
import random
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path
from typing import NamedTuple

import cluster

FIXTURE = cluster.ROOT / "fixtures/keda_e2e"
# The cost a busy worker reports, above the first threshold (300), so knarr
# writes it as the pod's deletion cost.
BUSY_COST = 1800
COST = "controller.kubernetes.io/pod-deletion-cost"
MARKER = "knarr.io/applied"
OPT_IN = "knarr.io/enabled"
KNARR = "app.kubernetes.io/name=knarr"
# Each round scales the fake worker out to PODS, half of them busy, and in by
# STEP, which the idle half covers.
PODS, STEP = 6, 3
# Seconds. Tests shrink the waits; the bounds are the thresholds themselves.
POLL = 1  # between reads of the pods, and between scrapes
SETTLE = 30  # the baseline's pause where the knarr phase waits on its gate
GATE = 180  # the knarr phase's wait for the load's annotations
SCALE = 300  # a scale-out or a scale-in: KEDA, then the HPA's 15 s sync
RESTART_SETTLE = 300  # the restart Deployments' first writes, at the defaults
READY = 180  # knarr's /readyz 200 after it is scaled back to 1
WATCH = 300  # (a): no patch of the untouched Deployment for 300 s
CLEANUP_BOUND = 120  # (b): two list intervals at the defaults
REWRITE_BOUND = 93  # (c): poll interval 30 s, its 10 % jitter, patch interval 60 s
RATE, BURST = 5, 10  # the defaults, which deploy/e2e-fast keeps
# The longest a segment may go without an answered scrape: cluster.py's 30 s
# for a port forward to come up, so a longer gap is more than one reconnect.
COVERAGE = 30


class Round(NamedTuple):
    """One scale-in round: the pods it removed, how many of them were busy, and
    how many idle pods it had to choose from."""

    victims: int
    busy: int
    idle: int


class Sample(NamedTuple):
    """One series' value in a /metrics scrape."""

    name: str
    labels: dict
    value: float

    def __str__(self):
        labels = ",".join(f'{key}="{value}"' for key, value in self.labels.items())
        return (
            f"{self.name}{{{labels}}} {self.value:g}" if labels else f"{self.name} {self.value:g}"
        )


def verify_download(body, sha256):
    """The downloaded bytes, refused unless their sha256 is the pinned one."""
    got = hashlib.sha256(body).hexdigest()
    if got != sha256:
        raise ValueError(f"sha256 mismatch: pinned {sha256}, downloaded {got}")
    return body


def keda_kustomization(pins, manifest, resource):
    """A kustomization over the release YAML that replaces each image it names
    with the pinned digest. Every image the YAML names must be pinned at the
    same tag, and every pin must be used, so a release that adds an image
    cannot run it unpinned."""
    pinned = {}
    for pin in pins:
        match = re.fullmatch(r"([^\s:@]+(?:/[^\s:@]+)+):([\w.-]+)@(sha256:[0-9a-f]{64})", pin)
        if not match:
            raise ValueError(f"pin {pin!r} is not name:tag@sha256:digest")
        pinned[f"{match[1]}:{match[2]}"] = (match[1], match[3])
    named = set(
        re.findall(
            r"^[ \t]*(?:-[ \t]+)?image:[ \t]*[\"']?([^\s\"']+)[\"']?[ \t]*$",
            manifest,
            re.MULTILINE,
        )
    )
    if unpinned := sorted(named - pinned.keys()):
        raise ValueError(f"unpinned image {unpinned[0]} in the release")
    if unused := sorted(pinned.keys() - named):
        raise ValueError(f"pinned image not in the release: {unused[0]}")
    lines = [
        "apiVersion: kustomize.config.k8s.io/v1beta1",
        "kind: Kustomization",
        "resources:",
        f"  - {resource}",
        "images:",
    ]
    for name, digest in sorted(pinned.values()):
        lines += [f"  - name: {name}", f"    digest: {digest}"]
    return "\n".join(lines) + "\n"


def scaled_object_bounds(minimum, maximum):
    """The merge patch that sets the ScaledObject's replica bounds; KEDA writes
    them to its HPA, which scales the Deployment."""
    if minimum > maximum:
        raise ValueError(f"minimum {minimum} above maximum {maximum}")
    return {"spec": {"minReplicaCount": minimum, "maxReplicaCount": maximum}}


def pick_busy(pods, seed, number):
    """Split the pods into busy and idle halves by a shuffle seeded with the run's
    seed and the round's number, so a rerun with the same seed draws the same
    split over the same names. Both phases draw with the same seed."""
    pods = sorted(pods)
    random.Random(f"{seed}-{number}").shuffle(pods)  # noqa: S311 - a fixture split, not a secret
    half = len(pods) // 2
    return sorted(pods[:half]), sorted(pods[half:])


def round_victims(before, survivors, killed):
    """The pods a round's scale-in removed: the cohort before it less the
    survivors. Churn makes the round invalid rather than judged, since its
    victims would no longer be the step the verdict judges: a survivor not in
    the cohort is a replacement, and a kill record for a pod that is not a
    victim is a death outside the scale-in."""
    if new := sorted(set(survivors) - set(before)):
        raise RuntimeError(
            f"survivor {', '.join(new)} was not among the {len(before)} before the scale-in: "
            "a pod was replaced during the round"
        )
    victims = sorted(set(before) - set(survivors))
    if extra := sorted(set(killed) - set(victims)):
        raise RuntimeError(
            f"kill record for {', '.join(extra)}, which the scale-in did not remove: "
            "a pod died outside the scale-in"
        )
    return victims


def busy_kills(records, victims):
    """How many of the round's victims the collector recorded as busy when
    SIGTERM reached them. A victim with no record fails the round: the count
    would be short by an unknown pod."""
    by_pod = {record["pod"]: record for record in records}
    if missing := sorted(set(victims) - by_pod.keys()):
        raise RuntimeError(f"no kill record for {', '.join(missing)}")
    return sum(1 for pod in victims if by_pod[pod]["busy"] is True)


def verdict(baseline, knarr):
    """The threshold the maintainer set on 2026-10-15 (OVERVIEW §3): with knarr,
    no busy kill in any round whose idle pods cover the scale-in step; the
    baseline must kill at least one busy pod over the run, or the run is void.
    Returns the line the hand-back quotes and PASS, FAIL or VOID. The split
    always covers the step, so a round with fewer idle pods than victims is
    churn the round should have refused, and is refused here rather than
    exempted."""
    if len(baseline) != len(knarr):
        raise ValueError(f"{len(baseline)} baseline rounds and {len(knarr)} knarr rounds")
    for phase, rounds in (("baseline", baseline), ("knarr", knarr)):
        for number, r in enumerate(rounds, 1):
            if r.idle < r.victims:
                raise ValueError(
                    f"{phase} round {number} removed {r.victims} pods with {r.idle} idle"
                )
    base_busy = sum(r.busy for r in baseline)
    # A busy kill knarr could have avoided fails the run whatever the baseline
    # did; a void baseline only makes a clean knarr phase inconclusive.
    if any(r.busy > 0 for r in knarr):
        outcome = "FAIL"
    elif base_busy == 0:
        outcome = "VOID"
    else:
        outcome = "PASS"
    line = (
        f"busy kills: baseline {base_busy} of {sum(r.victims for r in baseline)} victims "
        f"over {len(baseline)} rounds, knarr {sum(r.busy for r in knarr)} of "
        f"{sum(r.victims for r in knarr)}; threshold knarr 0 per round and baseline >= 1: "
        f"{outcome}"
    )
    return line, outcome


SAMPLE = re.compile(r"([a-zA-Z_:][\w:]*)(?:\{(.*)\})?\s+(\S+)(?:\s+\S+)?")
LABEL = re.compile(r'([a-zA-Z_]\w*)="((?:[^"\\]|\\.)*)"')


def parse_metrics(text):
    """The samples of one /metrics scrape as (name, labels, value), or None for
    a scrape the harness recorded as failed, one with an unreadable line, or
    one without knarr_build_info, which knarr sets at startup: a 200 without
    it is not knarr's counts."""
    samples = []
    for line in text.splitlines():
        if line.startswith("# scrape failed"):
            return None
        if not line or line.startswith("#"):
            continue
        match = SAMPLE.fullmatch(line)
        if not match:
            # A body cut off part way: no sample in it can be trusted.
            return None
        labels = {
            key: re.sub(r"\\(.)", lambda m: {"n": "\n"}.get(m[1], m[1]), value)
            for key, value in LABEL.findall(match[2] or "")
        }
        samples.append(Sample(match[1], labels, float(match[3])))
    if not any(sample.name == "knarr_build_info" for sample in samples):
        return None
    return samples


def total(samples, name, **labels):
    """The sum of every series of `name` whose labels include `labels`; an
    absent series sums to 0."""
    return sum(
        value
        for sample, have, value in samples
        if sample == name and all(have.get(key) == want for key, want in labels.items())
    )


def cumulative_patches(scrapes):
    """The patches one knarr process counted by each answered scrape, as (t,
    count). The count adds each knarr_patches_total series' rise since the
    scrape before; a series that was not there counts from 0. knarr retires a
    departed Deployment's counters once its cleanup is done (observability
    `SeriesLife`), so the sum of the series can fall while the patches it
    counted still count. `scrapes` are (t, samples or None) in time order."""
    points = []
    count = 0
    before = {}
    for t, samples in scrapes:
        if samples is None:
            continue
        now = {
            tuple(sorted(sample.labels.items())): sample.value
            for sample in samples
            if sample.name == "knarr_patches_total"
        }
        for series, value in now.items():
            old = before.get(series)
            count += value - old if old is not None and value >= old else value
        before = now
        points.append((t, count))
    return points


def rate_violations(samples, rate, burst):
    """Every pair of scrapes of one knarr process whose patch count rose by more
    than rate x ceil(seconds between them) + burst (budget `Threshold`), as
    (t0, t1, increase, allowed). The samples are (t, cumulative count) in time
    order, from cumulative_patches."""
    found = []
    for i, (t0, v0) in enumerate(samples):
        for t1, v1 in samples[i + 1 :]:
            allowed = rate * math.ceil(t1 - t0) + burst
            if v1 - v0 > allowed:
                found.append((t0, t1, v1 - v0, allowed))
    return found


def worst_window(samples, rate, burst):
    """The pair of scrapes with the least headroom under the bound, ties to the
    larger count, as (t0, t1, increase, allowed); None for fewer than two."""
    windows = (
        (t0, t1, v1 - v0, rate * math.ceil(t1 - t0) + burst)
        for i, (t0, v0) in enumerate(samples)
        for t1, v1 in samples[i + 1 :]
    )
    return min(windows, key=lambda w: (w[3] - w[2], -w[2]), default=None)


def peak_count(samples, seconds):
    """The most patches counted between two scrapes at most `seconds` apart."""
    return max(
        (
            v1 - v0
            for i, (t0, v0) in enumerate(samples)
            for t1, v1 in samples[i + 1 :]
            if t1 - t0 <= seconds
        ),
        default=0,
    )


def judge_untouched(reads, t_ready, seconds):
    """Restart `Threshold` (a): the new process's knarr_patches_total for the
    untouched Deployment stays 0 for `seconds` after readiness. `reads` are
    (t, count) per scrape, None for a failed one, in time order. The window
    closes at the first answered scrape at or past `seconds`, and that scrape
    must read 0 too: a patch late in the window shows only in it."""
    included = []
    for t, count in reads:
        if count is None or t < t_ready:
            continue
        included.append((t, count))
        if t - t_ready >= seconds:
            break
    for t, count in included:
        if count != 0:
            return False, (
                f"FAIL (a) untouched: knarr_patches_total {count:g} at "
                f"{t - t_ready:.1f} s after readiness"
            )
    last = max((t for t, _ in included), default=t_ready) - t_ready
    if last < seconds:
        return False, (
            f"FAIL (a) untouched: the last scrape was {last:.1f} s after readiness, "
            f"short of {seconds} s"
        )
    scrapes = len(included)
    return True, (
        f"ok   (a) untouched: knarr_patches_total 0 for {seconds} s after readiness, "
        f"{scrapes} scrapes"
    )


def process_identity(items):
    """The knarr process one read of its pods sees: each live pod's name, uid
    and (container, restartCount) pairs, sorted. A terminating pod is left
    out: its process is the one being replaced."""
    return tuple(
        sorted(
            (
                pod["metadata"]["name"],
                pod["metadata"]["uid"],
                tuple(
                    sorted(
                        (status["name"], status["restartCount"])
                        for status in pod.get("status", {}).get("containerStatuses", [])
                    )
                ),
            )
            for pod in items
            if "deletionTimestamp" not in pod["metadata"]
        )
    )


def process_change(start, end):
    """None when the reads at a segment's start and end saw the same one knarr
    pod with the same restart counts; otherwise why not. Budget `Threshold`
    holds within one run of the process, and (a) reads the new process's
    counter, so a segment that spans a restart is not one run. A uid is never
    reused and a restartCount only rises, so equal ends mean no restart
    between them."""
    if start == end and len(start) == 1:
        return None
    return f"knarr pods {start} at the start, {end} at the end"


def stamped(read, clock=time.monotonic):
    """(the time `read` returned, its value, or None for a failed kubectl). A
    stamp taken before a slow read would date a late observation early."""
    try:
        value = read()
    except subprocess.CalledProcessError:
        value = None
    return clock(), value


def settled_at(reads, t_ready, wanted):
    """Seconds after readiness from which every read was `wanted`, or None if
    the last read was not. Reads of None are unknown and skipped."""
    since = None
    for t, value in reads:
        if value is None or t < t_ready:
            continue
        if value != wanted:
            since = None
        elif since is None:
            since = t - t_ready
    return since


def last_read(reads, t_ready):
    return max((t for t, value in reads if value is not None), default=t_ready) - t_ready


def within(since, bound, what):
    ok = since <= bound
    return ok, f"{'ok  ' if ok else 'FAIL'} {what} {since:.1f} s after readiness, bound {bound} s"


def judge_cleanup(reads, t_ready, bound):
    """Restart `Threshold` (b): the opted-out Deployment's pods lose the
    annotation, and the marker once no record remains, within `bound` seconds
    of readiness and keep them off. `reads` are (t, True once every pod has
    neither)."""
    what = "(b) opt-out: annotation and marker"
    since = settled_at(reads, t_ready, True)
    if since is None:
        return False, f"FAIL {what} not gone by {last_read(reads, t_ready):.1f} s after readiness"
    return within(since, bound, f"{what} gone")


def judge_rewrite(reads, t_ready, bound):
    """Restart `Threshold` (c): the worker whose cost crossed during the downtime
    carries pod-deletion-cost=1800 within `bound` seconds of readiness. `reads`
    are (t, the annotation's value, "" when absent)."""
    what = f"(c) changed: pod-deletion-cost={BUSY_COST}"
    since = settled_at(reads, t_ready, str(BUSY_COST))
    if since is None:
        return (
            False,
            f"FAIL {what} not reached by {last_read(reads, t_ready):.1f} s after readiness",
        )
    return within(since, bound, what)


def judge_coverage(parsed, bound, label):
    """Whether one knarr process's scrapes cover its segment, which the patch
    rate needs: at least two answered, and no gap over `bound` seconds between
    answered scrapes or between one and the segment's first or last attempt.
    The windows only see patches between answered scrapes. `parsed` are (t,
    samples or None) in time order."""
    answered = [t for t, samples in parsed if samples is not None]
    what = f"coverage, {label}: {len(answered)} of {len(parsed)} scrapes answered"
    if len(answered) < 2:
        return False, f"INVALID {what}, fewer than 2"
    times = [parsed[0][0], *answered, parsed[-1][0]]
    gap = max(t1 - t0 for t0, t1 in itertools.pairwise(times))
    ok = gap <= bound
    return ok, f"{'ok  ' if ok else 'INVALID'} {what}, longest gap {gap:.1f} s of {bound} s"


def judge_preconditions(scrapes):
    """The run (b) and (c) are bounds for: no response answered 429, so no
    result is throttled, and no pause. A breach makes the run invalid, not a
    pass. `scrapes` are parsed scrapes, None for a failed one."""
    answered = [scrape for scrape in scrapes if scrape is not None]
    for number, scrape in enumerate(answered, 1):
        for sample in scrape:
            throttled = sample.labels.get("result") == "throttled"
            if (throttled or sample.name == "knarr_paused") and sample.value > 0:
                return False, f"INVALID preconditions: {sample} at scrape {number}"
    return True, (
        f"ok   preconditions: no throttled result and knarr_paused 0 in {len(answered)} scrapes"
    )


# The restart phase's three Deployments (lifecycle `Restart` `Threshold`).
UNTOUCHED, CHANGED, OPTOUT = "fake-worker-untouched", "fake-worker-changed", "fake-worker-optout"
NAME = "app.kubernetes.io/name"


def restart_deployments(worker):
    """Three clones of the fixture's worker Deployment, two replicas each, opted
    in, each selecting only its own pods by app.kubernetes.io/name. part-of is
    kept, so cluster-diagnostics finds their logs."""
    clones = []
    for name in (UNTOUCHED, CHANGED, OPTOUT):
        clone = copy.deepcopy(worker)
        clone["metadata"] = {
            "name": name,
            "labels": {**worker["metadata"]["labels"], NAME: name, OPT_IN: "true"},
        }
        clone["spec"]["replicas"] = 2
        clone["spec"]["selector"] = {"matchLabels": {NAME: name}}
        clone["spec"]["template"]["metadata"]["labels"][NAME] = name
        clones.append(clone)
    return clones


# ---------------------------------------------------------------- the cluster ---


class Run(NamedTuple):
    """What every phase of one run shares: the cluster's state directory, the
    output directory, the cluster's name and the two local images."""

    state: Path
    out: Path
    name: str
    knarr: str
    worker: str


class Pod(NamedTuple):
    """A pod as one read sees it: Ready and not terminating, and its annotations."""

    live: bool
    annotations: dict


def read_pods(selector):
    items = json.loads(cluster.output("kubectl", "get", "pods", "-l", selector, "-o", "json"))
    return {
        pod["metadata"]["name"]: Pod(cluster.live(pod), pod["metadata"].get("annotations") or {})
        for pod in items["items"]
    }


def knarr_process():
    """The knarr process as one read of its pods sees it (process_identity)."""
    pods = json.loads(cluster.output("kubectl", "get", "pods", "-l", KNARR, "-o", "json"))
    return process_identity(pods["items"])


def exactly_live(selector, count):
    """The sorted names when `selector` matches exactly `count` pods and every
    one is live: a scale-out is done when the new pods are Ready, a scale-in
    when the removed ones are gone."""
    pods = read_pods(selector)
    if len(pods) == count and all(pod.live for pod in pods.values()):
        return sorted(pods)
    return None


def wait_until(check, seconds, what):
    deadline = time.monotonic() + seconds
    while not (result := check()):
        if time.monotonic() >= deadline:
            raise RuntimeError(f"timed out after {seconds} s waiting for {what}")
        time.sleep(POLL)
    return result


def control(state, pod, cost):
    """Set a worker's cost through its control endpoint. The body names every
    member, so nothing an earlier run set survives."""
    body = json.dumps({"cost": cost, "accepting": True, "failure": "none", "latency_ms": 0})
    with cluster.port_forward(state, f"pod/{pod}", 8081) as port:
        cluster.answer(
            "PUT",
            f"http://127.0.0.1:{port}/control",
            body,
            accept=lambda got: got[0] == 200,
            what=f"{pod} control",
        )


def collector(state, method):
    """One request to the collector's /kills through a fresh port forward."""
    accept = cluster.exactly((204, "")) if method == "DELETE" else lambda got: got[0] == 200
    with cluster.port_forward(state, "service/fake-worker-collector", 8081) as port:
        _, body = cluster.answer(
            method, f"http://127.0.0.1:{port}/kills", accept=accept, what=f"{method} /kills"
        )
    return body


def set_bounds(count):
    patch = json.dumps(scaled_object_bounds(count, count))
    cluster.run("kubectl", "patch", "scaledobject", "fake-worker", "--type=merge", "-p", patch)


def load_gated(busy, idle):
    """True once knarr has written the load: every busy pod at the busy cost and
    no idle pod with a deletion cost."""
    pods = read_pods(cluster.WORKERS)
    return all(
        pod in pods and pods[pod].annotations.get(COST) == str(BUSY_COST) for pod in busy
    ) and all(COST not in pods[pod].annotations for pod in idle if pod in pods)


def scale_round(state, out, number, seed, phase):
    """One round: out to PODS, a seeded busy half and idle half through control,
    in by STEP, and the busy kills among the pods the scale-in removed. With
    knarr the scale-in waits until the load's annotations are written; without
    it, a fixed pause stands in and no pod may carry knarr's annotations."""
    set_bounds(PODS)
    before = wait_until(lambda: exactly_live(cluster.WORKERS, PODS), SCALE, f"{PODS} workers")
    collector(state, "DELETE")
    busy, idle = pick_busy(before, seed, number)
    for pod in before:
        control(state, pod, BUSY_COST if pod in busy else 0)
    if phase == "knarr":
        what = f"every busy pod at {COST.split('/')[1]}={BUSY_COST} and no idle pod with one"
        wait_until(lambda: load_gated(busy, idle), GATE, what)
    else:
        time.sleep(SETTLE)
        for pod, read in read_pods(cluster.WORKERS).items():
            if owned := sorted({COST, MARKER} & read.annotations.keys()):
                raise RuntimeError(f"baseline pod {pod} carries {', '.join(owned)}")
    set_bounds(STEP)
    survivors = wait_until(
        lambda: exactly_live(cluster.WORKERS, STEP), SCALE, f"the scale-in to {STEP}"
    )
    kills = json.loads(collector(state, "GET"))["kills"]
    victims = round_victims(before, survivors, [record["pod"] for record in kills])
    killed = busy_kills(kills, victims)
    for pod in survivors:
        control(state, pod, 0)
    out.mkdir(parents=True, exist_ok=True)
    kept = {"busy": busy, "idle": idle, "survivors": survivors, "victims": victims, "kills": kills}
    (out / f"{phase}-round-{number}.json").write_text(json.dumps(kept, indent=2) + "\n")
    print(f"ok   {phase} round {number}: {killed} of {len(victims)} victims busy")
    return Round(victims=len(victims), busy=killed, idle=len(idle))


class Scraper:
    """Scrapes knarr's /metrics about once a second on a thread while open,
    through a port forward it reopens whenever a scrape fails: the phases run
    for minutes, longer than a forward reliably lives. A reopened forward
    reaches whichever pod the Deployment resolves to, so the knarr process is
    read when scraping starts and when it ends, and a change fails the phase.
    Each scrape is kept under `out`, numbered, its first line the time it
    returned; a failed one keeps only a `# scrape failed` line."""

    def __init__(self, state, out):
        self.state = state
        self.out = out
        self.scrapes = []
        self.error = None
        self._process = None
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def __enter__(self):
        self.out.mkdir(parents=True, exist_ok=True)
        self._process = knarr_process()
        self._thread.start()
        return self

    def __exit__(self, exc_type, *_):
        self._stop.set()
        self._thread.join()
        if self.error is not None:
            raise RuntimeError(f"the /metrics scraper stopped: {self.error!r}")
        if exc_type is not None:
            return
        end = knarr_process()
        if change := process_change(self._process, end):
            raise RuntimeError(
                f"knarr was not one process through the {self.out.name} scrapes: {change}"
            )
        [(pod, _, restarts)] = end
        print(
            f"ok   one knarr process through the {self.out.name} scrapes: pod {pod}, "
            f"restarts {sum(count for _, count in restarts)}"
        )

    def answered_since(self, t):
        """True once a scrape at or after `t` answered."""
        return any(at >= t and parse_metrics(text) is not None for at, text in self.scrapes)

    def parsed(self):
        """(t, the scrape's samples, or None for a failed one), in time order."""
        return [(t, parse_metrics(text)) for t, text in self.scrapes]

    def _loop(self):
        try:
            self._scrape()
        except Exception as error:  # kept, and raised again at __exit__
            self.error = error

    def _scrape(self):
        while not self._stop.is_set():
            try:
                with cluster.port_forward(self.state, "deployment/knarr", 8080) as port:
                    while not self._stop.is_set():
                        status, body = cluster.http("GET", f"http://127.0.0.1:{port}/metrics")
                        if status != 200:
                            self._keep(f"# scrape failed: {status} {body[:200]!r}\n")
                            break
                        self._keep(body)
                        self._stop.wait(POLL)
            except RuntimeError as error:
                self._keep(f"# scrape failed: {error}\n")
            self._stop.wait(POLL)

    def _keep(self, text):
        t = time.monotonic()
        self.scrapes.append((t, text))
        path = self.out / f"{len(self.scrapes):05d}.txt"
        path.write_text(f"# at {time.time():.3f} monotonic {t:.3f}\n{text}")


def scrape_once(state):
    """One scrape through a fresh port forward: its samples, or None."""
    try:
        with cluster.port_forward(state, "deployment/knarr", 8080) as port:
            status, body = cluster.http("GET", f"http://127.0.0.1:{port}/metrics")
    except RuntimeError:
        return None
    return parse_metrics(body) if status == 200 else None


def install_keda(state):
    """Apply the pinned release YAML with its images pinned by digest, and wait
    for the operator, the metrics apiserver and its APIService. The download
    is kept under .cluster/keda/ and reused while its hash still matches."""
    pins = json.loads((FIXTURE / "keda.json").read_text())
    target = state / "keda"
    target.mkdir(exist_ok=True)
    core = target / "keda-core.yaml"
    if core.is_file() and hashlib.sha256(core.read_bytes()).hexdigest() == pins["sha256"]:
        body = core.read_bytes()
    else:
        if not pins["url"].startswith("https://"):
            raise ValueError(f"KEDA URL is not https: {pins['url']}")
        with urllib.request.urlopen(pins["url"], timeout=120) as response:  # noqa: S310 - https, checked above
            body = verify_download(response.read(), pins["sha256"])
        core.write_bytes(body)
    kustomization = keda_kustomization(pins["images"], body.decode(), core.name)
    (target / "kustomization.yaml").write_text(kustomization)
    rendered = cluster.output("kustomize", "build", str(target))
    cluster.run(
        "kubectl", "apply", "--server-side", "-f", "-", input=rendered, stdout=subprocess.DEVNULL
    )
    cluster.run(
        "kubectl",
        "wait",
        "--namespace=keda",
        "--for=condition=Available",
        "deployment/keda-operator",
        "deployment/keda-metrics-apiserver",
        "--timeout=300s",
    )
    cluster.run(
        "kubectl",
        "wait",
        "--for=condition=Available",
        "apiservice/v1beta1.external.metrics.k8s.io",
        "--timeout=300s",
    )
    print(f"ok   KEDA {pins['version']} installed from {pins['url']}, images pinned by digest")
    return pins["version"]


def reset():
    """Remove what an earlier run on this cluster left, so no pod starts with an
    annotation knarr wrote before. Foreground deletion waits for the pods."""
    cluster.run("kubectl", "delete", "scaledobject", "fake-worker", "--ignore-not-found")
    cluster.run(
        "kubectl",
        "delete",
        "deployment",
        "knarr",
        "fake-worker",
        UNTOUCHED,
        CHANGED,
        OPTOUT,
        "--ignore-not-found",
        "--cascade=foreground",
        "--wait=true",
        "--timeout=180s",
    )


def comparison(run, rounds, seed):
    """The baseline rounds without knarr, then the same rounds with it under
    deploy/e2e-fast, scraping /metrics throughout the second. Returns both
    phases' rounds and the knarr phase's scrapes."""
    state, out = run.state, run.out
    baseline = [scale_round(state, out, n, seed, "baseline") for n in range(1, rounds + 1)]
    cluster.deploy(run.name, state, run.knarr, "e2e-fast")
    cluster.run("kubectl", "label", "deployment", "fake-worker", f"{OPT_IN}=true", "--overwrite")
    with Scraper(state, out / "scrapes/comparison") as scraper:
        knarr = [scale_round(state, out, n, seed, "knarr") for n in range(1, rounds + 1)]
    return baseline, knarr, scraper.parsed()


def restart_settled(state, workers):
    """True once each restart Deployment's busy worker carries the busy cost and
    the marker, its idle worker neither, and knarr has nothing pending."""
    pods = read_pods(f"{NAME} in ({UNTOUCHED},{CHANGED},{OPTOUT})")
    for busy, idle in workers.values():
        if busy not in pods or idle not in pods:
            return False
        written = pods[busy].annotations
        if written.get(COST) != str(BUSY_COST) or MARKER not in written:
            return False
        if {COST, MARKER} & pods[idle].annotations.keys():
            return False
    samples = scrape_once(state)
    return samples is not None and all(
        total(samples, "knarr_patches_pending", deployment=deployment) == 0
        for deployment in workers
    )


def await_ready(state):
    """The time of knarr's first /readyz 200 after it is scaled back to 1,
    polled once a second through a forward reopened until the pod runs."""
    deadline = time.monotonic() + READY
    while time.monotonic() < deadline:
        with (
            contextlib.suppress(RuntimeError),
            cluster.port_forward(state, "deployment/knarr", 8080) as port,
        ):
            while time.monotonic() < deadline:
                status, _ = cluster.http("GET", f"http://127.0.0.1:{port}/readyz")
                if status == 200:
                    return time.monotonic()
                if status == 0:
                    break
                time.sleep(POLL)
        time.sleep(POLL)
    raise RuntimeError(f"knarr did not answer /readyz 200 within {READY} s of its restart")


def restart(run):
    """Lifecycle `Restart` `Threshold` at the defaults: settle three Deployments,
    stop knarr, change one's cost and opt another out while it is down, start
    it, and judge (a), (b) and (c) over the next WATCH seconds. Returns whether
    all held, with the scrapes after readiness."""
    state, out = run.state, run.out
    cluster.run("kubectl", "delete", "scaledobject", "fake-worker", "--wait=true")
    cluster.run(
        "kubectl",
        "delete",
        "deployment",
        "fake-worker",
        "--cascade=foreground",
        "--wait=true",
        "--timeout=180s",
    )
    cluster.deploy(run.name, state, run.knarr, "base")
    rendered = json.loads((state / "render/fake-worker/resources.json").read_text())
    worker = next(item for item in rendered["items"] if item["metadata"]["name"] == "fake-worker")
    clones = {"apiVersion": "v1", "kind": "List", "items": restart_deployments(worker)}
    cluster.run("kubectl", "apply", "-f", "-", input=json.dumps(clones))
    workers = {}
    for deployment in (UNTOUCHED, CHANGED, OPTOUT):
        cluster.run("kubectl", "rollout", "status", f"deployment/{deployment}", "--timeout=120s")
        busy, idle = wait_until(
            lambda d=deployment: exactly_live(f"{NAME}={d}", 2), SCALE, f"two {deployment} pods"
        )
        control(state, busy, BUSY_COST)
        control(state, idle, 0)
        workers[deployment] = (busy, idle)
    wait_until(lambda: restart_settled(state, workers), RESTART_SETTLE, "the restart Deployments")
    print(
        f"ok   settled: each Deployment's busy worker at {BUSY_COST} with the marker, nothing pending"
    )
    cluster.run("kubectl", "scale", "deployment/knarr", "--replicas=0")
    wait_until(lambda: not read_pods(KNARR), 120, "knarr's pod to go")
    changed = workers[CHANGED][1]
    control(state, changed, BUSY_COST)
    cluster.run("kubectl", "label", "deployment", OPTOUT, f"{OPT_IN}-")
    print(f"ok   downtime: {changed} set to {BUSY_COST}, {OPTOUT} opted out")
    cluster.run("kubectl", "scale", "deployment/knarr", "--replicas=1")
    t_ready = await_ready(state)
    print("ok   /readyz 200 after the restart")
    reads = []
    selector = f"{NAME} in ({UNTOUCHED},{CHANGED},{OPTOUT})"
    with Scraper(state, out / "scrapes/restart") as scraper:
        # Until the window is read through and a scrape at or past its end has
        # answered, which (a) needs, with a margin for a forward that drops
        # near the end. Each read is stamped when it returns.
        while (now := time.monotonic()) <= t_ready + WATCH + POLL or (
            not scraper.answered_since(t_ready + WATCH) and now < t_ready + WATCH + 60
        ):
            reads.append(stamped(lambda: read_pods(selector)))
            time.sleep(POLL)
    with (out / "restart-pods.jsonl").open("w") as kept:
        for t, pods in reads:
            annotations = (
                None if pods is None else {pod: read.annotations for pod, read in pods.items()}
            )
            kept.write(json.dumps({"t": t - t_ready, "pods": annotations}) + "\n")
    parsed = scraper.parsed()

    def cleaned(pods):
        if pods is None or any(pod not in pods for pod in workers[OPTOUT]):
            return None
        return not any({COST, MARKER} & pods[pod].annotations.keys() for pod in workers[OPTOUT])

    def rewritten(pods):
        return (
            None
            if pods is None or changed not in pods
            else pods[changed].annotations.get(COST, "")
        )

    untouched = [
        (
            t,
            None
            if samples is None
            else total(samples, "knarr_patches_total", deployment=UNTOUCHED),
        )
        for t, samples in parsed
    ]
    judged = [
        judge_untouched(untouched, t_ready, WATCH),
        judge_cleanup([(t, cleaned(pods)) for t, pods in reads], t_ready, CLEANUP_BOUND),
        judge_rewrite([(t, rewritten(pods)) for t, pods in reads], t_ready, REWRITE_BOUND),
        judge_preconditions([samples for _, samples in parsed]),
    ]
    for _, line in judged:
        print(line)
    return all(ok for ok, _ in judged), parsed


def patch_rate(segments):
    """Budget `Threshold` over each knarr process's scrapes: no window holds
    more than RATE x its seconds, rounded up, + BURST patches. A segment its
    scrapes do not cover fails rather than passes."""
    held = True
    limit = RATE * 60 + BURST
    for label, parsed in segments:
        covered, line = judge_coverage(parsed, COVERAGE, label)
        print(line)
        if not covered:
            held = False
            continue
        samples = cumulative_patches(parsed)
        violations = rate_violations(samples, RATE, BURST)
        worst = worst_window(samples, RATE, BURST)
        peak = peak_count(samples, 60)
        verdict = "FAIL" if violations else "ok  "
        held = held and not violations
        detail = f"worst window {worst[2]:g} patches in {worst[1] - worst[0]:.1f} s of {worst[3]} allowed"
        print(
            f"{verdict} patch rate, {label}: {len(samples)} scrapes, {detail}, "
            f"peak 60-s count {peak:g} of {limit}, {len(violations)} windows over 5·W + 10"
        )
    return held


def diagnostics():
    for args in [
        ("get", "pods", "--namespace=keda", "-o", "wide"),
        ("logs", "--namespace=keda", "deployment/keda-operator", "--tail=100"),
        ("get", "scaledobject", "-o", "yaml"),
        ("describe", "hpa"),
        ("get", "pods", "-o", "wide", "--show-labels"),
    ]:
        print(f"--- kubectl {' '.join(args)} ---", flush=True)
        subprocess.run(["kubectl", *args], check=False)


@contextlib.contextmanager
def timed(times, phase):
    started = time.monotonic()
    try:
        yield
    finally:
        times[phase] = time.monotonic() - started


def main():
    sys.stdout.reconfigure(line_buffering=True)
    checkout, rounds, seed = sys.argv[1:4]
    checkout = Path(checkout).resolve()
    rounds, seed = int(rounds), int(seed)
    if rounds < 1:
        raise ValueError("rounds must be at least 1")
    _, name, state = cluster.environment("keda-e2e", checkout)
    run = Run(state, checkout / "build/keda-e2e", name, f"knarr:{name}", f"fake-worker:{name}")
    if run.out.exists():
        shutil.rmtree(run.out)
    run.out.mkdir(parents=True)
    times = {}
    started = time.monotonic()
    try:
        with timed(times, "KEDA"):
            version = install_keda(state)
        with timed(times, "fixture"):
            reset()
            scaled = [FIXTURE / "scaledobject.json"]
            cluster.fake_worker_deploy(name, state, run.worker, scaled)
            # KEDA's core YAML has no admission webhook: a trigger the operator
            # refuses still applies, and shows only in this condition.
            cluster.run(
                "kubectl",
                "wait",
                "--for=condition=Ready",
                "scaledobject/fake-worker",
                "--timeout=120s",
            )
        with timed(times, "comparison"):
            baseline, knarr, during = comparison(run, rounds, seed)
        line, outcome = verdict(baseline, knarr)
        print(line)
        # Judged before the restart, so a restart that fails keeps it.
        rated = patch_rate([("deploy/e2e-fast", during)])
        with timed(times, "restart"):
            restarted, after = restart(run)
        rated = patch_rate([("after the restart", after)]) and rated
    except ValueError, RuntimeError, OSError, subprocess.CalledProcessError:
        diagnostics()
        raise
    kind = cluster.output("kind", "version").split()[1]
    node = cluster.KIND_NODE.split("@")[0].rpartition(":")[2]
    phases = ", ".join(f"{phase} {seconds:.0f} s" for phase, seconds in times.items())
    print(
        f"summary: KEDA {version}, kind {kind}, node {node}; {phases}; "
        f"total {time.monotonic() - started:.0f} s"
    )
    passed = outcome == "PASS" and restarted and rated
    print("keda-e2e: all checks passed" if passed else "keda-e2e: FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"keda-e2e: {error}", file=sys.stderr)
        sys.exit(1)
