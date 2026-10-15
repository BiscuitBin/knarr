//// The reconcile process: the driver on the LIST timer that reconcile's
//// Loop Cycle states (docs/specs/reconcile.allium). Every tick it reads the
//// token and the namespace, runs one discovery cycle of three LISTs, derives
//// the target set (config Discovery), remembers every target's newest view,
//// rebuilds the gauges and announces the states from the latest readings,
//// and hands the scheduler the listed pods and the joiners, the targets
//// with a pod IP (budget Leaving, reconcile NoPodIp). Each reading comes
//// back from the scheduler on its own, at the pod's rung; the reconciler
//// observes it into the pod's memory, decides the pod's desired state
//// against its marker and, until the patcher is wired (ticket 46, chunk
//// F2), sends each due write and yield at once through
//// `k8s_client.patch_pod`. It raises the Events and lines observability
//// names and latches readiness.
////
//// Every decision is a pure function of `reconcile`, `config`, `ownership`,
//// `cost_mapping` and `observability`; the effects are the injected `send`,
//// `poll`, `now`, `random` and `mark_ready`, and `reconciler_ffi` for the
//// files and the token's hash. The reconciler runs last in a set of four
//// under one supervisor, with the poll-worker factory, the scheduler and
//// the patcher, so a crash of any restarts them together (budget Restart).
//// The three actors reach each other by name, through one guarded send.

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
import knarr/config.{type Installed, type Target}
import knarr/cost_mapping.{Mapped}
import knarr/k8s_client.{type Deployment, type Pod, type ReplicaSet}
import knarr/k8s_http.{type SendError, Tls}
import knarr/metrics
import knarr/observability.{
  type Entry, type Field, type Level, type Series, Entry, Series,
}
import knarr/ownership.{
  type Marker, type Operation, type Owned, type Standing, AppliedRecord,
  Conflict, Write,
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
  /// The LIST timer, or the initialiser's first cycle.
  Tick
  /// From the scheduler: one reading returned for a target pod.
  Polled(scheduler.Polled)
  /// From the patcher: a turn to patch one pod. Wired in chunk F2 of
  /// ticket 46; nothing sends the patcher a `Due` until then, so no turn
  /// arrives.
  Turn(patcher.Turn)
  /// From the patcher: nothing of a departed Deployment's pods is pending
  /// or in turn. Wired in chunk F2 of ticket 46 with `Turn`.
  Quiet(deployment: String)
}

/// What this process keeps for one target pod across cycles: its reading
/// state, the operations of a patch a 422 refused until the next LIST
/// classifies them (reconcile Rejected422), its newest view, the LIST's or
/// a patch response (reconcile Sequence), and its latest reading with the
/// clock it came at, none before its first poll returns (JustStarted).
type Memory {
  Memory(
    state: PodState,
    kept: Option(List(Operation)),
    pod: Pod,
    latest: Option(#(Reading, Int)),
  )
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
/// shutdown, which stops the children in reverse start order, is dropped: a
/// plain `process.send` to an unregistered name crashes the sender. The one
/// place a message crosses between the set's processes.
fn notify(name: Name(message), message: message) -> Nil {
  case process.named(name) {
    Ok(_) -> process.send(process.named_subject(name), message)
    Error(Nil) -> Nil
  }
}

/// Starts the reconciler under its name. Its initialiser touches nothing
/// outside the VM: it drops the per-Deployment series a process before it
/// left in the registry (observability SeriesLife) and schedules the first
/// tick at once, so readiness latches as soon as the first cycle can run.
/// The selector takes the name, for the other two processes and a test,
/// and the plain subject the ticks come on.
fn start_reconciler(config: Config) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(self) {
    metrics.reset_deployment_series()
    let ticks = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select(ticks)
    process.send(ticks, Tick)
    actor.initialised(State(
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
    ))
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
    Tick -> {
      let state = tick(state)
      process.send_after(state.ticks, state.config.interval_ms, Tick)
      actor.continue(state)
    }
    Polled(returned) -> actor.continue(polled(state, returned))
    // Chunk F2 of ticket 46 answers a turn with one attempt and retires a
    // quiet Deployment's series; until then neither arrives.
    Turn(_) -> actor.continue(state)
    Quiet(_) -> actor.continue(state)
  }
}

// ------------------------------------------------------------- The cycle ---

fn tick(state: State) -> State {
  let config = state.config
  case read_file(config.token_file) {
    Error(ReadFailed(reason)) -> {
      log(observability.Error, "token unreadable", [
        observability.string_field(name: "reason", value: reason),
      ])
      state
    }
    Ok(token) -> {
      let token = string.trim(token)
      let state = note_token(state, token)
      case read_file(config.namespace_file) {
        Error(ReadFailed(reason)) -> {
          log(observability.Error, "namespace unreadable", [
            observability.string_field(name: "reason", value: reason),
          ])
          state
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

/// What one cycle carries through its steps: the credentials, the clock
/// readings, and the counter series incremented so far.
type Cycle {
  Cycle(
    config: Config,
    namespace: String,
    token: String,
    now: Int,
    at: String,
    counters: List(Series),
  )
}

fn cycle(
  state state: State,
  namespace namespace: String,
  token token: String,
) -> State {
  let config = state.config
  let started_ms = unix_milliseconds()
  let lists = {
    use pods <- try_list("pods", fn() {
      k8s_client.list_pods(
        target: config.target,
        namespace:,
        token:,
        send: config.send,
      )
    })
    use replica_sets <- try_list("replicasets", fn() {
      k8s_client.list_replica_sets(
        target: config.target,
        namespace:,
        token:,
        send: config.send,
      )
    })
    use deployments <- try_list("deployments", fn() {
      k8s_client.list_deployments(
        target: config.target,
        namespace:,
        token:,
        send: config.send,
      )
    })
    Ok(#(pods, replica_sets, deployments))
  }
  case lists {
    Error(Nil) -> state
    Ok(#(pods, replica_sets, deployments)) -> {
      // One clock reading after the LISTs is the time of the cycle's
      // Events and gauges; each reading and write has the clock of its own
      // return (reconcile Cycle).
      let now = config.now()
      discovered(
        state:,
        cycle: Cycle(
          config:,
          namespace:,
          token:,
          now:,
          at: rfc3339(now / 1000),
          counters: state.counters,
        ),
        pods:,
        replica_sets:,
        deployments:,
        started_ms:,
      )
    }
  }
}

/// One LIST; a failure ends the cycle with an error line (Logs Lines) and
/// the previous target set stands (config Discovery).
fn try_list(
  resource: String,
  list: fn() -> Result(a, k8s_client.ClientError(SendError)),
  next: fn(a) -> Result(b, Nil),
) -> Result(b, Nil) {
  case list() {
    Ok(items) -> next(items)
    Error(error) -> {
      log(observability.Error, "list failed", [
        observability.string_field(name: "resource", value: resource),
        ..describe(error)
      ])
      Error(Nil)
    }
  }
}

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
  // Every target's memory, kept from the last cycle or begun here, with the
  // LIST's view as its newest and a 422's operations classified against it
  // (reconcile Rejected422, Sequence). A memory of a pod the LIST no longer
  // shows is dropped with it.
  let memories =
    list.filter_map(targets, fn(target) {
      case list.find(pods, fn(pod) { pod.name == target.pod_name }) {
        Ok(pod) -> {
          let memory =
            dict.get(state.pods, pod.name)
            |> option.from_result
            |> option.unwrap(Memory(
              state: reconcile.initial(),
              kept: None,
              pod:,
              latest: None,
            ))
          Ok(#(target, classify_kept(Memory(..memory, pod:), pod)))
        }
        // Every target is one of the listed pods, so this arm is unreachable.
        Error(Nil) -> Error(Nil)
      }
    })
  let gauges = gauges(targets:, pods: memories)
  let state = State(..state, gauges: rebuild(state.gauges, gauges))
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
  notify(
    config.names.scheduler,
    scheduler.Listed(
      listed: list.map(targets, fn(target) { target.pod_name }),
      joining:,
    ),
  )
  let memories =
    list.fold(memories, dict.new(), fn(acc, item) {
      dict.insert(acc, { item.0 }.pod_name, item.1)
    })
  // A Deployment has left when no current target carries its name: the
  // series are labelled by name, so one recreated under the same name
  // between two LISTs keeps them (observability SeriesLife).
  let gone =
    list.filter_map(state.targets, fn(previous) {
      case
        list.any(targets, fn(t) {
          t.deployment_name == previous.deployment_name
        })
      {
        True -> Error(Nil)
        False -> Ok(previous.deployment_name)
      }
    })
    |> list.unique
  let #(gauges, counters) =
    list.fold(gone, #(state.gauges, cycle.counters), fn(acc, deployment) {
      #(retire(acc.0, deployment), retire(acc.1, deployment))
    })
  State(..state, targets:, pods: memories, seen:, invalid:, gauges:, counters:)
}

// ----------------------------------------------------------- One reading ---

/// A reading the scheduler returned: logged and counted, observed into the
/// pod's memory at the clock it came at (reconcile Cycle), and, until chunk
/// F2 of ticket 46 hands the decision to the patcher, acted on at once from
/// the pod's newest view, the patch response becoming that view (Sequence).
/// A reading of a pod no LIST has shown since, or one before any cycle has
/// run, has nowhere to land and is dropped.
fn polled(state: State, returned: scheduler.Polled) -> State {
  let pod_name = returned.pod_name
  let target =
    list.find(state.targets, fn(target) { target.pod_name == pod_name })
  case state.session, dict.get(state.pods, pod_name), target {
    Some(#(namespace, token)), Ok(memory), Ok(target) -> {
      let config = state.config
      let now = returned.at_ms
      let reading = returned.reading
      let cycle =
        Cycle(
          config:,
          namespace:,
          token:,
          now:,
          at: rfc3339(now / 1000),
          counters: state.counters,
        )
      let cycle =
        polled_line(cycle:, target:, endpoint: returned.endpoint, reading:)
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
      let #(pod, memory, cycle) =
        act(cycle:, target:, pod: memory.pod, memory:, reading:)
      State(
        ..state,
        pods: dict.insert(state.pods, pod_name, Memory(..memory, pod:)),
        counters: cycle.counters,
      )
    }
    _, _, _ -> state
  }
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
  cycle cycle: Cycle,
  target target: Target,
  endpoint endpoint: Endpoint,
  reading reading: Reading,
) -> Cycle {
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
  count(cycle:, name: observability.polls_total, labels: [
    target.deployment_name,
    kind,
  ])
}

/// A 422's operations are classified against the next LIST's view and then
/// forgotten (reconcile Rejected422). Acting on a rejection is ticket 32's.
fn classify_kept(memory: Memory, pod: Pod) -> Memory {
  case memory.kept {
    None -> memory
    Some(operations) -> {
      let _rejected =
        ownership.rejected(
          operations:,
          annotations: pod.annotations,
          deletion_timestamp: pod.deletion_timestamp,
        )
      Memory(..memory, kept: None)
    }
  }
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
  let cost_record = ownership.record(marker, ownership.pod_deletion_cost)
  let applied =
    reconcile.parse_applied(ownership.applied_value(
      marker:,
      owned: ownership.pod_deletion_cost,
    ))
  let cost_standing = case cost_record, applied.usable {
    Some(AppliedRecord(..)), False -> Conflict
    _, _ ->
      ownership.standing(
        marker:,
        annotations: pod.annotations,
        owned: ownership.pod_deletion_cost,
      )
  }
  let safe_record = ownership.record(marker, ownership.safe_to_evict)
  let safe_value =
    ownership.applied_value(marker:, owned: ownership.safe_to_evict)
  let safe_standing = case
    safe_record,
    reconcile.safe_to_evict_usable(safe_value)
  {
    Some(AppliedRecord(..)), False -> Conflict
    _, _ ->
      ownership.standing(
        marker:,
        annotations: pod.annotations,
        owned: ownership.safe_to_evict,
      )
  }
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

/// Decides and sends for one pod: yields first, then the due writes from
/// the newest view (reconcile Sequence, Terminating).
fn act(
  cycle cycle: Cycle,
  target target: Target,
  pod pod: Pod,
  memory memory: Memory,
  reading reading: Reading,
) -> #(Pod, Memory, Cycle) {
  case pod.deletion_timestamp {
    Some(_) -> #(pod, memory, cycle)
    None -> {
      let marker = ownership.read(pod.annotations)
      let views = view(target:, pod:, marker:)
      let conflicts =
        [views.cost, views.safe]
        |> list.filter(fn(owned) {
          owned.considered && owned.standing == Conflict
        })
      case yields(cycle:, target:, pod:, marker:, conflicts:, memory:) {
        Ok(#(pod, cycle)) -> write(cycle:, target:, pod:, memory:, reading:)
        Error(#(memory, cycle)) -> #(pod, memory, cycle)
      }
    }
  }
}

/// One yield per conflicting annotation, each from the view the one before
/// left: the pod every yield was accepted on, or, when a yield was refused,
/// which ends the pod's turn, the memory, holding a 422's operations for the
/// next LIST (reconcile Rejected422).
fn yields(
  cycle cycle: Cycle,
  target target: Target,
  pod pod: Pod,
  marker marker: Marker,
  conflicts conflicts: List(OwnedView),
  memory memory: Memory,
) -> Result(#(Pod, Cycle), #(Memory, Cycle)) {
  case conflicts {
    [] -> Ok(#(pod, cycle))
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
      case send_patch(cycle:, target:, pod:, operations:, purpose: "yield") {
        Ok(pod) -> {
          let cycle =
            count(cycle:, name: observability.yields_total, labels: [
              target.deployment_name,
              conflict.owned.name,
            ])
          let cycle =
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
                observability.string_field(
                  name: "annotation",
                  value: conflict.owned.name,
                ),
                observability.string_field(
                  name: "applied",
                  value: absent(event.applied),
                ),
                observability.string_field(
                  name: "found",
                  value: absent(event.found),
                ),
              ],
            )
          yields(
            cycle:,
            target:,
            pod:,
            marker: ownership.read(pod.annotations),
            conflicts: rest,
            memory:,
          )
        }
        // A refused yield raises nothing: the conflict is seen again from
        // the next LIST (ownership Event), which also classifies a 422's
        // operations.
        Error(PreconditionFailed) ->
          Error(#(Memory(..memory, kept: Some(operations)), cycle))
        Error(OtherFailure) -> Error(#(memory, cycle))
      }
    }
  }
}

/// The due writes may_write allows, in one patch (reconcile Desired, Due;
/// ownership WriteMode).
fn write(
  cycle cycle: Cycle,
  target target: Target,
  pod pod: Pod,
  memory memory: Memory,
  reading reading: Reading,
) -> #(Pod, Memory, Cycle) {
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
  case
    ownership.patch(
      marker:,
      annotations: pod.annotations,
      writes:,
      at: cycle.at,
    )
  {
    [] -> #(pod, memory, cycle)
    operations ->
      case send_patch(cycle:, target:, pod:, operations:, purpose: "apply") {
        Ok(pod) -> #(pod, memory, cycle)
        Error(PreconditionFailed) -> #(
          pod,
          Memory(..memory, kept: Some(operations)),
          cycle,
        )
        Error(OtherFailure) -> #(pod, memory, cycle)
      }
  }
}

/// Why a patch returned no pod: the 422 a failed precondition returns, or
/// anything else, which the next LIST sorts out (ownership Precondition).
type PatchFailure {
  PreconditionFailed
  OtherFailure
}

/// Sends one patch and logs it.
fn send_patch(
  cycle cycle: Cycle,
  target target: Target,
  pod pod: Pod,
  operations operations: List(Operation),
  purpose purpose: String,
) -> Result(Pod, PatchFailure) {
  let config = cycle.config
  let keys = ownership.keys(operations)
  let fields = [
    observability.string_field(
      name: "deployment",
      value: target.deployment_name,
    ),
    observability.string_field(name: "pod", value: pod.name),
    observability.string_field(name: "purpose", value: purpose),
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
  case result {
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
          case k8s_client.precondition_failed(failure) {
            True -> Error(PreconditionFailed)
            False -> Error(OtherFailure)
          }
        k8s_client.SendFailed(_) | k8s_client.UndecodableBody(_) ->
          Error(OtherFailure)
      }
    }
  }
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
    list.flat_map(pods, fn(item) {
      let #(target, memory) = item
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
          let views =
            view(target:, pod:, marker: ownership.read(pod.annotations))
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
          list.append(absent, not_ready)
        }
        _, _ -> []
      }
    })
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
/// Logs StateLines).
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
    _, _ -> {
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
  }
}

// ---------------------------------------------------------------- Gauges ---

/// Every per-Deployment gauge series of this cycle (observability Tiers,
/// Standing; reconcile Gauges, NotReadyWithCost), from each pod's newest
/// view and latest reading. A terminating pod counts on none of them.
fn gauges(
  targets targets: List(Target),
  pods pods: List(#(Target, Memory)),
) -> List(Series) {
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
      |> counted(fn(pair) {
        Series(observability.annotations, [
          observability.Label("deployment", name),
          observability.Label("annotation", pair.0),
          observability.Label("standing", pair.1),
        ])
      })
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
  metrics.inc(name, labels)
  let series =
    Series(
      name,
      list.map2(metrics.label_names(name), labels, observability.Label),
    )
  case list.contains(cycle.counters, series) {
    True -> cycle
    False -> Cycle(..cycle, counters: [series, ..cycle.counters])
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
