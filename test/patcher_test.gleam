//// The patcher process against closure fakes (budget WriteBudget,
//// docs/specs/budget.allium): the clock is a scripted millisecond value,
//// every turn the patcher grants lands on a subject the test owns, as the
//// reconciler's sink will, and the test answers each turn with the
//// `Attempted` or `NothingDue` the reconciler would. The patcher runs under
//// a real supervisor, so the per-pod interval, the token bucket, the
//// pending set, the 429 pause and the series a departed Deployment leaves
//// behind are observable through the turns and the exposition.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleeunit/should
import knarr/budget.{type Purpose}
import knarr/metrics
import knarr/observability
import knarr/patcher.{
  type Cleaning, type Turn, Accepted, Attempted, Cleaning, Departed, Due, Listed,
  NothingDue, Rejected, Throttled, Turn, Wake,
}

pub type Table

@external(erlang, "reconciler_test_ffi", "table_new")
fn table_new() -> Table

@external(erlang, "reconciler_test_ffi", "table_put")
fn put(table: Table, key: String, value: String) -> Nil

@external(erlang, "reconciler_test_ffi", "table_get")
fn get(table: Table, key: String) -> Result(String, Nil)

@external(erlang, "reconciler_test_ffi", "stop_root")
fn stop_root(pid: Pid) -> Nil

@external(erlang, "reconciler_ffi", "unix_milliseconds")
fn unix_milliseconds() -> Int

/// The scripted clock's start, in unix milliseconds.
const start_ms = 1_000_000

/// The patch interval the tests give a pod unless they say otherwise.
const interval = 60

type Harness {
  Harness(
    table: Table,
    sink: Subject(Turn),
    quiets: Subject(String),
    patcher: Subject(patcher.Message),
    root: Pid,
  )
}

/// A scripted patcher: the clock at `start_ms`, rate 5 and burst 10 as
/// config's defaults, the back-off ladder from 1 second to 60.
fn harness() -> Harness {
  let table = table_new()
  put(table, "now_ms", int.to_string(start_ms))
  start(
    rate_per_second: 5,
    burst: 10,
    now: fn() { scripted_now(table) },
    table:,
  )
}

fn scripted_now(table: Table) -> Int {
  get(table, "now_ms") |> result.try(int.parse) |> result.unwrap(0)
}

/// The patcher under a one-child supervisor, as the reconciler's set will
/// hold it.
fn start(
  rate_per_second rate_per_second: Int,
  burst burst: Int,
  now now: fn() -> Int,
  table table: Table,
) -> Harness {
  let sink = process.new_subject()
  let quiets = process.new_subject()
  let name: process.Name(patcher.Message) = process.new_name("patcher_test")
  let config =
    patcher.Config(
      self: name,
      now:,
      turn: fn(turn) { process.send(sink, turn) },
      quiet: fn(deployment) { process.send(quiets, deployment) },
      rate_per_second:,
      burst:,
      backoff_initial_s: 1,
      backoff_cap_s: 60,
    )
  let started =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(supervision.worker(fn() { patcher.start(config) }))
    |> supervisor.start
    |> should.be_ok
  Harness(
    table:,
    sink:,
    quiets:,
    patcher: process.named_subject(name),
    root: started.pid,
  )
}

fn due(
  harness harness: Harness,
  pod pod: String,
  purpose purpose: Purpose,
  deployment deployment: String,
  at at: Int,
) -> Nil {
  process.send(
    harness.patcher,
    Due(pod_name: pod, purpose:, deployment:, interval_s: interval, at_ms: at),
  )
}

fn due_with_interval(
  harness harness: Harness,
  pod pod: String,
  deployment deployment: String,
  interval_s interval_s: Int,
  at at: Int,
) -> Nil {
  process.send(
    harness.patcher,
    Due(
      pod_name: pod,
      purpose: budget.Apply,
      deployment:,
      interval_s:,
      at_ms: at,
    ),
  )
}

fn attempted(
  harness harness: Harness,
  pod pod: String,
  purpose purpose: Purpose,
  outcome outcome: patcher.Outcome,
  still_due still_due: Bool,
  at at: Int,
) -> Nil {
  process.send(
    harness.patcher,
    Attempted(pod_name: pod, purpose:, outcome:, still_due:, at_ms: at),
  )
}

fn done(harness harness: Harness, pod pod: String, at at: Int) -> Nil {
  attempted(
    harness:,
    pod:,
    purpose: budget.Apply,
    outcome: Accepted,
    still_due: False,
    at:,
  )
}

fn wake(harness harness: Harness, at at: Int) -> Nil {
  put(harness.table, "now_ms", int.to_string(at))
  process.send(harness.patcher, Wake)
}

/// A gauge value no pending age in these tests reaches, written before a
/// send so the grant that follows the message is seen to overwrite it.
const sentinel = 99

/// Sends a message and returns once the patcher has settled after it: every
/// grant sets knarr_patch_pending_oldest_seconds, so the sentinel written
/// before the send is gone once the message is processed. A test moves the
/// scripted clock only after this returns, so no message sees a later clock
/// than the one it was sent under.
fn send_settled(harness: Harness, message: patcher.Message) -> Nil {
  metrics.set(observability.patch_pending_oldest_seconds, [], sentinel)
  process.send(harness.patcher, message)
  assert await(
    fn() { !string.contains(metrics.collect(), oldest_line(sentinel)) },
    100,
  )
}

fn next_turn(harness: Harness) -> Turn {
  process.receive(harness.sink, 1000) |> should.be_ok
}

fn quiet(harness: Harness) -> Nil {
  assert process.receive(harness.sink, 200) == Error(Nil)
}

fn next_quiet(harness: Harness) -> String {
  process.receive(harness.quiets, 1000) |> should.be_ok
}

fn no_quiet(harness: Harness) -> Nil {
  assert process.receive(harness.quiets, 200) == Error(Nil)
}

/// True once the exposition carries `line`, within half a second: the
/// gauges are set after the turn was granted, so a test that just saw a
/// turn waits for them.
fn await_metric(line: String) -> Bool {
  await(fn() { string.contains(metrics.collect(), line) }, 50)
}

fn await_absent(text: String) -> Bool {
  await(fn() { !string.contains(metrics.collect(), text) }, 50)
}

/// `await_metric` with a budget of `attempts` tens of milliseconds, for a
/// change the patcher's own timer makes with the real clock.
fn await_metric_for(line: String, attempts: Int) -> Bool {
  await(fn() { string.contains(metrics.collect(), line) }, attempts)
}

fn await(condition: fn() -> Bool, attempts: Int) -> Bool {
  case condition() {
    True -> True
    False if attempts <= 0 -> False
    False -> {
      process.sleep(10)
      await(condition, attempts - 1)
    }
  }
}

fn pending_line(deployment: String, count: Int) -> String {
  "knarr_patches_pending{deployment=\""
  <> deployment
  <> "\"} "
  <> int.to_string(count)
  <> "\n"
}

fn paused_line(value: Int) -> String {
  "knarr_paused{scope=\"patch\"} " <> int.to_string(value) <> "\n"
}

fn pause_seconds_line(value: Int) -> String {
  "knarr_pause_seconds{scope=\"patch\"} " <> int.to_string(value) <> "\n"
}

fn oldest_line(value: Int) -> String {
  "knarr_patch_pending_oldest_seconds " <> int.to_string(value) <> "\n"
}

fn throttled(retry_after_s: Option(Int)) -> patcher.Outcome {
  Throttled(retry_after_s:)
}

// Restart: after a start the bucket is full and no pod is held, so the first
// due change gets its turn at once.
pub fn a_due_change_gets_a_turn_at_once_after_a_start_test() -> Nil {
  let harness = harness()
  assert await_metric(paused_line(0))
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "fresh",
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "a", purpose: budget.Apply)
  stop_root(harness.root)
}

// Pending, order: one turn is out at a time, and once it is answered the
// oldest-due entry goes next, across pods and purposes alike: the older
// entry here is an apply and alphabetically the last, so neither a cleanup
// priority nor name order could pick it.
pub fn one_turn_is_out_at_a_time_and_the_oldest_due_goes_first_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "order",
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  due(
    harness:,
    pod: "b",
    purpose: budget.Cleanup,
    deployment: "order",
    at: start_ms,
  )
  due(
    harness:,
    pod: "c",
    purpose: budget.Apply,
    deployment: "order",
    at: start_ms - 1000,
  )
  quiet(harness)
  done(harness:, pod: "a", at: start_ms)
  assert next_turn(harness) == Turn(pod_name: "c", purpose: budget.Apply)
  quiet(harness)
  done(harness:, pod: "c", at: start_ms)
  assert next_turn(harness) == Turn(pod_name: "b", purpose: budget.Cleanup)
  stop_root(harness.root)
}

// PerPod: a pod waits the patch interval from its last attempt whatever the
// outcome, and an entry still due keeps its place with its original
// due_since.
pub fn a_pod_waits_the_patch_interval_from_its_last_attempt_whatever_the_outcome_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "perpod",
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: Rejected,
    still_due: True,
    at: start_ms,
  )
  quiet(harness)
  assert await_metric(pending_line("perpod", 1))
  wake(harness:, at: start_ms + 59_000)
  quiet(harness)
  assert await_metric(oldest_line(59))
  wake(harness:, at: start_ms + 60_000)
  assert next_turn(harness) == Turn(pod_name: "a", purpose: budget.Apply)
  stop_root(harness.root)
}

// PerPod, Pending: an apply and a cleanup of one pod are two entries, kept
// from when each first became due, and two attempts an interval apart; a
// second Due of the same pod and purpose adds nothing.
pub fn one_pending_entry_per_pod_and_purpose_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "two",
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "a", purpose: budget.Apply)
  put(harness.table, "now_ms", int.to_string(start_ms + 1000))
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "two",
    at: start_ms + 1000,
  )
  due(
    harness:,
    pod: "a",
    purpose: budget.Cleanup,
    deployment: "two",
    at: start_ms + 1000,
  )
  assert await_metric(pending_line("two", 2))
  assert await_metric(oldest_line(1))
  done(harness:, pod: "a", at: start_ms + 1000)
  quiet(harness)
  assert await_metric(pending_line("two", 1))
  wake(harness:, at: start_ms + 60_000)
  quiet(harness)
  wake(harness:, at: start_ms + 61_000)
  assert next_turn(harness) == Turn(pod_name: "a", purpose: budget.Cleanup)
  stop_root(harness.root)
}

// PerPod: an interval of 0 leaves the bucket as the only bound, after a
// rejection too.
pub fn a_zero_interval_leaves_the_bucket_as_the_only_bound_test() -> Nil {
  let harness = harness()
  due_with_interval(
    harness:,
    pod: "a",
    deployment: "zero",
    interval_s: 0,
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: Rejected,
    still_due: True,
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  stop_root(harness.root)
}

// Bucket: a burst empties the bucket, and it refills rate_per_second per
// whole second, so half a second credits nothing.
pub fn the_bucket_bounds_a_burst_and_refills_whole_seconds_test() -> Nil {
  let table = table_new()
  put(table, "now_ms", int.to_string(start_ms))
  let harness =
    start(
      rate_per_second: 1,
      burst: 2,
      now: fn() { scripted_now(table) },
      table:,
    )
  due_with_interval(
    harness:,
    pod: "a",
    deployment: "bucket",
    interval_s: 0,
    at: start_ms,
  )
  due_with_interval(
    harness:,
    pod: "b",
    deployment: "bucket",
    interval_s: 0,
    at: start_ms,
  )
  due_with_interval(
    harness:,
    pod: "c",
    deployment: "bucket",
    interval_s: 0,
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  done(harness:, pod: "a", at: start_ms)
  assert next_turn(harness).pod_name == "b"
  done(harness:, pod: "b", at: start_ms)
  quiet(harness)
  wake(harness:, at: start_ms + 500)
  quiet(harness)
  wake(harness:, at: start_ms + 1000)
  assert next_turn(harness).pod_name == "c"
  done(harness:, pod: "c", at: start_ms + 1000)
  quiet(harness)
  stop_root(harness.root)
}

// Bucket: a turn that finds nothing due spends no token and leaves the
// bucket as it was, since no attempt was made; only an attempt spends one,
// and the pod is not held by an interval it never started.
pub fn nothing_due_leaves_the_bucket_as_it_was_test() -> Nil {
  let table = table_new()
  put(table, "now_ms", int.to_string(start_ms))
  let harness =
    start(
      rate_per_second: 1,
      burst: 1,
      now: fn() { scripted_now(table) },
      table:,
    )
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "nothing",
    at: start_ms,
  )
  due(
    harness:,
    pod: "b",
    purpose: budget.Apply,
    deployment: "nothing",
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  process.send(
    harness.patcher,
    NothingDue(pod_name: "a", purpose: budget.Apply),
  )
  assert next_turn(harness).pod_name == "b"
  done(harness:, pod: "b", at: start_ms)
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "nothing",
    at: start_ms,
  )
  quiet(harness)
  wake(harness:, at: start_ms + 1000)
  assert next_turn(harness).pod_name == "a"
  stop_root(harness.root)
}

// Threshold: the token is spent when the attempt is reported, so a turn
// answered late is counted against the bucket of that moment and at most
// burst + rate per whole second attempts fall in any window, 15 in one
// second at the defaults, however the refill and the answer interleave.
pub fn the_threshold_holds_when_a_turn_is_answered_late_test() -> Nil {
  let harness = harness()
  due_with_interval(
    harness:,
    pod: "a",
    deployment: "threshold",
    interval_s: 0,
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  put(harness.table, "now_ms", int.to_string(start_ms + 1500))
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: Accepted,
    still_due: True,
    at: start_ms + 1500,
  )
  let attempts =
    answer_every_turn(
      harness:,
      at: start_ms + 1500,
      until: start_ms + 3500,
      attempts: [
        start_ms + 1500,
      ],
    )
  assert attempts_in(attempts:, from: start_ms + 1500, window_s: 1) <= 15
  list.each([1, 2, 3], fn(window_s) {
    list.each(attempts, fn(from) {
      assert attempts_in(attempts:, from:, window_s:) <= 5 * window_s + 10
    })
  })
  assert list.length(attempts) == 20
  stop_root(harness.root)
}

/// Answers every turn at once with an attempt at the clock's reading `at`,
/// and once no turn is out moves the clock half a second and wakes the
/// patcher, until `until`. The attempts' times, newest first.
fn answer_every_turn(
  harness harness: Harness,
  at at: Int,
  until until: Int,
  attempts attempts: List(Int),
) -> List(Int) {
  put(harness.table, "now_ms", int.to_string(at))
  case process.receive(harness.sink, 200) {
    Ok(turn) -> {
      attempted(
        harness:,
        pod: turn.pod_name,
        purpose: turn.purpose,
        outcome: Accepted,
        still_due: True,
        at:,
      )
      answer_every_turn(harness:, at:, until:, attempts: [at, ..attempts])
    }
    Error(Nil) if at >= until -> attempts
    Error(Nil) -> {
      wake(harness:, at: at + 500)
      answer_every_turn(harness:, at: at + 500, until:, attempts:)
    }
  }
}

fn attempts_in(
  attempts attempts: List(Int),
  from from: Int,
  window_s window_s: Int,
) -> Int {
  list.count(attempts, fn(at) { at >= from && at < from + window_s * 1000 })
}

// PerPod, Pending: a Due for a change already pending keeps its due_since
// and refreshes its interval and Deployment, so a changed override reaches
// the held pod.
pub fn a_due_for_a_pending_entry_refreshes_its_interval_and_keeps_its_due_since_test() -> Nil {
  let harness = harness()
  due_with_interval(
    harness:,
    pod: "a",
    deployment: "stale",
    interval_s: 60,
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: Rejected,
    still_due: True,
    at: start_ms,
  )
  put(harness.table, "now_ms", int.to_string(start_ms + 30_000))
  due_with_interval(
    harness:,
    pod: "a",
    deployment: "stale-moved",
    interval_s: 3600,
    at: start_ms + 30_000,
  )
  assert await_metric(pending_line("stale-moved", 1))
  assert await_metric(pending_line("stale", 0))
  wake(harness:, at: start_ms + 60_000)
  quiet(harness)
  assert await_metric(oldest_line(60))
  wake(harness:, at: start_ms + 3_599_999)
  quiet(harness)
  wake(harness:, at: start_ms + 3_600_000)
  assert next_turn(harness).pod_name == "a"
  stop_root(harness.root)
}

// BackOff, PauseScope: a 429 pauses every pod for the ladder's length,
// doubling on each consecutive 429, shown on knarr_paused and
// knarr_pause_seconds for the patch scope and cleared when the pause lifts;
// a 2xx ends the run.
pub fn a_429_pauses_every_pod_and_the_wake_at_until_grants_test() -> Nil {
  let harness = harness()
  due_with_interval(
    harness:,
    pod: "a",
    deployment: "pause",
    interval_s: 0,
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: throttled(None),
    still_due: True,
    at: start_ms,
  )
  assert await_metric(paused_line(1))
  assert await_metric(pause_seconds_line(1))
  due_with_interval(
    harness:,
    pod: "b",
    deployment: "pause",
    interval_s: 0,
    at: start_ms,
  )
  quiet(harness)
  wake(harness:, at: start_ms + 999)
  quiet(harness)
  wake(harness:, at: start_ms + 1000)
  assert next_turn(harness).pod_name == "a"
  assert await_metric(paused_line(0))
  assert await_metric(pause_seconds_line(0))
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: throttled(None),
    still_due: True,
    at: start_ms + 1000,
  )
  assert await_metric(pause_seconds_line(2))
  wake(harness:, at: start_ms + 2999)
  quiet(harness)
  wake(harness:, at: start_ms + 3000)
  assert next_turn(harness).pod_name == "a"
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: throttled(None),
    still_due: True,
    at: start_ms + 3000,
  )
  assert await_metric(pause_seconds_line(4))
  wake(harness:, at: start_ms + 7000)
  assert next_turn(harness).pod_name == "a"
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: Accepted,
    still_due: False,
    at: start_ms + 7000,
  )
  assert next_turn(harness).pod_name == "b"
  assert await_metric(paused_line(0))
  assert await_metric(pause_seconds_line(0))
  attempted(
    harness:,
    pod: "b",
    purpose: budget.Apply,
    outcome: throttled(None),
    still_due: True,
    at: start_ms + 7000,
  )
  assert await_metric(pause_seconds_line(1))
  stop_root(harness.root)
}

// BackOff: a Retry-After raises the pause to its value, well past the
// ladder, and nothing is granted before it ends.
pub fn a_retry_after_holds_every_pod_past_the_ladder_test() -> Nil {
  let harness = harness()
  due_with_interval(
    harness:,
    pod: "a",
    deployment: "retry",
    interval_s: 0,
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: throttled(Some(120)),
    still_due: False,
    at: start_ms,
  )
  due_with_interval(
    harness:,
    pod: "b",
    deployment: "retry",
    interval_s: 0,
    at: start_ms,
  )
  assert await_metric(pause_seconds_line(120))
  wake(harness:, at: start_ms + 1000)
  quiet(harness)
  wake(harness:, at: start_ms + 119_999)
  quiet(harness)
  assert await_metric(paused_line(1))
  wake(harness:, at: start_ms + 120_000)
  assert next_turn(harness).pod_name == "b"
  assert await_metric(paused_line(0))
  stop_root(harness.root)
}

// BackOff, with the real clock: the patcher's own timer lifts the pause and
// grants without a message from outside.
pub fn the_wake_timer_lifts_the_pause_on_its_own_test() -> Nil {
  let table = table_new()
  let harness =
    start(rate_per_second: 5, burst: 10, now: unix_milliseconds, table:)
  let now = unix_milliseconds()
  due_with_interval(
    harness:,
    pod: "a",
    deployment: "timer",
    interval_s: 0,
    at: now,
  )
  assert next_turn(harness).pod_name == "a"
  let at = unix_milliseconds()
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: throttled(None),
    still_due: False,
    at:,
  )
  due_with_interval(
    harness:,
    pod: "b",
    deployment: "timer",
    interval_s: 0,
    at: now,
  )
  let turn = process.receive(harness.sink, 3000) |> should.be_ok
  assert unix_milliseconds() >= at + 1000
  assert turn.pod_name == "b"
  stop_root(harness.root)
}

// PauseScope, with the real clock: a pause with nothing left pending still
// ends on the patcher's own timer, so the patch-scope gauges clear.
pub fn a_pause_ends_on_the_timer_with_nothing_pending_test() -> Nil {
  let table = table_new()
  let harness =
    start(rate_per_second: 5, burst: 10, now: unix_milliseconds, table:)
  due_with_interval(
    harness:,
    pod: "a",
    deployment: "empty-pause",
    interval_s: 0,
    at: unix_milliseconds(),
  )
  assert next_turn(harness).pod_name == "a"
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: throttled(None),
    still_due: True,
    at: unix_milliseconds(),
  )
  assert await_metric(paused_line(1))
  process.send(
    harness.patcher,
    Listed(
      listed: [],
      targets: [],
      terminating: [],
      replaced: [],
      deployments: [],
      cleaning: [],
    ),
  )
  assert await_metric(pending_line("empty-pause", 0))
  assert await_metric_for(paused_line(0), 300)
  assert await_metric(pause_seconds_line(0))
  stop_root(harness.root)
}

// Pending, Leaving: a LIST discards the apply of a pod it no longer shows or
// shows terminating, its turn in flight included, and keeps the cleanup of a
// pod its cycle still makes due; an attempt answered after the discard does
// not bring the entry back.
pub fn a_list_discards_the_apply_of_a_gone_or_terminating_pod_and_keeps_its_cleanup_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "list",
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  due(
    harness:,
    pod: "b",
    purpose: budget.Apply,
    deployment: "list",
    at: start_ms,
  )
  due(
    harness:,
    pod: "d",
    purpose: budget.Cleanup,
    deployment: "list",
    at: start_ms,
  )
  due(
    harness:,
    pod: "c",
    purpose: budget.Apply,
    deployment: "list",
    at: start_ms,
  )
  assert await_metric(pending_line("list", 4))
  process.send(
    harness.patcher,
    Listed(
      listed: ["a", "b", "d"],
      targets: ["a", "b"],
      terminating: ["b"],
      replaced: [],
      deployments: ["list"],
      cleaning: [cleaning(pod: "d", deployment: "list", at: start_ms)],
    ),
  )
  assert await_metric(pending_line("list", 2))
  process.send(
    harness.patcher,
    Listed(
      listed: ["b", "d"],
      targets: ["b"],
      terminating: [],
      replaced: [],
      deployments: ["list"],
      cleaning: [cleaning(pod: "d", deployment: "list", at: start_ms)],
    ),
  )
  assert await_metric(pending_line("list", 1))
  quiet(harness)
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: Rejected,
    still_due: True,
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "d", purpose: budget.Cleanup)
  assert await_metric(pending_line("list", 1))
  attempted(
    harness:,
    pod: "d",
    purpose: budget.Cleanup,
    outcome: Accepted,
    still_due: False,
    at: start_ms,
  )
  quiet(harness)
  assert await_metric(pending_line("list", 0))
  stop_root(harness.root)
}

// observability SeriesLife: a departed Deployment is quiet only once nothing
// of its pods is pending or in turn, and its pending series leaves with it.
pub fn a_departed_deployment_is_quiet_once_nothing_of_its_pods_is_pending_or_in_turn_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "gone",
    at: start_ms,
  )
  due(
    harness:,
    pod: "b",
    purpose: budget.Apply,
    deployment: "gone",
    at: start_ms,
  )
  due(
    harness:,
    pod: "x",
    purpose: budget.Apply,
    deployment: "stays",
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  assert await_metric(pending_line("gone", 2))
  process.send(harness.patcher, Departed("gone"))
  no_quiet(harness)
  process.send(
    harness.patcher,
    Listed(
      listed: ["x"],
      targets: ["x"],
      terminating: [],
      replaced: [],
      deployments: ["stays"],
      cleaning: [],
    ),
  )
  no_quiet(harness)
  done(harness:, pod: "a", at: start_ms)
  assert next_turn(harness).pod_name == "x"
  assert next_quiet(harness) == "gone"
  assert await_absent("knarr_patches_pending{deployment=\"gone\"}")
  assert await_metric(pending_line("stays", 1))
  stop_root(harness.root)
}

// observability SeriesLife: a Deployment that departs and rejoins before it
// is quiet is never quiet; its pending series stays, and a later departure
// starts afresh.
pub fn a_deployment_that_rejoins_before_quiet_keeps_its_pending_series_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "rejoin",
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  assert await_metric(pending_line("rejoin", 1))
  process.send(harness.patcher, Departed("rejoin"))
  no_quiet(harness)
  process.send(
    harness.patcher,
    Listed(
      listed: ["a"],
      targets: ["a"],
      terminating: [],
      replaced: [],
      deployments: ["rejoin"],
      cleaning: [],
    ),
  )
  done(harness:, pod: "a", at: start_ms)
  no_quiet(harness)
  assert await_metric(pending_line("rejoin", 0))
  process.send(harness.patcher, Departed("rejoin"))
  assert next_quiet(harness) == "rejoin"
  assert await_absent("knarr_patches_pending{deployment=\"rejoin\"}")
  stop_root(harness.root)
}

// observability Budget: knarr_patch_pending_oldest_seconds is the age of the
// oldest pending change, and 0 when nothing is pending.
pub fn the_oldest_pending_age_is_exported_and_zero_when_empty_test() -> Nil {
  let harness = harness()
  assert await_metric(oldest_line(0))
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "oldest",
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  put(harness.table, "now_ms", int.to_string(start_ms + 5000))
  due(
    harness:,
    pod: "b",
    purpose: budget.Apply,
    deployment: "oldest",
    at: start_ms + 5000,
  )
  assert await_metric(oldest_line(5))
  done(harness:, pod: "a", at: start_ms + 5000)
  assert next_turn(harness).pod_name == "b"
  assert await_metric(oldest_line(0))
  done(harness:, pod: "b", at: start_ms + 5000)
  quiet(harness)
  assert await_metric(oldest_line(0))
  assert await_metric(pending_line("oldest", 0))
  stop_root(harness.root)
}

// The wake timer: a Wake that is not the recorded timer's, as one from a
// timer that fired before a later message re-armed, leaves no second timer
// running. The clock is scripted and the timer real: a held pod arms the
// timer for its two-second interval; a stale Wake and a Due that stretches
// the interval to ten re-arm for ten; the clock is moved past the hold, and
// nothing grants within the first timer's two seconds.
pub fn a_stale_wake_leaves_no_second_timer_running_test() -> Nil {
  let harness = harness()
  due_with_interval(
    harness:,
    pod: "a",
    deployment: "stale",
    interval_s: 2,
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: Rejected,
    still_due: True,
    at: start_ms,
  )
  send_settled(harness, Wake)
  send_settled(
    harness,
    Due(
      pod_name: "a",
      purpose: budget.Apply,
      deployment: "stale",
      interval_s: 10,
      at_ms: start_ms,
    ),
  )
  put(harness.table, "now_ms", int.to_string(start_ms + 10_000))
  assert process.receive(harness.sink, 2500) == Error(Nil)
  stop_root(harness.root)
}

// PerPod, Leaving: a pod the LIST no longer shows is forgotten with its last
// attempt, so one that returns under the same name is new to the patcher
// and not held by an interval it never started, while a pod the LIST keeps
// stays held from its last attempt.
pub fn a_list_forgets_the_last_attempt_of_a_pod_it_no_longer_shows_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "prune",
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  done(harness:, pod: "a", at: start_ms)
  due(
    harness:,
    pod: "b",
    purpose: budget.Apply,
    deployment: "prune",
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "b"
  done(harness:, pod: "b", at: start_ms)
  send_settled(
    harness,
    Listed(
      listed: ["b"],
      targets: ["b"],
      terminating: [],
      replaced: [],
      deployments: ["prune"],
      cleaning: [],
    ),
  )
  send_settled(
    harness,
    Listed(
      listed: ["a", "b"],
      targets: ["a", "b"],
      terminating: [],
      replaced: [],
      deployments: ["prune"],
      cleaning: [],
    ),
  )
  due(
    harness:,
    pod: "b",
    purpose: budget.Apply,
    deployment: "prune",
    at: start_ms,
  )
  quiet(harness)
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "prune",
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "a", purpose: budget.Apply)
  stop_root(harness.root)
}

// PerPod, Pending, Leaving: a pod listed under another uid is not the pod
// the patcher attempted, so its predecessor's held apply is discarded with
// its due_since, and its last attempt is forgotten: the replacement's own
// first change is granted at once, inside the interval the predecessor's
// attempt started.
pub fn a_list_that_replaces_a_pod_forgets_its_apply_and_last_attempt_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "replace",
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  done(harness:, pod: "a", at: start_ms)
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "replace",
    at: start_ms,
  )
  quiet(harness)
  assert await_metric(pending_line("replace", 1))
  send_settled(
    harness,
    Listed(
      listed: ["a"],
      targets: ["a"],
      terminating: [],
      replaced: ["a"],
      deployments: ["replace"],
      cleaning: [],
    ),
  )
  assert await_metric(pending_line("replace", 0))
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "replace",
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "a", purpose: budget.Apply)
  stop_root(harness.root)
}

/// A cleanup's attempt rejected, its entry kept or not by `still_due`.
fn cleanup_rejected(
  harness harness: Harness,
  pod pod: String,
  still_due still_due: Bool,
  at at: Int,
) -> Nil {
  send_settled(
    harness,
    Attempted(
      pod_name: pod,
      purpose: budget.Cleanup,
      outcome: Rejected,
      still_due:,
      at_ms: at,
    ),
  )
}

/// A cleanup a cycle makes due for `pod` at `at`, with the tests' interval.
fn cleaning(
  pod pod: String,
  deployment deployment: String,
  at at: Int,
) -> Cleaning {
  Cleaning(pod_name: pod, deployment:, interval_s: interval, at_ms: at)
}

/// A LIST that shows only `pods`, none of them a target, with `cleaning`
/// the cleanups its cycle makes due.
fn non_targets_listed(
  pods pods: List(String),
  replaced replaced: List(String),
  cleaning cleaning: List(Cleaning),
) -> patcher.Message {
  Listed(
    listed: pods,
    targets: [],
    terminating: [],
    replaced:,
    deployments: [],
    cleaning:,
  )
}

// PerPod, lifecycle Cleanup Retry: the interval is counted from a pod's last
// attempt whatever its purpose or outcome, a pod that is not a target
// included, so a LIST that shows the pod keeps its last attempt once its
// entry is gone. With the LIST inside the interval, a cleanup due again is
// held at interval - 1 seconds from the rejected attempt and granted at the
// interval.
pub fn a_list_keeps_the_last_attempt_of_a_listed_non_target_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "n",
    purpose: budget.Cleanup,
    deployment: "opted-out",
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "n", purpose: budget.Cleanup)
  cleanup_rejected(harness:, pod: "n", still_due: False, at: start_ms)
  put(harness.table, "now_ms", int.to_string(start_ms + 30_000))
  send_settled(
    harness,
    non_targets_listed(pods: ["n"], replaced: [], cleaning: [
      cleaning(pod: "n", deployment: "opted-out", at: start_ms + 30_000),
    ]),
  )
  quiet(harness)
  wake(harness:, at: start_ms + { interval - 1 } * 1000)
  quiet(harness)
  wake(harness:, at: start_ms + interval * 1000)
  assert next_turn(harness) == Turn(pod_name: "n", purpose: budget.Cleanup)
  stop_root(harness.root)
}

// Pending, lifecycle Cleanup Retry: a cleanup entry is kept while
// lifecycle's due names its pod; a LIST that still shows the pod but whose
// cycle no longer makes its cleanup due discards the entry, and nothing is
// granted for it once the interval is over.
pub fn a_list_discards_a_cleanup_its_cycle_no_longer_makes_due_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "n",
    purpose: budget.Cleanup,
    deployment: "undue",
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "n", purpose: budget.Cleanup)
  cleanup_rejected(harness:, pod: "n", still_due: True, at: start_ms)
  assert await_metric(pending_line("undue", 1))
  send_settled(
    harness,
    non_targets_listed(pods: ["n"], replaced: [], cleaning: [
      cleaning(pod: "n", deployment: "undue", at: start_ms),
    ]),
  )
  assert await_metric(pending_line("undue", 1))
  send_settled(
    harness,
    non_targets_listed(pods: ["n"], replaced: [], cleaning: []),
  )
  assert await_metric(pending_line("undue", 0))
  wake(harness:, at: start_ms + interval * 1000)
  quiet(harness)
  stop_root(harness.root)
}

// lifecycle Cleanup Done, observability SeriesLife: a cleanup in turn for a
// pod that has since left the pod LIST holds its departed Deployment until
// it is answered. The LIST discards its entry, so an answer that finds it
// still due brings nothing back, and the Deployment is then quiet.
pub fn a_cleanup_in_turn_for_a_pod_that_left_the_list_holds_quiet_until_answered_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "g",
    purpose: budget.Cleanup,
    deployment: "leaving",
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "g", purpose: budget.Cleanup)
  process.send(
    harness.patcher,
    non_targets_listed(pods: [], replaced: [], cleaning: []),
  )
  process.send(harness.patcher, Departed("leaving"))
  no_quiet(harness)
  cleanup_rejected(harness:, pod: "g", still_due: True, at: start_ms)
  assert next_quiet(harness) == "leaving"
  quiet(harness)
  stop_root(harness.root)
}

// PerPod, Pending: a pod listed under another uid is not the pod whose
// cleanup was due, so its predecessor's cleanup entry and last attempt are
// forgotten even when the replacement's cycle makes a cleanup due: the
// replacement's own cleanup, which the same LIST carries, is granted at
// once, inside the interval the predecessor's attempt started, and is due
// from the cycle's clock, not the predecessor's due_since.
pub fn a_list_that_replaces_a_pod_forgets_its_cleanup_and_last_attempt_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "n",
    purpose: budget.Cleanup,
    deployment: "recleanup",
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "n", purpose: budget.Cleanup)
  cleanup_rejected(harness:, pod: "n", still_due: True, at: start_ms)
  quiet(harness)
  assert await_metric(pending_line("recleanup", 1))
  put(harness.table, "now_ms", int.to_string(start_ms + 30_000))
  process.send(
    harness.patcher,
    non_targets_listed(pods: ["n"], replaced: ["n"], cleaning: [
      cleaning(pod: "n", deployment: "recleanup", at: start_ms + 30_000),
    ]),
  )
  assert next_turn(harness) == Turn(pod_name: "n", purpose: budget.Cleanup)
  // The predecessor's due_since of start_ms would read 30.
  assert await_metric(oldest_line(0))
  stop_root(harness.root)
}

// PerPod, lifecycle Cleanup Retry: a cleanup kept across a LIST takes the
// interval its cycle derives before anything is granted, so a pod whose
// cleanup moves from a 10 s override to the install's 60 s, as its
// Deployment opts out, is not granted at the old boundary; it is granted at
// the new one, from the pod's last attempt, its due_since kept.
pub fn a_list_refreshes_a_kept_cleanups_interval_before_any_grant_test() -> Nil {
  let harness = harness()
  due_with_interval(
    harness:,
    pod: "a",
    deployment: "short",
    interval_s: 10,
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "a", purpose: budget.Apply)
  done(harness:, pod: "a", at: start_ms)
  put(harness.table, "now_ms", int.to_string(start_ms + 5000))
  send_settled(
    harness,
    Due(
      pod_name: "a",
      purpose: budget.Cleanup,
      deployment: "short",
      interval_s: 10,
      at_ms: start_ms + 5000,
    ),
  )
  quiet(harness)
  put(harness.table, "now_ms", int.to_string(start_ms + 10_000))
  process.send(
    harness.patcher,
    non_targets_listed(pods: ["a"], replaced: [], cleaning: [
      Cleaning(
        pod_name: "a",
        deployment: "short",
        interval_s: 60,
        at_ms: start_ms + 10_000,
      ),
    ]),
  )
  quiet(harness)
  wake(harness:, at: start_ms + 59_999)
  quiet(harness)
  wake(harness:, at: start_ms + 60_000)
  assert next_turn(harness) == Turn(pod_name: "a", purpose: budget.Cleanup)
  assert await_metric(oldest_line(55))
  stop_root(harness.root)
}

// observability SeriesLife, lifecycle Cleanup Done; PerPod, Pending: a
// departed Deployment whose one interval-held cleanup is for a pod the LIST
// shows under another uid is not quiet at that LIST, since the cycle makes
// the replacement's cleanup due in the same step that forgets the
// predecessor's; the replacement's cleanup is granted at once, and its
// answer makes the Deployment quiet once.
pub fn a_replaced_pods_cleanup_keeps_its_departed_deployment_busy_test() -> Nil {
  let harness = harness()
  due(
    harness:,
    pod: "n",
    purpose: budget.Cleanup,
    deployment: "replaced",
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "n", purpose: budget.Cleanup)
  cleanup_rejected(harness:, pod: "n", still_due: True, at: start_ms)
  quiet(harness)
  send_settled(harness, Departed("replaced"))
  no_quiet(harness)
  put(harness.table, "now_ms", int.to_string(start_ms + 30_000))
  process.send(
    harness.patcher,
    non_targets_listed(pods: ["n"], replaced: ["n"], cleaning: [
      cleaning(pod: "n", deployment: "replaced", at: start_ms + 30_000),
    ]),
  )
  no_quiet(harness)
  assert next_turn(harness) == Turn(pod_name: "n", purpose: budget.Cleanup)
  assert await_metric(oldest_line(0))
  process.send(
    harness.patcher,
    NothingDue(pod_name: "n", purpose: budget.Cleanup),
  )
  assert next_quiet(harness) == "replaced"
  no_quiet(harness)
  stop_root(harness.root)
}
