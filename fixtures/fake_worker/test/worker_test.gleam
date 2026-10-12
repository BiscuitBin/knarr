//// The worker's state machine: control patches, SIGTERM, the drain and the
//// kill record the sink receives.

import fake_worker/kill_record.{KillRecord}
import fake_worker/worker
import gleam/list
import gleam/option.{None, Some}

fn busy(cost: Int, accepting: Bool) -> worker.State {
  worker.apply(
    worker.new(),
    worker.Patch(
      ..worker.no_change(),
      cost: Some(cost),
      accepting: Some(accepting),
    ),
  )
}

pub fn new_worker_is_idle_and_accepting_test() -> Nil {
  let state = worker.new()
  assert state.cost == 0
  assert state.accepting
  assert state.latency_ms == 0
  assert state.failure == worker.NoFailure
  assert state.drain == None
  assert worker.accepting(state)
}

pub fn a_patch_changes_only_what_it_names_test() -> Nil {
  let state = busy(1800, False)
  let next =
    worker.apply(
      state,
      worker.Patch(..worker.no_change(), latency_ms: Some(40)),
    )
  assert next == worker.State(..state, latency_ms: 40)
  assert worker.apply(state, worker.no_change()) == state
}

pub fn failure_names_round_trip_test() -> Nil {
  list.each(
    [
      worker.NoFailure, worker.Timeout, worker.ServerError, worker.NotFound,
      worker.Invalid, worker.Refused,
    ],
    fn(failure) {
      assert worker.parse_failure(worker.failure_name(failure)) == Ok(failure)
    },
  )
  assert worker.failure_name(worker.ServerError) == "server_error"
  assert worker.parse_failure("5xx") == Error(Nil)
}

// StatusEndpoint.Served: SIGTERM starts a drain that reports accepting false,
// and the record says what the worker was doing when it was told to stop.
pub fn terminate_records_a_busy_kill_test() -> Nil {
  let #(state, record) =
    busy(1800, True)
    |> worker.terminate(now_ms: 1000, drain_ms: 5000, pod: "w-1", sink: True)
  assert record
    == Some(KillRecord(pod: "w-1", busy: True, cost: 1800, accepting: True))
  assert state.drain
    == Some(worker.Drain(
      deadline_ms: 6000,
      delivered: False,
      next_attempt_ms: 1000,
    ))
  assert !worker.accepting(state)
}

pub fn terminate_records_an_idle_kill_test() -> Nil {
  let #(_, record) =
    worker.new()
    |> worker.terminate(now_ms: 0, drain_ms: 5000, pod: "w-2", sink: True)
  assert record
    == Some(KillRecord(pod: "w-2", busy: False, cost: 0, accepting: True))
}

pub fn a_second_sigterm_records_nothing_test() -> Nil {
  let #(state, _) =
    busy(10, True)
    |> worker.terminate(now_ms: 0, drain_ms: 5000, pod: "w", sink: True)
  let #(again, record) =
    worker.terminate(state, now_ms: 100, drain_ms: 5000, pod: "w", sink: True)
  assert record == None
  assert again == state
}

pub fn without_a_sink_the_record_counts_as_delivered_test() -> Nil {
  let #(state, _) =
    worker.new()
    |> worker.terminate(now_ms: 0, drain_ms: 5000, pod: "w", sink: False)
  assert state.drain
    == Some(worker.Drain(deadline_ms: 5000, delivered: True, next_attempt_ms: 0))
  assert worker.should_stop(state, now_ms: 0)
}

pub fn control_cannot_resume_accepting_while_draining_test() -> Nil {
  let #(state, _) =
    busy(10, True)
    |> worker.terminate(now_ms: 0, drain_ms: 5000, pod: "w", sink: False)
  let next =
    worker.apply(
      state,
      worker.Patch(..worker.no_change(), accepting: Some(True)),
    )
  assert !worker.accepting(next)
}

pub fn the_drain_ends_when_work_is_done_and_the_record_delivered_test() -> Nil {
  let #(state, _) =
    busy(10, True)
    |> worker.terminate(now_ms: 0, drain_ms: 5000, pod: "w", sink: True)
  assert !worker.should_stop(state, now_ms: 100)
  let done =
    worker.apply(state, worker.Patch(..worker.no_change(), cost: Some(0)))
  assert !worker.should_stop(done, now_ms: 100)
  assert worker.should_stop(worker.delivered(done), now_ms: 100)
}

pub fn the_drain_ends_at_the_deadline_whatever_the_work_test() -> Nil {
  let #(state, _) =
    busy(10, True)
    |> worker.terminate(now_ms: 0, drain_ms: 5000, pod: "w", sink: True)
  assert !worker.should_stop(state, now_ms: 4999)
  assert worker.should_stop(state, now_ms: 5000)
}

pub fn a_worker_that_was_never_told_to_stop_never_stops_test() -> Nil {
  assert !worker.should_stop(worker.new(), now_ms: 1_000_000)
  assert worker.delivered(worker.new()) == worker.new()
}

// The state owns the pending kill record and decides when to try to deliver
// it, so a sink that crashes mid-attempt loses no record: the next attempt is
// due again later.
pub fn a_delivery_attempt_is_due_at_sigterm_test() -> Nil {
  let #(state, _) =
    busy(10, True)
    |> worker.terminate(now_ms: 1000, drain_ms: 5000, pod: "w", sink: True)
  assert worker.attempt_due(state:, now_ms: 1000)
  let waiting = worker.retry_at(state:, at_ms: 3250)
  assert !worker.attempt_due(state: waiting, now_ms: 3249)
  assert worker.attempt_due(state: waiting, now_ms: 3250)
}

pub fn no_attempt_once_delivered_or_past_the_deadline_test() -> Nil {
  let #(state, _) =
    busy(10, True)
    |> worker.terminate(now_ms: 0, drain_ms: 5000, pod: "w", sink: True)
  assert !worker.attempt_due(state: worker.delivered(state), now_ms: 0)
  assert !worker.attempt_due(state:, now_ms: 5000)
  let #(no_sink, _) =
    busy(10, True)
    |> worker.terminate(now_ms: 0, drain_ms: 5000, pod: "w", sink: False)
  assert !worker.attempt_due(state: no_sink, now_ms: 0)
  assert !worker.attempt_due(state: worker.new(), now_ms: 0)
  assert worker.retry_at(state: worker.new(), at_ms: 9) == worker.new()
}
