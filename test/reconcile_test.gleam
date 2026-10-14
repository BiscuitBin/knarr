//// Tests for the Fallback and Loop contracts (docs/specs/reconcile.allium):
//// the reading state machine by sequence at the defaults, the parse of the
//// marker's applied record, the desired state and what is due. Every
//// function is pure, so each test passes values in and reads values out.

import gleam/option.{None, Some}
import knarr/poller
import knarr/reconcile.{
  type Applied, type PodState, type Reading, type ReadingKind, Absent, Applied,
  Desired, Fresh, Invalid, NotFound, PodState, Reading, Refused, Stale, TimedOut,
  Unknown, Unreachable, Valid,
}
import qcheck

const thresholds = [300, 900, 1800, 3600]

const margin = 60

/// Observes each reading in turn, from the initial state, at the defaults.
fn run(readings: List(#(ReadingKind, Int))) -> PodState {
  run_with(
    readings:,
    unknown_polls: reconcile.unknown_polls,
    absent_after: reconcile.absent_after,
  )
}

fn run_with(
  readings readings: List(#(ReadingKind, Int)),
  unknown_polls unknown_polls: Int,
  absent_after absent_after: Int,
) -> PodState {
  observe_all(
    state: reconcile.initial(),
    readings:,
    unknown_polls:,
    absent_after:,
  )
}

fn observe_all(
  state state: PodState,
  readings readings: List(#(ReadingKind, Int)),
  unknown_polls unknown_polls: Int,
  absent_after absent_after: Int,
) -> PodState {
  case readings {
    [] -> state
    [#(reading, at), ..rest] ->
      observe_all(
        state: reconcile.observe(
          state:,
          reading:,
          at:,
          unknown_polls:,
          absent_after:,
        ),
        readings: rest,
        unknown_polls:,
        absent_after:,
      )
  }
}

/// `kind` at `from`, then every `step` seconds, `count` readings in all.
fn every(
  kind kind: ReadingKind,
  from from: Int,
  step step: Int,
  count count: Int,
) -> List(#(ReadingKind, Int)) {
  case count {
    0 -> []
    _ -> [
      #(kind, from),
      ..every(kind:, from: from + step, step:, count: count - 1)
    ]
  }
}

fn valid(cost: Int) -> Reading {
  Reading(kind: Valid, cost: Some(cost), draining: False)
}

fn draining(cost: Int) -> Reading {
  Reading(kind: Valid, cost: Some(cost), draining: True)
}

fn failed(kind: ReadingKind) -> Reading {
  Reading(kind:, cost: None, draining: False)
}

fn applied(value: Int) -> Applied {
  Applied(value:, usable: True)
}

// -------------------------------------------------------------- Readings ---

// Fallback.Readings: initial is fresh with failed 0 and no run.
pub fn initial_is_fresh_with_nothing_counted_test() -> Nil {
  assert reconcile.initial()
    == PodState(kind: Fresh, failed: 0, run_since: None)
}

// Fallback.Readings: a skipped poll produces no reading, so nothing moves
// the state; only observe does.
pub fn a_skipped_poll_is_not_counted_test() -> Nil {
  let after_two = run([#(Valid, 0), #(TimedOut, 30), #(TimedOut, 60)])

  assert after_two == PodState(kind: Stale, failed: 2, run_since: None)
  // No reading at 90; the next at 120 is the third, not the fourth.
  assert reconcile.observe(
      state: after_two,
      reading: TimedOut,
      at: 120,
      unknown_polls: 3,
      absent_after: 300,
    )
    == PodState(kind: Unknown, failed: 3, run_since: None)
}

// ---------------------------------------------------------------- Window ---

// Fallback.Window: valid, x, x is stale with the value kept.
pub fn two_failures_after_a_valid_reading_are_stale_test() -> Nil {
  assert run([#(Valid, 0), #(Unreachable, 30), #(TimedOut, 60)])
    == PodState(kind: Stale, failed: 2, run_since: None)
}

// Fallback.Window: valid, x, x, x is unknown at the third, and the removal
// is due (Neutral).
pub fn three_failures_are_unknown_and_neutral_test() -> Nil {
  let state =
    run([#(Valid, 0), #(TimedOut, 30), #(Invalid, 60), #(Unreachable, 90)])

  assert state == PodState(kind: Unknown, failed: 3, run_since: None)
  assert reconcile.neutral(state)
}

// Fallback.Window: x, x, valid is fresh.
pub fn a_valid_reading_after_failures_is_fresh_test() -> Nil {
  assert run([#(TimedOut, 0), #(Invalid, 30), #(Valid, 60)])
    == PodState(kind: Fresh, failed: 0, run_since: None)
}

// Fallback.Window: a valid reading makes the pod fresh whatever its state,
// an unknown one included.
pub fn a_valid_reading_leaves_unknown_test() -> Nil {
  assert run([#(TimedOut, 0), #(TimedOut, 30), #(TimedOut, 60), #(Valid, 90)])
    == PodState(kind: Fresh, failed: 0, run_since: None)
}

// Fallback.Window: unknown_polls 1 makes the first reading that is not
// valid unknown.
pub fn unknown_polls_one_is_unknown_at_the_first_failure_test() -> Nil {
  assert run_with(
      readings: [#(Valid, 0), #(TimedOut, 30)],
      unknown_polls: 1,
      absent_after: 300,
    )
    == PodState(kind: Unknown, failed: 1, run_since: None)
}

// Fallback.Window: unknown_polls 100, the top of the range, stays stale
// through 99 failures and is unknown at the hundredth.
pub fn unknown_polls_one_hundred_is_unknown_at_the_hundredth_test() -> Nil {
  let ninety_nine =
    run_with(
      readings: every(kind: TimedOut, from: 0, step: 30, count: 99),
      unknown_polls: 100,
      absent_after: 300,
    )

  assert ninety_nine.kind == Stale
  assert ninety_nine.failed == 99
  assert run_with(
      readings: every(kind: TimedOut, from: 0, step: 30, count: 100),
      unknown_polls: 100,
      absent_after: 300,
    )
    == PodState(kind: Unknown, failed: 100, run_since: None)
}

// Fallback.Window: a stale pod is not neutral.
pub fn stale_is_not_neutral_test() -> Nil {
  assert !reconcile.neutral(PodState(kind: Stale, failed: 2, run_since: None))
  assert !reconcile.neutral(reconcile.initial())
}

// ---------------------------------------------------------------- Absent ---

// Fallback.Absent: not_found readings at 0, 30 … 300 s are absent at the
// one at 300.
pub fn a_not_found_run_of_absent_after_is_absent_test() -> Nil {
  let ten = run(every(kind: NotFound, from: 0, step: 30, count: 10))

  assert ten == PodState(kind: Unknown, failed: 10, run_since: Some(0))
  assert run(every(kind: NotFound, from: 0, step: 30, count: 11))
    == PodState(kind: Absent, failed: 11, run_since: Some(0))
}

// Fallback.Absent: refused readings count toward the run as not_found does.
pub fn a_refused_run_is_absent_test() -> Nil {
  assert run([#(Refused, 0), #(Refused, 300)])
    == PodState(kind: Absent, failed: 2, run_since: Some(0))
}

// Fallback.Absent: a timed_out at 150 breaks the run, so the reading at
// 300 is only 120 s into a new run.
pub fn a_timed_out_reading_breaks_the_run_test() -> Nil {
  let readings = [
    #(NotFound, 0),
    #(NotFound, 30),
    #(NotFound, 60),
    #(NotFound, 90),
    #(NotFound, 120),
    #(TimedOut, 150),
    #(NotFound, 180),
    #(NotFound, 210),
    #(NotFound, 240),
    #(NotFound, 270),
    #(NotFound, 300),
  ]

  assert run(readings)
    == PodState(kind: Unknown, failed: 11, run_since: Some(180))
}

// Fallback.Absent: an invalid at 150 breaks the run too.
pub fn an_invalid_reading_breaks_the_run_test() -> Nil {
  assert run([
      #(NotFound, 0),
      #(Invalid, 150),
      #(NotFound, 180),
      #(NotFound, 300),
    ])
    == PodState(kind: Unknown, failed: 4, run_since: Some(180))
}

// Fallback.Absent: a 290 s run is not absent.
pub fn a_run_shorter_than_absent_after_is_not_absent_test() -> Nil {
  assert run([#(NotFound, 0), #(NotFound, 290)])
    == PodState(kind: Stale, failed: 2, run_since: Some(0))
}

// Fallback.Absent: a run from 0 followed by a timed_out at 300 s is not
// absent, since the reading ends the run before entry is judged.
pub fn a_timed_out_reading_at_the_window_does_not_enter_absent_test() -> Nil {
  assert run([#(NotFound, 0), #(NotFound, 150), #(TimedOut, 300)])
    == PodState(kind: Unknown, failed: 3, run_since: None)
}

// Fallback.Absent: absent then timed_out stays absent, with the run as it
// is and failed still counting.
pub fn absent_stays_absent_on_a_timed_out_reading_test() -> Nil {
  assert run([#(NotFound, 0), #(NotFound, 300), #(TimedOut, 330)])
    == PodState(kind: Absent, failed: 3, run_since: Some(0))
  assert run([#(NotFound, 0), #(NotFound, 300), #(Invalid, 330)])
    == PodState(kind: Absent, failed: 3, run_since: Some(0))
}

// Fallback.Absent: absent then valid leaves, and the next run is a new one
// whose entry is a re-entry.
pub fn absent_leaves_on_a_valid_reading_test() -> Nil {
  let left = run([#(NotFound, 0), #(NotFound, 300), #(Valid, 330)])

  assert left == PodState(kind: Fresh, failed: 0, run_since: None)
  assert observe_all(
      state: left,
      readings: [#(NotFound, 360), #(NotFound, 660)],
      unknown_polls: 3,
      absent_after: 300,
    )
    == PodState(kind: Absent, failed: 2, run_since: Some(360))
}

// Fallback.Absent and Neutral: an absent entry with a value still standing
// under unknown_polls 100 is neutral, so the value is removed.
pub fn absent_is_neutral_even_while_stale_under_a_wide_window_test() -> Nil {
  let state =
    run_with(
      readings: every(kind: NotFound, from: 0, step: 30, count: 11),
      unknown_polls: 100,
      absent_after: 300,
    )

  assert state == PodState(kind: Absent, failed: 11, run_since: Some(0))
  assert reconcile.neutral(state)
}

// Fallback.Absent: absent_after 30, the bottom of the range, enters on the
// second reading of a 30 s run; 3600, the top, needs an hour.
pub fn absent_after_range_edges_test() -> Nil {
  assert run_with(
      readings: [#(NotFound, 0), #(NotFound, 30)],
      unknown_polls: 3,
      absent_after: 30,
    )
    == PodState(kind: Absent, failed: 2, run_since: Some(0))
  assert run_with(
      readings: [#(NotFound, 0), #(NotFound, 3599)],
      unknown_polls: 3,
      absent_after: 3600,
    )
    == PodState(kind: Stale, failed: 2, run_since: Some(0))
  assert run_with(
      readings: [#(NotFound, 0), #(NotFound, 3600)],
      unknown_polls: 3,
      absent_after: 3600,
    )
    == PodState(kind: Absent, failed: 2, run_since: Some(0))
}

// --------------------------------------------------------------- Restart ---

// Fallback.Restart: a restart is initial; an absent pod is polled afresh and
// re-enters once a new run has lasted the window.
pub fn a_restart_is_initial_test() -> Nil {
  let fresh = reconcile.initial()

  assert fresh == PodState(kind: Fresh, failed: 0, run_since: None)
  assert !reconcile.neutral(fresh)
  assert observe_all(
      state: fresh,
      readings: [#(NotFound, 0), #(NotFound, 300)],
      unknown_polls: 3,
      absent_after: 300,
    ).kind
    == Absent
}

// ----------------------------------------------------------- parse_applied ---

// Loop.Desired and Conflict: parse_applied reads a null or missing record as
// absent, a canonical int32 string as its value, and anything else as not
// usable.
pub fn parse_applied_reads_the_record_test() -> Nil {
  assert reconcile.parse_applied(None) == Applied(value: 0, usable: True)
  assert reconcile.parse_applied(Some("300"))
    == Applied(value: 300, usable: True)
  assert reconcile.parse_applied(Some("-1")) == Applied(value: -1, usable: True)
  assert reconcile.parse_applied(Some("2147483647"))
    == Applied(value: 2_147_483_647, usable: True)
  assert reconcile.parse_applied(Some("0")) == Applied(value: 0, usable: False)
  assert reconcile.parse_applied(Some("+5")) == Applied(value: 0, usable: False)
  assert reconcile.parse_applied(Some("007"))
    == Applied(value: 0, usable: False)
  assert reconcile.parse_applied(Some("2147483648"))
    == Applied(value: 0, usable: False)
  assert reconcile.parse_applied(Some("")) == Applied(value: 0, usable: False)
  assert reconcile.parse_applied(Some("busy"))
    == Applied(value: 0, usable: False)
}

// Loop.Conflict: a safe-to-evict record is usable when null, "true" or
// "false".
pub fn safe_to_evict_usable_reads_the_record_test() -> Nil {
  assert reconcile.safe_to_evict_usable(None)
  assert reconcile.safe_to_evict_usable(Some("true"))
  assert reconcile.safe_to_evict_usable(Some("false"))
  assert !reconcile.safe_to_evict_usable(Some("True"))
  assert !reconcile.safe_to_evict_usable(Some(""))
  assert !reconcile.safe_to_evict_usable(Some("yes"))
}

// --------------------------------------------------------------- reading ---

// Loop.Desired: the poller's reading becomes the loop's, kind by kind, with
// the cost and the drain state of a valid one.
pub fn reading_maps_the_pollers_reading_test() -> Nil {
  assert reconcile.reading(
      poller.Valid(poller.Status(cost: 40, accepting: True)),
    )
    == valid(40)
  assert reconcile.reading(
      poller.Valid(poller.Status(cost: 40, accepting: False)),
    )
    == draining(40)
  assert reconcile.reading(poller.NotFound) == failed(NotFound)
  assert reconcile.reading(poller.Invalid) == failed(Invalid)
  assert reconcile.reading(poller.Failed(poller.Refused)) == failed(Refused)
  assert reconcile.reading(poller.Failed(poller.TimedOut)) == failed(TimedOut)
  assert reconcile.reading(poller.Failed(poller.Unreachable))
    == failed(Unreachable)
}

// --------------------------------------------------------------- desired ---

// Loop.Desired: a valid reading on a fresh pod maps through cost_mapping
// against the applied value, and the safe-to-evict record stands.
pub fn desired_maps_a_valid_reading_against_the_applied_value_test() -> Nil {
  let fresh = run([#(Valid, 0)])

  assert reconcile.desired(
      state: fresh,
      reading: valid(500),
      applied: applied(0),
      safe_to_evict: None,
      thresholds:,
      margin:,
    )
    == Desired(cost: 500, safe_to_evict: None)
  assert reconcile.desired(
      state: fresh,
      reading: valid(500),
      applied: applied(300),
      safe_to_evict: Some("false"),
      thresholds:,
      margin:,
    )
    == Desired(cost: 300, safe_to_evict: Some("false"))
  assert reconcile.desired(
      state: fresh,
      reading: draining(100),
      applied: applied(300),
      safe_to_evict: None,
      thresholds:,
      margin:,
    )
    == Desired(cost: -1, safe_to_evict: None)
}

// Loop.Desired: a stale pod keeps its applied value.
pub fn desired_keeps_the_applied_value_while_stale_test() -> Nil {
  let stale = run([#(Valid, 0), #(TimedOut, 30)])

  assert reconcile.desired(
      state: stale,
      reading: failed(TimedOut),
      applied: applied(900),
      safe_to_evict: Some("false"),
      thresholds:,
      margin:,
    )
    == Desired(cost: 900, safe_to_evict: Some("false"))
}

// Loop.Desired and Fallback.Neutral: a neutral pod desires the removal of
// both annotations, a drained -1 and a safe-to-evict included.
pub fn desired_is_the_removal_while_neutral_test() -> Nil {
  let unknown = run([#(TimedOut, 0), #(TimedOut, 30), #(TimedOut, 60)])
  let absent = run([#(NotFound, 0), #(NotFound, 300)])

  assert reconcile.desired(
      state: unknown,
      reading: failed(TimedOut),
      applied: applied(-1),
      safe_to_evict: Some("false"),
      thresholds:,
      margin:,
    )
    == Desired(cost: 0, safe_to_evict: None)
  assert reconcile.desired(
      state: absent,
      reading: failed(NotFound),
      applied: applied(1800),
      safe_to_evict: None,
      thresholds:,
      margin:,
    )
    == Desired(cost: 0, safe_to_evict: None)
}

// Fallback.Neutral: the next valid reading after a removal maps against the
// absent applied value, so a busy pod is rewritten at once.
pub fn desired_after_a_removal_maps_against_absent_test() -> Nil {
  let fresh =
    run([#(TimedOut, 0), #(TimedOut, 30), #(TimedOut, 60), #(Valid, 90)])

  assert reconcile.desired(
      state: fresh,
      reading: valid(950),
      applied: applied(0),
      safe_to_evict: None,
      thresholds:,
      margin:,
    )
    == Desired(cost: 950, safe_to_evict: None)
}

// Loop.Desired: the Deployment's own thresholds and margin are used.
pub fn desired_uses_the_deployments_thresholds_test() -> Nil {
  assert reconcile.desired(
      state: run([#(Valid, 0)]),
      reading: valid(500),
      applied: applied(0),
      safe_to_evict: None,
      thresholds: [900],
      margin: 0,
    )
    == Desired(cost: 0, safe_to_evict: None)
}

// ------------------------------------------------------------------- due ---

// Loop.Due: a threshold crossing is due, and nothing is between crossings.
pub fn due_on_a_crossing_only_test() -> Nil {
  assert reconcile.due(
      desired: Desired(cost: 300, safe_to_evict: None),
      applied: applied(0),
      safe_to_evict: None,
    )
    == ["pod-deletion-cost"]
  assert reconcile.due(
      desired: Desired(cost: 300, safe_to_evict: None),
      applied: applied(300),
      safe_to_evict: None,
    )
    == []
}

// Loop.Due: the first annotation of a pod, whose applied value is 0 with no
// record, is due as a crossing is.
pub fn due_on_the_first_annotation_test() -> Nil {
  assert reconcile.due(
      desired: Desired(cost: 1800, safe_to_evict: None),
      applied: reconcile.parse_applied(None),
      safe_to_evict: None,
    )
    == ["pod-deletion-cost"]
}

// Loop.Due: startup repair, a marker that records a value the reading no
// longer maps to, is due; the removal that spells 0 is a write of 0.
pub fn due_on_startup_repair_and_removal_test() -> Nil {
  assert reconcile.due(
      desired: Desired(cost: 0, safe_to_evict: None),
      applied: applied(839),
      safe_to_evict: None,
    )
    == ["pod-deletion-cost"]
  assert reconcile.due(
      desired: Desired(cost: -1, safe_to_evict: None),
      applied: applied(300),
      safe_to_evict: None,
    )
    == ["pod-deletion-cost"]
}

// Loop.Due and Fallback.Neutral: the neutral removal makes both annotations
// due in one patch, in order, and nothing when neither stands.
pub fn due_on_the_neutral_removal_test() -> Nil {
  assert reconcile.due(
      desired: Desired(cost: 0, safe_to_evict: None),
      applied: applied(-1),
      safe_to_evict: Some("false"),
    )
    == ["pod-deletion-cost", "safe-to-evict"]
  assert reconcile.due(
      desired: Desired(cost: 0, safe_to_evict: None),
      applied: applied(0),
      safe_to_evict: None,
    )
    == []
}

// Loop.Due: a safe-to-evict flip alone is due.
pub fn due_on_a_safe_to_evict_flip_test() -> Nil {
  assert reconcile.due(
      desired: Desired(cost: 300, safe_to_evict: Some("false")),
      applied: applied(300),
      safe_to_evict: None,
    )
    == ["safe-to-evict"]
}

// Loop.JustStarted: a pod before any valid reading desires its applied
// value, so nothing is due and it stays unannotated.
pub fn nothing_is_due_before_the_first_valid_reading_test() -> Nil {
  let desired =
    reconcile.desired(
      state: run([#(TimedOut, 0)]),
      reading: failed(TimedOut),
      applied: reconcile.parse_applied(None),
      safe_to_evict: None,
      thresholds:,
      margin:,
    )

  assert desired == Desired(cost: 0, safe_to_evict: None)
  assert reconcile.due(
      desired:,
      applied: reconcile.parse_applied(None),
      safe_to_evict: None,
    )
    == []
}

// ------------------------------------------------------------------ Pure ---

// Fallback.Pure and Loop.Pure: the same arguments give the same results.
pub fn observe_and_desired_are_pure_test() -> Nil {
  let state = run([#(Valid, 0), #(NotFound, 30)])
  let again = run([#(Valid, 0), #(NotFound, 30)])
  let desired = fn() {
    reconcile.desired(
      state:,
      reading: valid(42),
      applied: applied(0),
      safe_to_evict: None,
      thresholds:,
      margin:,
    )
  }

  assert state == again
  assert desired() == desired()
}

// Fallback.Window and Absent: for any sequence of readings, failed is the
// number of readings since the last valid one, and absent is reached only
// through a not_found or refused run.
pub fn failed_counts_readings_since_the_last_valid_one_test() -> Nil {
  let config = qcheck.default_config() |> qcheck.with_seed(qcheck.seed(31))
  let kinds =
    qcheck.from_generators(qcheck.return(Valid), [
      qcheck.return(NotFound),
      qcheck.return(Invalid),
      qcheck.return(Refused),
      qcheck.return(TimedOut),
      qcheck.return(Unreachable),
    ])
  let sequences = qcheck.generic_list(kinds, qcheck.bounded_int(0, 20))
  use kinds <- qcheck.run(config, sequences)
  let readings = index(kinds, 0)
  let state = run(readings)
  let since_valid = count_since_valid(kinds, 0)

  assert state.failed == since_valid
  case state.kind {
    Absent -> {
      assert state.run_since != None
    }
    Fresh -> {
      assert since_valid == 0
    }
    Stale | Unknown -> {
      assert since_valid > 0
    }
  }
}

fn index(kinds: List(ReadingKind), at: Int) -> List(#(ReadingKind, Int)) {
  case kinds {
    [] -> []
    [kind, ..rest] -> [#(kind, at), ..index(rest, at + 30)]
  }
}

fn count_since_valid(kinds: List(ReadingKind), count: Int) -> Int {
  case kinds {
    [] -> count
    [Valid, ..rest] -> count_since_valid(rest, 0)
    [_, ..rest] -> count_since_valid(rest, count + 1)
  }
}

// ----------------------------------------------------------- Obligations ---

// config-default.unknown_polls
pub fn config_default_unknown_polls_test() -> Nil {
  assert reconcile.unknown_polls == 3
}

// config-default.absent_after
pub fn config_default_absent_after_test() -> Nil {
  assert reconcile.absent_after == 300
}

// value-equality.PodState and entity-fields.PodState: kind, failed and
// run_since, compared by value.
pub fn pod_state_is_a_kind_a_count_and_a_run_test() -> Nil {
  let state = PodState(kind: Stale, failed: 2, run_since: Some(30))

  assert state.kind == Stale
  assert state.failed == 2
  assert state.run_since == Some(30)
  assert state == PodState(kind: Stale, failed: 2, run_since: Some(30))
  assert state != PodState(..state, run_since: None)
}

// value-equality.Reading and entity-fields.Reading: kind, cost and draining.
pub fn reading_is_a_kind_a_cost_and_a_drain_state_test() -> Nil {
  let reading = Reading(kind: Valid, cost: Some(7), draining: True)

  assert reading.kind == Valid
  assert reading.cost == Some(7)
  assert reading.draining
  assert reading == Reading(kind: Valid, cost: Some(7), draining: True)
  assert reading != Reading(..reading, draining: False)
}

// value-equality.Applied and entity-fields.Applied: value and usable.
pub fn applied_is_a_value_and_whether_it_is_usable_test() -> Nil {
  let record = Applied(value: 300, usable: True)

  assert record.value == 300
  assert record.usable
  assert record == Applied(value: 300, usable: True)
  assert record != Applied(value: 0, usable: False)
}

// value-equality.Desired and entity-fields.Desired: cost and safe_to_evict.
pub fn desired_is_a_cost_and_a_safe_to_evict_value_test() -> Nil {
  let desired = Desired(cost: 300, safe_to_evict: Some("false"))

  assert desired.cost == 300
  assert desired.safe_to_evict == Some("false")
  assert desired == Desired(cost: 300, safe_to_evict: Some("false"))
  assert desired != Desired(..desired, safe_to_evict: None)
}

// enum-comparable.ReadingKind: the six kinds compare with each other and
// nothing else.
pub fn reading_kinds_are_comparable_test() -> Nil {
  let kinds = [
    reconcile.reading(poller.Valid(poller.Status(cost: 1, accepting: True))).kind,
    reconcile.reading(poller.NotFound).kind,
    reconcile.reading(poller.Invalid).kind,
    reconcile.reading(poller.Failed(poller.Refused)).kind,
    reconcile.reading(poller.Failed(poller.TimedOut)).kind,
    reconcile.reading(poller.Failed(poller.Unreachable)).kind,
  ]

  assert kinds == [Valid, NotFound, Invalid, Refused, TimedOut, Unreachable]
  assert reconcile.reading(poller.NotFound).kind != Refused
}
// contract-signature.Fallback.initial: () -> PodState. The sequence tests
// above discharge it.

// contract-signature.Fallback.observe: (state, reading, at, unknown_polls,
// absent_after) -> PodState. The sequence tests above discharge it.

// contract-signature.Fallback.neutral: (state) -> Boolean. The sequence
// tests above discharge it.

// contract-signature.Loop.parse_applied: (record) -> Applied. The
// parse_applied tests above discharge it.

// contract-signature.Loop.safe_to_evict_usable: (record) -> Boolean. The
// safe_to_evict_usable tests above discharge it.

// contract-signature.Loop.desired: (state, reading, applied, safe_to_evict,
// thresholds, margin) -> Desired. The desired tests above discharge it.

// contract-signature.Loop.due: (desired, applied, safe_to_evict) ->
// List<String>. The due tests above discharge it.
