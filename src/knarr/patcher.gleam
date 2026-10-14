//// The patcher process: budget's WriteBudget (docs/specs/budget.allium)
//// run under supervision. It keeps the token bucket, the install-wide 429
//// pause, the pending set and each pod's last attempt, and grants the
//// reconciler one patch turn at a time: the oldest-due pending change that
//// budget allows, with a token reserved for it until the reconciler answers
//// that it attempted the patch or found nothing due. Every decision is
//// budget's; the clock is injected, the one timer carries every wake, and
//// every turn and every quiet Deployment leave through the injected sinks,
//// so this module never names the reconciler. Nothing here reaches Erlang
//// but through gleam_otp, gleam_erlang and the observability logger.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq}
import gleam/otp/actor
import gleam/set.{type Set}
import gleam/string
import knarr/budget.{
  type Bucket, type Pause, type Pending, type Purpose, Bucket, Pause, Pending,
}
import knarr/metrics
import knarr/observability.{type Field, type Level}

/// How the apiserver answered one patch attempt, as budget's pause reads
/// it: a 2xx, a 429 with its Retry-After in whole seconds, or anything
/// else, a transport failure included.
pub type Outcome {
  Accepted
  Throttled(retry_after_s: Option(Int))
  Rejected
}

/// One turn granted to the reconciler: the pod and the purpose of the
/// pending change it may now re-derive and send.
pub type Turn {
  Turn(pod_name: String, purpose: Purpose)
}

pub type Config {
  Config(
    /// This process's name; the reconciler sends to it.
    self: Name(Message),
    /// The clock, in unix milliseconds.
    now: fn() -> Int,
    /// Where every granted turn goes: the reconciler's guarded send.
    turn: fn(Turn) -> Nil,
    /// Where a departed Deployment's name goes once nothing of its pods is
    /// pending or in turn: the reconciler's guarded send.
    quiet: fn(String) -> Nil,
    /// config.patch_rate_per_second.
    rate_per_second: Int,
    /// config.patch_burst.
    burst: Int,
    /// config.backoff_initial, in seconds.
    backoff_initial_s: Int,
    /// config.backoff_cap, in seconds.
    backoff_cap_s: Int,
  )
}

pub type Message {
  /// From the reconciler: a change first became due on a pod, with the
  /// pod's patch interval, the Deployment's override or config's default.
  /// Pending unless already so for that pod and purpose.
  Due(
    pod_name: String,
    purpose: Purpose,
    deployment: String,
    interval_s: Int,
    at_ms: Int,
  )
  /// From the reconciler after every successful discovery cycle: the
  /// target pods, and which of them are terminating. The apply of a pod
  /// not listed or terminating is discarded; every cleanup is kept.
  Listed(targets: List(String), terminating: List(String))
  /// From the reconciler: a Deployment left the target set. Answered on
  /// `quiet` once nothing of its pods is pending or in turn.
  Departed(deployment: String)
  /// The pause, refill or interval timer, or a test moving the clock.
  Wake
  /// From the reconciler: its answer to a turn, after one attempt on the
  /// pod. `still_due` keeps the entry with its original due_since.
  Attempted(
    pod_name: String,
    purpose: Purpose,
    outcome: Outcome,
    still_due: Bool,
    at_ms: Int,
  )
  /// From the reconciler: its answer to a turn when the re-derived change
  /// was nothing. The entry leaves and the token is refunded.
  NothingDue(pod_name: String, purpose: Purpose)
}

/// One pending change: budget's entry, the pod's Deployment and its patch
/// interval in seconds.
type Entry {
  Entry(pending: Pending, deployment: String, interval_s: Int)
}

type State {
  State(
    config: Config,
    self: Subject(Message),
    bucket: Bucket,
    pause: Pause,
    /// True from a 429 lengthening the pause until a grant finds it over.
    paused: Bool,
    /// By pod name and purpose. The entry in turn stays here until the
    /// reconciler answers, or a LIST discards it.
    pending: Dict(#(String, Purpose), Entry),
    /// By pod name, across purposes.
    last_attempt: Dict(String, Int),
    /// The turn granted and not yet answered, carrying its Deployment so a
    /// departure waits for it even after a LIST discarded its entry.
    in_turn: Option(Entry),
    /// Deployments departed and not yet quiet.
    departing: List(String),
    /// Deployments with a knarr_patches_pending series, removed at quiet.
    series: Set(String),
    wake: Option(process.Timer),
  )
}

/// Starts the patcher fresh (budget Restart): the bucket at burst, no
/// pause, nothing pending and no pod held, so every pod is patchable at
/// once.
pub fn start(config: Config) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(self) {
    set_pause_gauges(paused: 0, seconds: 0)
    metrics.set(observability.patch_pending_oldest_seconds, [], 0)
    actor.initialised(State(
      config:,
      self:,
      bucket: Bucket(tokens: config.burst, refilled_at: config.now()),
      pause: Pause(until: 0, consecutive: 0),
      paused: False,
      pending: dict.new(),
      last_attempt: dict.new(),
      in_turn: None,
      departing: [],
      series: set.new(),
      wake: None,
    ))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.named(config.self)
  |> actor.on_message(on_message)
  |> actor.start
}

fn on_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Due(pod_name:, purpose:, deployment:, interval_s:, at_ms:) ->
      due(state:, pod_name:, purpose:, deployment:, interval_s:, at_ms:)
    Listed(targets:, terminating:) -> listed(state:, targets:, terminating:)
    Departed(deployment) -> departed(state, deployment)
    Wake -> State(..state, wake: None)
    Attempted(pod_name:, purpose:, outcome:, still_due:, at_ms:) ->
      attempted(state:, pod_name:, purpose:, outcome:, still_due:, at_ms:)
    NothingDue(pod_name:, purpose:) -> nothing_due(state:, pod_name:, purpose:)
  }
  |> grant
}

// ---------------------------------------------------------- The entries ---

/// At most one entry per pod and purpose, kept from when the change first
/// became due (budget Pending): a second Due of the same key adds nothing.
fn due(
  state state: State,
  pod_name pod_name: String,
  purpose purpose: Purpose,
  deployment deployment: String,
  interval_s interval_s: Int,
  at_ms at_ms: Int,
) -> State {
  let key = #(pod_name, purpose)
  use <- bool.guard(dict.has_key(state.pending, key), state)
  let entry =
    Entry(
      pending: Pending(pod_name:, purpose:, due_since: at_ms),
      deployment:,
      interval_s:,
    )
  State(..state, pending: dict.insert(state.pending, key, entry))
}

/// The apply of a pod the LIST no longer shows, or shows terminating, is
/// discarded, its turn in flight included; a cleanup is kept (budget
/// Pending, Leaving).
fn listed(
  state state: State,
  targets targets: List(String),
  terminating terminating: List(String),
) -> State {
  let targets = set.from_list(targets)
  let terminating = set.from_list(terminating)
  let pending =
    dict.filter(state.pending, fn(key, _) {
      case key.1 {
        budget.Cleanup -> True
        budget.Apply ->
          set.contains(targets, key.0) && !set.contains(terminating, key.0)
      }
    })
  State(..state, pending:)
}

fn departed(state: State, deployment: String) -> State {
  use <- bool.guard(list.contains(state.departing, deployment), state)
  State(..state, departing: [deployment, ..state.departing])
}

/// The turn answered: the pod's last attempt is now whatever the outcome
/// (budget PerPod), the pause folds the status in (BackOff), and the entry
/// leaves unless still due, in which case it keeps its original due_since.
/// An entry a LIST discarded meanwhile is not brought back. An answer to
/// no turn out is ignored: every turn is answered exactly once.
fn attempted(
  state state: State,
  pod_name pod_name: String,
  purpose purpose: Purpose,
  outcome outcome: Outcome,
  still_due still_due: Bool,
  at_ms at_ms: Int,
) -> State {
  use <- bool.guard(!in_turn(state:, pod_name:, purpose:), state)
  let #(status, retry_after) = case outcome {
    Accepted -> #(200, None)
    Throttled(retry_after_s) -> #(429, retry_after_s)
    Rejected -> #(403, None)
  }
  let pause =
    budget.pause(
      pause: state.pause,
      status:,
      retry_after:,
      now: at_ms,
      initial: state.config.backoff_initial_s,
      cap: state.config.backoff_cap_s,
    )
  let state = case pause.until > state.pause.until {
    True -> pause_started(state:, until: pause.until, retry_after:, at_ms:)
    False -> state
  }
  let pending = case still_due {
    True -> state.pending
    False -> dict.delete(state.pending, #(pod_name, purpose))
  }
  State(
    ..state,
    pause:,
    pending:,
    in_turn: None,
    last_attempt: dict.insert(state.last_attempt, pod_name, at_ms),
  )
}

/// The turn found nothing due: the entry leaves and the reserved token
/// returns to the bucket, and the pod's last attempt is unchanged, since
/// none was made.
fn nothing_due(
  state state: State,
  pod_name pod_name: String,
  purpose purpose: Purpose,
) -> State {
  use <- bool.guard(!in_turn(state:, pod_name:, purpose:), state)
  let bucket = state.bucket
  State(
    ..state,
    pending: dict.delete(state.pending, #(pod_name, purpose)),
    in_turn: None,
    bucket: Bucket(
      ..bucket,
      tokens: int.min(bucket.tokens + 1, state.config.burst),
    ),
  )
}

fn in_turn(
  state state: State,
  pod_name pod_name: String,
  purpose purpose: Purpose,
) -> Bool {
  case state.in_turn {
    Some(entry) ->
      entry.pending.pod_name == pod_name && entry.pending.purpose == purpose
    None -> False
  }
}

// ---------------------------------------------------------------- Pause ---

/// A 429 lengthened the pause: the patch-scope gauges carry its length
/// from the attempt, and the line says so (observability Budget, Lines).
fn pause_started(
  state state: State,
  until until: Int,
  retry_after retry_after: Option(Int),
  at_ms at_ms: Int,
) -> State {
  let seconds = { until - at_ms } / 1000
  set_pause_gauges(paused: 1, seconds:)
  let retry_field = case retry_after {
    Some(value) -> [
      observability.int_field(name: "retry_after_seconds", value:),
    ]
    None -> []
  }
  log(observability.Info, "patch pause", [
    observability.int_field(name: "pause_seconds", value: seconds),
    ..list.append(retry_field, [
      observability.string_field(
        name: "scope",
        value: observability.patch_scope,
      ),
    ])
  ])
  State(..state, paused: True)
}

/// The pause is over at the first grant that finds now at or past until:
/// the gauges clear once, and the line says so.
fn pause_lifted(state: State, now: Int) -> State {
  use <- bool.guard(!state.paused || now < state.pause.until, state)
  set_pause_gauges(paused: 0, seconds: 0)
  log(observability.Info, "patch pause ended", [
    observability.string_field(name: "scope", value: observability.patch_scope),
  ])
  State(..state, paused: False)
}

fn set_pause_gauges(paused paused: Int, seconds seconds: Int) -> Nil {
  metrics.set(observability.paused, [observability.patch_scope], paused)
  metrics.set(observability.pause_seconds, [observability.patch_scope], seconds)
}

@external(erlang, "observability_ffi", "log")
fn log(level: Level, msg: String, fields: List(Field)) -> Nil

// ---------------------------------------------------------------- Grant ---

/// After every message: the bucket refilled to now, the pause lifted if
/// over, and, when no turn is out, the oldest-due entry budget allows gets
/// the turn with one token reserved for it (budget Bucket, Pending). Then
/// the gauges, the departures and the timer.
fn grant(state: State) -> actor.Next(State, Message) {
  let now = state.config.now()
  let bucket =
    budget.refill(
      bucket: state.bucket,
      now:,
      rate_per_second: state.config.rate_per_second,
      burst: state.config.burst,
    )
  let state = State(..state, bucket:) |> pause_lifted(now)
  let state = case state.in_turn {
    Some(_) -> state
    None ->
      case first_allowed(state, now) {
        Some(entry) -> {
          state.config.turn(Turn(
            pod_name: entry.pending.pod_name,
            purpose: entry.pending.purpose,
          ))
          State(
            ..state,
            in_turn: Some(entry),
            bucket: Bucket(..state.bucket, tokens: state.bucket.tokens - 1),
          )
        }
        None -> state
      }
  }
  let state = state |> gauges(now) |> settle_departing
  actor.continue(State(..state, wake: rearm(state, now)))
}

/// The first entry, in budget's oldest-due order with ties by name, for
/// which budget allows the patch now, under the pause, the pod's interval
/// and the bucket.
fn first_allowed(state: State, now: Int) -> Option(Entry) {
  state.pending
  |> dict.values
  |> list.sort(by_name)
  |> list.map(fn(entry) { entry.pending })
  |> budget.order
  |> list.find_map(fn(pending) {
    case dict.get(state.pending, #(pending.pod_name, pending.purpose)) {
      Ok(entry) -> {
        let allowed =
          budget.allow(
            pending:,
            last_attempt: dict.get(state.last_attempt, pending.pod_name)
              |> option.from_result,
            bucket: state.bucket,
            pause: state.pause,
            now:,
            patch_interval: entry.interval_s,
          )
        case allowed {
          True -> Ok(entry)
          False -> Error(Nil)
        }
      }
      Error(Nil) -> Error(Nil)
    }
  })
  |> option.from_result
}

fn by_name(a: Entry, b: Entry) -> Order {
  case string.compare(a.pending.pod_name, b.pending.pod_name) {
    Eq -> string.compare(purpose_name(a.pending), purpose_name(b.pending))
    other -> other
  }
}

fn purpose_name(pending: Pending) -> String {
  case pending.purpose {
    budget.Apply -> "apply"
    budget.Cleanup -> "cleanup"
  }
}

/// knarr_patches_pending per Deployment, 0 for one that lost its last
/// entry until it is quiet, and the age of the oldest pending change
/// (observability Budget).
fn gauges(state: State, now: Int) -> State {
  let entries = dict.values(state.pending)
  let counts =
    list.fold(entries, dict.new(), fn(acc, entry) {
      dict.upsert(acc, entry.deployment, fn(count) {
        option.unwrap(count, 0) + 1
      })
    })
  let series = set.union(state.series, set.from_list(dict.keys(counts)))
  set.each(series, fn(deployment) {
    metrics.set(
      observability.patches_pending,
      [deployment],
      dict.get(counts, deployment) |> result_or_zero,
    )
  })
  let oldest =
    entries
    |> list.map(fn(entry) { entry.pending.due_since })
    |> list.reduce(int.min)
    |> option.from_result
    |> option.map(fn(since) { int.max(0, { now - since } / 1000) })
    |> option.unwrap(0)
  metrics.set(observability.patch_pending_oldest_seconds, [], oldest)
  State(..state, series:)
}

fn result_or_zero(count: Result(Int, Nil)) -> Int {
  case count {
    Ok(count) -> count
    Error(Nil) -> 0
  }
}

/// A departed Deployment is quiet once no entry of its pods is pending and
/// none is in turn: its pending series leaves and the sink hears its name
/// (observability SeriesLife).
fn settle_departing(state: State) -> State {
  let busy = fn(deployment: String) {
    list.any(dict.values(state.pending), fn(entry) {
      entry.deployment == deployment
    })
    || case state.in_turn {
      Some(entry) -> entry.deployment == deployment
      None -> False
    }
  }
  let #(still, quiet) = list.partition(state.departing, busy)
  list.each(quiet, fn(deployment) {
    metrics.remove(observability.patches_pending, [deployment])
    state.config.quiet(deployment)
  })
  State(..state, departing: still, series: set.drop(state.series, quiet))
}

/// The one timer, re-armed for the next instant a held entry could go
/// without a message: the pause's end, else the next whole refill second
/// when the bucket is empty, else the earliest interval end of a held pod.
/// Nothing pending, or a turn out, needs no timer.
fn rearm(state: State, now: Int) -> Option(process.Timer) {
  case state.wake {
    Some(timer) -> {
      process.cancel_timer(timer)
      Nil
    }
    None -> Nil
  }
  use <- bool.guard(
    dict.is_empty(state.pending) || option.is_some(state.in_turn),
    None,
  )
  let at = case now < state.pause.until, state.bucket.tokens <= 0 {
    True, _ -> Some(state.pause.until)
    False, True -> Some(state.bucket.refilled_at + 1000)
    False, False ->
      state.pending
      |> dict.values
      |> list.filter_map(fn(entry) {
        case dict.get(state.last_attempt, entry.pending.pod_name) {
          Ok(last) if last + entry.interval_s * 1000 > now ->
            Ok(last + entry.interval_s * 1000)
          _ -> Error(Nil)
        }
      })
      |> list.reduce(int.min)
      |> option.from_result
  }
  option.map(at, fn(at) {
    process.send_after(state.self, int.max(0, at - now), Wake)
  })
}
