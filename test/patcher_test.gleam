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
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleeunit/should
import knarr/budget.{type Purpose}
import knarr/metrics
import knarr/patcher.{
  type Turn, Accepted, Attempted, Departed, Due, Listed, NothingDue, Rejected,
  Throttled, Turn, Wake,
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
// oldest-due entry goes next, across pods and purposes alike.
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
    pod: "c",
    purpose: budget.Apply,
    deployment: "order",
    at: start_ms,
  )
  due(
    harness:,
    pod: "b",
    purpose: budget.Cleanup,
    deployment: "order",
    at: start_ms - 1000,
  )
  quiet(harness)
  done(harness:, pod: "a", at: start_ms)
  assert next_turn(harness) == Turn(pod_name: "b", purpose: budget.Cleanup)
  quiet(harness)
  attempted(
    harness:,
    pod: "b",
    purpose: budget.Cleanup,
    outcome: Accepted,
    still_due: False,
    at: start_ms,
  )
  assert next_turn(harness) == Turn(pod_name: "c", purpose: budget.Apply)
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

// Bucket: a turn that finds nothing due refunds its token, and the pod it
// was for is not held by an interval it never spent.
pub fn nothing_due_refunds_the_token_test() -> Nil {
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
    deployment: "refund",
    at: start_ms,
  )
  due(
    harness:,
    pod: "b",
    purpose: budget.Apply,
    deployment: "refund",
    at: start_ms,
  )
  assert next_turn(harness).pod_name == "a"
  process.send(
    harness.patcher,
    NothingDue(pod_name: "a", purpose: budget.Apply),
  )
  assert next_turn(harness).pod_name == "b"
  done(harness:, pod: "b", at: start_ms)
  quiet(harness)
  wake(harness:, at: start_ms + 1000)
  due(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    deployment: "refund",
    at: start_ms + 1000,
  )
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
  attempted(
    harness:,
    pod: "a",
    purpose: budget.Apply,
    outcome: throttled(None),
    still_due: False,
    at: unix_milliseconds(),
  )
  due_with_interval(
    harness:,
    pod: "b",
    deployment: "timer",
    interval_s: 0,
    at: now,
  )
  assert process.receive(harness.sink, 500) == Error(Nil)
  let turn = process.receive(harness.sink, 1500) |> should.be_ok
  assert turn.pod_name == "b"
  stop_root(harness.root)
}

// Pending, Leaving: a LIST discards the apply of a pod it no longer shows or
// shows terminating, its turn in flight included, and keeps the cleanup; an
// attempt answered after the discard does not bring the entry back.
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
    pod: "b",
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
  process.send(harness.patcher, Listed(targets: ["a", "b"], terminating: ["b"]))
  assert await_metric(pending_line("list", 2))
  process.send(harness.patcher, Listed(targets: ["b"], terminating: []))
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
  assert next_turn(harness) == Turn(pod_name: "b", purpose: budget.Cleanup)
  assert await_metric(pending_line("list", 1))
  attempted(
    harness:,
    pod: "b",
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
  process.send(harness.patcher, Listed(targets: ["x"], terminating: []))
  no_quiet(harness)
  done(harness:, pod: "a", at: start_ms)
  assert next_turn(harness).pod_name == "x"
  assert next_quiet(harness) == "gone"
  assert await_absent("knarr_patches_pending{deployment=\"gone\"}")
  assert await_metric(pending_line("stays", 1))
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
