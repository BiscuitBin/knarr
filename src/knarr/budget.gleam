//// The PollSchedule and WriteBudget contracts (docs/specs/budget.allium): a
//// pod's place on the poll ladder, the concurrency bound, joining and leaving
//// by the LIST, the token bucket, the per-pod patch interval, the pending set
//// and the 429 pause. Every function is pure: the clock and the random draw
//// are passed in, and nothing here reads state, time or the pod, or sends.
//// Timestamps are unix milliseconds; durations and draws are whole seconds.
//// The scheduler and the patcher that keep this state are `scheduler` and
//// `patcher`, under supervision.

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set

/// config.poll_interval, in seconds.
pub const poll_interval = 30

/// config.poll_timeout, in seconds.
pub const poll_timeout = 5

/// config.poll_jitter_percent: the most a rung's delay may add, as a percent
/// of the interval.
pub const poll_jitter_percent = 10

/// config.list_interval, in seconds.
pub const list_interval = 60

/// config.poll_concurrency: polls sent and not yet returned, per install.
pub const poll_concurrency = 64

/// config.patch_interval, in seconds.
pub const patch_interval = 60

/// config.patch_rate_per_second: tokens the bucket gains per whole second.
pub const patch_rate_per_second = 5

/// config.patch_burst: the most tokens the bucket holds.
pub const patch_burst = 10

/// config.backoff_initial, in seconds.
pub const backoff_initial = 1

/// config.backoff_cap, in seconds.
pub const backoff_cap = 60

/// One pod's place on the poll schedule: when its next poll is due and whether
/// a poll of it is outstanding, queued or sent and not yet returned.
pub type Schedule {
  Schedule(pod_name: String, next_due: Int, outstanding: Bool)
}

/// What a pending change is for: `Apply` for a change reconcile derives from
/// the latest reading, the yield a conflict turns it into included; `Cleanup`
/// for a removal lifecycle's Cleanup names.
pub type Purpose {
  Apply
  Cleanup
}

/// A change that is due but may not go yet. The change itself is not stored;
/// it is re-derived when the pod's turn comes.
pub type Pending {
  Pending(pod_name: String, purpose: Purpose, due_since: Int)
}

/// The global patch budget: whole tokens, and the millisecond they were last
/// refilled to.
pub type Bucket {
  Bucket(tokens: Int, refilled_at: Int)
}

/// The install-wide pause after a 429: when patching may resume, and how many
/// consecutive 429s produced it. `Pause(until: 0, consecutive: 0)` is unpaused.
pub type Pause {
  Pause(until: Int, consecutive: Int)
}

/// A joining pod's first due time: now plus a delay of 0 to one interval
/// less one second, `random` being the caller's draw from 0 to interval - 1
/// (Phase). The draw is clamped to that range, which the spec leaves to the
/// caller.
pub fn phase(
  pod_name pod_name: String,
  now now: Int,
  interval interval: Int,
  random random: Int,
) -> Schedule {
  let delay = int.clamp(random, min: 0, max: interval - 1)
  Schedule(pod_name:, next_due: now + delay * 1000, outstanding: False)
}

/// The longest delay a rung may add, in whole seconds: jitter_percent of the
/// interval, rounded down (Jitter). Not a contract signature. The caller
/// draws a rung's `random` as `int.random(jitter_bound(...) + 1)`, so 0 to
/// the bound inclusive.
pub fn jitter_bound(
  interval interval: Int,
  jitter_percent jitter_percent: Int,
) -> Int {
  jitter_percent * interval / 100
}

/// The next rung of the ladder: the previous due time plus the interval plus
/// a delay of 0 to jitter_percent of the interval in whole seconds, `random`
/// being the caller's draw for this rung (Jitter). The draw is clamped to
/// that range. `outstanding` is kept, since a rung is skipped while a poll is
/// outstanding (NoOverlap). The caller calls `next` once per rung until the
/// due time is after now; `advance` does that, which is why `now` is unread
/// here.
pub fn next(
  schedule schedule: Schedule,
  now _now: Int,
  interval interval: Int,
  jitter_percent jitter_percent: Int,
  random random: Int,
) -> Schedule {
  let delay =
    int.clamp(random, min: 0, max: jitter_bound(interval:, jitter_percent:))
  Schedule(
    ..schedule,
    next_due: schedule.next_due + { interval + delay } * 1000,
  )
}

/// `next` applied once per rung, each with a fresh draw from `draw`, until the
/// due time is after now, so a rung already passed is skipped (Jitter). Not a
/// contract signature: it is the loop the clause tells the caller to run.
pub fn advance(
  schedule schedule: Schedule,
  now now: Int,
  interval interval: Int,
  jitter_percent jitter_percent: Int,
  draw draw: fn(Int) -> Int,
) -> Schedule {
  let moved =
    next(
      schedule:,
      now:,
      interval:,
      jitter_percent:,
      random: draw(jitter_bound(interval:, jitter_percent:) + 1),
    )
  case moved.next_due > now {
    True -> moved
    False -> advance(schedule: moved, now:, interval:, jitter_percent:, draw:)
  }
}

/// True for a due poll while fewer than `concurrency` polls are sent and not
/// yet returned (Concurrency). A poll not yet due is not admitted; whether the
/// pod is already outstanding is NoOverlap's check, made before queueing.
pub fn admit(
  schedule schedule: Schedule,
  now now: Int,
  sent sent: Int,
  concurrency concurrency: Int,
) -> Bool {
  now >= schedule.next_due && sent < concurrency
}

/// The schedules after a LIST: every schedule whose pod the LIST shows, kept
/// as it is, then every joining entry for a listed pod that has none, in
/// order; a joining entry for a scheduled or unlisted pod is ignored
/// (Leaving, Restart).
pub fn on_list(
  schedules schedules: List(Schedule),
  listed listed: List(String),
  joining joining: List(Schedule),
) -> List(Schedule) {
  let listed = set.from_list(listed)
  let kept =
    list.filter(schedules, fn(one) { set.contains(listed, one.pod_name) })
  let scheduled = set.from_list(list.map(kept, fn(one) { one.pod_name }))
  let #(added, _) =
    list.fold(joining, #([], scheduled), fn(acc, one) {
      let #(added, scheduled) = acc
      let joins =
        set.contains(listed, one.pod_name)
        && !set.contains(scheduled, one.pod_name)
      case joins {
        True -> #([one, ..added], set.insert(scheduled, one.pod_name))
        False -> acc
      }
    })
  list.append(kept, list.reverse(added))
}

/// The bucket credited for the whole seconds since it was last refilled:
/// rate_per_second tokens each, never above burst, with refilled_at advanced
/// by exactly those seconds so the fraction is carried (Bucket). From
/// refilled_at 0, a call at 500 ms changes nothing and a call at 1500 ms adds
/// one second of tokens and sets refilled_at to 1000. A clock behind
/// refilled_at credits nothing, a guard beyond the clause.
pub fn refill(
  bucket bucket: Bucket,
  now now: Int,
  rate_per_second rate_per_second: Int,
  burst burst: Int,
) -> Bucket {
  let seconds = { now - bucket.refilled_at } / 1000
  use <- bool.guard(seconds <= 0, bucket)
  Bucket(
    tokens: int.min(bucket.tokens + seconds * rate_per_second, burst),
    refilled_at: bucket.refilled_at + seconds * 1000,
  )
}

/// True when the change may go now: the install is not paused, the pod's
/// patch interval since its last attempt has ended or it has none, and the
/// bucket holds a token, which the patch then spends (PerPod, Bucket,
/// BackOff). `patch_interval` is the pod's Deployment's or
/// config.patch_interval for a cleanup of a non-target. `pending` is by
/// definition due, so it is unread here.
pub fn allow(
  pending _pending: Pending,
  last_attempt last_attempt: Option(Int),
  bucket bucket: Bucket,
  pause pause: Pause,
  now now: Int,
  patch_interval patch_interval: Int,
) -> Bool {
  let unpaused = now >= pause.until
  let interval_over = case last_attempt {
    None -> True
    Some(at) -> now >= at + patch_interval * 1000
  }
  unpaused && interval_over && bucket.tokens >= 1
}

/// The pause after a patch or LIST response (BackOff, PauseScope): a 429
/// lengthens the run and sets until to the later of its current value and now
/// plus the greater of the capped doubling and Retry-After; a 2xx ends the
/// run and leaves until; any other status changes nothing.
pub fn pause(
  pause pause: Pause,
  status status: Int,
  retry_after retry_after: Option(Int),
  now now: Int,
  initial initial: Int,
  cap cap: Int,
) -> Pause {
  case status {
    429 -> {
      let consecutive = pause.consecutive + 1
      let computed =
        int.max(
          doubled(value: initial, times: consecutive - 1, cap:),
          option.unwrap(retry_after, 0),
        )
      Pause(until: int.max(pause.until, now + computed * 1000), consecutive:)
    }
    _ if status >= 200 && status < 300 -> Pause(..pause, consecutive: 0)
    _ -> pause
  }
}

/// `value` doubled `times` times, never above `cap`.
fn doubled(value value: Int, times times: Int, cap cap: Int) -> Int {
  case times <= 0 || value >= cap {
    True -> int.min(value, cap)
    False -> doubled(value: value * 2, times: times - 1, cap:)
  }
}

/// The pending entries oldest-due first, ties in the order given, with no
/// priority for a drained, terminating or cleanup change and no rotation by
/// Deployment (Pending).
pub fn order(pending pending: List(Pending)) -> List(Pending) {
  list.sort(pending, fn(a, b) { int.compare(a.due_since, b.due_since) })
}
