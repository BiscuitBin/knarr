//// The patcher process: budget's WriteBudget (docs/specs/budget.allium)
//// run under supervision. It keeps the token bucket, the install-wide 429
//// pause, the pending set and each pod's last attempt, and grants the
//// reconciler one patch turn at a time: the oldest-due pending change that
//// budget allows, the bucket's token spent when the reconciler answers that
//// it attempted the patch and none when it found nothing due, so the bucket
//// of the moment of the attempt bounds the attempts (budget Threshold).
//// Every decision is budget's; the clock is injected, the one timer carries
//// every wake, and every turn and every quiet Deployment leave through the
//// injected sinks, so this module never names the reconciler. Nothing here
//// reaches Erlang but through gleam_otp, gleam_erlang and the observability
//// logger.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq}
import gleam/otp/actor
import gleam/result
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
  /// Pending unless already so for that pod and purpose, in which case the
  /// entry keeps its due_since and takes the interval and Deployment sent.
  Due(
    pod_name: String,
    purpose: Purpose,
    deployment: String,
    interval_s: Int,
    at_ms: Int,
  )
  /// From the reconciler after every successful discovery cycle: the
  /// target pods, which of them are terminating, which are listed under
  /// another uid than the cycle before, and the Deployments in the target
  /// set. The apply of a pod not listed, terminating or replaced is
  /// discarded, and a replaced pod's last attempt forgotten; every cleanup
  /// is kept; a listed Deployment is no longer departing, so one that
  /// rejoins before it is quiet is never quiet.
  Listed(
    targets: List(String),
    terminating: List(String),
    replaced: List(String),
    deployments: List(String),
  )
  /// From the reconciler: a Deployment left the target set. Answered on
  /// `quiet` once nothing of its pods is pending or in turn.
  Departed(deployment: String)
  /// The pause, refill or interval timer, or a test moving the clock. The
  /// timer is armed on this process's name, so one that fires after a
  /// restart reaches the replacement, which grants again: any `Wake` is a
  /// grant and nothing more, whichever timer sent it.
  Wake
  /// From the reconciler: its answer to a turn, after one attempt on the
  /// pod, which spends one token. `still_due` keeps the entry with its
  /// original due_since.
  Attempted(
    pod_name: String,
    purpose: Purpose,
    outcome: Outcome,
    still_due: Bool,
    at_ms: Int,
  )
  /// From the reconciler: its answer to a turn when the re-derived change
  /// was nothing. The entry leaves and no token is spent.
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
    /// By pod name, across purposes, for the pods the last LIST showed or
    /// that still have an entry; a LIST forgets the rest.
    last_attempt: Dict(String, Int),
    /// The turn granted and not yet answered, carrying its Deployment so a
    /// departure waits for it even after a LIST discarded its entry.
    in_turn: Option(Entry),
    /// Deployments departed and not yet quiet.
    departing: List(String),
    /// Deployments with a knarr_patches_pending series, removed at quiet.
    series: Set(String),
    /// The one timer last armed, cancelled before every re-arm so no second
    /// chain of wakes starts, whichever `Wake` is being handled.
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
    Listed(targets:, terminating:, replaced:, deployments:) ->
      listed(state:, targets:, terminating:, replaced:, deployments:)
    Departed(deployment) -> departed(state, deployment)
    Wake -> state
    Attempted(pod_name:, purpose:, outcome:, still_due:, at_ms:) ->
      attempted(state:, pod_name:, purpose:, outcome:, still_due:, at_ms:)
    NothingDue(pod_name:, purpose:) -> nothing_due(state:, pod_name:, purpose:)
  }
  |> grant
}

// ---------------------------------------------------------- The entries ---

/// At most one entry per pod and purpose, kept from when the change first
/// became due (budget Pending): a second Due of the same key keeps the
/// entry's due_since and refreshes its interval and Deployment, so a changed
/// override (PerPod) reaches a held pod. The copy in turn is refreshed too.
fn due(
  state state: State,
  pod_name pod_name: String,
  purpose purpose: Purpose,
  deployment deployment: String,
  interval_s interval_s: Int,
  at_ms at_ms: Int,
) -> State {
  let key = #(pod_name, purpose)
  let refresh = fn(entry: Entry) { Entry(..entry, deployment:, interval_s:) }
  let entry = case dict.get(state.pending, key) {
    Ok(entry) -> refresh(entry)
    Error(Nil) ->
      Entry(
        pending: Pending(pod_name:, purpose:, due_since: at_ms),
        deployment:,
        interval_s:,
      )
  }
  let in_turn = case state.in_turn {
    Some(held)
      if held.pending.pod_name == pod_name && held.pending.purpose == purpose
    -> Some(refresh(held))
    other -> other
  }
  State(..state, pending: dict.insert(state.pending, key, entry), in_turn:)
}

/// The apply of a pod the LIST no longer shows, or shows terminating, is
/// discarded, its turn in flight included; a cleanup is kept (budget
/// Pending, Leaving). The last attempt of a pod the LIST no longer shows
/// and that has no entry left is forgotten with it, so a pod that returns
/// under the same name is new to the patcher (PerPod: the interval is held
/// from a pod's last attempt, and this is not that pod). A pod the LIST
/// shows under another uid is that case within one LIST: its apply is
/// discarded with its due_since and its last attempt forgotten whatever
/// entry is left, while a turn already out is answered as any other is
/// (PerPod, Pending). A Deployment the LIST shows in the target set is no
/// longer departing (observability SeriesLife).
fn listed(
  state state: State,
  targets targets: List(String),
  terminating terminating: List(String),
  replaced replaced: List(String),
  deployments deployments: List(String),
) -> State {
  let targets = set.from_list(targets)
  let terminating = set.from_list(terminating)
  let replaced = set.from_list(replaced)
  let pending =
    dict.filter(state.pending, fn(key, _) {
      case key.1 {
        budget.Cleanup -> True
        budget.Apply ->
          set.contains(targets, key.0)
          && !set.contains(terminating, key.0)
          && !set.contains(replaced, key.0)
      }
    })
  let last_attempt =
    dict.filter(state.last_attempt, fn(pod_name, _) {
      !set.contains(replaced, pod_name)
      && {
        set.contains(targets, pod_name)
        || set.contains(terminating, pod_name)
        || list.any(dict.keys(pending), fn(key) { key.0 == pod_name })
      }
    })
  let departing =
    list.filter(state.departing, fn(departed) {
      !list.contains(deployments, departed)
    })
  State(..state, pending:, last_attempt:, departing:)
}

fn departed(state: State, deployment: String) -> State {
  use <- bool.guard(list.contains(state.departing, deployment), state)
  State(..state, departing: [deployment, ..state.departing])
}

/// The turn answered: the attempt spends one token of the bucket refilled
/// to now (budget Bucket, Threshold), the pod's last attempt is now whatever
/// the outcome (PerPod), the pause folds the status in (BackOff), and the
/// entry leaves unless still due, in which case it keeps its original
/// due_since. An entry a LIST discarded meanwhile is not brought back. An
/// answer to no turn out is ignored: every turn is answered exactly once.
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
    bucket: spend(state),
    last_attempt: dict.insert(state.last_attempt, pod_name, at_ms),
  )
}

/// The bucket refilled to now less the token the attempt spent, never below
/// 0: a grant needs a token, and nothing else spends one while the turn is
/// out, so the token is there.
fn spend(state: State) -> Bucket {
  let bucket =
    budget.refill(
      bucket: state.bucket,
      now: state.config.now(),
      rate_per_second: state.config.rate_per_second,
      burst: state.config.burst,
    )
  Bucket(..bucket, tokens: int.max(0, bucket.tokens - 1))
}

/// The turn found nothing due: the entry leaves, and the bucket and the
/// pod's last attempt are unchanged, since no attempt was made.
fn nothing_due(
  state state: State,
  pod_name pod_name: String,
  purpose purpose: Purpose,
) -> State {
  use <- bool.guard(!in_turn(state:, pod_name:, purpose:), state)
  State(
    ..state,
    pending: dict.delete(state.pending, #(pod_name, purpose)),
    in_turn: None,
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
/// the turn (budget Bucket, Pending); the token is spent when the attempt
/// is answered, not here. Then the gauges, the departures and the timer.
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
          State(..state, in_turn: Some(entry))
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
      dict.get(counts, deployment) |> result.unwrap(0),
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

/// The one timer, re-armed for the next instant the state changes without
/// a message: the pause's end while a pause lasts, whatever is pending, so
/// the pause gauges clear when it ends (PauseScope); else, with something
/// pending and no turn out, the next whole refill second when the bucket is
/// empty, else the earliest interval end of a held pod. The timer last
/// armed is always cancelled first, fired or not, since cancelling a spent
/// timer is harmless and the recorded timer is the only one this process
/// may have running; a `Wake` arriving from an earlier timer therefore
/// never leaves a second chain behind.
fn rearm(state: State, now: Int) -> Option(process.Timer) {
  case state.wake {
    Some(timer) -> {
      process.cancel_timer(timer)
      Nil
    }
    None -> Nil
  }
  use <- bool.lazy_guard(now < state.pause.until, fn() {
    Some(process.send_after(state.self, state.pause.until - now, Wake))
  })
  use <- bool.guard(
    dict.is_empty(state.pending) || option.is_some(state.in_turn),
    None,
  )
  let at = case state.bucket.tokens <= 0 {
    True -> Some(state.bucket.refilled_at + 1000)
    False ->
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
