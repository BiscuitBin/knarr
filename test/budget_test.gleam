//// Tests for the PollSchedule and WriteBudget contracts
//// (docs/specs/budget.allium): the poll ladder and its jitter, the
//// concurrency bound, joining and leaving by the LIST, the token bucket, the
//// per-pod patch interval, the 429 pause and the order of pending changes.
//// Every function is pure, so each test passes values in and reads values
//// out. Timestamps are unix milliseconds; durations and draws are seconds.

import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import knarr/budget.{
  type Bucket, type Pause, type Pending, type Schedule, Apply, Bucket, Cleanup,
  Pause, Pending, Schedule,
}
import qcheck

/// An unpaused install.
const unpaused = Pause(until: 0, consecutive: 0)

/// A full bucket at the defaults, as after a restart (Restart).
const full = Bucket(tokens: 10, refilled_at: 0)

/// A schedule due at `at` with no poll outstanding.
fn due(pod_name: String, at: Int) -> Schedule {
  Schedule(pod_name:, next_due: at, outstanding: False)
}

/// An apply pending for `pod_name` since `since`.
fn pending(pod_name: String, since: Int) -> Pending {
  Pending(pod_name:, purpose: Apply, due_since: since)
}

/// `allow` for one apply at the default patch interval.
fn allowed(
  last_attempt last_attempt: Option(Int),
  bucket bucket: Bucket,
  pause pause: Pause,
  now now: Int,
) -> Bool {
  budget.allow(
    pending: pending("w", 0),
    last_attempt:,
    bucket:,
    pause:,
    now:,
    patch_interval: 60,
  )
}

/// A run of `count` bare 429s, each at the previous until, from unpaused
/// with the given initial and cap, collecting each result in order.
fn ladder(count count: Int, initial initial: Int, cap cap: Int) -> List(Pause) {
  let #(_, results) =
    int.range(from: 0, to: count, with: #(unpaused, []), run: fn(acc, _) {
      let #(pause, results) = acc
      let next =
        budget.pause(
          pause:,
          status: 429,
          retry_after: None,
          now: pause.until,
          initial:,
          cap:,
        )
      #(next, [next, ..results])
    })
  list.reverse(results)
}

/// The seconds each pause in a ladder adds beyond the previous until.
fn deltas(ladder: List(Pause)) -> List(Int) {
  let #(_, out) =
    list.fold(ladder, #(0, []), fn(acc, pause) {
      let #(previous, out) = acc
      #(pause.until, [{ pause.until - previous } / 1000, ..out])
    })
  list.reverse(out)
}

// ------------------------------------------------- Interval, Phase, Jitter ---

// PollSchedule.Phase: a joining pod is first due at now plus 0 to interval
// less one second, from the caller's draw, for a 30-second and a 5-second
// interval.
pub fn phase_puts_the_first_poll_within_the_interval_test() -> Nil {
  assert budget.phase(pod_name: "w-1", now: 10_000, interval: 30, random: 0)
    == Schedule(pod_name: "w-1", next_due: 10_000, outstanding: False)
  assert budget.phase(pod_name: "w-1", now: 10_000, interval: 30, random: 29).next_due
    == 39_000
  assert budget.phase(pod_name: "w-1", now: 10_000, interval: 5, random: 0).next_due
    == 10_000
  assert budget.phase(pod_name: "w-1", now: 10_000, interval: 5, random: 4).next_due
    == 14_000
}

// PollSchedule.Phase: the draw is 0 to interval less one; a draw outside it
// is clamped, a guard beyond the clause.
pub fn phase_clamps_a_draw_outside_the_range_test() -> Nil {
  assert budget.phase(pod_name: "w", now: 10_000, interval: 30, random: 30).next_due
    == 39_000
  assert budget.phase(pod_name: "w", now: 10_000, interval: 30, random: -1).next_due
    == 10_000
}

// PollSchedule.Jitter: the most a rung adds is jitter_percent of the
// interval in whole seconds, rounded down.
pub fn jitter_bound_is_the_percent_of_the_interval_rounded_down_test() -> Nil {
  assert budget.jitter_bound(interval: 30, jitter_percent: 10) == 3
  assert budget.jitter_bound(interval: 5, jitter_percent: 10) == 0
  assert budget.jitter_bound(interval: 33, jitter_percent: 10) == 3
  assert budget.jitter_bound(interval: 30, jitter_percent: 0) == 0
  assert budget.jitter_bound(interval: 300, jitter_percent: 100) == 300
}

// PollSchedule.Jitter: from a rung due at 30 s with a 30-second interval and
// 10 percent jitter the next is due 30 to 33 seconds later, never earlier.
pub fn next_is_the_previous_due_plus_the_interval_plus_the_draw_test() -> Nil {
  let rung = due("w", 30_000)

  assert budget.next(
      schedule: rung,
      now: 30_000,
      interval: 30,
      jitter_percent: 10,
      random: 0,
    ).next_due
    == 60_000
  assert budget.next(
      schedule: rung,
      now: 30_000,
      interval: 30,
      jitter_percent: 10,
      random: 3,
    ).next_due
    == 63_000
  assert budget.next(
      schedule: rung,
      now: 30_000,
      interval: 30,
      jitter_percent: 10,
      random: 4,
    ).next_due
    == 63_000
  assert budget.next(
      schedule: rung,
      now: 30_000,
      interval: 30,
      jitter_percent: 0,
      random: 3,
    ).next_due
    == 60_000
}

// PollSchedule.Interval: the interval is the Deployment's override or else
// config.poll_interval; next and phase take whichever the caller passes.
pub fn next_uses_the_interval_passed_in_test() -> Nil {
  assert budget.next(
      schedule: due("w", 0),
      now: 0,
      interval: 45,
      jitter_percent: 0,
      random: 0,
    ).next_due
    == 45_000
  assert budget.next(
      schedule: due("w", 0),
      now: 0,
      interval: budget.poll_interval,
      jitter_percent: 0,
      random: 0,
    ).next_due
    == 30_000
  assert budget.phase(pod_name: "w", now: 0, interval: 45, random: 44).next_due
    == 44_000
}

// PollSchedule.NoOverlap: a rung skipped while the pod's poll is outstanding
// moves the due time and leaves the poll outstanding.
pub fn next_keeps_outstanding_as_it_is_test() -> Nil {
  let outstanding = Schedule(pod_name: "w", next_due: 30_000, outstanding: True)

  assert budget.next(
    schedule: outstanding,
    now: 30_000,
    interval: 30,
    jitter_percent: 0,
    random: 0,
  ).outstanding
  assert !budget.next(
    schedule: due("w", 30_000),
    now: 30_000,
    interval: 30,
    jitter_percent: 0,
    random: 0,
  ).outstanding
}

// PollSchedule.Jitter: a poll due at 0 that returns at 40 with a 30-second
// interval and no jitter is next due at 60, not 40; a return at exactly 60 is
// due at 90; a return at 20 is due at 30.
pub fn advance_skips_rungs_already_passed_test() -> Nil {
  assert budget.advance(
      schedule: due("w", 0),
      now: 40_000,
      interval: 30,
      jitter_percent: 0,
      draw: fn(_) { 0 },
    ).next_due
    == 60_000
  assert budget.advance(
      schedule: due("w", 0),
      now: 60_000,
      interval: 30,
      jitter_percent: 0,
      draw: fn(_) { 0 },
    ).next_due
    == 90_000
  assert budget.advance(
      schedule: due("w", 0),
      now: 20_000,
      interval: 30,
      jitter_percent: 0,
      draw: fn(_) { 0 },
    ).next_due
    == 30_000
}

// PollSchedule.Jitter: each rung is the previous plus the interval plus its
// own draw; the draw is handed the bound plus one, as int.random takes it.
pub fn advance_draws_afresh_for_every_rung_test() -> Nil {
  // The bound at 30 s and 10 percent is 3, so the draw is handed 4 and
  // every rung adds 3: rungs at 33 s and 66 s.
  assert budget.advance(
      schedule: due("w", 0),
      now: 40_000,
      interval: 30,
      jitter_percent: 10,
      draw: fn(n) { n - 1 },
    ).next_due
    == 66_000
  assert budget.advance(
      schedule: due("w", 0),
      now: 40_000,
      interval: 30,
      jitter_percent: 10,
      draw: fn(_) { 0 },
    ).next_due
    == 60_000
  // The draw is made once per rung, not once and reused: from due 0 to past
  // 60 s with draw 0 takes three rungs (30, 60, 90), so three draws.
  let draws = process.new_subject()
  assert budget.advance(
      schedule: due("w", 0),
      now: 60_000,
      interval: 30,
      jitter_percent: 10,
      draw: fn(n) {
        process.send(draws, n)
        0
      },
    ).next_due
    == 90_000
  assert process.receive(draws, 0) == Ok(4)
  assert process.receive(draws, 0) == Ok(4)
  assert process.receive(draws, 0) == Ok(4)
  assert process.receive(draws, 0) == Error(Nil)
}

// PollSchedule.Jitter: for any interval 5 to 300, jitter 0 to 100 and
// in-range draw, the next due is at least the previous plus the interval and
// at most that plus the bound.
pub fn next_never_shortens_the_gap_property_test() -> Nil {
  let config = qcheck.default_config() |> qcheck.with_seed(qcheck.seed(46))
  let inputs =
    qcheck.tuple3(
      qcheck.bounded_int(from: 5, to: 300),
      qcheck.bounded_int(from: 0, to: 100),
      qcheck.bounded_int(from: 0, to: 300),
    )
  use #(interval, jitter_percent, random) <- qcheck.run(config, inputs)
  let schedule = due("w", 30_000)
  let moved =
    budget.next(schedule:, now: 30_000, interval:, jitter_percent:, random:)
  // The bound as the clause states it, jitter_percent of the interval
  // rounded down, computed here rather than taken from budget.jitter_bound.
  let bound = { interval * jitter_percent } / 100

  assert budget.jitter_bound(interval:, jitter_percent:) == bound
  assert moved.next_due >= schedule.next_due + interval * 1000
  assert moved.next_due <= schedule.next_due + { interval + bound } * 1000
}

// PollSchedule.Jitter: an interval of 0, outside config's range, advances one
// rung and returns rather than looping (a guard beyond the clause).
pub fn advance_ends_for_a_zero_interval_test() -> Nil {
  assert budget.advance(
      schedule: due("w", 0),
      now: 1000,
      interval: 0,
      jitter_percent: 0,
      draw: fn(_) { 0 },
    ).next_due
    == 0
}

// PollSchedule.Jitter: the bound rounds down, so 10 percent of 19 s is 1 s.
pub fn jitter_bound_rounds_down_test() -> Nil {
  assert budget.jitter_bound(interval: 19, jitter_percent: 10) == 1
  assert budget.jitter_bound(interval: 5, jitter_percent: 10) == 0
  assert budget.jitter_bound(interval: 300, jitter_percent: 100) == 300
}

// -------------------------------------------------- NoOverlap, Concurrency ---

// PollSchedule.Concurrency: a due poll is admitted while fewer than
// poll_concurrency are sent: true at 63, false at 64 with the default bound.
pub fn admit_is_true_below_the_concurrency_bound_test() -> Nil {
  let schedule = due("w", 1000)

  assert budget.admit(schedule:, now: 1000, sent: 63, concurrency: 64)
  assert !budget.admit(schedule:, now: 1000, sent: 64, concurrency: 64)
  assert budget.admit(schedule:, now: 1000, sent: 0, concurrency: 1)
  assert !budget.admit(schedule:, now: 1000, sent: 1, concurrency: 1)
  assert budget.admit(schedule:, now: 1000, sent: 1023, concurrency: 1024)
}

// PollSchedule.Concurrency: admit is for a due poll; one not yet due is not
// admitted however much room there is.
pub fn admit_is_false_before_the_due_time_test() -> Nil {
  assert !budget.admit(
    schedule: due("w", 2000),
    now: 1999,
    sent: 0,
    concurrency: 64,
  )
  assert budget.admit(
    schedule: due("w", 2000),
    now: 2000,
    sent: 0,
    concurrency: 64,
  )
}

// PollSchedule.Concurrency: a queued poll is outstanding and is admitted when
// room appears; the skip of a due poll while one is outstanding is
// NoOverlap's, made before queueing.
pub fn admit_does_not_read_outstanding_test() -> Nil {
  assert budget.admit(
    schedule: Schedule(pod_name: "w", next_due: 1000, outstanding: True),
    now: 1000,
    sent: 63,
    concurrency: 64,
  )
}

// PollSchedule.NoOverlap: a poll due while the previous is outstanding is
// skipped and the next is due on the next rung counted from the skipped due
// time.
pub fn a_skipped_poll_is_due_on_the_rung_after_the_skipped_one_test() -> Nil {
  assert budget.advance(
      schedule: Schedule(pod_name: "w", next_due: 30_000, outstanding: True),
      now: 30_000,
      interval: 30,
      jitter_percent: 0,
      draw: fn(_) { 0 },
    )
    == Schedule(pod_name: "w", next_due: 60_000, outstanding: True)
}

// ------------------------------------------- ListCadence, Leaving, Restart ---

// PollSchedule.Leaving: on_list drops every schedule whose pod the latest
// LIST does not show.
pub fn on_list_drops_a_pod_the_list_no_longer_shows_test() -> Nil {
  let schedules = [due("a", 1), due("b", 2)]

  assert budget.on_list(schedules:, listed: ["a"], joining: []) == [due("a", 1)]
  assert budget.on_list(schedules:, listed: [], joining: []) == []
}

// PollSchedule.Leaving: a pod the LIST shows stays, deletionTimestamp set or
// not, with its due time and outstanding flag as they were.
pub fn on_list_keeps_a_listed_pod_whatever_its_state_test() -> Nil {
  let terminating = Schedule(pod_name: "a", next_due: 5000, outstanding: True)

  assert budget.on_list(
      schedules: [terminating],
      listed: ["a", "b"],
      joining: [],
    )
    == [terminating]
}

// PollSchedule.Leaving: for every listed pod with no schedule, on_list adds
// the entry joining holds, built by the caller with phase from that pod's
// interval and its own draw.
pub fn on_list_adds_joining_for_listed_pods_without_a_schedule_test() -> Nil {
  assert budget.on_list(schedules: [due("a", 1)], listed: ["a", "b"], joining: [
      budget.phase(pod_name: "b", now: 0, interval: 30, random: 7),
    ])
    == [
      due("a", 1),
      Schedule(pod_name: "b", next_due: 7000, outstanding: False),
    ]
}

// PollSchedule.Leaving: an entry whose pod already has a schedule is ignored.
pub fn on_list_ignores_a_joining_entry_for_a_scheduled_pod_test() -> Nil {
  assert budget.on_list(schedules: [due("a", 5000)], listed: ["a"], joining: [
      due("a", 99),
    ])
    == [due("a", 5000)]
}

// PollSchedule.Leaving: joining is read only for listed pods.
pub fn on_list_ignores_a_joining_entry_for_an_unlisted_pod_test() -> Nil {
  assert budget.on_list(schedules: [], listed: ["a"], joining: [
      due("a", 1),
      due("c", 2),
    ])
    == [due("a", 1)]
}

// PollSchedule.Leaving: one schedule per pod.
pub fn on_list_takes_the_first_joining_entry_per_pod_test() -> Nil {
  assert budget.on_list(schedules: [], listed: ["a"], joining: [
      due("a", 1),
      due("a", 2),
    ])
    == [due("a", 1)]
}

// PollSchedule.Restart: with no schedules, the first LIST rebuilds every one
// from joining, each phase drawn afresh, in joining order.
pub fn on_list_rebuilds_every_schedule_from_joining_after_a_restart_test() -> Nil {
  assert budget.on_list(schedules: [], listed: ["a", "b"], joining: [
      budget.phase(pod_name: "a", now: 0, interval: 30, random: 3),
      budget.phase(pod_name: "b", now: 0, interval: 30, random: 29),
    ])
    == [
      Schedule(pod_name: "a", next_due: 3000, outstanding: False),
      Schedule(pod_name: "b", next_due: 29_000, outstanding: False),
    ]
}

// PollSchedule.ListCadence: the LIST timer's default is 60 seconds and is a
// value of its own, not derived from a poll interval. The timer itself is
// the reconciler's process test.
pub fn list_interval_is_configured_on_its_own_test() -> Nil {
  assert budget.list_interval == 60
}

// ---------------------------------------------------------- Bucket, PerPod ---

// WriteBudget.Bucket: from refilled_at 0 a call at 0.5 s adds nothing and
// leaves refilled_at at 0; a call at 1.5 s adds 5 tokens and sets
// refilled_at to 1 s.
pub fn refill_adds_whole_seconds_only_and_carries_the_fraction_test() -> Nil {
  let empty = Bucket(tokens: 0, refilled_at: 0)

  assert budget.refill(bucket: empty, now: 500, rate_per_second: 5, burst: 10)
    == empty
  assert budget.refill(bucket: empty, now: 1500, rate_per_second: 5, burst: 10)
    == Bucket(tokens: 5, refilled_at: 1000)
  assert budget.refill(
      bucket: Bucket(tokens: 5, refilled_at: 1000),
      now: 2999,
      rate_per_second: 5,
      burst: 10,
    )
    == Bucket(tokens: 10, refilled_at: 2000)
}

// WriteBudget.Bucket: tokens never exceed patch_burst, 10 by default.
pub fn refill_is_capped_at_the_burst_test() -> Nil {
  assert budget.refill(bucket: full, now: 10_000, rate_per_second: 5, burst: 10)
    == Bucket(tokens: 10, refilled_at: 10_000)
  assert budget.refill(
      bucket: Bucket(tokens: 3, refilled_at: 0),
      now: 2000,
      rate_per_second: 5,
      burst: 10,
    )
    == Bucket(tokens: 10, refilled_at: 2000)
  assert budget.refill(
      bucket: Bucket(tokens: 0, refilled_at: 0),
      now: 3000,
      rate_per_second: 100,
      burst: 200,
    )
    == Bucket(tokens: 200, refilled_at: 3000)
}

// WriteBudget.Bucket: rate_per_second tokens per whole second, 1 and 100
// being the range's ends.
pub fn refill_credits_the_configured_rate_test() -> Nil {
  let empty = Bucket(tokens: 0, refilled_at: 0)

  assert budget.refill(bucket: empty, now: 3500, rate_per_second: 1, burst: 200)
    == Bucket(tokens: 3, refilled_at: 3000)
  assert budget.refill(
      bucket: empty,
      now: 1000,
      rate_per_second: 100,
      burst: 200,
    )
    == Bucket(tokens: 100, refilled_at: 1000)
}

// WriteBudget.Bucket: a clock behind refilled_at credits nothing, a guard
// beyond the clause.
pub fn refill_before_refilled_at_changes_nothing_test() -> Nil {
  let bucket = Bucket(tokens: 2, refilled_at: 5000)

  assert budget.refill(bucket:, now: 4000, rate_per_second: 5, burst: 10)
    == bucket
}

// WriteBudget.Bucket: for any bucket within the burst and any later clock,
// tokens stay within the burst, never fall, and refilled_at never passes
// now.
pub fn refill_never_exceeds_the_burst_property_test() -> Nil {
  let config = qcheck.default_config() |> qcheck.with_seed(qcheck.seed(24))
  let inputs =
    qcheck.tuple5(
      qcheck.bounded_int(from: 1, to: 100),
      qcheck.bounded_int(from: 1, to: 200),
      qcheck.bounded_int(from: 0, to: 200),
      qcheck.bounded_int(from: 0, to: 100_000),
      qcheck.bounded_int(from: 0, to: 100_000),
    )
  use #(rate_per_second, burst, tokens, refilled_at, elapsed) <- qcheck.run(
    config,
    inputs,
  )
  let bucket = Bucket(tokens: int.min(tokens, burst), refilled_at:)
  let now = refilled_at + elapsed
  let refilled = budget.refill(bucket:, now:, rate_per_second:, burst:)

  assert refilled.tokens <= burst
  assert refilled.tokens >= bucket.tokens
  assert refilled.refilled_at <= now
  assert now - refilled.refilled_at < 1000
}

// WriteBudget.Bucket: allow needs one token.
pub fn allow_needs_one_token_test() -> Nil {
  assert allowed(
    last_attempt: None,
    bucket: Bucket(tokens: 1, refilled_at: 0),
    pause: unpaused,
    now: 0,
  )
  assert !allowed(
    last_attempt: None,
    bucket: Bucket(tokens: 0, refilled_at: 0),
    pause: unpaused,
    now: 0,
  )
}

// WriteBudget.PerPod: inside the 60-second interval of the pod's last
// attempt, whatever its outcome, allow is false; at the interval it is true.
pub fn allow_is_false_inside_the_patch_interval_of_the_last_attempt_test() -> Nil {
  assert !allowed(
    last_attempt: Some(0),
    bucket: full,
    pause: unpaused,
    now: 59_999,
  )
  assert allowed(
    last_attempt: Some(0),
    bucket: full,
    pause: unpaused,
    now: 60_000,
  )
}

// WriteBudget.PerPod: a pod knarr has not patched since it started is not
// held by the interval.
pub fn allow_is_not_held_when_last_attempt_is_null_test() -> Nil {
  assert allowed(last_attempt: None, bucket: full, pause: unpaused, now: 0)
}

// WriteBudget.PerPod: a patch interval of 0 is valid and leaves the bucket as
// the only bound, after a rejection too.
pub fn allow_with_patch_interval_zero_is_bound_by_the_bucket_alone_test() -> Nil {
  assert budget.allow(
    pending: pending("w", 0),
    last_attempt: Some(1000),
    bucket: full,
    pause: unpaused,
    now: 1000,
    patch_interval: 0,
  )
  assert !budget.allow(
    pending: pending("w", 0),
    last_attempt: Some(1000),
    bucket: Bucket(tokens: 0, refilled_at: 0),
    pause: unpaused,
    now: 1000,
    patch_interval: 0,
  )
}

// WriteBudget.PerPod: an apply and a cleanup to one pod are two attempts an
// interval apart; the function sees the pod's last attempt, not its purpose.
pub fn allow_counts_the_interval_across_purposes_test() -> Nil {
  let cleanup = Pending(pod_name: "w", purpose: Cleanup, due_since: 0)

  assert !budget.allow(
    pending: cleanup,
    last_attempt: Some(0),
    bucket: full,
    pause: unpaused,
    now: 30_000,
    patch_interval: 60,
  )
  assert budget.allow(
    pending: cleanup,
    last_attempt: Some(0),
    bucket: full,
    pause: unpaused,
    now: 60_000,
    patch_interval: 60,
  )
}

// WriteBudget.PerPod: the interval is the Deployment's override or else
// config.patch_interval, for a non-target cleanup always the latter.
pub fn allow_takes_the_interval_passed_in_test() -> Nil {
  assert budget.allow(
    pending: pending("w", 0),
    last_attempt: Some(0),
    bucket: full,
    pause: unpaused,
    now: 10_000,
    patch_interval: 10,
  )
  assert !budget.allow(
    pending: pending("w", 0),
    last_attempt: Some(0),
    bucket: full,
    pause: unpaused,
    now: 10_000,
    patch_interval: budget.patch_interval,
  )
}

// ----------------------------------------------------- BackOff, PauseScope ---

// WriteBudget.BackOff: the first 429 pauses 1 second, the next 2, 4, 8, 16,
// 32, then 60 at the cap and 60 again.
pub fn consecutive_429s_double_the_pause_to_the_cap_test() -> Nil {
  assert ladder(count: 8, initial: 1, cap: 60)
    == [
      Pause(until: 1000, consecutive: 1),
      Pause(until: 3000, consecutive: 2),
      Pause(until: 7000, consecutive: 3),
      Pause(until: 15_000, consecutive: 4),
      Pause(until: 31_000, consecutive: 5),
      Pause(until: 63_000, consecutive: 6),
      Pause(until: 123_000, consecutive: 7),
      Pause(until: 183_000, consecutive: 8),
    ]
}

// WriteBudget.BackOff: the pause is the greater of the capped doubling and
// Retry-After, so 120 seconds beats the 60-second cap, and a Retry-After
// below the doubling does not shorten it.
pub fn retry_after_beats_the_cap_test() -> Nil {
  assert budget.pause(
      pause: unpaused,
      status: 429,
      retry_after: Some(120),
      now: 0,
      initial: 1,
      cap: 60,
    )
    == Pause(until: 120_000, consecutive: 1)
  assert budget.pause(
      pause: Pause(until: 0, consecutive: 6),
      status: 429,
      retry_after: Some(5),
      now: 0,
      initial: 1,
      cap: 60,
    )
    == Pause(until: 60_000, consecutive: 7)
}

// WriteBudget.BackOff: a bare 429 a second after a Retry-After of 120 leaves
// until where it was and lengthens the run.
pub fn a_pause_is_never_shortened_test() -> Nil {
  assert budget.pause(
      pause: Pause(until: 120_000, consecutive: 1),
      status: 429,
      retry_after: None,
      now: 1000,
      initial: 1,
      cap: 60,
    )
    == Pause(until: 120_000, consecutive: 2)
}

// WriteBudget.BackOff: a 2xx returns consecutive 0 and leaves until as it is.
pub fn a_success_ends_the_run_and_leaves_until_test() -> Nil {
  let paused = Pause(until: 120_000, consecutive: 3)
  let ended =
    budget.pause(
      pause: paused,
      status: 200,
      retry_after: None,
      now: 1000,
      initial: 1,
      cap: 60,
    )

  assert ended == Pause(until: 120_000, consecutive: 0)
  assert budget.pause(
      pause: paused,
      status: 201,
      retry_after: None,
      now: 1000,
      initial: 1,
      cap: 60,
    )
    == Pause(until: 120_000, consecutive: 0)
  assert budget.pause(
      pause: paused,
      status: 299,
      retry_after: None,
      now: 1000,
      initial: 1,
      cap: 60,
    )
    == Pause(until: 120_000, consecutive: 0)
  // 199 and 300 are not successes: the run stands.
  assert budget.pause(
      pause: paused,
      status: 199,
      retry_after: None,
      now: 1000,
      initial: 1,
      cap: 60,
    )
    == paused
  assert budget.pause(
      pause: paused,
      status: 300,
      retry_after: None,
      now: 1000,
      initial: 1,
      cap: 60,
    )
    == paused
  // The next 429 restarts the run at 1 second, which does not pass the
  // until still standing.
  assert budget.pause(
      pause: ended,
      status: 429,
      retry_after: None,
      now: 1000,
      initial: 1,
      cap: 60,
    )
    == Pause(until: 120_000, consecutive: 1)
}

// WriteBudget.BackOff: any status that is not 429 or 2xx leaves the Pause,
// so a 403 between two 429s does not shorten the next pause.
pub fn a_rejection_between_two_429s_leaves_the_run_test() -> Nil {
  let paused = Pause(until: 1000, consecutive: 1)
  let leaves = fn(status) {
    budget.pause(
      pause: paused,
      status:,
      retry_after: None,
      now: 1000,
      initial: 1,
      cap: 60,
    )
    == paused
  }

  assert leaves(403)
  assert leaves(422)
  assert leaves(404)
  assert leaves(500)
  assert budget.pause(
      pause: paused,
      status: 429,
      retry_after: None,
      now: 1000,
      initial: 1,
      cap: 60,
    )
    == Pause(until: 3000, consecutive: 2)
}

// WriteBudget.BackOff: backoff_initial and backoff_cap are install-wide;
// initial 2 and cap 600 double 2, 4, ... 512, 600; initial 5 and cap 5 pause
// 5 every time.
pub fn pause_takes_initial_and_cap_from_config_test() -> Nil {
  assert deltas(ladder(count: 11, initial: 2, cap: 600))
    == [2, 4, 8, 16, 32, 64, 128, 256, 512, 600, 600]
  assert deltas(ladder(count: 2, initial: 5, cap: 5)) == [5, 5]
}

// WriteBudget.BackOff and PauseScope: while paused allow is false for every
// pod of the install, bucket and interval notwithstanding; at until it is
// true again.
pub fn allow_is_false_for_every_pod_while_paused_test() -> Nil {
  let paused = Pause(until: 10_000, consecutive: 1)
  let allowed_at = fn(pod, now) {
    budget.allow(
      pending: pending(pod, 0),
      last_attempt: None,
      bucket: full,
      pause: paused,
      now:,
      patch_interval: 60,
    )
  }

  assert list.all(["a", "b", "c"], fn(pod) { !allowed_at(pod, 9999) })
  assert list.all(["a", "b", "c"], fn(pod) { allowed_at(pod, 10_000) })
}

// WriteBudget.PauseScope: the discovery cycle keeps a Pause of its own; a 429
// on a LIST lengthens it as BackOff says and leaves the patch pause
// untouched.
pub fn the_list_pause_is_a_pause_of_its_own_under_the_same_rule_test() -> Nil {
  let lists =
    budget.pause(
      pause: unpaused,
      status: 429,
      retry_after: Some(30),
      now: 0,
      initial: 1,
      cap: 60,
    )

  assert lists == Pause(until: 30_000, consecutive: 1)
  assert unpaused == Pause(until: 0, consecutive: 0)
  assert allowed(last_attempt: None, bucket: full, pause: unpaused, now: 0)
}

// WriteBudget.PauseScope: admit takes no Pause, so a poll is admitted during
// a patch or LIST pause; the signature has no pause argument.
pub fn polls_are_never_paused_test() -> Nil {
  assert budget.admit(schedule: due("w", 0), now: 0, sent: 0, concurrency: 64)
}

// ---------------------------------------------------------- Pending, order ---

// WriteBudget.Pending: order serves entries oldest-due first.
pub fn order_serves_oldest_due_first_test() -> Nil {
  let cleanup = Pending(pod_name: "a", purpose: Cleanup, due_since: 1000)

  assert budget.order(pending: [pending("b", 3000), cleanup, pending("c", 2000)])
    == [cleanup, pending("c", 2000), pending("b", 3000)]
}

// WriteBudget.Pending: no priority for a drained, terminating or cleanup
// change and no rotation by Deployment; only due_since orders.
pub fn order_gives_no_priority_to_a_cleanup_or_a_deployment_test() -> Nil {
  let cleanup = Pending(pod_name: "x-1", purpose: Cleanup, due_since: 5000)

  assert budget.order(pending: [
      cleanup,
      pending("y-1", 4000),
      pending("x-2", 4500),
    ])
    == [pending("y-1", 4000), pending("x-2", 4500), cleanup]
}

// WriteBudget.Restart: every cleanup the first cycle derives is due at once
// with one due_since; order keeps them in the order given.
pub fn order_keeps_the_order_given_for_equal_due_times_test() -> Nil {
  let cleanups = [
    Pending(pod_name: "c", purpose: Cleanup, due_since: 0),
    Pending(pod_name: "a", purpose: Cleanup, due_since: 0),
    Pending(pod_name: "b", purpose: Cleanup, due_since: 0),
  ]

  assert budget.order(pending: cleanups) == cleanups
}

// WriteBudget.Pending: at most one entry per pod and purpose, so a pod due an
// apply and a cleanup has two, distinct values.
pub fn a_pod_due_both_has_two_entries_test() -> Nil {
  let apply = Pending(pod_name: "w", purpose: Apply, due_since: 1000)
  let cleanup = Pending(pod_name: "w", purpose: Cleanup, due_since: 1000)

  assert apply != cleanup
  assert budget.order(pending: [cleanup, apply]) == [cleanup, apply]
}

// WriteBudget.Pending: nothing pending orders to nothing.
pub fn order_of_nothing_is_nothing_test() -> Nil {
  assert budget.order(pending: []) == []
}

// --------------------------------------------------------------- Threshold ---

// WriteBudget.Threshold: the bucket driven at the worst case, a change due for
// a fresh pod at every 100 ms step for 120 s with patch_interval 0 so only the
// bucket binds, every allowed attempt spending a token, makes at most 5·W + 10
// attempts in any W-second window, so at most 310 in a minute, and the run is
// saturating: 610 attempts in all.
pub fn at_most_five_per_second_plus_the_burst_in_any_window_test() -> Nil {
  // Steps 0 to 1200 inclusive, 100 ms apart: 120 seconds.
  let #(_, sent) =
    int.range(from: 0, to: 1201, with: #(full, []), run: fn(acc, step) {
      let #(bucket, sent) = acc
      let now = step * 100
      let bucket = budget.refill(bucket:, now:, rate_per_second: 5, burst: 10)
      spend(bucket:, now:, sent:)
    })
  let sent = list.reverse(sent)

  assert list.length(sent) == 610
  list.each([1, 10, 60], fn(w) {
    // Every half-open W-second window that starts on a step and ends by
    // 120 s.
    let counts =
      int.range(from: 0, to: 1201 - w * 10, with: [], run: fn(counts, start) {
        let from = start * 100
        [list.count(sent, fn(t) { t >= from && t < from + w * 1000 }), ..counts]
      })
    assert list.all(counts, fn(count) { count <= 5 * w + 10 })
    case w {
      60 -> {
        assert list.fold(counts, 0, int.max) == 305
      }
      _ -> Nil
    }
  })
}

// WriteBudget.Threshold: the bound is reached, not just respected: the burst
// spent just before a whole second and 5 at every whole second after it put
// exactly 5·60 + 10 = 310 attempts in one 60-second window.
pub fn the_worst_window_reaches_exactly_the_bound_test() -> Nil {
  let #(_, sent) =
    int.range(from: 0, to: 61, with: #(full, []), run: fn(acc, second) {
      let #(bucket, sent) = acc
      let now = case second {
        0 -> 999
        _ -> second * 1000
      }
      let bucket = budget.refill(bucket:, now:, rate_per_second: 5, burst: 10)
      spend(bucket:, now:, sent:)
    })
  let in_window = list.count(sent, fn(t) { t >= 999 && t < 60_999 })

  assert in_window == 310
  assert list.length(sent) == 310
}

/// Attempts at `now` while `allow` says so, each spending a token.
fn spend(
  bucket bucket: Bucket,
  now now: Int,
  sent sent: List(Int),
) -> #(Bucket, List(Int)) {
  let allowed =
    budget.allow(
      pending: pending("p", now),
      last_attempt: None,
      bucket:,
      pause: unpaused,
      now:,
      patch_interval: 0,
    )
  use <- bool.guard(!allowed, #(bucket, sent))
  spend(bucket: Bucket(..bucket, tokens: bucket.tokens - 1), now:, sent: [
    now,
    ..sent
  ])
}

// -------------------------------------------------------------------- Pure ---

// PollSchedule.Pure and WriteBudget.Pure: every function is a function of its
// arguments alone, so repeated application gives the same value.
pub fn every_function_is_pure_by_repeated_application_test() -> Nil {
  let schedule = due("w", 30_000)
  let entry = pending("w", 0)
  let paused = Pause(until: 5000, consecutive: 2)

  assert budget.phase(pod_name: "w", now: 0, interval: 30, random: 7)
    == budget.phase(pod_name: "w", now: 0, interval: 30, random: 7)
  assert budget.next(
      schedule:,
      now: 30_000,
      interval: 30,
      jitter_percent: 10,
      random: 2,
    )
    == budget.next(
      schedule:,
      now: 30_000,
      interval: 30,
      jitter_percent: 10,
      random: 2,
    )
  assert budget.advance(
      schedule:,
      now: 100_000,
      interval: 30,
      jitter_percent: 10,
      draw: fn(_) { 1 },
    )
    == budget.advance(
      schedule:,
      now: 100_000,
      interval: 30,
      jitter_percent: 10,
      draw: fn(_) { 1 },
    )
  assert budget.admit(schedule:, now: 30_000, sent: 3, concurrency: 64)
    == budget.admit(schedule:, now: 30_000, sent: 3, concurrency: 64)
  assert budget.on_list(schedules: [schedule], listed: ["w", "x"], joining: [
      due("x", 1),
    ])
    == budget.on_list(schedules: [schedule], listed: ["w", "x"], joining: [
      due("x", 1),
    ])
  assert budget.refill(bucket: full, now: 2500, rate_per_second: 5, burst: 10)
    == budget.refill(bucket: full, now: 2500, rate_per_second: 5, burst: 10)
  assert budget.allow(
      pending: entry,
      last_attempt: Some(0),
      bucket: full,
      pause: paused,
      now: 70_000,
      patch_interval: 60,
    )
    == budget.allow(
      pending: entry,
      last_attempt: Some(0),
      bucket: full,
      pause: paused,
      now: 70_000,
      patch_interval: 60,
    )
  assert budget.pause(
      pause: paused,
      status: 429,
      retry_after: Some(9),
      now: 5000,
      initial: 1,
      cap: 60,
    )
    == budget.pause(
      pause: paused,
      status: 429,
      retry_after: Some(9),
      now: 5000,
      initial: 1,
      cap: 60,
    )
  assert budget.order(pending: [pending("b", 2), entry])
    == budget.order(pending: [pending("b", 2), entry])
}

// ------------------------------------------------------------- Obligations ---

// config-default.poll_interval
pub fn config_default_poll_interval_test() -> Nil {
  assert budget.poll_interval == 30
}

// config-default.poll_timeout
pub fn config_default_poll_timeout_test() -> Nil {
  assert budget.poll_timeout == 5
}

// config-default.poll_jitter_percent
pub fn config_default_poll_jitter_percent_test() -> Nil {
  assert budget.poll_jitter_percent == 10
}

// config-default.list_interval
pub fn config_default_list_interval_test() -> Nil {
  assert budget.list_interval == 60
}

// config-default.poll_concurrency
pub fn config_default_poll_concurrency_test() -> Nil {
  assert budget.poll_concurrency == 64
}

// config-default.patch_interval
pub fn config_default_patch_interval_test() -> Nil {
  assert budget.patch_interval == 60
}

// config-default.patch_rate_per_second
pub fn config_default_patch_rate_per_second_test() -> Nil {
  assert budget.patch_rate_per_second == 5
}

// config-default.patch_burst
pub fn config_default_patch_burst_test() -> Nil {
  assert budget.patch_burst == 10
}

// config-default.backoff_initial
pub fn config_default_backoff_initial_test() -> Nil {
  assert budget.backoff_initial == 1
}

// config-default.backoff_cap
pub fn config_default_backoff_cap_test() -> Nil {
  assert budget.backoff_cap == 60
}

// value-equality.Schedule and entity-fields.Schedule: pod_name, next_due and
// outstanding, compared by value.
pub fn schedule_is_a_pod_a_due_time_and_an_outstanding_flag_test() -> Nil {
  let schedule = Schedule(pod_name: "w-1", next_due: 30_000, outstanding: True)

  assert schedule.pod_name == "w-1"
  assert schedule.next_due == 30_000
  assert schedule.outstanding
  assert schedule
    == Schedule(pod_name: "w-1", next_due: 30_000, outstanding: True)
  assert schedule != Schedule(..schedule, outstanding: False)
}

// value-equality.Pending and entity-fields.Pending: pod_name, purpose and
// due_since, compared by value.
pub fn pending_is_a_pod_a_purpose_and_a_due_time_test() -> Nil {
  let entry = Pending(pod_name: "w-1", purpose: Cleanup, due_since: 1000)

  assert entry.pod_name == "w-1"
  assert entry.purpose == Cleanup
  assert entry.due_since == 1000
  assert entry == Pending(pod_name: "w-1", purpose: Cleanup, due_since: 1000)
  assert entry != Pending(..entry, purpose: Apply)
}

// value-equality.Bucket and entity-fields.Bucket: tokens and refilled_at.
pub fn bucket_is_tokens_and_a_refill_time_test() -> Nil {
  let bucket = Bucket(tokens: 7, refilled_at: 3000)

  assert bucket.tokens == 7
  assert bucket.refilled_at == 3000
  assert bucket == Bucket(tokens: 7, refilled_at: 3000)
  assert bucket != Bucket(..bucket, tokens: 6)
}

// value-equality.Pause and entity-fields.Pause: until and consecutive.
pub fn pause_is_an_until_and_a_count_test() -> Nil {
  let paused = Pause(until: 9000, consecutive: 4)

  assert paused.until == 9000
  assert paused.consecutive == 4
  assert paused == Pause(until: 9000, consecutive: 4)
  assert paused != Pause(..paused, consecutive: 0)
}
// contract-signature.PollSchedule.phase: (pod_name, now, interval, random) ->
// Schedule. The phase tests above discharge it.

// contract-signature.PollSchedule.next: (schedule, now, interval,
// jitter_percent, random) -> Schedule. The next and advance tests above
// discharge it.

// contract-signature.PollSchedule.admit: (schedule, now, sent, concurrency) ->
// Boolean. The admit tests above discharge it.

// contract-signature.PollSchedule.on_list: (schedules, listed, joining) ->
// List<Schedule>. The on_list tests above discharge it.

// contract-signature.WriteBudget.refill: (bucket, now, rate_per_second, burst)
// -> Bucket. The refill tests above discharge it.

// contract-signature.WriteBudget.allow: (pending, last_attempt, bucket, pause,
// now, patch_interval) -> Boolean. The allow tests above discharge it.

// contract-signature.WriteBudget.pause: (pause, status, retry_after, now,
// initial, cap) -> Pause. The pause tests above discharge it.

// contract-signature.WriteBudget.order: (pending) -> List<Pending>. The order
// tests above discharge it.
