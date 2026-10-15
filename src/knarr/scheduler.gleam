//// The scheduler process: budget's PollSchedule (docs/specs/budget.allium)
//// run under supervision. It keeps every target pod's place on the poll
//// ladder, queues the due polls under the concurrency bound and sends each
//// through a worker started under the poll-worker factory, which polls
//// through the injected `poll` and answers on a subject this process owns.
//// Every decision is budget's; the clock and the draw are injected, each
//// timer carries the identity of what it wakes, and every reading leaves
//// through the injected `polled` sink, so this module never names the
//// reconciler. Nothing here reaches Erlang but through gleam_otp and
//// gleam_erlang.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/supervision
import gleam/set
import gleam/string
import knarr/budget.{type Schedule, Schedule}
import knarr/metrics
import knarr/observability.{type Field, type Level}
import knarr/poller.{type Endpoint}
import knarr/reconcile.{type Reading}

/// One target pod with a pod IP as the LIST showed it, by name and uid,
/// with the poll interval of its Deployment.
pub type Joiner {
  Joiner(
    pod_name: String,
    pod_uid: String,
    deployment: String,
    interval_s: Int,
    endpoint: Endpoint,
  )
}

/// What the scheduler hands the reconciler for one returned poll: the pod
/// the poll was sent for, by name and uid, the reading as reconcile
/// consumes it, and the clock at delivery.
pub type Polled {
  Polled(
    pod_name: String,
    pod_uid: String,
    deployment: String,
    endpoint: Endpoint,
    reading: Reading,
    at_ms: Int,
  )
}

pub type Config {
  Config(
    /// This process's name; the reconciler sends `Listed` to it.
    self: Name(Message),
    /// The poll-worker factory's name, started by `workers_supervised`.
    workers: Name(factory_supervisor.Message(Job, Nil)),
    /// One poll of a worker. Production passes `poller.poll` over
    /// `poller_http.send`; a test passes a closure.
    poll: fn(Endpoint) -> poller.Reading,
    /// The clock, in unix milliseconds.
    now: fn() -> Int,
    /// A draw from 0 to one below the bound given; production passes
    /// `int.random`.
    random: fn(Int) -> Int,
    /// Where every delivered reading goes: the reconciler's guarded send.
    polled: fn(Polled) -> Nil,
    /// config.poll_timeout, in seconds.
    poll_timeout_s: Int,
    /// config.poll_jitter_percent.
    jitter_percent: Int,
    /// config.poll_concurrency.
    concurrency: Int,
  )
}

/// The argument the factory's template takes: one poll to run, and the
/// subject to answer on.
pub type Job {
  Job(
    pod_name: String,
    endpoint: Endpoint,
    poll: fn(Endpoint) -> poller.Reading,
    now: fn() -> Int,
    reply: Subject(Message),
  )
}

/// The timers below are armed on this process's name, so one that fires
/// after a restart reaches the replacement, not nobody: a `Wake` only
/// settles, which is idempotent, and a `Deadline` names a flight the
/// replacement does not hold, so it is nothing.
pub type Message {
  /// From the reconciler after every successful discovery cycle: every
  /// target pod's name, and the joiners, the targets with a pod IP, each
  /// with its interval.
  Listed(listed: List(String), joining: List(Joiner))
  /// The single due-time timer, or a test moving the clock. Any `Wake` is
  /// a settle and nothing more, whichever timer sent it.
  Wake
  /// From a worker: the reading and the wall time the poll took.
  Returned(
    pod_name: String,
    worker: Pid,
    reading: poller.Reading,
    elapsed_ms: Int,
  )
  /// The per-flight watchdog: the worker did not return within twice the
  /// timeout and a second. Acted on only while that worker is the pod's
  /// flight.
  Deadline(pod_name: String, worker: Pid)
  /// A worker exited, from `process.select_monitors`.
  Down(process.Down)
}

/// One scheduled pod: its place on the ladder and what a poll of it needs.
/// `served` is the rung its outstanding poll is for, from the moment the
/// rung came due until the poll returns; `schedule.next_due` is then the
/// rung after, climbed and counted as skipped whenever it passes while the
/// poll is queued or in flight (budget NoOverlap). An entry with no poll
/// outstanding has `served` None and `next_due` the rung it waits for.
type Entry {
  Entry(
    schedule: Schedule,
    served: Option(Int),
    pod_uid: String,
    deployment: String,
    interval_s: Int,
    endpoint: Endpoint,
  )
}

/// One poll sent and not yet returned, with the uid of the pod it was sent
/// for.
type Flight {
  Flight(
    worker: Pid,
    monitor: process.Monitor,
    deadline: process.Timer,
    pod_uid: String,
  )
}

type State {
  State(
    config: Config,
    self: Subject(Message),
    /// The plain subject workers answer on: a send to it after this process
    /// died is dropped, where a send to the name would crash the worker.
    replies: Subject(Message),
    /// By pod name. The queue is derived: every entry with a poll
    /// outstanding and no flight, oldest served rung first.
    schedules: Dict(String, Entry),
    /// By pod name; `sent` is its size.
    flights: Dict(String, Flight),
    /// The one due-time timer last armed, cancelled before every re-arm so
    /// no second chain of wakes starts, whichever `Wake` is being handled.
    wake: Option(process.Timer),
  )
}

/// The poll-worker factory as a child of the reconciler's set, named so the
/// scheduler finds it again after a restart. Its children are temporary: a
/// worker that crashed is reported by the monitor, not polled again.
pub fn workers_supervised(
  name: Name(factory_supervisor.Message(Job, Nil)),
) -> supervision.ChildSpecification(factory_supervisor.Supervisor(Job, Nil)) {
  factory_supervisor.worker_child(worker)
  |> factory_supervisor.named(name)
  |> factory_supervisor.restart_strategy(supervision.Temporary)
  |> factory_supervisor.supervised
}

/// Starts the scheduler with no schedule: the first `Listed` builds it
/// (budget Restart). The selector takes the name, the workers' reply
/// subject and the monitors.
pub fn start(config: Config) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(self) {
    let replies = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select(replies)
      |> process.select_monitors(Down)
    metrics.set(observability.poll_queue_depth, [], 0)
    actor.initialised(State(
      config:,
      self:,
      replies:,
      schedules: dict.new(),
      flights: dict.new(),
      wake: None,
    ))
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.named(config.self)
  |> actor.on_message(on_message)
  |> actor.start
}

fn on_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Listed(listed:, joining:) -> join(state:, listed:, joining:)
    Wake -> state
    Returned(pod_name:, worker:, reading:, elapsed_ms:) ->
      returned(state:, pod_name:, worker:, reading:, elapsed_ms:)
    Deadline(pod_name:, worker:) -> overdue(state:, pod_name:, worker:)
    Down(process.ProcessDown(pid:, ..)) -> crashed(state, pid)
    Down(process.PortDown(..)) -> state
  }
  |> settle
}

// ------------------------------------------------------------- The LIST ---

/// The schedules after a LIST (budget Leaving, Phase): a joiner with no
/// entry gets its phase from a fresh draw, one already scheduled keeps its
/// ladder, its outstanding poll and its queue place, and takes the
/// Deployment, interval and endpoint the LIST now shows, and
/// `budget.on_list` drops every pod the LIST no longer shows, its queued
/// poll with it. A joiner whose uid is not its entry's left and joined in
/// this LIST: its entry is dropped before `budget.on_list`, so it joins
/// from a fresh phase. A dropped or replaced pod's flight is released and
/// its worker stopped, so a poll of it never outlives it and a pod that
/// rejoins has one poll running at most. A Deployment that no entry names
/// any more, its pods gone or moved to another Deployment, loses its
/// skipped-poll series (observability SeriesLife).
fn join(
  state state: State,
  listed listed: List(String),
  joining joining: List(Joiner),
) -> State {
  let now = state.config.now()
  let replaced =
    list.filter_map(joining, fn(one) {
      case dict.get(state.schedules, one.pod_name) {
        Ok(entry) if entry.pod_uid != one.pod_uid -> Ok(one.pod_name)
        _ -> Error(Nil)
      }
    })
  let prior = dict.drop(state.schedules, replaced)
  let fresh =
    joining
    |> list.filter(fn(one) { !dict.has_key(prior, one.pod_name) })
    |> list.map(fn(one) {
      budget.phase(
        pod_name: one.pod_name,
        now:,
        interval: one.interval_s,
        random: state.config.random(one.interval_s),
      )
    })
  let survivors =
    budget.on_list(
      schedules: dict.values(prior)
        |> list.map(fn(entry) { entry.schedule }),
      listed:,
      joining: fresh,
    )
  let joiners =
    joining |> list.map(fn(one) { #(one.pod_name, one) }) |> dict.from_list
  let schedules =
    list.fold(survivors, dict.new(), fn(acc, schedule) {
      let pod_name = schedule.pod_name
      case dict.get(joiners, pod_name), dict.get(prior, pod_name) {
        Ok(joiner), Ok(entry) ->
          dict.insert(
            acc,
            pod_name,
            Entry(
              ..entry,
              schedule:,
              deployment: joiner.deployment,
              interval_s: joiner.interval_s,
              endpoint: joiner.endpoint,
            ),
          )
        Ok(joiner), Error(Nil) ->
          dict.insert(
            acc,
            pod_name,
            Entry(
              schedule:,
              served: None,
              pod_uid: joiner.pod_uid,
              deployment: joiner.deployment,
              interval_s: joiner.interval_s,
              endpoint: joiner.endpoint,
            ),
          )
        Error(Nil), Ok(entry) ->
          dict.insert(acc, pod_name, Entry(..entry, schedule:))
        Error(Nil), Error(Nil) -> acc
      }
    })
  let flights =
    state.flights
    |> dict.to_list
    |> list.fold(state.flights, fn(flights, pair) {
      let #(pod_name, flight) = pair
      use <- bool.guard(
        dict.has_key(schedules, pod_name) && !list.contains(replaced, pod_name),
        flights,
      )
      release(flight)
      stop(flight.worker)
      dict.delete(flights, pod_name)
    })
  let remaining = deployments(schedules)
  deployments(state.schedules)
  |> set.filter(fn(deployment) { !set.contains(remaining, deployment) })
  |> set.each(fn(deployment) {
    metrics.remove(observability.polls_skipped_total, [deployment])
  })
  State(..state, schedules:, flights:)
}

fn deployments(schedules: Dict(String, Entry)) -> set.Set(String) {
  schedules
  |> dict.values
  |> list.map(fn(entry) { entry.deployment })
  |> set.from_list
}

// ---------------------------------------------------------- The returns ---

/// A worker's answer: delivered when it is the flight's worker, discarded
/// when the pod left the schedule, or left and rejoined, under its uid or
/// another, while it was out (budget Leaving).
fn returned(
  state state: State,
  pod_name pod_name: String,
  worker worker: Pid,
  reading reading: poller.Reading,
  elapsed_ms elapsed_ms: Int,
) -> State {
  case dict.get(state.flights, pod_name) {
    Ok(flight) if flight.worker == worker -> {
      release(flight)
      let reading = reconcile.reading(reading)
      let seconds = case reading.kind {
        reconcile.TimedOut -> int.to_float(state.config.poll_timeout_s)
        _ -> int.to_float(elapsed_ms) /. 1000.0
      }
      State(..state, flights: dict.delete(state.flights, pod_name))
      |> deliver(pod_name:, pod_uid: flight.pod_uid, reading:, seconds:)
    }
    _ -> state
  }
}

/// The watchdog fired for a flight still out: the worker broke
/// `poller_http.send`'s bound and is stopped, and the pod's reading is
/// timed_out at the timeout (worker_contract Transport). A deadline whose
/// worker is no longer the pod's flight, as after the poll returned, the pod
/// left, or this process restarted, is nothing.
fn overdue(
  state state: State,
  pod_name pod_name: String,
  worker worker: Pid,
) -> State {
  case dict.get(state.flights, pod_name) {
    Ok(flight) if flight.worker == worker -> {
      release(flight)
      stop(worker)
      State(..state, flights: dict.delete(state.flights, pod_name))
      |> timed_out(pod_name:, pod_uid: flight.pod_uid)
    }
    _ -> state
  }
}

/// A worker exited before it answered: its pod's reading is timed_out. A
/// pid with no flight, as one already answered, is nothing.
fn crashed(state: State, pid: Pid) -> State {
  let flight =
    state.flights
    |> dict.to_list
    |> list.find(fn(pair) { { pair.1 }.worker == pid })
  case flight {
    Ok(#(pod_name, flight)) -> {
      release(flight)
      State(..state, flights: dict.delete(state.flights, pod_name))
      |> timed_out(pod_name:, pod_uid: flight.pod_uid)
    }
    Error(Nil) -> state
  }
}

fn timed_out(
  state state: State,
  pod_name pod_name: String,
  pod_uid pod_uid: String,
) -> State {
  deliver(
    state:,
    pod_name:,
    pod_uid:,
    reading: reconcile.Reading(
      kind: reconcile.TimedOut,
      cost: None,
      draining: False,
    ),
    seconds: int.to_float(state.config.poll_timeout_s),
  )
}

/// Stops watching a flight: its deadline and its monitor, which also drops a
/// `Down` already in the mailbox.
fn release(flight: Flight) -> Nil {
  process.cancel_timer(flight.deadline)
  process.demonitor_process(flight.monitor)
}

/// Stops a worker with the exit its supervisor would send, `shutdown`,
/// which the worker does not trap and so dies of; a temporary child that
/// exits with `shutdown` is a routine stop to the factory, where a `kill`
/// is a crash it reports as an error (child_terminated) on every drop or
/// deadline.
fn stop(worker: Pid) -> Nil {
  process.send_abnormal_exit(worker, atom.create("shutdown"))
}

/// One reading delivered: observed on the duration histogram, handed to the
/// sink under the uid of the pod its poll was sent for, the flight's, and
/// the pod no longer outstanding, with every rung that passed while its
/// poll was out skipped (budget Jitter, NoOverlap, Leaving).
fn deliver(
  state state: State,
  pod_name pod_name: String,
  pod_uid pod_uid: String,
  reading reading: Reading,
  seconds seconds: Float,
) -> State {
  case dict.get(state.schedules, pod_name) {
    Ok(entry) -> {
      metrics.observe(observability.poll_duration_seconds, seconds)
      let now = state.config.now()
      state.config.polled(Polled(
        pod_name:,
        pod_uid:,
        deployment: entry.deployment,
        endpoint: entry.endpoint,
        reading:,
        at_ms: now,
      ))
      let entry =
        Entry(
          ..entry,
          served: None,
          schedule: Schedule(..entry.schedule, outstanding: False),
        )
        |> skip_passed(config: state.config, now:)
      State(..state, schedules: dict.insert(state.schedules, pod_name, entry))
    }
    Error(Nil) -> state
  }
}

// --------------------------------------------------------------- Settle ---

/// After every message: the due polls join the queue, the queue is served
/// under the bound, the gauge is set and the timer re-armed for the next
/// due time, or within a second when the factory refused a worker.
fn settle(state: State) -> actor.Next(State, Message) {
  let now = state.config.now()
  let #(state, refused) = state |> mark(now) |> dispatch(now)
  metrics.set(observability.poll_queue_depth, [], list.length(queue(state)))
  actor.continue(State(..state, wake: rearm(state:, now:, refused:)))
}

/// An entry whose rung has come joins the queue, served for that rung, with
/// its ladder climbed to the rung after; one already outstanding, queued or
/// in flight, skips every rung that has passed since, each counted (budget
/// NoOverlap). After this no entry's next rung is at or before now.
fn mark(state: State, now: Int) -> State {
  let schedules =
    dict.map_values(state.schedules, fn(_pod_name, entry) {
      use <- bool.guard(entry.schedule.next_due > now, entry)
      case entry.served {
        None ->
          Entry(
            ..entry,
            served: Some(entry.schedule.next_due),
            schedule: Schedule(
              ..next_rung(entry, state.config),
              outstanding: True,
            ),
          )
        Some(_) -> entry
      }
      |> skip_passed(config: state.config, now:)
    })
  State(..state, schedules:)
}

/// The queue served oldest rung first while budget admits the rung each
/// poll is for (Concurrency). A worker the factory refused leaves its poll
/// queued, and the refusal is reported so the next settle is within a
/// second rather than at the next message.
fn dispatch(state: State, now: Int) -> #(State, Bool) {
  case queue(state) {
    [] -> #(state, False)
    [entry, ..] -> {
      let admitted =
        budget.admit(
          schedule: Schedule(..entry.schedule, next_due: serving(entry)),
          now:,
          sent: dict.size(state.flights),
          concurrency: state.config.concurrency,
        )
      use <- bool.guard(!admitted, #(state, False))
      case send(state, entry) {
        Some(state) -> dispatch(state, now)
        None -> #(state, True)
      }
    }
  }
}

/// One poll sent: a worker under the factory, monitored and given its
/// deadline. The ladder was climbed when the rung came due, so the entry
/// is unchanged.
fn send(state: State, entry: Entry) -> Option(State) {
  let config = state.config
  let pod_name = entry.schedule.pod_name
  let job =
    Job(
      pod_name:,
      endpoint: entry.endpoint,
      poll: config.poll,
      now: config.now,
      reply: state.replies,
    )
  case
    factory_supervisor.get_by_name(config.workers)
    |> factory_supervisor.start_child(job)
  {
    Ok(started) -> {
      let monitor = process.monitor(started.pid)
      let deadline =
        process.send_after(
          state.self,
          config.poll_timeout_s * 2000 + 1000,
          Deadline(pod_name:, worker: started.pid),
        )
      let flight =
        Flight(worker: started.pid, monitor:, deadline:, pod_uid: entry.pod_uid)
      Some(
        State(..state, flights: dict.insert(state.flights, pod_name, flight)),
      )
    }
    Error(error) -> {
      log(observability.Warning, "poll worker not started", [
        observability.string_field(name: "pod", value: pod_name),
        observability.string_field(name: "reason", value: start_error(error)),
      ])
      None
    }
  }
}

fn start_error(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "init_timeout"
    actor.InitFailed(reason) -> reason
    actor.InitExited(_) -> "init_exited"
  }
}

@external(erlang, "observability_ffi", "log")
fn log(level: Level, msg: String, fields: List(Field)) -> Nil

/// The entries with a poll outstanding and not sent, oldest served rung
/// first, by name among equals.
fn queue(state: State) -> List(Entry) {
  state.schedules
  |> dict.values
  |> list.filter(fn(entry) {
    option.is_some(entry.served)
    && !dict.has_key(state.flights, entry.schedule.pod_name)
  })
  |> list.sort(by_served)
}

/// The rung an outstanding entry's poll is for; for one not outstanding,
/// the rung it waits for.
fn serving(entry: Entry) -> Int {
  option.unwrap(entry.served, entry.schedule.next_due)
}

fn by_served(a: Entry, b: Entry) -> Order {
  case int.compare(serving(a), serving(b)) {
    Eq -> string.compare(a.schedule.pod_name, b.schedule.pod_name)
    other -> other
  }
}

/// The one timer, re-armed for the earliest next rung of any entry: the
/// rung a waiting pod is polled on, or the one a queued or in-flight pod
/// skips; or one second from now, if sooner, after the factory refused a
/// worker, so the queued poll is tried again without waiting for an
/// unrelated message. The timer last armed is always cancelled first, fired
/// or not, since cancelling a spent timer is harmless and the recorded
/// timer is the only one this process may have running; a `Wake` arriving
/// from an earlier timer therefore never leaves a second chain behind.
fn rearm(
  state state: State,
  now now: Int,
  refused refused: Bool,
) -> Option(process.Timer) {
  case state.wake {
    Some(timer) -> {
      process.cancel_timer(timer)
      Nil
    }
    None -> Nil
  }
  let retry = case refused {
    True -> [now + 1000]
    False -> []
  }
  let earliest =
    state.schedules
    |> dict.values
    |> list.map(fn(entry) { entry.schedule.next_due })
    |> list.append(retry)
    |> list.reduce(int.min)
  case earliest {
    Ok(due) -> Some(process.send_after(state.self, int.max(0, due - now), Wake))
    Error(Nil) -> None
  }
}

// ----------------------------------------------------------- The ladder ---

/// The rung after the entry's next one (budget Jitter).
fn next_rung(entry: Entry, config: Config) -> Schedule {
  budget.next(
    schedule: entry.schedule,
    now: entry.schedule.next_due,
    interval: entry.interval_s,
    jitter_percent: config.jitter_percent,
    random: config.random(
      budget.jitter_bound(
        interval: entry.interval_s,
        jitter_percent: config.jitter_percent,
      )
      + 1,
    ),
  )
}

/// Every rung at or before now skipped, each counted on
/// knarr_polls_skipped_total, so the next poll is due on the first rung
/// after now (budget Jitter, NoOverlap): the loop over `budget.next` the
/// Jitter clause leaves to the caller. An interval outside config's range
/// moves one rung at most, so the loop ends.
fn skip_passed(
  entry entry: Entry,
  config config: Config,
  now now: Int,
) -> Entry {
  use <- bool.guard(entry.schedule.next_due > now, entry)
  metrics.inc(observability.polls_skipped_total, [entry.deployment])
  let entry = Entry(..entry, schedule: next_rung(entry, config))
  case entry.interval_s <= 0 {
    True -> entry
    False -> skip_passed(entry:, config:, now:)
  }
}

// ----------------------------------------------------------- The worker ---

type Go {
  Go
}

/// One poll under the factory: an actor whose initialiser sends itself
/// `Go`, so `start_child` returns at once, and whose one message runs the
/// poll, answers on the scheduler's subject and stops.
fn worker(job: Job) -> actor.StartResult(Nil) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send(self, Go)
    actor.initialised(job) |> actor.returning(Nil) |> Ok
  })
  |> actor.on_message(run)
  |> actor.start
}

fn run(job: Job, _go: Go) -> actor.Next(Job, Go) {
  let started = job.now()
  let reading = job.poll(job.endpoint)
  process.send(
    job.reply,
    Returned(
      pod_name: job.pod_name,
      worker: process.self(),
      reading:,
      elapsed_ms: job.now() - started,
    ),
  )
  actor.stop()
}
