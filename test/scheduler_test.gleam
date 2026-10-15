//// The scheduler process against closure fakes (budget PollSchedule,
//// docs/specs/budget.allium): the clock is a scripted value, the draws a
//// scripted list, and every poll is a closure that holds its worker at a
//// gate until the test releases it with the reading it returns, so the
//// queue, the concurrency bound and no overlap are observable. The
//// scheduler runs under a real supervisor beside its worker factory, and
//// the readings land on a subject the test owns, as the reconciler's sink
//// will.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleeunit/should
import knarr/metrics
import knarr/observability
import knarr/poller.{type Endpoint, Endpoint}
import knarr/reconcile
import knarr/scheduler.{type Polled, Joiner, Listed, Wake}

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

const interval = 30

const port = 8080

const path = "/knarr/v1/status"

/// One poll held at the gate: the pod, as its endpoint names it, the worker
/// polling it, and the subject that releases it with the reading to return.
type Held {
  Held(
    pod: String,
    endpoint: Endpoint,
    worker: Pid,
    release: Subject(poller.Reading),
  )
}

type Harness {
  Harness(
    table: Table,
    gate: Subject(Held),
    sink: Subject(Polled),
    scheduler: Subject(scheduler.Message),
    root: Pid,
  )
}

/// A scripted scheduler: the clock at `now` seconds, the draws given, taken
/// in order and 0 once spent, and every poll held at the gate.
fn harness(draws: String) -> Harness {
  let table = table_new()
  put(table, "now", "1000")
  put(table, "draws", draws)
  let gate = process.new_subject()
  start(
    table:,
    gate:,
    poll: held(gate),
    concurrency: 64,
    poll_timeout_s: 1,
    now: fn() { scripted_now(table) },
  )
}

fn scripted_now(table: Table) -> Int {
  let seconds = get(table, "now") |> result.try(int.parse) |> result.unwrap(0)
  seconds * 1000
}

fn draw(table: Table, _bound: Int) -> Int {
  case get(table, "draws") |> result.unwrap("") |> string.split(",") {
    [first, ..rest] -> {
      put(table, "draws", string.join(rest, ","))
      int.parse(first) |> result.unwrap(0)
    }
    [] -> 0
  }
}

/// The scheduler and its worker factory under one supervisor, as the
/// reconciler's set will hold them.
fn start(
  table table: Table,
  gate gate: Subject(Held),
  poll poll: fn(Endpoint) -> poller.Reading,
  concurrency concurrency: Int,
  poll_timeout_s poll_timeout_s: Int,
  now now: fn() -> Int,
) -> Harness {
  let sink = process.new_subject()
  let name: process.Name(scheduler.Message) = process.new_name("scheduler_test")
  let workers: process.Name(factory_supervisor.Message(scheduler.Job, Nil)) =
    process.new_name("scheduler_test_workers")
  let config =
    scheduler.Config(
      self: name,
      workers:,
      poll:,
      now:,
      random: draw(table, _),
      polled: fn(polled) { process.send(sink, polled) },
      poll_timeout_s:,
      jitter_percent: 10,
      concurrency:,
    )
  let started =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(scheduler.workers_supervised(workers))
    |> supervisor.add(supervision.worker(fn() { scheduler.start(config) }))
    |> supervisor.start
    |> should.be_ok
  Harness(
    table:,
    gate:,
    sink:,
    scheduler: process.named_subject(name),
    root: started.pid,
  )
}

/// A poll that parks its worker at the gate until the test releases it.
fn held(gate: Subject(Held)) -> fn(Endpoint) -> poller.Reading {
  fn(endpoint: Endpoint) {
    let release = process.new_subject()
    process.send(
      gate,
      Held(pod: endpoint.pod_ip, endpoint:, worker: process.self(), release:),
    )
    process.receive_forever(release)
  }
}

fn joiner(pod: String, deployment: String) -> scheduler.Joiner {
  Joiner(
    pod_name: pod,
    deployment:,
    interval_s: interval,
    endpoint: Endpoint(pod_ip: pod, port:, path:),
  )
}

/// A gauge value no queue in these tests reaches, written before a send so
/// the settle that follows the message is seen to overwrite it.
const sentinel = 99

/// Sends a message and returns once the scheduler has settled after it:
/// every settle sets knarr_poll_queue_depth, so the sentinel written before
/// the send is gone once the message is processed. A test moves the
/// scripted clock only after this returns, so no message sees a later clock
/// than the one it was sent under.
fn send_settled(harness: Harness, message: scheduler.Message) -> Nil {
  metrics.set(observability.poll_queue_depth, [], sentinel)
  process.send(harness.scheduler, message)
  assert await(
    fn() { sample("knarr_poll_queue_depth") != int.to_float(sentinel) },
    100,
  )
}

fn listed(harness: Harness, joining: List(scheduler.Joiner)) -> Nil {
  let names = list.map(joining, fn(one) { one.pod_name })
  send_settled(harness, Listed(listed: names, joining:))
}

/// Moves the scripted clock to `at` seconds and wakes the scheduler,
/// returning once it has settled at that clock.
fn wake(harness harness: Harness, at at: Int) -> Nil {
  put(harness.table, "now", int.to_string(at))
  send_settled(harness, Wake)
}

fn next_held(harness: Harness) -> Held {
  process.receive(harness.gate, 1000) |> should.be_ok
}

/// Nothing reaches the gate for 200 ms: an assertion that no poll was
/// sent, never an acknowledgement that a message was processed.
fn quiet(harness: Harness) -> Nil {
  assert process.receive(harness.gate, 200) == Error(Nil)
}

fn next_polled(harness: Harness) -> Polled {
  process.receive(harness.sink, 1000) |> should.be_ok
}

fn valid(cost: Int) -> poller.Reading {
  poller.Valid(poller.Status(cost:, accepting: True))
}

/// True once the exposition carries `line`, within half a second: the
/// gauges and counters are set after the poll was sent, so a test that
/// just saw a worker at the gate waits for them.
fn await_metric(line: String) -> Bool {
  await(fn() { string.contains(metrics.collect(), line) }, 50)
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

/// The value of an unlabelled sample, 0.0 when absent.
fn sample(name: String) -> Float {
  let prefix = name <> " "
  metrics.collect()
  |> string.split("\n")
  |> list.find(fn(line) { string.starts_with(line, prefix) })
  |> result.map(fn(line) { string.drop_start(line, string.length(prefix)) })
  |> result.try(fn(text) {
    float.parse(text)
    |> result.lazy_or(fn() { int.parse(text) |> result.map(int.to_float) })
  })
  |> result.unwrap(0.0)
}

fn timed_out() -> reconcile.Reading {
  reconcile.Reading(kind: reconcile.TimedOut, cost: None, draining: False)
}

// Phase: a joining pod is first due at now plus the draw, in whole seconds,
// and nothing polls it before.
pub fn a_joining_pod_is_first_polled_at_its_phase_test() -> Nil {
  let harness = harness("7")
  listed(harness, [joiner("a", "phase")])
  quiet(harness)
  wake(harness:, at: 1006)
  quiet(harness)
  wake(harness:, at: 1007)
  let held = next_held(harness)
  assert held.pod == "a"
  process.send(held.release, valid(1))
  assert next_polled(harness).pod_name == "a"
  stop_root(harness.root)
}

// Jitter: the next rung is the previous plus the interval plus a fresh
// draw, and no poll fires merely because the previous returned.
pub fn the_next_rung_is_the_previous_plus_the_interval_plus_a_fresh_draw_test() -> Nil {
  let harness = harness("0,2")
  listed(harness, [joiner("a", "jitter")])
  let held = next_held(harness)
  process.send(held.release, valid(1))
  let polled = next_polled(harness)
  assert polled.reading
    == reconcile.Reading(kind: reconcile.Valid, cost: Some(1), draining: False)
  assert polled.at_ms == 1_000_000
  quiet(harness)
  wake(harness:, at: 1031)
  quiet(harness)
  wake(harness:, at: 1032)
  assert next_held(harness).pod == "a"
  stop_root(harness.root)
}

// Jitter: a rung that passed while the poll was out is skipped, and the next
// poll is due on the first rung after now, never early to catch up.
pub fn a_poll_returning_late_skips_the_passed_rungs_test() -> Nil {
  let harness = harness("0")
  listed(harness, [joiner("a", "late")])
  let held = next_held(harness)
  put(harness.table, "now", "1040")
  process.send(held.release, valid(1))
  assert next_polled(harness).at_ms == 1_040_000
  assert await_metric("knarr_polls_skipped_total{deployment=\"late\"} 1\n")
  wake(harness:, at: 1059)
  quiet(harness)
  wake(harness:, at: 1060)
  assert next_held(harness).pod == "a"
  stop_root(harness.root)
}

// NoOverlap: a rung that falls due while a poll is outstanding is skipped
// and counted, and the following poll is due on the next rung from the
// skipped due time.
pub fn a_poll_due_while_one_is_outstanding_is_skipped_and_counted_test() -> Nil {
  let harness = harness("0")
  listed(harness, [joiner("a", "overlap")])
  let held = next_held(harness)
  wake(harness:, at: 1030)
  quiet(harness)
  assert await_metric("knarr_polls_skipped_total{deployment=\"overlap\"} 1\n")
  put(harness.table, "now", "1035")
  process.send(held.release, valid(1))
  assert next_polled(harness).pod_name == "a"
  wake(harness:, at: 1059)
  quiet(harness)
  wake(harness:, at: 1060)
  assert next_held(harness).pod == "a"
  stop_root(harness.root)
}

// Concurrency: a due poll above the bound waits in the queue, counted by
// knarr_poll_queue_depth, and is served oldest-due first once a poll
// returns.
pub fn the_queue_holds_due_polls_above_concurrency_and_serves_oldest_due_first_test() -> Nil {
  let table = table_new()
  put(table, "now", "1000")
  put(table, "draws", "0,1,2")
  let gate = process.new_subject()
  let harness =
    start(
      table:,
      gate:,
      poll: held(gate),
      concurrency: 2,
      poll_timeout_s: 1,
      now: fn() { scripted_now(table) },
    )
  listed(harness, [
    joiner("a", "queue"),
    joiner("b", "queue"),
    joiner("c", "queue"),
  ])
  let first = next_held(harness)
  assert first.pod == "a"
  assert await_metric("knarr_poll_queue_depth 0\n")
  wake(harness:, at: 1002)
  assert next_held(harness).pod == "b"
  quiet(harness)
  assert await_metric("knarr_poll_queue_depth 1\n")
  process.send(first.release, valid(1))
  assert next_polled(harness).pod_name == "a"
  assert next_held(harness).pod == "c"
  assert await_metric("knarr_poll_queue_depth 0\n")
  stop_root(harness.root)
}

// Phase, with the real clock: the scheduler's own timer fires the first
// poll at its phase without a message from outside.
pub fn the_wake_timer_fires_the_first_poll_at_its_phase_test() -> Nil {
  let table = table_new()
  put(table, "draws", "1")
  let gate = process.new_subject()
  let harness =
    start(
      table:,
      gate:,
      poll: held(gate),
      concurrency: 64,
      poll_timeout_s: 1,
      now: unix_milliseconds,
    )
  process.send(
    harness.scheduler,
    Listed(listed: ["a"], joining: [
      Joiner(..joiner("a", "timer"), interval_s: 5),
    ]),
  )
  assert process.receive(harness.gate, 500) == Error(Nil)
  let held = process.receive(harness.gate, 1500) |> should.be_ok
  assert held.pod == "a"
  stop_root(harness.root)
}

// Leaving: a pod the LIST no longer shows leaves the queue at once and is
// never sent, and the response to its poll in flight is discarded.
pub fn a_pod_the_list_no_longer_shows_leaves_the_queue_and_its_response_is_discarded_test() -> Nil {
  let table = table_new()
  put(table, "now", "1000")
  put(table, "draws", "0,0")
  let gate = process.new_subject()
  let harness =
    start(
      table:,
      gate:,
      poll: held(gate),
      concurrency: 1,
      poll_timeout_s: 1,
      now: fn() { scripted_now(table) },
    )
  listed(harness, [joiner("a", "leaving"), joiner("b", "leaving")])
  let held = next_held(harness)
  assert held.pod == "a"
  assert await_metric("knarr_poll_queue_depth 1\n")
  listed(harness, [])
  assert await_metric("knarr_poll_queue_depth 0\n")
  process.send(held.release, valid(1))
  assert process.receive(harness.sink, 300) == Error(Nil)
  quiet(harness)
  stop_root(harness.root)
}

// Leaving: a listed pod already scheduled keeps its ladder, so a second
// LIST draws no new phase, and takes the endpoint the LIST now shows.
pub fn a_listed_pod_already_scheduled_keeps_its_ladder_and_takes_the_new_endpoint_test() -> Nil {
  let harness = harness("5")
  listed(harness, [joiner("a", "kept")])
  quiet(harness)
  let moved =
    Joiner(
      ..joiner("a", "kept"),
      endpoint: Endpoint(pod_ip: "a", port: 9000, path:),
    )
  listed(harness, [moved])
  quiet(harness)
  wake(harness:, at: 1005)
  let held = next_held(harness)
  assert held.endpoint.port == 9000
  process.send(held.release, valid(1))
  assert next_polled(harness).endpoint.port == 9000
  stop_root(harness.root)
}

// Transport, and the worker monitor: a worker that crashes is that pod's
// timed_out reading alone, and its slot frees for the next in the queue.
pub fn a_crashed_worker_is_that_pods_timed_out_reading_alone_test() -> Nil {
  let table = table_new()
  put(table, "now", "1000")
  put(table, "draws", "0,1,2")
  let gate = process.new_subject()
  let crashing = fn(endpoint: Endpoint) {
    case endpoint.pod_ip {
      "b" -> {
        process.kill(process.self())
        poller.Invalid
      }
      _ -> held(gate)(endpoint)
    }
  }
  let harness =
    start(
      table:,
      gate:,
      poll: crashing,
      concurrency: 1,
      poll_timeout_s: 1,
      now: fn() { scripted_now(table) },
    )
  listed(harness, [
    joiner("a", "crash"),
    joiner("b", "crash"),
    joiner("c", "crash"),
  ])
  let first = next_held(harness)
  assert first.pod == "a"
  wake(harness:, at: 1002)
  quiet(harness)
  process.send(first.release, valid(3))
  let polled = next_polled(harness)
  assert polled.pod_name == "a"
  assert polled.reading.cost == Some(3)
  let polled = next_polled(harness)
  assert polled.pod_name == "b"
  assert polled.reading == timed_out()
  assert next_held(harness).pod == "c"
  stop_root(harness.root)
}

// Transport, and the per-flight deadline: a worker that does not answer
// within twice the timeout and a second is killed and is a timed_out
// reading.
pub fn a_worker_past_its_deadline_is_killed_and_timed_out_test() -> Nil {
  let table = table_new()
  put(table, "now", "1000")
  put(table, "draws", "0")
  let gate = process.new_subject()
  let sleeping = fn(endpoint: Endpoint) {
    process.send(
      gate,
      Held(
        pod: endpoint.pod_ip,
        endpoint:,
        worker: process.self(),
        release: process.new_subject(),
      ),
    )
    process.sleep(10_000)
    poller.Invalid
  }
  let harness =
    start(
      table:,
      gate:,
      poll: sleeping,
      concurrency: 1,
      poll_timeout_s: 1,
      now: fn() { scripted_now(table) },
    )
  listed(harness, [joiner("a", "deadline")])
  let held = next_held(harness)
  let polled = process.receive(harness.sink, 4500) |> should.be_ok
  assert polled.pod_name == "a"
  assert polled.reading == timed_out()
  assert await(fn() { !process.is_alive(held.worker) }, 50)
  stop_root(harness.root)
}

// observability Polls: every delivered reading is observed on
// knarr_poll_duration_seconds, a timed_out one at the timeout.
pub fn poll_duration_is_observed_and_a_timed_out_poll_at_the_timeout_test() -> Nil {
  let count = sample("knarr_poll_duration_seconds_count")
  let sum = sample("knarr_poll_duration_seconds_sum")
  let harness = harness("0")
  listed(harness, [joiner("a", "duration")])
  let held = next_held(harness)
  process.send(held.release, valid(1))
  assert next_polled(harness).reading.kind == reconcile.Valid
  wake(harness:, at: 1030)
  let held = next_held(harness)
  process.send(held.release, poller.Failed(poller.TimedOut))
  assert next_polled(harness).reading == timed_out()
  assert await(
    fn() { sample("knarr_poll_duration_seconds_count") == count +. 2.0 },
    50,
  )
  assert sample("knarr_poll_duration_seconds_sum") == sum +. 1.0
  stop_root(harness.root)
}

// observability SeriesLife: the skipped-poll series of a Deployment leaves
// the exposition when the LIST shows none of its pods.
pub fn the_skipped_poll_series_leaves_with_its_deployment_test() -> Nil {
  let harness = harness("0")
  listed(harness, [joiner("a", "gone")])
  let held = next_held(harness)
  wake(harness:, at: 1030)
  assert await_metric("knarr_polls_skipped_total{deployment=\"gone\"} 1\n")
  listed(harness, [])
  assert await(
    fn() {
      !string.contains(
        metrics.collect(),
        "knarr_polls_skipped_total{deployment=\"gone\"}",
      )
    },
    50,
  )
  process.send(held.release, valid(1))
  assert process.receive(harness.sink, 300) == Error(Nil)
  stop_root(harness.root)
}

// Leaving, and the concurrency bound: a pod that leaves while its poll is
// out loses that worker, so when it rejoins its new poll is the only one
// running and the old worker's answer never reaches the sink.
pub fn a_pod_that_leaves_and_rejoins_has_one_poll_running_and_the_old_worker_dead_test() -> Nil {
  let table = table_new()
  put(table, "now", "1000")
  put(table, "draws", "0")
  let gate = process.new_subject()
  let harness =
    start(
      table:,
      gate:,
      poll: held(gate),
      concurrency: 1,
      poll_timeout_s: 1,
      now: fn() { scripted_now(table) },
    )
  listed(harness, [joiner("a", "rejoin")])
  let old = next_held(harness)
  assert old.pod == "a"
  listed(harness, [])
  listed(harness, [joiner("a", "rejoin")])
  let new = next_held(harness)
  assert new.pod == "a"
  assert new.worker != old.worker
  assert await(fn() { !process.is_alive(old.worker) }, 50)
  process.send(old.release, valid(1))
  assert process.receive(harness.sink, 300) == Error(Nil)
  process.send(new.release, valid(2))
  assert next_polled(harness).reading.cost == Some(2)
  stop_root(harness.root)
}

// NoOverlap, and Concurrency: a rung that passes while the pod waits in the
// queue is skipped and counted at once, and the count survives the pod
// leaving before it was served.
pub fn a_rung_passing_while_queued_is_counted_and_kept_when_the_pod_leaves_test() -> Nil {
  let table = table_new()
  put(table, "now", "1000")
  put(table, "draws", "0,0")
  let gate = process.new_subject()
  let harness =
    start(
      table:,
      gate:,
      poll: held(gate),
      concurrency: 1,
      poll_timeout_s: 1,
      now: fn() { scripted_now(table) },
    )
  let slow = Joiner(..joiner("a", "queued"), interval_s: 90)
  listed(harness, [slow, joiner("b", "queued")])
  let held = next_held(harness)
  assert held.pod == "a"
  assert await_metric("knarr_poll_queue_depth 1\n")
  wake(harness:, at: 1030)
  assert await_metric("knarr_polls_skipped_total{deployment=\"queued\"} 1\n")
  put(harness.table, "now", "1031")
  listed(harness, [slow])
  assert await_metric("knarr_poll_queue_depth 0\n")
  assert await_metric("knarr_polls_skipped_total{deployment=\"queued\"} 1\n")
  process.send(held.release, valid(1))
  assert next_polled(harness).pod_name == "a"
  quiet(harness)
  stop_root(harness.root)
}

// NoOverlap, and Jitter: after a rung passed while the pod was queued, its
// poll is served for the rung it was queued on, and the following one is
// due on the next rung from the skipped due time.
pub fn a_pod_served_after_a_queued_skip_is_next_due_on_the_rung_after_the_skipped_one_test() -> Nil {
  let table = table_new()
  put(table, "now", "1000")
  put(table, "draws", "0,0")
  let gate = process.new_subject()
  let harness =
    start(
      table:,
      gate:,
      poll: held(gate),
      concurrency: 1,
      poll_timeout_s: 1,
      now: fn() { scripted_now(table) },
    )
  let slow = Joiner(..joiner("a", "served"), interval_s: 90)
  listed(harness, [slow, joiner("b", "served")])
  let held = next_held(harness)
  assert held.pod == "a"
  wake(harness:, at: 1030)
  assert await_metric("knarr_polls_skipped_total{deployment=\"served\"} 1\n")
  put(harness.table, "now", "1031")
  process.send(held.release, valid(1))
  assert next_polled(harness).pod_name == "a"
  let held = next_held(harness)
  assert held.pod == "b"
  process.send(held.release, valid(1))
  assert next_polled(harness).pod_name == "b"
  wake(harness:, at: 1059)
  quiet(harness)
  wake(harness:, at: 1060)
  assert next_held(harness).pod == "b"
  stop_root(harness.root)
}

// The wake timer: a Wake that is not the recorded timer's, as one from a
// timer that fired before a later message re-armed, leaves no second timer
// running. The clock is scripted and the timer real: the first timer is
// armed for two seconds; a stale Wake and a LIST then re-arm for ten; the
// clock is moved to where the LIST's pod is due, and nothing polls it
// within the first timer's two seconds.
pub fn a_stale_wake_leaves_no_second_timer_running_test() -> Nil {
  let harness = harness("2,10,0")
  listed(harness, [joiner("a", "stale")])
  send_settled(harness, Wake)
  listed(harness, [
    Joiner(..joiner("b", "stale"), interval_s: 90),
    joiner("c", "stale"),
  ])
  assert next_held(harness).pod == "c"
  put(harness.table, "now", "1010")
  assert process.receive(harness.gate, 2500) == Error(Nil)
  stop_root(harness.root)
}

// observability SeriesLife: the skipped-poll series of a Deployment leaves
// the exposition when its last pod moves to another Deployment, the pod
// itself staying scheduled.
pub fn the_skipped_poll_series_leaves_when_its_last_pod_moves_to_another_deployment_test() -> Nil {
  let harness = harness("0")
  listed(harness, [joiner("a", "before")])
  let held = next_held(harness)
  wake(harness:, at: 1030)
  assert await_metric("knarr_polls_skipped_total{deployment=\"before\"} 1\n")
  listed(harness, [joiner("a", "after")])
  assert await(
    fn() {
      !string.contains(
        metrics.collect(),
        "knarr_polls_skipped_total{deployment=\"before\"}",
      )
    },
    50,
  )
  process.send(held.release, valid(1))
  assert next_polled(harness).deployment == "after"
  stop_root(harness.root)
}

// Transport, and the per-flight deadline: a poll that returned in time is
// not timed out when its deadline would have fired. The deadline is real,
// three seconds at a timeout of one, so the sink is watched past it.
pub fn a_poll_that_returned_is_not_timed_out_when_its_deadline_would_have_fired_test() -> Nil {
  let harness = harness("0")
  listed(harness, [joiner("a", "returned")])
  let held = next_held(harness)
  process.send(held.release, valid(1))
  assert next_polled(harness).reading.kind == reconcile.Valid
  assert process.receive(harness.sink, 3500) == Error(Nil)
  stop_root(harness.root)
}
