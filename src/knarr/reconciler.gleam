//// The reconcile process: the driver on the LIST timer that reconcile's
//// Loop Cycle states (docs/specs/reconcile.allium). Every tick it reads the
//// token and the namespace, runs one discovery cycle of three LISTs, derives
//// the target set (config Discovery), remembers every listed pod's newest
//// view with its lifecycle View, rebuilds the gauges and announces the
//// states from the latest readings, hands the scheduler the listed pods and
//// the joiners, the targets with a pod IP (budget Leaving, reconcile
//// NoPodIp), and hands the patcher every cleanup a View makes due
//// (lifecycle Cleanup Scope, Order). Each reading comes back from the
//// scheduler on its own, at the pod's rung; the reconciler observes it
//// into the pod's memory and decides whether anything is due
//// on the pod against its marker; if so it tells the patcher, which grants
//// one turn at a time as budget's WriteBudget allows. On a turn the change
//// is re-derived from the newest view and the latest reading (budget
//// Pending) and one patch is sent through `k8s_client.patch_pod`: a
//// conflict's yield, else the due writes; the turn is answered with the
//// attempt's outcome or with nothing due, exactly once. A 429 on a LIST
//// pauses the cycles (budget PauseScope); a Deployment that left the target
//// set is retired once the patcher says it is quiet (observability
//// SeriesLife). It raises the Events and lines observability names, the
//// rejections among them, from a turn's result or from the LIST that
//// classifies a 422 (ownership Rejected), and latches readiness.
////
//// Every decision is a pure function of `reconcile`, `config`, `ownership`,
//// `lifecycle`, `cost_mapping`, `budget` and `observability`; the effects
//// are the injected `send`, `poll`, `now`, `random` and `mark_ready`, and
//// `reconciler_ffi` for the files and the token's hash. The reconciler runs
//// last in a set of four under one supervisor, with the poll-worker
//// factory, the scheduler and the patcher, so a crash of any restarts them
//// together (budget Restart). The three actors reach each other by name,
//// through one guarded send.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import knarr/budget
import knarr/config.{type Installed, type Target}
import knarr/cost_mapping.{Mapped}
import knarr/k8s_client.{type Deployment, type Pod, type ReplicaSet}
import knarr/k8s_http.{type SendError, Tls}
import knarr/lifecycle
import knarr/metrics
import knarr/observability.{
  type Entry, type Field, type Level, type Series, Entry, Series,
}
import knarr/ownership.{
  type Marker, type Operation, type Owned, type Standing, Conflict, Write,
}
import knarr/patcher
import knarr/poller.{type Endpoint, Endpoint}
import knarr/poller_http
import knarr/reconcile.{type PodState, type Reading}
import knarr/scheduler
import knarr/token

pub type Config {
  Config(
    target: k8s_client.Target,
    namespace_file: String,
    token_file: String,
    /// How requests reach the apiserver. Production passes `k8s_http.send`
    /// with the service-account CA; a test passes a closure.
    send: fn(Request(String)) -> Result(Response(String), SendError),
    /// One poll of a worker. Production passes `poller.poll` over
    /// `poller_http.send`; a test passes a closure.
    poll: fn(Endpoint) -> poller.Reading,
    /// The clock, in unix milliseconds. reconcile, ownership and
    /// observability take seconds, derived where they are called.
    now: fn() -> Int,
    /// A draw from 0 to one below the bound given, for budget's phase and
    /// jitter; production passes `int.random`.
    random: fn(Int) -> Int,
    /// Latches `/readyz` (observability Probes Readiness).
    mark_ready: fn() -> Nil,
    installed: Installed,
    /// The LIST timer: config.list_interval in milliseconds.
    interval_ms: Int,
    version: String,
    /// The names of the set's processes, minted once by `names`.
    names: Names,
  )
}

/// The registered names of the set's four processes. Minted once per
/// config, never in a child's start closure, since every `process.new_name`
/// is an atom for the life of the VM.
pub type Names {
  Names(
    reconciler: Name(Message),
    scheduler: Name(scheduler.Message),
    patcher: Name(patcher.Message),
    workers: Name(factory_supervisor.Message(scheduler.Job, Nil)),
  )
}

pub fn names() -> Names {
  Names(
    reconciler: process.new_name("knarr_reconciler"),
    scheduler: process.new_name("knarr_scheduler"),
    patcher: process.new_name("knarr_patcher"),
    workers: process.new_name("knarr_poll_workers"),
  )
}

/// A config by position, for the application callback in Erlang. It is the
/// one place a field order is spelled out in Erlang; `mark_ready` is the
/// runtime's to fill in.
pub fn config(
  host host: String,
  port port: Int,
  namespace_file namespace_file: String,
  token_file token_file: String,
  ca_file ca_file: String,
  installed installed: Installed,
) -> Config {
  let version = poller_http.version()
  let timeout_ms = installed.defaults.poll_timeout * 1000
  Config(
    target: k8s_client.Target(host:, port:),
    namespace_file:,
    token_file:,
    send: k8s_http.send(_, Tls(ca_file)),
    poll: fn(endpoint) {
      poller.poll(
        endpoint:,
        version:,
        max_body_bytes: installed.max_body_bytes,
        send: poller_http.send(_, timeout_ms:),
      )
    },
    now: unix_milliseconds,
    random: int.random,
    mark_ready: fn() { Nil },
    installed:,
    interval_ms: installed.list_interval * 1000,
    version:,
    names: names(),
  )
}

pub type Message {
  /// The LIST timer's own message, the initialiser's first among them:
  /// one cycle, then the next armed config.list_interval later, so there
  /// is one chain (reconcile Cycle).
  Timer
  /// A cycle asked for from outside, as a test does: run, with nothing
  /// armed, so it starts no second chain.
  Tick
  /// The LIST pause's own timer, armed on the process-owned subject when
  /// a 429 lengthens the pause, for the `until` it then had: it clears the
  /// pause gauges when the pause ends, runs no cycle and arms nothing. One
  /// for an `until` a later 429 has lengthened past is nothing.
  ListPauseEnded(until: Int)
  /// From the scheduler: one reading returned for a target pod.
  Polled(scheduler.Polled)
  /// From the patcher: a turn to make one patch attempt on one pod, for
  /// the purpose it names. Answered exactly once, with the attempt's
  /// outcome or with nothing due.
  Turn(patcher.Turn)
  /// From the patcher: nothing of a departed Deployment's pods is pending
  /// or in turn, so its series may go (observability SeriesLife).
  Quiet(deployment: String)
}

/// What this process keeps for one pod across cycles: its reading
/// state, the operations of a patch a 422 refused until the next LIST
/// classifies them, during which nothing is due on the pod (reconcile
/// Rejected422), its newest view, the LIST's or a patch response (reconcile
/// Sequence), whether that view is stale, an accepted patch having returned
/// no view, so nothing is due on the pod until the next LIST supplies one
/// (reconcile Sequence), its latest reading with the clock it came at, none
/// before its first poll returns (JustStarted), and its active rejection
/// runs, at most one per reason, from a rejection to the pod's next
/// accepted patch (observability Events Rejected, Cadence OnEntry), and
/// the lifecycle View the last cycle in which every LIST succeeded built
/// for it, none before one has (lifecycle Cleanup View).
type Memory {
  Memory(
    state: PodState,
    kept: Option(Kept),
    pod: Pod,
    stale: Bool,
    latest: Option(#(Reading, Int)),
    runs: List(Entry),
    cleanup_view: Option(lifecycle.View),
  )
}

/// The operations of a patch a 422 refused and the purpose it was sent
/// for, so the LIST that classifies them as a rejection reports it.
type Kept {
  Kept(operations: List(Operation), purpose: observability.Purpose)
}

type State {
  State(
    config: Config,
    /// The subject the LIST timer is armed on: this process's own, not its
    /// name. A timer sent to the name is resolved when it fires, so one a
    /// process armed before a restart would tick the process that replaced
    /// it and start a second LIST chain; one sent to a dead pid is dropped.
    ticks: Subject(Message),
    token_sha256: Option(String),
    /// The namespace and the token read at the last tick, so a reading
    /// returned between ticks can be acted on.
    session: Option(#(String, String)),
    targets: List(Target),
    pods: Dict(String, Memory),
    seen: List(Entry),
    /// The invalid override text last seen, by Deployment uid and key
    /// (config InvalidValue).
    invalid: Dict(#(String, String), String),
    /// The labelled gauge series set in the last cycle, rebuilt each cycle,
    /// and the counter series incremented since the Deployment's series
    /// began, so SeriesLife can retire every one.
    gauges: List(Series),
    counters: List(Series),
    ready: Bool,
    /// The LIST pause a 429 on a LIST lengthens (budget PauseScope); its
    /// `until` is set to 0 once its timer or a tick finds it over, so the
    /// gauges clear once.
    list_pause: budget.Pause,
    /// Deployments that left the target set and are not yet quiet; their
    /// series are held until the patcher says so (observability SeriesLife).
    departing: List(String),
  )
}

/// The set under its own supervisor: three restarts a minute before the
/// root sees one failure, so a crashing child cannot take the listener down
/// with it inside the root's two-in-five-seconds tolerance.
pub fn supervised(
  config: Config,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  set(config) |> supervisor.supervised
}

/// The set started on its own, for a test that drives it.
pub fn start(config: Config) -> actor.StartResult(supervisor.Supervisor) {
  set(config) |> supervisor.start
}

/// The four processes under one supervisor, restarted together: the
/// poll-worker factory first, so the scheduler's first `Listed` finds it;
/// the scheduler; the patcher; the reconciler last, because its initialiser
/// resets the per-Deployment series, which the other two touch only once it
/// has sent them something, and because it is the one that sends unprompted,
/// so every name it sends to is registered when it starts. Shutdown is the
/// reverse, and the guarded send covers the window in which the reconciler
/// is gone and the other two still answer.
fn set(config: Config) -> supervisor.Builder {
  let names = config.names
  supervisor.new(supervisor.OneForAll)
  |> supervisor.restart_tolerance(intensity: 3, period: 60)
  |> supervisor.add(scheduler.workers_supervised(names.workers))
  |> supervisor.add(
    supervision.worker(fn() { scheduler.start(scheduler_config(config)) }),
  )
  |> supervisor.add(
    supervision.worker(fn() { patcher.start(patcher_config(config)) }),
  )
  |> supervisor.add(
    supervision.worker(fn() { start_reconciler(config) })
    |> supervision.timeout(ms: 15_000),
  )
}

fn scheduler_config(config: Config) -> scheduler.Config {
  let names = config.names
  scheduler.Config(
    self: names.scheduler,
    workers: names.workers,
    poll: config.poll,
    now: config.now,
    random: config.random,
    polled: fn(polled) { notify(names.reconciler, Polled(polled)) },
    poll_timeout_s: config.installed.defaults.poll_timeout,
    jitter_percent: config.installed.poll_jitter_percent,
    concurrency: config.installed.poll_concurrency,
  )
}

fn patcher_config(config: Config) -> patcher.Config {
  let names = config.names
  patcher.Config(
    self: names.patcher,
    now: config.now,
    turn: fn(turn) { notify(names.reconciler, Turn(turn)) },
    quiet: fn(deployment) { notify(names.reconciler, Quiet(deployment)) },
    rate_per_second: config.installed.patch_rate_per_second,
    burst: config.installed.patch_burst,
    backoff_initial_s: config.installed.backoff_initial,
    backoff_cap_s: config.installed.backoff_cap,
  )
}

/// A send to a named process that is not registered, as during the set's
/// shutdown, which stops the children in reverse start order, or between a
/// crash and the restart, is dropped: a plain `process.send` to an
/// unregistered name crashes the sender, and a check before it leaves the
/// window between the two. The one place a message crosses between the
/// set's processes, in one non-asserting send in `reconciler_ffi`.
@external(erlang, "reconciler_ffi", "notify")
fn notify(name: Name(message), message: message) -> Nil

/// Starts the reconciler under its name. Its initialiser touches nothing
/// outside the VM: it drops the per-Deployment series a process before it
/// left in the registry (observability SeriesLife), declares the LIST pause
/// over (budget Restart) and schedules the first tick at once, so readiness
/// latches as soon as the first cycle can run. The selector takes the name,
/// for the other two processes and a test, and the plain subject the ticks
/// come on.
fn start_reconciler(config: Config) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(self) {
    metrics.reset_deployment_series()
    set_list_pause_gauges(paused: 0, seconds: 0)
    let ticks = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select(ticks)
    process.send(ticks, Timer)
    actor.initialised(
      State(
        config:,
        ticks:,
        token_sha256: None,
        session: None,
        targets: [],
        pods: dict.new(),
        seen: [],
        invalid: dict.new(),
        gauges: [],
        counters: [],
        ready: False,
        list_pause: budget.Pause(until: 0, consecutive: 0),
        departing: [],
      ),
    )
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.named(config.names.reconciler)
  |> actor.on_message(on_message)
  |> actor.start
}

fn on_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Timer -> {
      let state = tick(state)
      process.send_after(state.ticks, state.config.interval_ms, Timer)
      actor.continue(state)
    }
    Tick -> actor.continue(tick(state))
    ListPauseEnded(until:) -> actor.continue(list_pause_ended(state, until))
    Polled(returned) -> actor.continue(polled(state, returned))
    Turn(granted) -> actor.continue(turn(state, granted))
    Quiet(deployment) -> actor.continue(quiet(state, deployment))
  }
}

// ------------------------------------------------------------- The cycle ---

/// One tick: nothing inside the LIST pause (budget PauseScope), the timer
/// keeping its cadence; otherwise the files are read and a cycle runs. A
/// tick inside the pause reads no file either, so a token rotated during
/// the pause is seen, and its change logged, at the first tick after it:
/// at most backoff_cap later, or a longer Retry-After, which the cap does
/// not bound (k8s_client TokenReload: the token is read for a cycle, and a
/// paused tick makes none; budget BackOff). A failed read of either file
/// ends the session too (the token is never cached past the cycle that
/// read it), so until the next good read a turn is answered nothing due
/// and a poll's entry waits for the LIST to announce it; readings are still
/// observed.
fn tick(state: State) -> State {
  let config = state.config
  let now = config.now()
  use <- bool.guard(now < state.list_pause.until, state)
  let state = list_pause_lifted(state)
  case read_file(config.token_file) {
    Error(ReadFailed(reason)) -> {
      log(observability.Error, "token unreadable", [
        observability.string_field(name: "reason", value: reason),
      ])
      State(..state, session: None)
    }
    Ok(token) -> {
      let token = string.trim(token)
      let state = note_token(state, token)
      case read_file(config.namespace_file) {
        Error(ReadFailed(reason)) -> {
          log(observability.Error, "namespace unreadable", [
            observability.string_field(name: "reason", value: reason),
          ])
          State(..state, session: None)
        }
        Ok(namespace) -> {
          let namespace = string.trim(namespace)
          let state = State(..state, session: Some(#(namespace, token)))
          cycle(state:, namespace:, token:)
        }
      }
    }
  }
}

/// Logs a token change as the file's sha256 and the expiry claim, never the
/// token (k8s_client TokenReload, observability NeverLogged).
fn note_token(state: State, token: String) -> State {
  let sha256 = sha256_hex12(token)
  case state.token_sha256 == Some(sha256) {
    True -> state
    False -> {
      log(observability.Info, "token changed", [
        observability.string_field(name: "sha256", value: sha256),
        observability.string_field(name: "expires_at", value: jwt_exp(token)),
      ])
      State(..state, token_sha256: Some(sha256))
    }
  }
}

/// What one cycle, one reading or one turn carries through its steps: the
/// credentials, the clock readings, the counter series incremented so far,
/// and the last patch attempt made, with the status and Retry-After the
/// patcher's outcome is read from.
type Cycle {
  Cycle(
    config: Config,
    namespace: String,
    token: String,
    now: Int,
    at: String,
    counters: List(Series),
    attempt: Option(Attempt),
  )
}

/// How the apiserver answered a patch: its status, `None` for a transport
/// failure, and the Retry-After of a refusal in whole seconds.
type Attempt {
  Attempt(status: Option(Int), retry_after: Option(Int))
}

/// A `Cycle` for work between ticks, from the session the last tick read,
/// at the clock given in milliseconds.
fn context(
  state state: State,
  namespace namespace: String,
  token token: String,
  now now: Int,
) -> Cycle {
  Cycle(
    config: state.config,
    namespace:,
    token:,
    now:,
    at: rfc3339(now / 1000),
    counters: state.counters,
    attempt: None,
  )
}

/// One discovery cycle: the three LISTs, each counted on knarr_lists_total;
/// a 429 on any pauses the LISTs and keeps the target set and the schedules
/// (budget PauseScope); any other failure keeps them too; a cycle in which
/// all three succeeded ends the pause's run.
fn cycle(
  state state: State,
  namespace namespace: String,
  token token: String,
) -> State {
  let config = state.config
  let installed = config.installed
  let started_ms = unix_milliseconds()
  let #(counters, lists) = {
    use pods, counters <- try_list("pods", state.counters, fn() {
      k8s_client.list_pods(
        target: config.target,
        namespace:,
        token:,
        send: config.send,
      )
    })
    use replica_sets, counters <- try_list("replicasets", counters, fn() {
      k8s_client.list_replica_sets(
        target: config.target,
        namespace:,
        token:,
        send: config.send,
      )
    })
    use deployments, counters <- try_list("deployments", counters, fn() {
      k8s_client.list_deployments(
        target: config.target,
        namespace:,
        token:,
        send: config.send,
      )
    })
    #(counters, Ok(#(pods, replica_sets, deployments)))
  }
  let state = State(..state, counters:)
  case lists {
    Error(k8s_client.Refused(k8s_client.Failure(status: 429, retry_after:, ..))) ->
      list_throttled(state, retry_after)
    // Logged by `try_list`; the previous target set stands.
    Error(k8s_client.Refused(_))
    | Error(k8s_client.SendFailed(_))
    | Error(k8s_client.UndecodableBody(_)) -> state
    Ok(#(pods, replica_sets, deployments)) -> {
      // One clock reading after the LISTs is the time of the cycle's
      // Events and gauges; each reading and write has the clock of its own
      // return (reconcile Cycle).
      let now = config.now()
      let list_pause =
        budget.pause(
          pause: state.list_pause,
          status: 200,
          retry_after: None,
          now:,
          initial: installed.backoff_initial,
          cap: installed.backoff_cap,
        )
      discovered(
        state: State(..state, list_pause:),
        cycle: context(state:, namespace:, token:, now:),
        pods:,
        replica_sets:,
        deployments:,
        started_ms:,
      )
    }
  }
}

/// One LIST, counted on knarr_lists_total by its result (observability
/// Budget); a failure ends the cycle with an error line (Logs Lines) and the
/// previous target set stands (config Discovery). The counter series are
/// threaded through, since the `Cycle` is built after the LISTs.
fn try_list(
  resource: String,
  counters: List(Series),
  list: fn() -> Result(a, k8s_client.ClientError(SendError)),
  next: fn(a, List(Series)) ->
    #(List(Series), Result(b, k8s_client.ClientError(SendError))),
) -> #(List(Series), Result(b, k8s_client.ClientError(SendError))) {
  let counted = fn(status) {
    remember(counters:, name: observability.lists_total, labels: [
      resource,
      observability.list_result(status),
    ])
  }
  case list() {
    Ok(items) -> next(items, counted(Some(200)))
    Error(error) -> {
      log(observability.Error, "list failed", [
        observability.string_field(name: "resource", value: resource),
        ..describe(error)
      ])
      #(counted(status_of(error)), Error(error))
    }
  }
}

/// The status a client error carries: a refusal's, none for a transport or
/// decode failure.
fn status_of(error: k8s_client.ClientError(SendError)) -> Option(Int) {
  case error {
    k8s_client.Refused(failure) -> Some(failure.status)
    k8s_client.SendFailed(_) | k8s_client.UndecodableBody(_) -> None
  }
}

/// A 429 on a LIST: the pause lengthens as budget's BackOff says, with the
/// gauges and the line of scope list (observability Budget); the target set
/// and the schedules stand, so neither actor hears of this cycle. A pause
/// that lengthened arms its end on the process-owned subject, so the gauges
/// clear when it ends and not at the next tick; one that did not lengthen
/// is covered by the timer already armed.
fn list_throttled(state: State, retry_after: Option(Int)) -> State {
  let installed = state.config.installed
  let now = state.config.now()
  let pause =
    budget.pause(
      pause: state.list_pause,
      status: 429,
      retry_after:,
      now:,
      initial: installed.backoff_initial,
      cap: installed.backoff_cap,
    )
  let seconds = { pause.until - now } / 1000
  set_list_pause_gauges(paused: 1, seconds:)
  let retry_field = case retry_after {
    Some(value) -> [
      observability.int_field(name: "retry_after_seconds", value:),
    ]
    None -> []
  }
  log(observability.Info, "list pause", [
    observability.int_field(name: "pause_seconds", value: seconds),
    ..list.append(retry_field, [
      observability.string_field(name: "scope", value: observability.list_scope),
    ])
  ])
  case pause.until > state.list_pause.until {
    True -> {
      process.send_after(
        state.ticks,
        pause.until - now,
        ListPauseEnded(until: pause.until),
      )
      Nil
    }
    False -> Nil
  }
  State(..state, list_pause: pause)
}

/// The pause's timer: the pause it was armed for is over if `until` is
/// still the pause's, else a later 429 lengthened it and armed its own.
fn list_pause_ended(state: State, until: Int) -> State {
  use <- bool.guard(state.list_pause.until != until, state)
  list_pause_lifted(state)
}

/// The pause's end, on its timer or the first tick sent after it: the
/// gauges clear once and the line says so; `until` is left at 0, which a
/// later 429 cannot shorten since it is already past.
fn list_pause_lifted(state: State) -> State {
  use <- bool.guard(state.list_pause.until == 0, state)
  set_list_pause_gauges(paused: 0, seconds: 0)
  log(observability.Info, "list pause ended", [
    observability.string_field(name: "scope", value: observability.list_scope),
  ])
  State(..state, list_pause: budget.Pause(..state.list_pause, until: 0))
}

fn set_list_pause_gauges(paused paused: Int, seconds seconds: Int) -> Nil {
  metrics.set(observability.paused, [observability.list_scope], paused)
  metrics.set(observability.pause_seconds, [observability.list_scope], seconds)
}

/// A cycle whose three LISTs succeeded: the target set, the gauges, the
/// Events and lines, and what the scheduler and the patcher learn from it.
/// Only a good cycle reaches here, so during a LIST pause both keep the
/// previous target set: a pod deleted meanwhile stays scheduled and keeps
/// its pending apply, whose turns fail at the apiserver until the next good
/// LIST drops it, bounded by the pause (budget PauseScope, Pending).
fn discovered(
  state state: State,
  cycle cycle: Cycle,
  pods pods: List(Pod),
  replica_sets replica_sets: List(ReplicaSet),
  deployments deployments: List(Deployment),
  started_ms started_ms: Int,
) -> State {
  let config = cycle.config
  let defaults = config.installed.defaults
  let deployments =
    list.filter(deployments, fn(d) { config.opted_in(d.labels) })
  let targets = config.targets(deployments:, replica_sets:, pods:, defaults:)
  // Readiness latches at the end of the first cycle in which every LIST
  // succeeded (observability Probes Readiness).
  let state = case state.ready {
    True -> state
    False -> {
      config.mark_ready()
      State(..state, ready: True)
    }
  }
  metrics.set(
    observability.last_discovery_timestamp_seconds,
    [],
    cycle.now / 1000,
  )
  metrics.observe(
    observability.discovery_duration_seconds,
    int.to_float(unix_milliseconds() - started_ms) /. 1000.0,
  )
  metrics.set(observability.targets, ["deployments"], list.length(deployments))
  metrics.set(observability.targets, ["pods"], list.length(targets))
  log(observability.Info, "discovery", [
    observability.int_field(
      name: "deployments",
      value: list.length(deployments),
    ),
    observability.int_field(name: "pods", value: list.length(targets)),
  ])
  let #(invalid, cycle) =
    overrides(previous: state.invalid, deployments:, cycle:)
  // Every listed pod's memory, kept from the last cycle or begun here, with
  // this cycle's lifecycle View, and a 422's operations classified against
  // the LIST's view under the View's deployment, a pod that left the target
  // set since included (reconcile Rejected422, Sequence; ownership
  // Rejected; observability Labels). A memory of a pod the LIST no longer
  // shows is dropped with it.
  let by_name =
    list.fold(targets, dict.new(), fn(acc, target) {
      dict.insert(acc, target.pod_name, target)
    })
  let #(listed_pods, cycle) =
    list.fold(pods, #([], cycle), fn(acc, pod) {
      let #(listed_pods, cycle) = acc
      let target = dict.get(by_name, pod.name) |> option.from_result
      let view = cleanup_view(pod:, target:, replica_sets:)
      let #(memory, cycle) =
        classify_kept(
          cycle:,
          deployment: view.deployment,
          pod:,
          memory: listed_memory(previous: state.pods, pod:, target:),
        )
      let memory = Memory(..memory, cleanup_view: Some(view))
      #([#(target, memory, view), ..listed_pods], cycle)
    })
  let listed_pods = list.reverse(listed_pods)
  // The gauges, the announcements, the schedule and the patcher's applies
  // read the targets' memories alone.
  let memories =
    list.filter_map(listed_pods, fn(item) {
      case item {
        #(Some(target), memory, _) -> Ok(#(target, memory))
        #(None, _, _) -> Error(Nil)
      }
    })
  let others =
    list.filter_map(listed_pods, fn(item) {
      case item {
        #(None, _, view) -> Ok(view)
        #(Some(_), _, _) -> Error(Nil)
      }
    })
  let current = gauges(targets:, pods: memories, others:)
  let #(seen, cycle) = announce(seen: state.seen, pods: memories, cycle:)
  // The schedule learns joining and leaving from the LIST alone: every
  // target by name, and a joiner for each with a pod IP (budget Leaving,
  // reconcile NoPodIp). The scheduler keeps the ladder of a pod it already
  // has and polls a joiner from its phase.
  let joining =
    list.filter_map(memories, fn(item) {
      let #(target, memory) = item
      case memory.pod.pod_ip {
        Some(pod_ip) ->
          Ok(scheduler.Joiner(
            pod_name: target.pod_name,
            pod_uid: memory.pod.uid,
            deployment: target.deployment_name,
            interval_s: target.settings.poll_interval,
            endpoint: Endpoint(
              pod_ip:,
              port: target.settings.status_port,
              path: target.settings.status_path,
            ),
          ))
        None -> Error(Nil)
      }
    })
  let listed = list.map(targets, fn(target) { target.pod_name })
  notify(config.names.scheduler, scheduler.Listed(listed:, joining:))
  // The patcher learns the same in one message: the apply of a pod not
  // listed, or listed terminating, is discarded (budget Pending, Leaving),
  // the apply, the cleanup and the last attempt of a pod listed under
  // another uid are forgotten (budget PerPod, Pending), the last attempt of
  // every pod the LIST shows is kept, and a listed Deployment is not
  // departing; then every View with a Removal is a pending cleanup, a kept
  // one refreshed with the interval this cycle derives. One message, so the
  // patcher grants nothing and settles no departure between the prune and
  // the cleanups, and before any departure, so a Deployment a cleanup holds
  // is busy when it departs. Every cleanup of this cycle carries the
  // cycle's clock, so the first cycle after a start derives every due
  // cleanup at once with one due_since (lifecycle Cleanup Order, Retry,
  // Restart NoStartupStep; budget Restart); a repeat keeps its own. The
  // interval is the target's, config.patch_interval for a pod that is not
  // one (budget PerPod).
  let replaced =
    list.filter_map(listed_pods, fn(item) {
      let #(_, memory, _) = item
      case dict.get(state.pods, memory.pod.name) {
        Ok(before) if before.pod.uid != memory.pod.uid -> Ok(memory.pod.name)
        _ -> Error(Nil)
      }
    })
  let cleaning =
    list.filter_map(listed_pods, fn(item) {
      let #(target, _, view) = item
      use <- bool.guard(lifecycle.due(view) == [], Error(Nil))
      let interval_s = case target {
        Some(target) -> target.settings.patch_interval
        None -> defaults.patch_interval
      }
      Ok(patcher.Cleaning(
        pod_name: view.pod_name,
        deployment: view.deployment,
        interval_s:,
        at_ms: cycle.now,
      ))
    })
  let deployment_names =
    list.map(targets, fn(target) { target.deployment_name }) |> list.unique
  notify(
    config.names.patcher,
    patcher.Listed(
      listed: list.map(pods, fn(pod) { pod.name }),
      targets: listed,
      terminating: list.filter_map(memories, fn(item) {
        case { item.1 }.pod.deletion_timestamp {
          Some(_) -> Ok({ item.0 }.pod_name)
          None -> Error(Nil)
        }
      }),
      replaced:,
      deployments: deployment_names,
      cleaning:,
    ),
  )
  let memories =
    list.fold(listed_pods, dict.new(), fn(acc, item) {
      let #(_, memory, _) = item
      dict.insert(acc, memory.pod.name, memory)
    })
  // A Deployment has left when no current target carries its name: the
  // series are labelled by name, so one recreated under the same name
  // between two LISTs keeps them (observability SeriesLife). One that left
  // is departing until the patcher says it is quiet; one that rejoined
  // before that is not.
  let gone =
    list.filter_map(state.targets, fn(previous) {
      case list.contains(deployment_names, previous.deployment_name) {
        True -> Error(Nil)
        False -> Ok(previous.deployment_name)
      }
    })
    |> list.unique
  list.each(gone, fn(deployment) {
    notify(config.names.patcher, patcher.Departed(deployment:))
  })
  let departing =
    state.departing
    |> list.filter(fn(deployment) {
      !list.contains(deployment_names, deployment)
    })
    |> list.append(gone)
    |> list.unique
  // The gauge series of a departing Deployment are held, not rebuilt away,
  // until it is quiet; every other series of the last cycle that this one
  // did not set leaves the exposition. A held series this cycle set again,
  // as knarr_annotations for a departing Deployment's pods that are no
  // longer targets, is kept once.
  let #(held, previous) = list.partition(state.gauges, labelled(_, departing))
  let held = list.filter(held, fn(series) { !list.contains(current, series) })
  let gauges = list.append(rebuild(previous, current), held)
  State(
    ..state,
    targets:,
    pods: memories,
    seen:,
    invalid:,
    departing:,
    gauges:,
    counters: cycle.counters,
  )
}

/// The memory a pod begins with: no reading, no kept 422, no run, the view
/// the LIST gave, and no lifecycle View yet.
fn fresh(pod: Pod) -> Memory {
  Memory(
    state: reconcile.initial(),
    kept: None,
    pod:,
    stale: False,
    latest: None,
    runs: [],
    cleanup_view: None,
  )
}

/// One listed pod's memory for this cycle. A target keeps its memory with
/// the LIST's view as its newest, no longer stale. A pod that is not a
/// target keeps only its rejection runs and a kept 422, which this LIST
/// classifies: it is in no state but the rejection runs, whose LIST is the
/// unselected pod LIST, while every other state's is the target set
/// (observability Cadence OnEntry), so it rejoins the schedule from the
/// initial state (reconcile NoPodIp). A terminating pod leaves every state,
/// its runs among them, and a pod the LIST shows under another uid is begun
/// afresh, as a restart begins it (reconcile Cycle).
fn listed_memory(
  previous previous: Dict(String, Memory),
  pod pod: Pod,
  target target: Option(Target),
) -> Memory {
  let memory = case dict.get(previous, pod.name) {
    Ok(memory) if memory.pod.uid == pod.uid -> memory
    _ -> fresh(pod)
  }
  let runs = case pod.deletion_timestamp {
    Some(_) -> []
    None -> memory.runs
  }
  case target {
    Some(_) -> Memory(..memory, pod:, stale: False, runs:)
    None -> Memory(..fresh(pod), kept: memory.kept, runs:)
  }
}

/// A listed pod's lifecycle View (lifecycle Cleanup View): `target` from
/// config's target set; `enabled` pod-deletion-cost always and
/// safe-to-evict while the target's Deployment opts in, nothing for a pod
/// that is not a target; `terminating` from deletionTimestamp; `deployment`
/// the target's Deployment, else the name its ReplicaSet's controller owner
/// carries, empty when the chain names no Deployment (Label); `held` from
/// the pod's newest API-returned view, which at the cycle is its LIST's
/// (ownership Adoption).
fn cleanup_view(
  pod pod: Pod,
  target target: Option(Target),
  replica_sets replica_sets: List(ReplicaSet),
) -> lifecycle.View {
  let #(deployment, enabled) = case target {
    Some(target) -> #(
      target.deployment_name,
      case target.settings.safe_to_evict {
        True -> [ownership.pod_deletion_cost.name, ownership.safe_to_evict.name]
        False -> [ownership.pod_deletion_cost.name]
      },
    )
    None -> #(lifecycle.deployment_of(owner: pod.owner, replica_sets:), [])
  }
  lifecycle.View(
    pod_name: pod.name,
    deployment:,
    target: option.is_some(target),
    enabled:,
    terminating: option.is_some(pod.deletion_timestamp),
    held: lifecycle.held(
      marker: ownership.read(pod.annotations),
      annotations: pod.annotations,
    ),
  )
}

/// Whether a series is labelled with one of the Deployments given.
fn labelled(series: Series, deployments: List(String)) -> Bool {
  list.any(deployments, fn(deployment) {
    observability.retire(series: [series], deployment:) == []
  })
}

// ----------------------------------------------------------- One reading ---

/// A reading the scheduler returned: logged and counted, observed into the
/// pod's memory at the clock it came at (reconcile Cycle), and decided on
/// from the pod's newest view: when a yield or a write is due, the patcher
/// is told the apply is pending, with the pod's patch interval (budget
/// Pending, PerPod); nothing is sent to the apiserver here. The change is
/// re-derived on the turn, so a later reading that leaves nothing due costs
/// nothing but a turn. A reading that lands is observed on the poll
/// duration histogram as it is counted; a reading of a pod no LIST has
/// shown since, one for a uid the newest view does not carry, or one before
/// any cycle has run, has nowhere to land and is dropped, neither counted
/// nor observed (reconcile Cycle, budget Leaving; observability Polls).
fn polled(state: State, returned: scheduler.Polled) -> State {
  let pod_name = returned.pod_name
  let target =
    list.find(state.targets, fn(target) { target.pod_name == pod_name })
  case dict.get(state.pods, pod_name), target {
    Ok(memory), Ok(target) if memory.pod.uid == returned.pod_uid -> {
      metrics.observe(observability.poll_duration_seconds, returned.seconds)
      let config = state.config
      let now = returned.at_ms
      let reading = returned.reading
      let counters =
        polled_line(
          counters: state.counters,
          target:,
          endpoint: returned.endpoint,
          reading:,
        )
      let memory =
        Memory(
          ..memory,
          state: reconcile.observe(
            state: memory.state,
            reading: reading.kind,
            at: now / 1000,
            unknown_polls: config.installed.unknown_polls,
            absent_after: config.installed.absent_after,
          ),
          latest: Some(#(reading, now)),
        )
      let pod = memory.pod
      let at = rfc3339(now / 1000)
      let due =
        !held(memory)
        && {
          conflicts(target:, pod:) != []
          || due_operations(target:, pod:, memory:, reading:, at:) != []
        }
      case due {
        True ->
          notify(
            config.names.patcher,
            patcher.Due(
              pod_name:,
              purpose: budget.Apply,
              deployment: target.deployment_name,
              interval_s: target.settings.patch_interval,
              at_ms: now,
            ),
          )
        False -> Nil
      }
      // The states this reading entered are announced now, with it, not
      // at the next LIST (observability OnEntry; reconcile Absent names the
      // reading that entered). Without a session the Event cannot be
      // created, so the entry is left for the LIST after the next good
      // read to announce, if the pod is still in the state then.
      let #(seen, counters) = case state.session {
        Some(#(namespace, token)) -> {
          let cycle =
            Cycle(..context(state:, namespace:, token:, now:), counters:)
          let #(seen, cycle) =
            announce_polled(seen: state.seen, target:, memory:, cycle:)
          #(seen, cycle.counters)
        }
        None -> #(state.seen, counters)
      }
      State(
        ..state,
        pods: dict.insert(state.pods, pod_name, memory),
        seen:,
        counters:,
      )
    }
    _, _ -> state
  }
}

/// The pod's part of the announced states after a reading: the states it
/// is in now, less those it was already in, announced; the pod's entries
/// in `seen` replaced by the current ones, so the LIST after announces
/// nothing of them again, and a state left and re-entered between LISTs
/// is announced again (observability OnEntry).
fn announce_polled(
  seen seen: List(Entry),
  target target: Target,
  memory memory: Memory,
  cycle cycle: Cycle,
) -> #(List(Entry), Cycle) {
  let pod_name = target.pod_name
  let #(mine, others) =
    list.partition(seen, fn(entry) { entry.pod_name == pod_name })
  let current = entries(target:, memory:)
  let cycle =
    observability.entered(seen: mine, current:)
    |> list.fold(cycle, fn(cycle, entry) {
      announce_one(cycle:, entry:, item: #(target, memory))
    })
  #(list.append(others, current), cycle)
}

/// The invalid-override Events on entry and the unknown-key lines once per
/// cycle (config InvalidValue and Unknown, observability InvalidOverride).
fn overrides(
  previous previous: Dict(#(String, String), String),
  deployments deployments: List(Deployment),
  cycle cycle: Cycle,
) -> #(Dict(#(String, String), String), Cycle) {
  let defaults = cycle.config.installed.defaults
  list.fold(deployments, #(dict.new(), cycle), fn(acc, deployment) {
    let #(memory, cycle) = acc
    list.each(
      config.unknown(deployment.labels, deployment.annotations),
      fn(key) {
        log(observability.Warning, "unknown key", [
          observability.string_field(name: "deployment", value: deployment.name),
          observability.string_field(name: "key", value: key),
        ])
      },
    )
    list.fold(
      config.invalid(deployment.annotations, defaults),
      #(memory, cycle),
      fn(acc, invalid) {
        let #(memory, cycle) = acc
        let id = #(deployment.uid, invalid.key)
        let cycle = case dict.get(previous, id) == Ok(invalid.value) {
          True -> cycle
          False -> {
            let message = config.message(invalid)
            let fields = [
              observability.string_field(
                name: "deployment",
                value: deployment.name,
              ),
              observability.string_field(name: "key", value: invalid.key),
              observability.string_field(name: "value", value: invalid.value),
              observability.string_field(name: "reason", value: invalid.reason),
            ]
            raise(
              cycle:,
              involved: k8s_client.DeploymentObject(
                name: deployment.name,
                uid: deployment.uid,
              ),
              reason: observability.invalid_override,
              message:,
              msg: "invalid override",
              fields:,
            )
          }
        }
        #(dict.insert(memory, id, invalid.value), cycle)
      },
    )
  })
}

fn polled_line(
  counters counters: List(Series),
  target target: Target,
  endpoint endpoint: Endpoint,
  reading reading: Reading,
) -> List(Series) {
  let kind = reading_label(reading.kind)
  let fields = [
    observability.string_field(
      name: "deployment",
      value: target.deployment_name,
    ),
    observability.string_field(name: "pod", value: target.pod_name),
    observability.int_field(name: "port", value: endpoint.port),
    observability.string_field(name: "path", value: endpoint.path),
    observability.string_field(name: "reading", value: kind),
  ]
  let fields = case reading {
    reconcile.Reading(cost: Some(cost), draining:, ..) ->
      list.append(fields, [
        observability.int_field(name: "cost", value: cost),
        observability.bool_field(name: "accepting", value: !draining),
      ])
    _ -> fields
  }
  log(observability.Debug, "poll", fields)
  remember(counters:, name: observability.polls_total, labels: [
    target.deployment_name,
    kind,
  ])
}

/// Whether nothing is due on the pod until the next LIST, whatever its
/// reading: it is terminating (reconcile Terminating), it holds a 422's
/// operations, which are not retried before that LIST (Rejected422), or an
/// accepted patch left its view stale (Sequence).
fn held(memory: Memory) -> Bool {
  option.is_some(memory.pod.deletion_timestamp)
  || option.is_some(memory.kept)
  || memory.stale
}

/// A 422's operations are classified against the next LIST's view and then
/// forgotten (reconcile Rejected422): when every test would have passed,
/// the 422 was a rejection with status 422 (ownership Rejected).
fn classify_kept(
  cycle cycle: Cycle,
  deployment deployment: String,
  pod pod: Pod,
  memory memory: Memory,
) -> #(Memory, Cycle) {
  case memory.kept {
    None -> #(memory, cycle)
    Some(Kept(operations:, purpose:)) -> {
      let memory = Memory(..memory, kept: None)
      case
        ownership.rejected(
          operations:,
          annotations: pod.annotations,
          deletion_timestamp: pod.deletion_timestamp,
        )
      {
        True ->
          rejection(
            cycle:,
            deployment:,
            pod:,
            memory:,
            operations:,
            purpose:,
            status: 422,
          )
        False -> #(memory, cycle)
      }
    }
  }
}

/// One known rejection of a patch (ownership Rejected): counted on
/// knarr_patch_rejections_total (observability Catalogue Patches) and, on
/// the first of a run for its reason, raised as PatchRejected or
/// CleanupRejected on the Pod with its warning line (Events Rejected,
/// CleanupRejected, AlsoLogged); a second rejection in the run counts and
/// raises nothing. The run ends with the pod's next accepted patch, which
/// `accepted` records. The function is purpose-agnostic: ticket 47 calls
/// it with `observability.Cleanup`, and `left` is then `ownership.left`
/// over the cleanup's operations against `pod`'s annotations. `deployment`
/// is the label observability Labels names: the Deployment's name for a
/// target, `lifecycle.deployment_of` for a pod that is not one.
fn rejection(
  cycle cycle: Cycle,
  deployment deployment: String,
  pod pod: Pod,
  memory memory: Memory,
  operations operations: List(Operation),
  purpose purpose: observability.Purpose,
  status status: Int,
) -> #(Memory, Cycle) {
  let cycle =
    count(cycle:, name: observability.patch_rejections_total, labels: [
      deployment,
      observability.purpose_label(purpose),
    ])
  let #(state, msg) = case purpose {
    observability.Apply | observability.Yield -> #(
      observability.Rejected,
      "patch rejected",
    )
    observability.Cleanup -> #(
      observability.CleanupRejected,
      "cleanup rejected",
    )
  }
  let entry = Entry(pod_name: pod.name, annotation: None, state:)
  case observability.entered(seen: memory.runs, current: [entry]) {
    [] -> #(memory, cycle)
    _ -> {
      let left = case purpose {
        observability.Apply | observability.Yield -> []
        observability.Cleanup ->
          ownership.left(operations:, annotations: pod.annotations)
      }
      let event =
        observability.RejectedEvent(
          pod_name: pod.name,
          pod_uid: pod.uid,
          purpose:,
          status:,
          keys: ownership.keys(operations),
          left:,
        )
      let fields = [
        observability.string_field(name: "deployment", value: deployment),
        observability.string_field(name: "pod", value: pod.name),
        observability.string_field(
          name: "purpose",
          value: observability.purpose_label(purpose),
        ),
        observability.int_field(name: "status", value: status),
        observability.strings_field(name: "keys", values: event.keys),
      ]
      let fields = case purpose {
        observability.Cleanup ->
          list.append(fields, [
            observability.strings_field(
              name: "left",
              values: list.map(left, fn(pair) { pair.0 <> "=" <> pair.1 }),
            ),
          ])
        observability.Apply | observability.Yield -> fields
      }
      let cycle =
        raise(
          cycle:,
          involved: k8s_client.PodObject(name: pod.name, uid: pod.uid),
          reason: observability.reason(event),
          message: observability.rejected_message(event),
          msg:,
          fields:,
        )
      #(Memory(..memory, runs: [entry, ..memory.runs]), cycle)
    }
  }
}

/// An accepted patch of any purpose ends the pod's rejection runs
/// (observability Events Rejected).
fn accepted(memory: Memory) -> Memory {
  Memory(..memory, runs: [])
}

// ---------------------------------------------------------- One pod's turn ---

/// Where each owned annotation stands on a view, with the parse of its
/// applied record (reconcile Conflict).
type OwnedView {
  OwnedView(
    owned: Owned,
    standing: Standing,
    applied: reconcile.Applied,
    safe_to_evict: Option(String),
    considered: Bool,
  )
}

/// Both owned annotations' views on one pod.
type Views {
  Views(cost: OwnedView, safe: OwnedView)
}

fn view(target target: Target, pod pod: Pod, marker marker: Marker) -> Views {
  let applied =
    reconcile.parse_applied(ownership.applied_value(
      marker:,
      owned: ownership.pod_deletion_cost,
    ))
  let cost_standing =
    lifecycle.effective_standing(
      marker:,
      annotations: pod.annotations,
      owned: ownership.pod_deletion_cost,
    )
  let safe_record = ownership.record(marker, ownership.safe_to_evict)
  let safe_value =
    ownership.applied_value(marker:, owned: ownership.safe_to_evict)
  let safe_standing =
    lifecycle.effective_standing(
      marker:,
      annotations: pod.annotations,
      owned: ownership.safe_to_evict,
    )
  Views(
    cost: OwnedView(
      owned: ownership.pod_deletion_cost,
      standing: cost_standing,
      applied:,
      safe_to_evict: None,
      considered: True,
    ),
    safe: OwnedView(
      owned: ownership.safe_to_evict,
      standing: safe_standing,
      applied:,
      safe_to_evict: safe_value,
      considered: target.settings.safe_to_evict || option.is_some(safe_record),
    ),
  )
}

/// The owned annotations in conflict on a view, cost first (reconcile
/// Conflict, ownership Adoption): each is due a yield.
fn conflicts(target target: Target, pod pod: Pod) -> List(OwnedView) {
  let views = view(target:, pod:, marker: ownership.read(pod.annotations))
  [views.cost, views.safe]
  |> list.filter(fn(owned) { owned.considered && owned.standing == Conflict })
}

/// The operations of the write due on a view from the latest reading
/// (reconcile Desired, Due; ownership WriteMode), empty when nothing is.
fn due_operations(
  target target: Target,
  pod pod: Pod,
  memory memory: Memory,
  reading reading: Reading,
  at at: String,
) -> List(Operation) {
  let marker = ownership.read(pod.annotations)
  let Views(cost:, safe:) = view(target:, pod:, marker:)
  let safe_applied = case safe.considered {
    True -> safe.safe_to_evict
    False -> None
  }
  let desired =
    reconcile.desired(
      state: memory.state,
      reading:,
      applied: cost.applied,
      safe_to_evict: safe_applied,
      thresholds: target.settings.thresholds,
      margin: target.settings.threshold_margin,
    )
  let writes =
    reconcile.due(desired:, applied: cost.applied, safe_to_evict: safe_applied)
    |> list.filter_map(fn(name) {
      let #(owned, value) = case name == cost.owned.name {
        True -> #(cost, cost_mapping.render(Mapped(desired.cost)))
        False -> #(safe, desired.safe_to_evict)
      }
      case ownership.may_write(owned.standing) {
        True -> Ok(Write(owned.owned, value))
        False -> Error(Nil)
      }
    })
  ownership.patch(marker:, annotations: pod.annotations, writes:, at:)
}

/// A turn the patcher granted: one patch attempt on the pod, re-derived
/// from its newest view and latest reading (budget Pending), the first
/// conflict's yield if any, else the due writes (reconcile Sequence), and
/// one answer, always: `Attempted` with the outcome and whether anything
/// is still due, or `NothingDue` when the pod is gone, terminating, has no
/// reading yet (JustStarted), holds a 422 for the next LIST (Rejected422)
/// or has nothing to write. A cleanup turn, which discovery now enqueues,
/// is still answered nothing due: re-deriving it from the newest view and
/// sending it is ticket 47's next step. An accepted response
/// becomes the pod's view. The request is built at the turn's clock, the
/// marker's `at` among it, and the answer carries the clock after the
/// attempt returned, so the pod's interval and a pause run from the
/// response, not from a request a slow apiserver sat on (budget PerPod,
/// BackOff). The patcher's target set is the last good LIST's: during a
/// LIST pause a pod deleted meanwhile keeps its entry, and its turns fail
/// at the apiserver until the next good LIST drops it.
fn turn(state: State, granted: patcher.Turn) -> State {
  let patcher.Turn(pod_name:, purpose:) = granted
  let target =
    list.find(state.targets, fn(target) { target.pod_name == pod_name })
  case purpose, state.session, dict.get(state.pods, pod_name), target {
    budget.Apply, Some(#(namespace, token)), Ok(memory), Ok(target) -> {
      let now = state.config.now()
      let cycle = context(state:, namespace:, token:, now:)
      case attempt(cycle:, target:, memory:) {
        Some(#(pod, memory, cycle, still_due)) -> {
          answer(
            state:,
            granted:,
            attempt: cycle.attempt,
            still_due:,
            at_ms: state.config.now(),
          )
          State(
            ..state,
            pods: dict.insert(state.pods, pod_name, Memory(..memory, pod:)),
            counters: cycle.counters,
          )
        }
        None -> nothing_due(state, granted)
      }
    }
    _, _, _, _ -> nothing_due(state, granted)
  }
}

/// The answer to a turn on which no attempt was made.
fn nothing_due(state: State, granted: patcher.Turn) -> State {
  answer(state:, granted:, attempt: None, still_due: False, at_ms: 0)
  state
}

/// One attempt on the pod's turn, or none when the pod has no reading yet
/// or nothing is due on it until the next LIST (reconcile JustStarted,
/// `held`): the pod, the memory and the cycle after it, and whether
/// anything is still due.
fn attempt(
  cycle cycle: Cycle,
  target target: Target,
  memory memory: Memory,
) -> Option(#(Pod, Memory, Cycle, Bool)) {
  let pod = memory.pod
  use <- bool.guard(held(memory), None)
  case conflicts(target:, pod:), memory.latest {
    [conflict, ..], _ ->
      Some(yield_turn(cycle:, target:, pod:, memory:, conflict:))
    [], None -> None
    [], Some(#(reading, _)) ->
      Some(write_turn(cycle:, target:, pod:, memory:, reading:))
  }
}

/// The one answer to a turn, with the turn's own key: the attempt made, or
/// nothing due when none was.
fn answer(
  state state: State,
  granted granted: patcher.Turn,
  attempt attempt: Option(Attempt),
  still_due still_due: Bool,
  at_ms at_ms: Int,
) -> Nil {
  let patcher.Turn(pod_name:, purpose:) = granted
  let message = case attempt {
    Some(attempt) ->
      patcher.Attempted(
        pod_name:,
        purpose:,
        outcome: outcome(attempt),
        still_due:,
        at_ms:,
      )
    None -> patcher.NothingDue(pod_name:, purpose:)
  }
  notify(state.config.names.patcher, message)
}

/// The yield of one conflict on the turn; the apply stays due when another
/// conflict or a write remains on the view the yield left, unless the yield
/// was refused with a 422 or accepted with no view, which leave nothing due
/// before the next LIST (reconcile Rejected422, Sequence).
fn yield_turn(
  cycle cycle: Cycle,
  target target: Target,
  pod pod: Pod,
  memory memory: Memory,
  conflict conflict: OwnedView,
) -> #(Pod, Memory, Cycle, Bool) {
  let marker = ownership.read(pod.annotations)
  let #(pod, memory, cycle) = case
    yields(cycle:, target:, pod:, marker:, conflicts: [conflict], memory:)
  {
    Ok(#(pod, memory, cycle)) -> #(pod, memory, cycle)
    Error(#(memory, cycle)) -> #(pod, memory, cycle)
  }
  let still_due =
    !held(memory)
    && {
      conflicts(target:, pod:) != []
      || case memory.latest {
        Some(#(reading, _)) ->
          due_operations(target:, pod:, memory:, reading:, at: cycle.at) != []
        None -> False
      }
    }
  #(pod, memory, cycle, still_due)
}

/// The due writes on the turn; the apply stays due unless they were
/// accepted or refused with a 422, which is not retried before the next
/// LIST rebuilds the write (reconcile Rejected422): a 429 waits out the
/// pause, any other refusal, a 400 or 403 rejection among them, is tried
/// again after the pod's interval.
fn write_turn(
  cycle cycle: Cycle,
  target target: Target,
  pod pod: Pod,
  memory memory: Memory,
  reading reading: Reading,
) -> #(Pod, Memory, Cycle, Bool) {
  let #(pod, memory, cycle) = write(cycle:, target:, pod:, memory:, reading:)
  let still_due = case held(memory), cycle.attempt {
    False, Some(attempt) -> outcome(attempt) != patcher.Accepted
    True, _ | False, None -> False
  }
  #(pod, memory, cycle, still_due)
}

/// The patcher's reading of an attempt: a 2xx accepted, a 429 throttled
/// with its Retry-After, anything else rejected, a transport failure
/// included.
fn outcome(attempt: Attempt) -> patcher.Outcome {
  case attempt.status {
    Some(status) if status >= 200 && status < 300 -> patcher.Accepted
    Some(429) -> patcher.Throttled(retry_after_s: attempt.retry_after)
    Some(_) | None -> patcher.Rejected
  }
}

/// The patcher has nothing of a departed Deployment's pods pending or in
/// turn: its series go now (observability SeriesLife). A quiet for a
/// Deployment that is not departing, one that rejoined the target set
/// included, since `discovered` drops it from `departing`, changes nothing;
/// the target check is a second guard on the same fact.
fn quiet(state: State, deployment: String) -> State {
  use <- bool.guard(!list.contains(state.departing, deployment), state)
  let departing = list.filter(state.departing, fn(d) { d != deployment })
  case
    list.any(state.targets, fn(target) { target.deployment_name == deployment })
  {
    True -> State(..state, departing:)
    False ->
      State(
        ..state,
        departing:,
        gauges: retire(state.gauges, deployment),
        counters: retire(state.counters, deployment),
      )
  }
}

/// One yield per conflicting annotation, each from the view the one before
/// left: the pod every yield was accepted on with the memory, or, when a
/// yield was refused or accepted with no view, which ends the pod's turn,
/// the memory, holding a 422's operations for the next LIST (reconcile
/// Rejected422), the rejection's run (ownership Rejected) or the stale view
/// (Sequence).
fn yields(
  cycle cycle: Cycle,
  target target: Target,
  pod pod: Pod,
  marker marker: Marker,
  conflicts conflicts: List(OwnedView),
  memory memory: Memory,
) -> Result(#(Pod, Memory, Cycle), #(Memory, Cycle)) {
  case conflicts {
    [] -> Ok(#(pod, memory, cycle))
    [conflict, ..rest] -> {
      let operations =
        ownership.yield(
          marker:,
          annotations: pod.annotations,
          owned: conflict.owned,
          at: cycle.at,
        )
      let event =
        ownership.event(
          pod_name: pod.name,
          pod_uid: pod.uid,
          marker:,
          annotations: pod.annotations,
          owned: conflict.owned,
        )
      let #(cycle, result) =
        send_patch(
          cycle:,
          target:,
          pod:,
          operations:,
          purpose: observability.Yield,
        )
      case result {
        Ok(patched) -> {
          let cycle = yielded(cycle:, target:, pod:, conflict:, event:)
          yields(
            cycle:,
            target:,
            pod: patched,
            marker: ownership.read(patched.annotations),
            conflicts: rest,
            memory: accepted(memory),
          )
        }
        // A refused yield raises no AnnotationYielded: the conflict is seen
        // again from the next LIST (ownership Event), which also classifies
        // a 422's operations; a 400 or 403 is a rejection at once.
        Error(PreconditionFailed) ->
          Error(#(
            Memory(
              ..memory,
              kept: Some(Kept(operations:, purpose: observability.Yield)),
            ),
            cycle,
          ))
        Error(Rejected(status)) ->
          Error(rejection(
            cycle:,
            deployment: target.deployment_name,
            pod:,
            memory:,
            operations:,
            purpose: observability.Yield,
            status:,
          ))
        // Accepted without a view: the yield is reported as any accepted
        // one, from the pre-yield view, the runs end, and nothing more is
        // due on the pod until the next LIST supplies the view the next
        // yield and the apply need (reconcile Sequence).
        Error(AcceptedUnseen) ->
          Error(#(
            Memory(..accepted(memory), stale: True),
            yielded(cycle:, target:, pod:, conflict:, event:),
          ))
        Error(OtherFailure) -> Error(#(memory, cycle))
      }
    }
  }
}

/// The report of one accepted yield: counted on knarr_yields_total
/// (observability Catalogue Standing) and raised as AnnotationYielded on the
/// Pod from the pre-yield view (ownership Event).
fn yielded(
  cycle cycle: Cycle,
  target target: Target,
  pod pod: Pod,
  conflict conflict: OwnedView,
  event event: ownership.ConflictEvent,
) -> Cycle {
  let cycle =
    count(cycle:, name: observability.yields_total, labels: [
      target.deployment_name,
      conflict.owned.name,
    ])
  raise(
    cycle:,
    involved: k8s_client.PodObject(name: pod.name, uid: pod.uid),
    reason: observability.annotation_yielded,
    message: ownership.message(event),
    msg: "annotation yielded",
    fields: [
      observability.string_field(
        name: "deployment",
        value: target.deployment_name,
      ),
      observability.string_field(name: "pod", value: pod.name),
      observability.string_field(name: "annotation", value: conflict.owned.name),
      observability.string_field(name: "applied", value: absent(event.applied)),
      observability.string_field(name: "found", value: absent(event.found)),
    ],
  )
}

/// The due writes may_write allows, in one patch (reconcile Desired, Due;
/// ownership WriteMode); nothing is sent when none is due.
fn write(
  cycle cycle: Cycle,
  target target: Target,
  pod pod: Pod,
  memory memory: Memory,
  reading reading: Reading,
) -> #(Pod, Memory, Cycle) {
  case due_operations(target:, pod:, memory:, reading:, at: cycle.at) {
    [] -> #(pod, memory, cycle)
    operations -> {
      let #(cycle, result) =
        send_patch(
          cycle:,
          target:,
          pod:,
          operations:,
          purpose: observability.Apply,
        )
      case result {
        Ok(pod) -> #(pod, accepted(memory), cycle)
        Error(PreconditionFailed) -> #(
          pod,
          Memory(
            ..memory,
            kept: Some(Kept(operations:, purpose: observability.Apply)),
          ),
          cycle,
        )
        Error(Rejected(status)) -> {
          let #(memory, cycle) =
            rejection(
              cycle:,
              deployment: target.deployment_name,
              pod:,
              memory:,
              operations:,
              purpose: observability.Apply,
              status:,
            )
          #(pod, memory, cycle)
        }
        // Accepted without a view: the runs end, and nothing more is due on
        // the pod until the next LIST supplies the pod (reconcile Sequence).
        Error(AcceptedUnseen) -> #(
          pod,
          Memory(..accepted(memory), stale: True),
          cycle,
        )
        Error(OtherFailure) -> #(pod, memory, cycle)
      }
    }
  }
}

/// Why a patch returned no pod: the 422 a failed precondition returns, the
/// 400 or 403 that is a rejection at once (ownership Rejected), a 2xx
/// whose body gives no usable view, which is still an accepted patch
/// (k8s_client Verbs; observability Events Rejected), or anything else,
/// which the next LIST sorts out (ownership Precondition).
type PatchFailure {
  PreconditionFailed
  Rejected(status: Int)
  AcceptedUnseen
  OtherFailure
}

/// Sends one patch, logs it, counts it on knarr_patches_total by its
/// result (observability Patches) and records the attempt on the cycle, so
/// a turn can answer with its outcome: a 429 is counted once, as throttled,
/// and is `OtherFailure` to the callers, which read it off the attempt. An
/// undecodable body answers a 2xx, since the client decodes one only after
/// its success-status guard, so it is counted and answered as accepted.
fn send_patch(
  cycle cycle: Cycle,
  target target: Target,
  pod pod: Pod,
  operations operations: List(Operation),
  purpose purpose: observability.Purpose,
) -> #(Cycle, Result(Pod, PatchFailure)) {
  let config = cycle.config
  let keys = ownership.keys(operations)
  let label = observability.purpose_label(purpose)
  let fields = [
    observability.string_field(
      name: "deployment",
      value: target.deployment_name,
    ),
    observability.string_field(name: "pod", value: pod.name),
    observability.string_field(name: "purpose", value: label),
    observability.strings_field(name: "keys", values: keys),
  ]
  let result =
    k8s_client.patch_pod(
      target: config.target,
      namespace: cycle.namespace,
      pod: pod.name,
      token: cycle.token,
      document: ownership.document(operations),
      send: config.send,
    )
  let outcome = case result {
    Ok(patched) -> {
      log(
        observability.Debug,
        "patch",
        list.append(fields, [
          observability.int_field(name: "status", value: 200),
        ]),
      )
      Ok(patched)
    }
    Error(error) -> {
      log(observability.Debug, "patch", list.append(fields, describe(error)))
      case error {
        k8s_client.Refused(failure) ->
          case
            k8s_client.precondition_failed(failure),
            observability.patch_result(Some(failure.status))
          {
            True, _ -> Error(PreconditionFailed)
            False, "rejected" -> Error(Rejected(failure.status))
            False, _ -> Error(OtherFailure)
          }
        k8s_client.UndecodableBody(_) -> Error(AcceptedUnseen)
        k8s_client.SendFailed(_) -> Error(OtherFailure)
      }
    }
  }
  let #(status, retry_after) = case result {
    Ok(_) | Error(k8s_client.UndecodableBody(_)) -> #(Some(200), None)
    Error(k8s_client.Refused(failure)) -> #(
      Some(failure.status),
      failure.retry_after,
    )
    Error(k8s_client.SendFailed(_)) -> #(None, None)
  }
  let cycle =
    count(cycle:, name: observability.patches_total, labels: [
      target.deployment_name,
      label,
      observability.patch_result(status),
    ])
  #(Cycle(..cycle, attempt: Some(Attempt(status:, retry_after:))), outcome)
}

// ------------------------------------------------------- Events and lines ---

/// One create attempt of an Event, counted on knarr_events_total, with its
/// warning line before and a second line if the create fails (observability
/// Events Conventions, AlsoLogged).
fn raise(
  cycle cycle: Cycle,
  involved involved: k8s_client.InvolvedObject,
  reason reason: String,
  message message: String,
  msg msg: String,
  fields fields: List(Field),
) -> Cycle {
  let config = cycle.config
  log(observability.Warning, msg, [
    observability.string_field(name: "reason", value: reason),
    ..fields
  ])
  let event = k8s_client.Event(involved:, reason:, message:, at: cycle.at)
  case
    k8s_client.create_event(
      target: config.target,
      namespace: cycle.namespace,
      token: cycle.token,
      event:,
      send: config.send,
    )
  {
    Ok(Nil) ->
      count(cycle:, name: observability.events_total, labels: [
        reason,
        "created",
      ])
    Error(error) -> {
      log(observability.Warning, "event create failed", [
        observability.string_field(name: "reason", value: reason),
        ..describe(error)
      ])
      count(cycle:, name: observability.events_total, labels: [reason, "failed"])
    }
  }
}

/// The current entries of the states announced on entry, what entered, and
/// the Events and lines for each (reconcile Absent, NotReadyWithCost;
/// observability Cadence OnEntry), from each pod's newest view and latest
/// reading. A terminating pod is in no state, and a pod with no reading yet
/// is in none either: absent takes readings, and NotReady with cost a known
/// one.
fn announce(
  seen seen: List(Entry),
  pods pods: List(#(Target, Memory)),
  cycle cycle: Cycle,
) -> #(List(Entry), Cycle) {
  let current =
    list.flat_map(pods, fn(item) { entries(target: item.0, memory: item.1) })
  let cycle =
    observability.entered(seen:, current:)
    |> list.fold(cycle, fn(cycle, entry) {
      case list.find(pods, fn(item) { { item.1 }.pod.name == entry.pod_name }) {
        Ok(item) -> announce_one(cycle:, entry:, item:)
        // Every entry comes from `pods`, so this arm is unreachable.
        Error(Nil) -> cycle
      }
    })
  #(current, cycle)
}

/// The announced states one pod is in, from its newest view and latest
/// reading: contract_absent from reconcile's state, not_ready_with_cost and
/// foreign from the view (observability OnEntry; ownership Adoption). A
/// terminating pod is in no state, and a pod with no reading yet is in none
/// either: absent takes readings, NotReady with cost a known one, and a
/// foreign annotation is announced with the pod's first reading, as the
/// other two are. The rejection runs are not here: they are held per pod
/// and announced by `rejection` as they start.
fn entries(target target: Target, memory memory: Memory) -> List(Entry) {
  let pod = memory.pod
  case pod.deletion_timestamp, memory.latest {
    None, Some(_) -> {
      let absent = case memory.state.kind {
        reconcile.Absent -> [
          Entry(
            pod_name: pod.name,
            annotation: None,
            state: observability.ContractAbsent,
          ),
        ]
        _ -> []
      }
      let views = view(target:, pod:, marker: ownership.read(pod.annotations))
      let not_ready = case not_ready_with_cost(pod:, memory:, views:) {
        True -> [
          Entry(
            pod_name: pod.name,
            annotation: None,
            state: observability.NotReadyWithCost,
          ),
        ]
        False -> []
      }
      list.flatten([absent, not_ready, foreign_entries(pod:, views:)])
    }
    _, _ -> []
  }
}

/// One foreign entry per considered owned annotation standing foreign on
/// the pod (ownership Adoption; observability Cadence OnEntry).
fn foreign_entries(pod pod: Pod, views views: Views) -> List(Entry) {
  list.filter_map([views.cost, views.safe], fn(owned) {
    case owned.considered && owned.standing == ownership.Foreign {
      True ->
        Ok(Entry(
          pod_name: pod.name,
          annotation: Some(owned.owned.name),
          state: observability.ForeignAnnotation,
        ))
      False -> Error(Nil)
    }
  })
}

/// A pod is NotReady with cost while its Ready condition is false, a
/// reading of it is known and not neutral, and its applied value is above 0
/// (reconcile NotReadyWithCost). A pod's first memory is not neutral but
/// has no reading, hence the second test.
fn not_ready_with_cost(
  pod pod: Pod,
  memory memory: Memory,
  views views: Views,
) -> Bool {
  !pod.ready
  && option.is_some(memory.latest)
  && !reconcile.neutral(memory.state)
  && views.cost.applied.usable
  && views.cost.applied.value > 0
}

/// The Event and line of one entry (observability Events ContractAbsent,
/// Logs StateLines, Lines).
fn announce_one(
  cycle cycle: Cycle,
  entry entry: Entry,
  item item: #(Target, Memory),
) -> Cycle {
  let #(target, memory) = item
  let pod = memory.pod
  case entry.state, memory.latest {
    observability.ContractAbsent, Some(#(reading, _)) -> {
      let event =
        observability.AbsentEvent(
          deployment_name: target.deployment_name,
          deployment_uid: target.deployment_uid,
          pod_name: pod.name,
          port: target.settings.status_port,
          path: target.settings.status_path,
          reading: observability_kind(reading.kind),
        )
      raise(
        cycle:,
        involved: k8s_client.DeploymentObject(
          name: target.deployment_name,
          uid: target.deployment_uid,
        ),
        reason: observability.contract_absent,
        message: observability.absent_message(event),
        msg: "contract absent",
        fields: [
          observability.string_field(
            name: "deployment",
            value: target.deployment_name,
          ),
          observability.string_field(name: "pod", value: pod.name),
          observability.int_field(name: "port", value: event.port),
          observability.string_field(name: "path", value: event.path),
          observability.string_field(
            name: "reading",
            value: reading_label(reading.kind),
          ),
        ],
      )
    }
    // An absent entry has a reading, since the state takes readings to
    // enter, so this arm is unreachable.
    observability.ContractAbsent, None -> cycle
    observability.NotReadyWithCost, _ -> {
      let views = view(target:, pod:, marker: ownership.read(pod.annotations))
      log(observability.Warning, "not ready with cost", [
        observability.string_field(
          name: "deployment",
          value: target.deployment_name,
        ),
        observability.string_field(name: "pod", value: pod.name),
        observability.int_field(
          name: "applied",
          value: views.cost.applied.value,
        ),
      ])
      cycle
    }
    observability.ForeignAnnotation, _ -> {
      foreign_line(target:, pod:, annotation: entry.annotation)
      cycle
    }
    // `entries` never puts a rejection run in `current`: `rejection`
    // announces it when it starts.
    observability.Rejected, _ | observability.CleanupRejected, _ -> cycle
  }
}

/// The "foreign annotation" line: the owned annotation's name, its key and
/// the value found on the pod (observability Logs Lines); no Event
/// (ownership Adoption).
fn foreign_line(
  target target: Target,
  pod pod: Pod,
  annotation annotation: Option(String),
) -> Nil {
  let owned =
    list.find(ownership.owned_annotations, fn(o) { Some(o.name) == annotation })
  case owned {
    Ok(owned) -> {
      let value =
        pod.annotations
        |> option.then(fn(map) {
          dict.get(map, owned.key) |> option.from_result
        })
      log(observability.Warning, "foreign annotation", [
        observability.string_field(
          name: "deployment",
          value: target.deployment_name,
        ),
        observability.string_field(name: "pod", value: pod.name),
        observability.string_field(name: "annotation", value: owned.name),
        observability.string_field(name: "key", value: owned.key),
        observability.string_field(name: "value", value: absent(value)),
      ])
    }
    // Every foreign entry names one of the two owned annotations.
    Error(Nil) -> Nil
  }
}

// ---------------------------------------------------------------- Gauges ---

/// Every per-Deployment gauge series of this cycle (observability Tiers,
/// Standing; reconcile Gauges, NotReadyWithCost), from each pod's newest
/// view and latest reading. A terminating pod counts on none of them. A pod
/// that is not a target, given by its View in `others`, counts only on
/// knarr_annotations, under its View's deployment and only for an
/// annotation standing owned, so a yielded or conflict record an opt-out
/// leaves counts nowhere (observability Standing).
fn gauges(
  targets targets: List(Target),
  pods pods: List(#(Target, Memory)),
  others others: List(lifecycle.View),
) -> List(Series) {
  let other_standings = fn(name) {
    others
    |> list.filter(fn(view) { view.deployment == name && !view.terminating })
    |> list.flat_map(fn(view) {
      list.filter_map(view.held, fn(held) {
        case held.standing {
          lifecycle.HeldOwned -> Ok(#(held.name, "owned"))
          lifecycle.HeldConflict | lifecycle.HeldYielded -> Error(Nil)
        }
      })
    })
  }
  let annotations = fn(name, pairs) {
    counted(pairs, fn(pair: #(String, String)) {
      Series(observability.annotations, [
        observability.Label("deployment", name),
        observability.Label("annotation", pair.0),
        observability.Label("standing", pair.1),
      ])
    })
  }
  let names =
    list.map(targets, fn(target) { target.deployment_name }) |> list.unique
  let others_only =
    others
    |> list.map(fn(view) { view.deployment })
    |> list.unique
    |> list.filter(fn(name) { !list.contains(names, name) })
    |> list.flat_map(fn(name) { annotations(name, other_standings(name)) })
  targets
  |> list.map(fn(target) {
    #(target.deployment_name, target.settings.thresholds)
  })
  |> list.unique
  |> list.flat_map(fn(deployment) {
    let #(name, thresholds) = deployment
    let live =
      list.filter(pods, fn(item) {
        { item.0 }.deployment_name == name
        && option.is_none({ item.1 }.pod.deletion_timestamp)
      })
    let views =
      list.map(live, fn(item) {
        let #(target, memory) = item
        let pod = memory.pod
        #(
          pod,
          memory,
          view(target:, pod:, marker: ownership.read(pod.annotations)),
        )
      })
    let tiers =
      views
      |> list.filter_map(fn(item) {
        let cost = { item.2 }.cost
        case cost.standing {
          ownership.Unowned | ownership.OwnedByKnarr ->
            Ok(observability.tier(value: cost.applied.value, thresholds:))
          _ -> Error(Nil)
        }
      })
      |> counted(fn(tier) {
        Series(observability.pods, [
          observability.Label("deployment", name),
          observability.Label("tier", tier),
        ])
      })
    let standings =
      views
      |> list.flat_map(fn(item) {
        list.filter_map([{ item.2 }.cost, { item.2 }.safe], fn(owned) {
          case owned.considered, standing_label(owned.standing) {
            True, Some(standing) -> Ok(#(owned.owned.name, standing))
            _, _ -> Error(Nil)
          }
        })
      })
      |> list.append(other_standings(name))
      |> annotations(name, _)
    let by_state = fn(metric, predicate: fn(Pod, Memory, Views) -> Bool) {
      let count =
        list.count(views, fn(item) { predicate(item.0, item.1, item.2) })
      #(Series(metric, [observability.Label("deployment", name)]), count)
    }
    [
      by_state(observability.pods_unknown, fn(_, memory, _) {
        memory.state.kind == reconcile.Unknown
      }),
      by_state(observability.pods_contract_absent, fn(_, memory, _) {
        memory.state.kind == reconcile.Absent
      }),
      by_state(observability.pods_not_ready_with_cost, not_ready_with_cost),
      ..list.append(tiers, standings)
    ]
  })
  |> list.append(others_only)
  |> list.map(fn(pair) {
    let #(series, value) = pair
    metrics.set(series.name, list.map(series.labels, fn(l) { l.value }), value)
    series
  })
}

fn counted(items: List(a), series: fn(a) -> Series) -> List(#(Series, Int)) {
  items
  |> list.group(fn(item) { item })
  |> dict.to_list
  |> list.map(fn(group) { #(series(group.0), list.length(group.1)) })
}

fn standing_label(standing: Standing) -> Option(String) {
  case standing {
    ownership.Unowned -> None
    ownership.OwnedByKnarr -> Some("owned")
    Conflict -> Some("conflict")
    ownership.Yielded -> Some("yielded")
    ownership.Foreign -> Some("foreign")
  }
}

/// Removes every gauge series of the last cycle this cycle did not set, so a
/// tier or standing that vanished leaves the exposition.
fn rebuild(previous: List(Series), current: List(Series)) -> List(Series) {
  previous
  |> list.filter(fn(series) { !list.contains(current, series) })
  |> list.each(fn(series) {
    metrics.remove(series.name, list.map(series.labels, fn(l) { l.value }))
  })
  current
}

/// Removes every series labelled with a Deployment that left (observability
/// SeriesLife).
fn retire(series: List(Series), deployment: String) -> List(Series) {
  let kept = observability.retire(series:, deployment:)
  series
  |> list.filter(fn(s) { !list.contains(kept, s) })
  |> list.each(fn(s) {
    metrics.remove(s.name, list.map(s.labels, fn(l) { l.value }))
  })
  kept
}

/// Increments a counter series and remembers it for retirement.
fn count(
  cycle cycle: Cycle,
  name name: String,
  labels labels: List(String),
) -> Cycle {
  Cycle(..cycle, counters: remember(counters: cycle.counters, name:, labels:))
}

/// `count` for a step before the cycle has its `Cycle`: the LISTs.
fn remember(
  counters counters: List(Series),
  name name: String,
  labels labels: List(String),
) -> List(Series) {
  metrics.inc(name, labels)
  let series =
    Series(
      name,
      list.map2(metrics.label_names(name), labels, observability.Label),
    )
  case list.contains(counters, series) {
    True -> counters
    False -> [series, ..counters]
  }
}

// --------------------------------------------------------------- Helpers ---

fn reading_label(kind: reconcile.ReadingKind) -> String {
  observability.reading_label(observability_kind(kind))
}

fn observability_kind(
  kind: reconcile.ReadingKind,
) -> observability.ReadingKind {
  case kind {
    reconcile.Valid -> observability.Valid
    reconcile.NotFound -> observability.NotFound
    reconcile.Invalid -> observability.Invalid
    reconcile.Refused -> observability.Refused
    reconcile.TimedOut -> observability.TimedOut
    reconcile.Unreachable -> observability.Unreachable
  }
}

fn absent(value: Option(String)) -> String {
  option.unwrap(value, "absent")
}

fn jwt_exp(token: String) -> String {
  case token.jwt_expiry(token) {
    Ok(exp) -> int.to_string(exp)
    Error(token.NotThreeSegments) -> "not_a_jwt"
    Error(token.NotBase64Url) -> "claims_not_base64url"
    Error(token.NotJsonClaims) -> "claims_not_json"
    Error(token.NoExpClaim) -> "no_exp_claim"
    Error(token.ExpNotAnInteger) -> "exp_not_an_integer"
  }
}

/// A client error as log fields: the status of a refusal, or the transport
/// failure; never the body (observability NeverLogged).
fn describe(error: k8s_client.ClientError(SendError)) -> List(Field) {
  case error {
    k8s_client.Refused(failure) -> [
      observability.int_field(name: "status", value: failure.status),
    ]
    k8s_client.UndecodableBody(_) -> [
      observability.string_field(name: "error", value: "undecodable_body"),
    ]
    k8s_client.SendFailed(k8s_http.TlsAlert(alert)) -> [
      observability.string_field(name: "error", value: "tls_alert " <> alert),
    ]
    k8s_client.SendFailed(k8s_http.ConnectFailed(reason)) -> [
      observability.string_field(
        name: "error",
        value: "connect_failed " <> reason,
      ),
    ]
    k8s_client.SendFailed(k8s_http.Timeout) -> [
      observability.string_field(name: "error", value: "timeout"),
    ]
    k8s_client.SendFailed(k8s_http.Other(reason)) -> [
      observability.string_field(name: "error", value: "other " <> reason),
    ]
  }
}

@external(erlang, "observability_ffi", "log")
fn log(level: Level, msg: String, fields: List(Field)) -> Nil

/// Why a file could not be read: the POSIX reason, such as `enoent`.
type ReadError {
  ReadFailed(reason: String)
}

@external(erlang, "reconciler_ffi", "read_file")
fn read_file(path: String) -> Result(String, ReadError)

@external(erlang, "reconciler_ffi", "sha256_hex12")
fn sha256_hex12(data: String) -> String

@external(erlang, "reconciler_ffi", "unix_milliseconds")
fn unix_milliseconds() -> Int

@external(erlang, "reconciler_ffi", "rfc3339")
fn rfc3339(seconds: Int) -> String
