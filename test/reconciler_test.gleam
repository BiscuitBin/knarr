//// The reconcile process against closure fakes (reconcile Loop Cycle,
//// docs/specs/reconcile.allium): a scripted apiserver answers the three
//// LISTs, the patches and the Event creates and forwards every request to
//// the test; a scripted poll answers each pod; the clock, the draw and
//// readiness are injected. The reconciler runs in its set beside the
//// scheduler, the patcher and the poll-worker factory. Each cycle is driven
//// by a Tick the test sends, with the timer held off; the draw is 0, so a
//// pod the LIST joins is polled at once, its due change is handed to the
//// patcher and its patch follows on the turn within the second; a Wake the
//// test sends moves the scheduler's or the patcher's clock between LISTs.

import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/system
import gleam/result
import gleam/string
import gleeunit/should
import knarr/budget
import knarr/config.{Defaults, Installed}
import knarr/k8s_client
import knarr/k8s_http
import knarr/metrics
import knarr/observability
import knarr/patcher
import knarr/poller.{type Endpoint}
import knarr/reconcile
import knarr/reconciler
import knarr/runtime
import knarr/scheduler

pub type Table

@external(erlang, "reconciler_test_ffi", "table_new")
fn table_new() -> Table

@external(erlang, "reconciler_test_ffi", "table_put")
fn put(table: Table, key: String, value: String) -> Nil

@external(erlang, "reconciler_test_ffi", "table_get")
fn get(table: Table, key: String) -> Result(String, Nil)

@external(erlang, "reconciler_test_ffi", "table_append")
fn append(table: Table, key: String, value: String) -> Nil

@external(erlang, "reconciler_test_ffi", "table_list")
fn list_of(table: Table, key: String) -> List(String)

@external(erlang, "reconciler_test_ffi", "capture_logs")
fn capture_logs(table: Table) -> Nil

@external(erlang, "reconciler_test_ffi", "release_logs")
fn release_logs() -> Nil

@external(erlang, "reconciler_test_ffi", "children")
fn children(supervisor: Pid) -> List(Pid)

@external(erlang, "reconciler_test_ffi", "await_new_children")
fn await_new_children(supervisor: Pid, previous: List(Pid)) -> List(Pid)

@external(erlang, "reconciler_ffi", "unix_milliseconds")
fn unix_milliseconds() -> Int

@external(erlang, "reconciler_test_ffi", "stop_root")
fn stop_root(pid: Pid) -> Nil

@external(erlang, "reconciler_test_ffi", "write_file")
fn write_file(path: String, content: String) -> Nil

@external(erlang, "reconciler_test_ffi", "delete_file")
fn delete_file(path: String) -> Nil

const marker_key = "knarr.io/applied"

const cost_key = "controller.kubernetes.io/pod-deletion-cost"

const deployment_uid = "dep-1"

const installed =
  Installed(
    defaults: Defaults(
      status_port: 8080,
      status_path: "/knarr/v1/status",
      thresholds: [300, 900, 1800, 3600],
      threshold_margin: 60,
      poll_interval: 30,
      patch_interval: 60,
      poll_timeout: 1,
    ),
    max_body_bytes: 4096,
    unknown_polls: 3,
    absent_after: 300,
    list_interval: 60,
    poll_concurrency: 2,
    poll_jitter_percent: 10,
    patch_rate_per_second: 5,
    patch_burst: 10,
    backoff_initial: 1,
    backoff_cap: 60,
    log_level: observability.Info,
  )

/// A pod as the scripted LIST serves it. `annotations` is the map's JSON
/// text, "null" for no map.
type PodFixture {
  PodFixture(
    name: String,
    uid: String,
    ip: Option(String),
    annotations: String,
    terminating: Bool,
    ready: Bool,
    owner: String,
  )
}

fn pod(name: String) -> PodFixture {
  PodFixture(
    name:,
    uid: "u-" <> name,
    ip: Some("10.0.0." <> name),
    annotations: "null",
    terminating: False,
    ready: True,
    owner: "rs-1",
  )
}

fn marked(cost: String, at: String) -> String {
  let marker =
    "{\"at\":\""
    <> at
    <> "\",\"pod-deletion-cost\":{\"applied\":\""
    <> cost
    <> "\",\"at\":\""
    <> at
    <> "\"}}"
  json.object([
    #(cost_key, json.string(cost)),
    #(marker_key, json.string(marker)),
  ])
  |> json.to_string
}

/// A marker owning both annotations: the cost and safe-to-evict given, each
/// on the pod and recorded as applied at 1000.
fn owning_both(cost: String, safe: String) -> String {
  let marker =
    "{\"at\":\""
    <> at(1000)
    <> "\",\"pod-deletion-cost\":{\"applied\":\""
    <> cost
    <> "\",\"at\":\""
    <> at(1000)
    <> "\"},\"safe-to-evict\":{\"applied\":\""
    <> safe
    <> "\",\"at\":\""
    <> at(1000)
    <> "\"}}"
  json.object([
    #(cost_key, json.string(cost)),
    #(ste_key, json.string(safe)),
    #(marker_key, json.string(marker)),
  ])
  |> json.to_string
}

/// The record reconcile's Neutral leaves: the cost removed from the pod and
/// recorded as a null applied value, the marker kept. It stands owned
/// (ownership Adoption).
fn null_record() -> String {
  json.object([
    #(
      marker_key,
      json.string(
        "{\"at\":\""
        <> at(1000)
        <> "\",\"pod-deletion-cost\":{\"applied\":null,\"at\":\""
        <> at(1000)
        <> "\"}}",
      ),
    ),
  ])
  |> json.to_string
}

fn pod_json(fixture: PodFixture) -> String {
  let ip = case fixture.ip {
    Some(ip) -> "\"podIP\":\"" <> ip <> "\","
    None -> ""
  }
  let deletion = case fixture.terminating {
    True -> "\"deletionTimestamp\":\"2026-10-13T10:00:00Z\","
    False -> ""
  }
  let ready = case fixture.ready {
    True -> "True"
    False -> "False"
  }
  "{\"metadata\":{\"name\":\""
  <> fixture.name
  <> "\",\"uid\":\""
  <> fixture.uid
  <> "\","
  <> deletion
  <> "\"annotations\":"
  <> fixture.annotations
  <> ",\"ownerReferences\":[{\"kind\":\"ReplicaSet\",\"name\":\"rs\",\"uid\":\""
  <> fixture.owner
  <> "\",\"controller\":true}]},\"status\":{"
  <> ip
  <> "\"conditions\":[{\"type\":\"Ready\",\"status\":\""
  <> ready
  <> "\"}]}}"
}

fn items(bodies: List(String)) -> String {
  "{\"items\":[" <> string.join(bodies, ",") <> "]}"
}

fn set_pods(table: Table, pods: List(PodFixture)) -> Nil {
  put(table, "pods", items(list.map(pods, pod_json)))
}

fn set_deployment(table: Table, annotations: String) -> Nil {
  let name = get(table, "name") |> result.unwrap("worker")
  put(
    table,
    "deployments",
    items([
      "{\"metadata\":{\"name\":\""
      <> name
      <> "\",\"uid\":\""
      <> deployment_uid
      <> "\",\"labels\":{\"knarr.io/enabled\":\"true\"},\"annotations\":"
      <> annotations
      <> "}}",
    ]),
  )
}

/// The ReplicaSet owned by the Deployment of the uid given.
fn set_replica_set(table: Table, owner_uid: String) -> Nil {
  let name = get(table, "name") |> result.unwrap("worker")
  put(
    table,
    "replicasets",
    items([
      "{\"metadata\":{\"name\":\"rs\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"kind\":\"Deployment\",\"name\":\""
      <> name
      <> "\",\"uid\":\""
      <> owner_uid
      <> "\",\"controller\":true}]}}",
    ]),
  )
}

/// The Deployment deleted and recreated under the same name: a new uid on
/// it and on its ReplicaSet's owner reference.
fn recreate_deployment(table: Table, uid: String) -> Nil {
  let name = get(table, "name") |> result.unwrap("worker")
  set_replica_set(table, uid)
  put(
    table,
    "deployments",
    items([
      "{\"metadata\":{\"name\":\""
      <> name
      <> "\",\"uid\":\""
      <> uid
      <> "\",\"labels\":{\"knarr.io/enabled\":\"true\"},\"annotations\":{}}}",
    ]),
  )
}

/// The Deployment listed without the opt-in label: an opt-out.
fn opt_out(table: Table) -> Nil {
  let name = get(table, "name") |> result.unwrap("worker")
  put(
    table,
    "deployments",
    items([
      "{\"metadata\":{\"name\":\""
      <> name
      <> "\",\"uid\":\""
      <> deployment_uid
      <> "\",\"labels\":{},\"annotations\":{}}}",
    ]),
  )
}

/// The Deployment's ReplicaSet and a second, "other-rs", listed with no
/// owner, as a cascade-orphan deletion of its Deployment leaves it.
fn orphan_replica_set(table: Table) -> Nil {
  let name = get(table, "name") |> result.unwrap("worker")
  put(
    table,
    "replicasets",
    items([
      "{\"metadata\":{\"name\":\"rs\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"kind\":\"Deployment\",\"name\":\""
        <> name
        <> "\",\"uid\":\""
        <> deployment_uid
        <> "\",\"controller\":true}]}}",
      "{\"metadata\":{\"name\":\"other\",\"uid\":\"other-rs\"}}",
    ]),
  )
}

/// The Deployment annotation that opts its pods in to safe-to-evict.
const safe_to_evict_on = "{\"knarr.io/safe-to-evict\":\"true\"}"

/// A scripted cluster: one opted-in Deployment, one ReplicaSet, the pods
/// given, readings per pod IP, and the clock at `now`.
fn cluster(name: String, pods: List(PodFixture)) -> Table {
  let table = table_new()
  put(table, "name", name)
  set_pods(table, pods)
  set_replica_set(table, deployment_uid)
  set_deployment(table, "{}")
  put(table, "now", "1000")
  put(table, "patch_status", "200")
  table
}

/// The scripted apiserver: answers from the table and forwards every
/// request to `requests`. A LIST is refused with 429 while "list_status",
/// or "list_status:" and its resource, is "429"; a patch answers with
/// "patch_status", after moving the clock to "patch_advances_now" once when
/// that is set, as a slow response does, or fails in transport while
/// "patch_status" is "send_failed"; a refusal of either carries
/// "list_retry_after" or "patch_retry_after" as its Retry-After header when
/// set.
fn apiserver(
  table: Table,
  requests: Subject(Request(String)),
) -> fn(Request(String)) -> Result(Response(String), k8s_http.SendError) {
  fn(request: Request(String)) {
    process.send(requests, request)
    let resource =
      request.path |> string.split("/") |> list.last |> result.unwrap("")
    case request.method {
      http.Get -> {
        let throttled =
          get(table, "list_status") == Ok("429")
          || get(table, "list_status:" <> resource) == Ok("429")
        case throttled, get(table, resource) {
          True, _ ->
            Ok(
              response.new(429)
              |> response.set_body("{}")
              |> retry_after(table:, key: "list_retry_after"),
            )
          False, Ok(body) -> Ok(response.new(200) |> response.set_body(body))
          False, Error(Nil) -> Error(k8s_http.TlsAlert("unknown_ca"))
        }
      }
      http.Patch -> {
        advance_clock(table)
        case get(table, "patch_status") {
          Ok("send_failed") -> Error(k8s_http.ConnectFailed("econnrefused"))
          _ -> Ok(patched(table:, resource:))
        }
      }
      http.Post -> Ok(response.new(201) |> response.set_body("{}"))
      // The reconciler sends no other method.
      _ -> Ok(response.new(405) |> response.set_body(""))
    }
  }
}

/// The answer to a patch of the pod `resource`: "patch_status", 200 when
/// unset, with "patched:" and the pod's name as its body, else the pod
/// with no annotations.
fn patched(table table: Table, resource resource: String) -> Response(String) {
  let status =
    get(table, "patch_status")
    |> result.try(int.parse)
    |> result.unwrap(200)
  let body = case get(table, "patched:" <> resource) {
    Ok(body) -> body
    Error(Nil) -> pod_json(pod(resource))
  }
  response.new(status)
  |> response.set_body(body)
  |> retry_after(table:, key: "patch_retry_after")
}

/// A slow response: the clock moves to "patch_advances_now", in seconds,
/// before the patch is answered, once; the key is cleared on the way.
fn advance_clock(table: Table) -> Nil {
  case get(table, "patch_advances_now") {
    Ok("") | Error(Nil) -> Nil
    Ok(seconds) -> {
      put(table, "now", seconds)
      put(table, "patch_advances_now", "")
    }
  }
}

/// The Retry-After header the table holds under `key`, when it holds one.
fn retry_after(
  response response: Response(String),
  table table: Table,
  key key: String,
) -> Response(String) {
  case get(table, key) {
    Ok(seconds) -> response.set_header(response, "retry-after", seconds)
    Error(Nil) -> response
  }
}

/// The scripted poll: the reading the table holds for the pod IP, valid at
/// cost 500 when none is set. Each poll is recorded under "polled".
fn poller(table: Table) -> fn(Endpoint) -> poller.Reading {
  fn(endpoint: Endpoint) {
    append(
      table,
      "polled",
      endpoint.pod_ip <> ":" <> int.to_string(endpoint.port) <> endpoint.path,
    )
    case get(table, "reading:" <> endpoint.pod_ip) {
      Ok("not_found") -> poller.NotFound
      Ok("timed_out") -> poller.Failed(poller.TimedOut)
      Ok("refused") -> poller.Failed(poller.Refused)
      Ok("draining") -> poller.Valid(poller.Status(cost: 100, accepting: False))
      // A worker that never answers within the scheduler's deadline.
      Ok("hang") -> {
        process.sleep(10_000)
        poller.Valid(poller.Status(cost: 1, accepting: True))
      }
      Ok(cost) ->
        poller.Valid(poller.Status(
          cost: int.parse(cost) |> result.unwrap(0),
          accepting: True,
        ))
      Error(Nil) -> poller.Valid(poller.Status(cost: 500, accepting: True))
    }
  }
}

fn files(name: String) -> #(String, String) {
  let dir = "build/reconciler_test/" <> name
  let token_file = dir <> "/token"
  let namespace_file = dir <> "/namespace"
  write_file(namespace_file, "default\n")
  write_file(token_file, "a-token")
  #(token_file, namespace_file)
}

type Harness {
  Harness(
    table: Table,
    requests: Subject(Request(String)),
    ready: Subject(Nil),
    config: reconciler.Config,
  )
}

/// A harness with the clock scripted in seconds under "now" and read in
/// milliseconds, the draw always 0, and the four names minted once, so a
/// set stopped and started again on the same harness finds them free.
fn harness(name: String, pods: List(PodFixture)) -> Harness {
  let table = cluster(name, pods)
  let requests = process.new_subject()
  let ready = process.new_subject()
  let #(token_file, namespace_file) = files(name)
  let config =
    reconciler.Config(
      target:,
      namespace_file:,
      token_file:,
      send: apiserver(table, requests),
      poll: poller(table),
      now: fn() {
        let seconds =
          get(table, "now") |> result.try(int.parse) |> result.unwrap(0)
        seconds * 1000
      },
      random: fn(_) { 0 },
      mark_ready: fn() { process.send(ready, Nil) },
      installed:,
      interval_ms: 3_600_000,
      version: "0.1.0",
      names: reconciler.names(),
    )
  Harness(table:, requests:, ready:, config:)
}

/// A harness whose bucket never holds a token: no turn is granted, so every
/// change a cycle hands the patcher stays pending and knarr_patches_pending
/// counts what each cycle enqueued.
fn holding(name: String, pods: List(PodFixture)) -> Harness {
  let harness = harness(name, pods)
  Harness(
    ..harness,
    config: reconciler.Config(
      ..harness.config,
      installed: Installed(..installed, patch_burst: 0),
    ),
  )
}

const target = k8s_client.Target(host: "10.96.0.1", port: 443)

/// The set under its supervisor: the pid to stop it by.
fn start(harness: Harness) -> Pid {
  let started = reconciler.start(harness.config) |> should.be_ok
  started.pid
}

/// The next request within a second.
fn next(harness: Harness) -> Request(String) {
  process.receive(harness.requests, 1000) |> should.be_ok
}

/// The three LISTs of a cycle, in the order the reconciler sends them.
fn lists(harness: Harness) -> Nil {
  let paths = [next(harness).path, next(harness).path, next(harness).path]
  assert paths
    == [
      "/api/v1/namespaces/default/pods",
      "/apis/apps/v1/namespaces/default/replicasets",
      "/apis/apps/v1/namespaces/default/deployments",
    ]
}

fn quiet(harness: Harness) -> Nil {
  assert process.receive(harness.requests, 200) == Error(Nil)
}

/// Moves the clock and asks the reconciler for a cycle; unlike its timer,
/// a tick arms nothing, so the chain the timer runs is left alone.
fn tick(harness harness: Harness, at at: Int) -> Nil {
  put(harness.table, "now", int.to_string(at))
  process.send(
    process.named_subject(harness.config.names.reconciler),
    reconciler.Tick,
  )
}

/// Moves the clock and wakes the scheduler, as its timer would.
fn wake(harness harness: Harness, at at: Int) -> Nil {
  put(harness.table, "now", int.to_string(at))
  process.send(
    process.named_subject(harness.config.names.scheduler),
    scheduler.Wake,
  )
}

/// Moves the clock and wakes the patcher, as its timer would.
fn patcher_wake(harness harness: Harness, at at: Int) -> Nil {
  put(harness.table, "now", int.to_string(at))
  to_patcher(harness, patcher.Wake)
}

/// A message to the patcher from outside the set: a pending change the
/// reconciler has not derived, so a turn the reconciler must still answer.
fn to_patcher(harness: Harness, message: patcher.Message) -> Nil {
  process.send(process.named_subject(harness.config.names.patcher), message)
}

/// The patch counter series of `deployment` with `purpose` and `result`.
fn patches(
  deployment deployment: String,
  purpose purpose: String,
  result result: String,
) -> String {
  "knarr_patches_total{deployment=\""
  <> deployment
  <> "\",purpose=\""
  <> purpose
  <> "\",result=\""
  <> result
  <> "\"} "
}

/// The pending gauge series of `deployment`.
fn pending(deployment: String) -> String {
  "knarr_patches_pending{deployment=\"" <> deployment <> "\"} "
}

/// The pid registered under `name`: one of the set's processes.
fn pid_of(name: process.Name(message)) -> Pid {
  process.named(name) |> should.be_ok
}

/// Returns once a running process has handled every message sent to it
/// before this call: an actor takes its mailbox in order, a system message
/// among the rest. A suspended one answers at once, having handled nothing.
fn settled(pid: Pid) -> Nil {
  let _state = system.get_state(pid)
  Nil
}

/// Returns once the reconciler has answered what it was handling, the
/// patcher has handled that answer, and the reconciler has handled any
/// quiet the patcher sent in reply.
fn settle(harness: Harness) -> Nil {
  let names = harness.config.names
  settled(pid_of(names.reconciler))
  settled(pid_of(names.patcher))
  settled(pid_of(names.reconciler))
}

/// True once the exposition carries `line`, within `ms`: a series set
/// after a poll returned lands after the test saw the LISTs.
fn await_metric(line: String, ms: Int) -> Bool {
  await_exposition(string.contains(_, line), ms)
}

/// True once no series of `deployment` is left in the exposition, within
/// `ms`.
fn await_retired(deployment: String, ms: Int) -> Bool {
  await_exposition(
    fn(exposition) {
      !string.contains(exposition, "deployment=\"" <> deployment <> "\"")
    },
    ms,
  )
}

fn await_exposition(condition: fn(String) -> Bool, ms: Int) -> Bool {
  await(fn() { condition(metrics.collect()) }, ms / 10)
}

/// True once `count` polls were made, within `ms`.
fn await_polls(
  harness harness: Harness,
  count count: Int,
  within ms: Int,
) -> Bool {
  await(
    fn() { list.length(list_of(harness.table, "polled")) == count },
    ms / 10,
  )
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

/// The value of the counter series `line` names in the exposition, 0 when
/// absent: a counter without a Deployment label is never reset, so a test
/// asserts the increase it caused.
fn counter(line: String) -> Int {
  metrics.collect()
  |> string.split("\n")
  |> list.find_map(fn(row) {
    case string.split_once(row, " ") {
      Ok(#(series, value)) if series == line -> int.parse(value)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap(0)
}

fn patch_of(request: Request(String), pod: String) -> String {
  assert request.method == http.Patch
  assert request.path == "/api/v1/namespaces/default/pods/" <> pod
  request.body
}

fn event_of(request: Request(String)) -> #(String, String, String) {
  assert request.method == http.Post
  assert request.path == "/api/v1/namespaces/default/events"
  let decoder = {
    use reason <- decode.field("reason", decode.string)
    use message <- decode.field("message", decode.string)
    use kind <- decode.subfield(["involvedObject", "kind"], decode.string)
    decode.success(#(reason, message, kind))
  }
  json.parse(request.body, decoder) |> should.be_ok
}

/// The captured log lines whose msg is `msg`.
fn lines(harness: Harness, msg: String) -> List(String) {
  list_of(harness.table, "logs")
  |> list.filter(string.contains(_, "\"msg\":\"" <> msg <> "\""))
}

/// The fixed clock values the tests use, as RFC 3339 times.
fn at(seconds: Int) -> String {
  case seconds {
    1000 -> "1970-01-01T00:16:40Z"
    _ -> "1970-01-01T00:21:40Z"
  }
}

// ------------------------------------------------------------------ Cycle ---

// Loop.Cycle, Desired, Due, budget Leaving, Pending and ownership WriteMode:
// one cycle lists and joins every target with a pod IP to the schedule,
// each is polled at its phase, at once with draw 0, its due change is
// handed to the patcher and, on the turn it grants, a busy pod is patched
// with the value and the marker in one document, counted on
// knarr_patches_total (observability Patches); a terminating pod is polled
// but never patched; a pod without an IP is neither (NoPodIp).
pub fn a_cycle_polls_every_target_with_an_ip_and_patches_a_busy_pod_test() -> Nil {
  let harness =
    harness("busy", [
      pod("1"),
      PodFixture(..pod("2"), ip: None),
      PodFixture(..pod("3"), terminating: True),
      PodFixture(..pod("4"), owner: "other-rs"),
    ])
  let set = start(harness)

  lists(harness)
  assert process.receive(harness.ready, 1000) == Ok(Nil)
  let document = patch_of(next(harness), "1")
  assert document
    == "[{\"op\":\"test\",\"path\":\"/metadata/deletionTimestamp\",\"value\":null},{\"op\":\"test\",\"path\":\"/metadata/annotations\",\"value\":null},{\"op\":\"add\",\"path\":\"/metadata/annotations\",\"value\":{\"controller.kubernetes.io/pod-deletion-cost\":\"500\",\"knarr.io/applied\":\"{\\\"at\\\":\\\""
    <> at(1000)
    <> "\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":\\\"500\\\",\\\"at\\\":\\\""
    <> at(1000)
    <> "\\\"}}\"}}]"
  quiet(harness)
  assert list.sort(list_of(harness.table, "polled"), string.compare)
    == ["10.0.0.1:8080/knarr/v1/status", "10.0.0.3:8080/knarr/v1/status"]
  assert await_metric(
    patches(deployment: "busy", purpose: "apply", result: "accepted") <> "1\n",
    1000,
  )
  // An accepted apply leaves nothing pending (budget Pending).
  assert await_metric("knarr_patches_pending{deployment=\"busy\"} 0\n", 1000)
  stop_root(set)
}

// budget ListCadence, Jitter and reconcile Loop.Cycle: a second LIST at the
// same clock joins nothing new and polls nothing, since the pod keeps its
// place on the ladder; the next rung, thirty seconds on with draw 0, polls
// it without a LIST, on the scheduler's wake.
pub fn a_second_list_at_the_same_clock_polls_nothing_and_the_rung_does_test() -> Nil {
  let harness = harness("cadence", [pod("1")])
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  let one = ["10.0.0.1:8080/knarr/v1/status"]
  assert list_of(harness.table, "polled") == one
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  assert list_of(harness.table, "polled") == one
  wake(harness:, at: 1029)
  quiet(harness)
  assert list_of(harness.table, "polled") == one
  wake(harness:, at: 1030)
  assert await_polls(harness:, count: 2, within: 1000)
  quiet(harness)
  stop_root(set)
}

// Loop.Cycle, budget Concurrency and worker_contract Transport: a poll that
// produces no response within the scheduler's deadline is that pod's
// timed_out reading and no other pod's; the readings of the pods that
// answered land on their own pods, each patched as its poll returns, the
// third once the hanging poll's slot is not needed for it.
pub fn a_hanging_poll_is_timed_out_for_its_pod_alone_test() -> Nil {
  let harness = harness("hang", [pod("1"), pod("2"), pod("3")])
  put(harness.table, "reading:10.0.0.1", "1000")
  put(harness.table, "reading:10.0.0.2", "hang")
  put(harness.table, "reading:10.0.0.3", "2000")
  let set = start(harness)

  lists(harness)
  let first = next(harness)
  let second = next(harness)
  let patches =
    list.map([first, second], fn(request) {
      assert request.method == http.Patch
      #(request.path, request.body)
    })
  let body_of = fn(pod) {
    list.key_find(patches, "/api/v1/namespaces/default/pods/" <> pod)
  }
  assert result.map(body_of("1"), string.contains(_, "\"1000\"")) == Ok(True)
  assert result.map(body_of("3"), string.contains(_, "\"2000\"")) == Ok(True)
  assert body_of("2") == Error(Nil)
  // Pod 2 is given up at twice the timeout and a second (poll_timeout 1:
  // three seconds) and its reading observed as timed_out.
  assert await_metric(
    "knarr_polls_total{deployment=\"hang\",reading=\"timed_out\"} 1\n",
    4500,
  )
  quiet(harness)
  stop_root(set)
}

// Loop.Due: a pod whose marker records the value its reading maps to has
// nothing due, so a second cycle sends no patch.
pub fn nothing_is_due_between_crossings_test() -> Nil {
  let harness =
    harness("steady", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  let set = start(harness)

  lists(harness)
  quiet(harness)
  tick(harness:, at: 1300)
  lists(harness)
  quiet(harness)
  stop_root(set)
}

// Loop.Rejected422 and ownership Rejected: a 422 keeps the patch's
// operations until the next LIST and is not retried before it: the turn
// leaves nothing pending, the poll after it hands the patcher nothing, and a
// patcher wake past the pod's interval sends nothing. The LIST classifies
// the operations and the write is simply rebuilt from the poll that follows
// it. observability Events Rejected and Catalogue Patches: the LIST shows
// the view unchanged, so every test would have passed and the 422 is a
// rejection, raised as PatchRejected with status 422 before the rebuilt
// patch and counted once.
pub fn a_422_is_left_to_the_next_list_test() -> Nil {
  let harness = harness("422", [pod("1")])
  put(harness.table, "patch_status", "422")
  let set = start(harness)

  lists(harness)
  let first = patch_of(next(harness), "1")
  quiet(harness)
  let refused =
    patches(deployment: "422", purpose: "apply", result: "precondition_failed")
  assert await_metric(refused <> "1\n", 1000)
  assert await_metric("knarr_patches_pending{deployment=\"422\"} 0\n", 1000)
  wake(harness:, at: 1030)
  assert await_polls(harness:, count: 2, within: 1000)
  quiet(harness)
  patcher_wake(harness:, at: 1060)
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(exposition, refused <> "1\n")
  assert !string.contains(
    exposition,
    patches(deployment: "422", purpose: "apply", result: "accepted"),
  )
  put(harness.table, "patch_status", "200")
  tick(harness:, at: 1300)
  lists(harness)
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "PatchRejected"
  assert kind == "Pod"
  assert string.contains(message, "rejected knarr's patch with 422;")
  let second = patch_of(next(harness), "1")
  assert string.contains(first, "\"500\"")
  assert string.contains(second, "\"500\"")
  assert string.contains(second, at(1300))
  quiet(harness)
  assert await_metric(
    patches(deployment: "422", purpose: "apply", result: "accepted") <> "1\n",
    1000,
  )
  assert string.contains(
    metrics.collect(),
    "knarr_patch_rejections_total{deployment=\"422\",purpose=\"apply\"} 1\n",
  )
  stop_root(set)
}

// Loop.Rejected422 and ownership Rejected: a 422 whose next LIST shows a
// changed view, here a foreign value under the cost key, failed its
// precondition and is no rejection: no Event and no count (observability
// Catalogue Patches).
pub fn a_422_whose_view_changed_is_no_rejection_test() -> Nil {
  let harness = harness("422-moved", [pod("1")])
  put(harness.table, "patch_status", "422")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  set_pods(harness.table, [PodFixture(..pod("1"), annotations: foreign())])
  tick(harness:, at: 1300)
  lists(harness)
  quiet(harness)
  assert !string.contains(
    metrics.collect(),
    "knarr_patch_rejections_total{deployment=\"422-moved\"",
  )
  stop_root(set)
}

// Fallback.Neutral and Loop.Due: three failed readings make the pod unknown
// and the removal is sent, keeping the marker with a null record. The
// readings come at the pod's rungs, 1000, 1030 and 1060 with draw 0, each
// served by the LIST that passes it.
pub fn the_neutral_removal_follows_three_failures_test() -> Nil {
  let harness =
    harness("neutral", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "reading:10.0.0.1", "timed_out")
  let set = start(harness)

  lists(harness)
  quiet(harness)
  tick(harness:, at: 1040)
  lists(harness)
  quiet(harness)
  tick(harness:, at: 1300)
  lists(harness)
  let document = patch_of(next(harness), "1")
  assert string.contains(
    document,
    "{\"op\":\"remove\",\"path\":\"/metadata/annotations/controller.kubernetes.io~1pod-deletion-cost\"}",
  )
  assert string.contains(document, "\\\"applied\\\":null")
  quiet(harness)
  stop_root(set)
}

// lifecycle Restart NoExpiry and Leftovers, Fallback.Restart and Neutral: a
// value a restarted knarr finds on a marked pod stands until the reading
// window elapses again in the new process. Two failed readings before the
// restart carry nothing over, so the removal is sent only at the new
// process's third failure, not its first; the marker's at, long past by
// then, decides nothing (Informational).
pub fn a_restart_keeps_a_found_value_until_the_window_elapses_again_test() -> Nil {
  let harness =
    harness("no-expiry", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "reading:10.0.0.1", "timed_out")
  let set = start(harness)

  lists(harness)
  quiet(harness)
  tick(harness:, at: 1300)
  lists(harness)
  quiet(harness)
  stop_root(set)

  let set = start(harness)
  lists(harness)
  quiet(harness)
  tick(harness:, at: 2300)
  lists(harness)
  quiet(harness)
  tick(harness:, at: 2600)
  lists(harness)
  let document = patch_of(next(harness), "1")
  assert string.contains(
    document,
    "{\"op\":\"remove\",\"path\":\"/metadata/annotations/controller.kubernetes.io~1pod-deletion-cost\"}",
  )
  assert string.contains(document, "\\\"applied\\\":null")
  quiet(harness)
  stop_root(set)
}

// Fallback.Absent, observability Events ContractAbsent and Cadence OnEntry,
// Restart: the Event is raised once, at the poll whose reading enters the
// state, with the port, path and that reading, not again at the LISTs or
// polls while the pod stays, and once more after a restart (lifecycle
// Restart Leftovers: the new process's memory starts empty). The gauge
// moves at the LIST after the poll.
pub fn contract_absent_raises_one_event_on_entry_and_again_after_a_restart_test() -> Nil {
  let harness = harness("absent", [pod("1")])
  put(harness.table, "reading:10.0.0.1", "not_found")
  set_deployment(
    harness.table,
    "{\"knarr.io/status-port\":\"9000\",\"knarr.io/status-path\":\"/status\"}",
  )
  let set = start(harness)

  lists(harness)
  quiet(harness)
  tick(harness:, at: 1300)
  lists(harness)
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "ContractAbsent"
  assert kind == "Deployment"
  assert message
    == "pod 1: no knarr status contract at port 9000 path /status; last reading not_found"
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_pods_contract_absent{deployment=\"absent\"} 0\n",
  )
  tick(harness:, at: 1330)
  lists(harness)
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_pods_contract_absent{deployment=\"absent\"} 1\n",
  )
  stop_root(set)

  let set = start(harness)
  lists(harness)
  quiet(harness)
  tick(harness:, at: 1630)
  lists(harness)
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "ContractAbsent"
  quiet(harness)
  stop_root(set)
}

// observability Cadence OnEntry and reconcile Absent: a state entered by a
// poll and left by the next, both between two LISTs, is still announced
// once, at the poll that entered it; the LIST after sees it left and
// announces nothing.
pub fn a_state_entered_and_left_between_two_lists_is_announced_once_test() -> Nil {
  let harness = harness("absent-gap", [pod("1")])
  put(harness.table, "reading:10.0.0.1", "not_found")
  let set = start(harness)

  lists(harness)
  quiet(harness)
  tick(harness:, at: 1300)
  lists(harness)
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "ContractAbsent"
  quiet(harness)
  // The next rung reads a valid status: the pod leaves absent and its
  // cost is written.
  put(harness.table, "reading:10.0.0.1", "500")
  wake(harness:, at: 1330)
  patch_of(next(harness), "1")
  quiet(harness)
  tick(harness:, at: 1360)
  lists(harness)
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_pods_contract_absent{deployment=\"absent-gap\"} 0\n",
  )
  stop_root(set)
}

// reconcile Cycle: the LIST timer is one chain, armed by the timer's own
// message once per timed cycle; a tick sent from outside, as a test does,
// runs a cycle and arms nothing, so it starts no second chain.
pub fn an_external_tick_runs_a_cycle_and_starts_no_second_chain_test() -> Nil {
  let harness = harness("chain", [])
  let harness =
    Harness(
      ..harness,
      config: reconciler.Config(..harness.config, interval_ms: 600),
    )
  let set = start(harness)

  lists(harness)
  tick(harness:, at: 1000)
  lists(harness)
  // The timer's cycle, 600 ms after the first; a chain the tick started
  // would LIST again a few milliseconds after it.
  lists(harness)
  quiet(harness)
  stop_root(set)
}

// reconcile NoPodIp and budget Leaving: a pod without a pod IP is a target
// that counts and is not polled; the LIST that first shows its IP joins it
// to the schedule, and it is polled at its phase, at once with draw 0.
pub fn a_pod_that_gains_an_ip_joins_the_schedule_at_the_list_that_shows_it_test() -> Nil {
  let harness = harness("no-ip", [pod("1"), PodFixture(..pod("2"), ip: None)])
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert string.contains(metrics.collect(), "knarr_targets{kind=\"pods\"} 2\n")
  assert list_of(harness.table, "polled") == ["10.0.0.1:8080/knarr/v1/status"]
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    pod("2"),
  ])
  tick(harness:, at: 1000)
  lists(harness)
  patch_of(next(harness), "2")
  quiet(harness)
  assert list_of(harness.table, "polled")
    == ["10.0.0.1:8080/knarr/v1/status", "10.0.0.2:8080/knarr/v1/status"]
  stop_root(set)
}

// reconcile Cycle and budget Leaving: a reading for a pod no LIST shows,
// which the scheduler would have discarded, lands nowhere: it is neither
// counted nor observed, and the process carries on.
pub fn a_reading_for_a_pod_the_list_does_not_show_lands_nowhere_test() -> Nil {
  let harness = harness("stray", [pod("1")])
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  process.send(
    process.named_subject(harness.config.names.reconciler),
    reconciler.Polled(scheduler.Polled(
      pod_name: "2",
      pod_uid: "u-2",
      deployment: "stray",
      endpoint: poller.Endpoint(
        pod_ip: "10.0.0.2",
        port: 8080,
        path: "/knarr/v1/status",
      ),
      reading: reconcile.Reading(
        kind: reconcile.Valid,
        cost: Some(500),
        draining: False,
      ),
      seconds: 0.0,
      at_ms: 1_000_000,
    )),
  )
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_polls_total{deployment=\"stray\",reading=\"valid\"} 1\n",
  )
  stop_root(set)
}

// reconcile Cycle and budget Leaving: a pod listed under a new uid is a
// new pod, so a reading of the pod it replaced, sent for the old uid,
// lands nowhere: it is neither counted nor handed to the patcher. The
// replacement has no pod IP yet, so no poll of its own is made.
pub fn a_reading_for_a_replaced_pod_lands_nowhere_test() -> Nil {
  let harness = harness("replaced", [pod("1")])
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  set_pods(harness.table, [PodFixture(..pod("1"), uid: "u-1b", ip: None)])
  tick(harness:, at: 1000)
  lists(harness)
  process.send(
    process.named_subject(harness.config.names.reconciler),
    reconciler.Polled(scheduler.Polled(
      pod_name: "1",
      pod_uid: "u-1",
      deployment: "replaced",
      endpoint: poller.Endpoint(
        pod_ip: "10.0.0.1",
        port: 8080,
        path: "/knarr/v1/status",
      ),
      reading: reconcile.Reading(
        kind: reconcile.Valid,
        cost: Some(500),
        draining: False,
      ),
      seconds: 0.0,
      at_ms: 1_000_000,
    )),
  )
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_polls_total{deployment=\"replaced\",reading=\"valid\"} 1\n",
  )
  assert string.contains(
    metrics.collect(),
    "knarr_patches_pending{deployment=\"replaced\"} 0\n",
  )
  stop_root(set)
}

// reconcile Cycle and JustStarted: a pod relisted under a new uid begins
// its memory afresh, so a write its predecessor's reading made due is not
// built on it: the turn the patcher grants finds no reading and is
// answered nothing due. The replacement is written from its own reading
// once a LIST shows its IP and its first poll returns.
pub fn a_replacement_pod_is_not_written_from_its_predecessors_reading_test() -> Nil {
  let harness = harness("predecessor", [pod("1")])
  let replacement = PodFixture(..pod("1"), uid: "u-1b")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  put(harness.table, "reading:10.0.0.1", "1000")
  wake(harness:, at: 1030)
  assert await_polls(harness:, count: 2, within: 1000)
  // The write is due and waits out the pod's interval (budget PerPod).
  assert await_metric(
    "knarr_patches_pending{deployment=\"predecessor\"} 1\n",
    1000,
  )
  quiet(harness)
  set_pods(harness.table, [PodFixture(..replacement, ip: None)])
  tick(harness:, at: 1030)
  lists(harness)
  quiet(harness)
  patcher_wake(harness:, at: 1060)
  quiet(harness)
  assert await_metric(
    "knarr_patches_pending{deployment=\"predecessor\"} 0\n",
    1000,
  )
  put(harness.table, "patched:1", pod_json(replacement))
  set_pods(harness.table, [replacement])
  tick(harness:, at: 1060)
  lists(harness)
  assert string.contains(patch_of(next(harness), "1"), "\"1000\"")
  quiet(harness)
  stop_root(set)
}

// reconcile Cycle, budget Leaving and observability Polls: a pod listed
// under a new uid with no pod IP leaves its predecessor's schedule
// standing, and that schedule's reading lands nowhere: it is neither
// counted on knarr_polls_total nor observed on knarr_poll_duration_seconds,
// while the predecessor's own reading was observed as it landed.
pub fn a_standing_schedules_reading_for_a_replaced_pod_is_not_observed_test() -> Nil {
  let observed = "knarr_poll_duration_seconds_count"
  let before = counter(observed)
  let harness = harness("unobserved", [pod("1")])
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert counter(observed) == before + 1
  set_pods(harness.table, [PodFixture(..pod("1"), uid: "u-1b", ip: None)])
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  wake(harness:, at: 1030)
  assert await_polls(harness:, count: 2, within: 1000)
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_polls_total{deployment=\"unobserved\",reading=\"valid\"} 1\n",
  )
  assert counter(observed) == before + 1
  stop_root(set)
}

// budget PerPod and Pending: a pod listed under a new uid has not been
// patched, so the attempt on its predecessor does not hold it: the
// replacement's own first reading finds a write due and it is patched at
// once, inside the interval the predecessor's patch started.
pub fn a_replacement_pod_is_not_held_by_its_predecessors_patch_test() -> Nil {
  let harness = harness("unheld", [pod("1")])
  let replacement = PodFixture(..pod("1"), uid: "u-1b")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  put(harness.table, "patched:1", pod_json(replacement))
  set_pods(harness.table, [replacement])
  tick(harness:, at: 1010)
  lists(harness)
  let patched =
    process.receive(harness.requests, 1000)
    |> result.map(fn(request) { #(request.method, request.path) })
  assert patched == Ok(#(http.Patch, "/api/v1/namespaces/default/pods/1"))
  quiet(harness)
  stop_root(set)
}

// Probes.Readiness: readiness latches only after a cycle in which all three
// LISTs succeed; a failed LIST ends the cycle with the previous target set.
// lifecycle Restart Replica and Leftovers: a new process answers /readyz 503
// until its first discovery cycle in which every LIST of it succeeds.
pub fn readiness_latches_after_the_first_complete_cycle_test() -> Nil {
  let harness = harness("ready", [pod("1")])
  let deployments = get(harness.table, "deployments") |> should.be_ok
  put(harness.table, "deployments", "")
  let set = start(harness)

  lists(harness)
  quiet(harness)
  assert process.receive(harness.ready, 200) == Error(Nil)
  put(harness.table, "deployments", deployments)
  tick(harness:, at: 1000)
  lists(harness)
  assert process.receive(harness.ready, 1000) == Ok(Nil)
  patch_of(next(harness), "1")
  stop_root(set)
}

// k8s_client TokenReload: a token that cannot be read skips the cycle and
// logs; a later file is picked up and the token is re-read every cycle.
pub fn an_unreadable_token_skips_the_cycle_test() -> Nil {
  let harness = harness("token", [])
  delete_file(harness.config.token_file)
  capture_logs(harness.table)
  let set = start(harness)

  quiet(harness)
  write_file(harness.config.token_file, "second-token")
  tick(harness:, at: 1000)
  let first = next(harness)
  assert request.get_header(first, "authorization") == Ok("Bearer second-token")
  next(harness)
  next(harness)
  release_logs()
  let logs = list_of(harness.table, "logs")
  assert list.any(logs, fn(line) {
    string.contains(line, "\"level\":\"error\",\"msg\":\"token unreadable\"")
    && string.contains(line, "\"reason\":\"enoent\"")
  })
  assert list.any(logs, fn(line) {
    string.contains(line, "\"msg\":\"token changed\"")
    && !string.contains(line, "second-token")
  })
  stop_root(set)
}

// config InvalidValue and observability Events InvalidOverride: one Event
// per invalid key on entry, none while the text stays, again when it
// changes; config Unknown and Logs Lines: an unknown key is logged once per
// cycle.
pub fn invalid_and_unknown_keys_are_reported_at_their_cadence_test() -> Nil {
  let harness = harness("overrides", [])
  set_deployment(
    harness.table,
    "{\"knarr.io/status-port\":\"abc\",\"knarr.io/colour\":\"blue\"}",
  )
  capture_logs(harness.table)
  let set = start(harness)

  lists(harness)
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "InvalidOverride"
  assert kind == "Deployment"
  assert message
    == "knarr.io/status-port: \"abc\" is invalid, not an integer; the default stands"
  quiet(harness)
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  set_deployment(
    harness.table,
    "{\"knarr.io/status-port\":\"xyz\",\"knarr.io/colour\":\"blue\"}",
  )
  tick(harness:, at: 1000)
  lists(harness)
  let #(_, message, _) = event_of(next(harness))
  assert string.contains(message, "\"xyz\"")
  quiet(harness)
  release_logs()
  let unknown =
    list_of(harness.table, "logs")
    |> list.filter(fn(line) {
      string.contains(line, "\"msg\":\"unknown key\"")
      && string.contains(line, "\"key\":\"annotation knarr.io/colour\"")
    })
  assert list.length(unknown) == 3
  stop_root(set)
}

// config Effective and budget Leaving: the pods of a Deployment that opted
// out leave the target set and the schedule, nothing here names them,
// leaving being retired (ticket 23), and no poll of them is made again;
// observability SeriesLife and lifecycle Cleanup Done: its pod holds no
// marker on the LIST, so nothing is due, its cleanup is done at that cycle
// and its series are retired once the patcher is quiet.
pub fn an_opt_out_names_no_pods_and_retires_the_series_test() -> Nil {
  let harness = harness("leaving", [pod("1")])
  capture_logs(harness.table)
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_polls_total{deployment=\"leaving\",reading=\"valid\"} 1\n",
  )
  put(harness.table, "deployments", items([]))
  tick(harness:, at: 1300)
  lists(harness)
  quiet(harness)
  release_logs()
  assert !list.any(list_of(harness.table, "logs"), fn(line) {
    string.contains(line, "\"msg\":\"pods leaving\"")
  })
  assert await_retired("leaving", 1000)
  wake(harness:, at: 1330)
  quiet(harness)
  assert list_of(harness.table, "polled") == ["10.0.0.1:8080/knarr/v1/status"]
  stop_root(set)
}

// observability Tiers, Standing and reconcile Gauges, NotReadyWithCost: the
// gauges are rebuilt each cycle from the newest views and the latest
// readings, a NotReady pod with a cost counts only once a reading is known,
// and a terminating pod counts only in knarr_targets.
pub fn gauges_are_rebuilt_each_cycle_test() -> Nil {
  let harness =
    harness("gauges", [
      PodFixture(..pod("1"), annotations: marked("1800", at(1000))),
      PodFixture(
        ..pod("2"),
        annotations: marked("1800", at(1000)),
        ready: False,
      ),
      PodFixture(..pod("3"), terminating: True),
    ])
  put(harness.table, "reading:10.0.0.1", "1850")
  put(harness.table, "reading:10.0.0.2", "1850")
  put(harness.table, "reading:10.0.0.3", "timed_out")
  let set = start(harness)

  lists(harness)
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(exposition, "knarr_targets{kind=\"deployments\"} 1\n")
  assert string.contains(exposition, "knarr_targets{kind=\"pods\"} 3\n")
  assert string.contains(
    exposition,
    "knarr_pods{deployment=\"gauges\",tier=\"3\"} 2\n",
  )
  assert string.contains(
    exposition,
    "knarr_annotations{deployment=\"gauges\",annotation=\"pod-deletion-cost\",standing=\"owned\"} 2\n",
  )
  // The first LIST has no reading for pod 2 yet: a NotReady pod with a
  // marker is not counted before one (reconcile NotReadyWithCost).
  assert string.contains(
    exposition,
    "knarr_pods_not_ready_with_cost{deployment=\"gauges\"} 0\n",
  )
  assert string.contains(
    exposition,
    "knarr_pods_unknown{deployment=\"gauges\"} 0\n",
  )
  assert string.contains(
    exposition,
    "knarr_last_discovery_timestamp_seconds 1000\n",
  )

  // The polls at 1000 have returned; the next cycle counts the reading.
  tick(harness:, at: 1030)
  lists(harness)
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_pods_not_ready_with_cost{deployment=\"gauges\"} 1\n",
  )

  // Pod 2 goes away; the tier series is rebuilt and the readiness gauge
  // drops to 0 rather than keeping a stale value.
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("1800", at(1000))),
  ])
  tick(harness:, at: 1300)
  lists(harness)
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_pods{deployment=\"gauges\",tier=\"3\"} 1\n",
  )
  assert string.contains(
    exposition,
    "knarr_pods_not_ready_with_cost{deployment=\"gauges\"} 0\n",
  )
  stop_root(set)
}

/// A pod whose annotation reads 999 while knarr's marker applied 300: a
/// conflict (ownership Adoption).
fn conflicting() -> String {
  json.object([
    #(cost_key, json.string("999")),
    #(
      marker_key,
      json.string(
        "{\"at\":\""
        <> at(1000)
        <> "\",\"pod-deletion-cost\":{\"applied\":\"300\",\"at\":\""
        <> at(1000)
        <> "\"}}",
      ),
    ),
  ])
  |> json.to_string
}

/// The same pod after the yield: the marker records the yield.
fn yielded() -> String {
  json.object([
    #(cost_key, json.string("999")),
    #(
      marker_key,
      json.string(
        "{\"at\":\""
        <> at(1000)
        <> "\",\"pod-deletion-cost\":{\"at\":\""
        <> at(1000)
        <> "\",\"yielded\":\"999\"}}",
      ),
    ),
  ])
  |> json.to_string
}

/// A pod carrying the cost key with no marker: foreign (ownership Adoption).
fn foreign() -> String {
  json.object([#(cost_key, json.string("7"))]) |> json.to_string
}

// ownership Adoption, Yield and Event: a conflict is yielded first, the
// Event is sent after the yield is accepted, and the write that follows is
// built from the yield's response. The standing gauge is rebuilt by the
// LIST after the yield, which shows the yielded pod.
pub fn a_conflict_is_yielded_and_its_event_raised_after_the_patch_test() -> Nil {
  let harness =
    harness("yield", [PodFixture(..pod("1"), annotations: conflicting())])
  put(
    harness.table,
    "patched:1",
    pod_json(PodFixture(..pod("1"), annotations: yielded())),
  )
  let set = start(harness)

  lists(harness)
  let yield = patch_of(next(harness), "1")
  assert string.contains(
    yield,
    "{\"op\":\"test\",\"path\":\"/metadata/annotations/controller.kubernetes.io~1pod-deletion-cost\",\"value\":\"999\"}",
  )
  assert string.contains(yield, "\\\"yielded\\\":\\\"999\\\"")
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "AnnotationYielded"
  assert kind == "Pod"
  assert message
    == "controller.kubernetes.io/pod-deletion-cost: knarr applied 300 and found 999; another writer owns it now and knarr will not write it again on this pod"
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_yields_total{deployment=\"yield\",annotation=\"pod-deletion-cost\"} 1\n",
  )
  assert string.contains(
    exposition,
    "knarr_annotations{deployment=\"yield\",annotation=\"pod-deletion-cost\",standing=\"conflict\"} 1\n",
  )
  assert string.contains(
    exposition,
    "knarr_events_total{reason=\"AnnotationYielded\",result=\"created\"} 1\n",
  )
  set_pods(harness.table, [PodFixture(..pod("1"), annotations: yielded())])
  tick(harness:, at: 1030)
  lists(harness)
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_annotations{deployment=\"yield\",annotation=\"pod-deletion-cost\",standing=\"yielded\"} 1\n",
  )
  stop_root(set)
}

// ownership Event, Rejected and Loop.Rejected422: a yield the apiserver
// refuses with a 422 raises no AnnotationYielded and ends the pod's turn,
// nothing stays pending and no turn inside the LIST interval yields again.
// The next LIST shows the conflict unchanged, so the kept operations
// classify as a rejection: PatchRejected with 422 for purpose yield
// (observability Events Rejected) precedes the yield sent again, and the
// accepted yield raises AnnotationYielded and ends the run.
pub fn a_yield_refused_with_422_is_classified_by_the_next_list_and_yielded_again_test() -> Nil {
  let harness =
    harness("refused-yield", [
      PodFixture(..pod("1"), annotations: conflicting()),
    ])
  put(harness.table, "patch_status", "422")
  let set = start(harness)

  lists(harness)
  let yield = patch_of(next(harness), "1")
  assert string.contains(yield, "\\\"yielded\\\":\\\"999\\\"")
  quiet(harness)
  assert await_metric(
    "knarr_patches_pending{deployment=\"refused-yield\"} 0\n",
    1000,
  )
  patcher_wake(harness:, at: 1060)
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    patches(
      deployment: "refused-yield",
      purpose: "yield",
      result: "precondition_failed",
    )
      <> "1\n",
  )
  put(harness.table, "patch_status", "200")
  put(
    harness.table,
    "patched:1",
    pod_json(PodFixture(..pod("1"), annotations: yielded())),
  )
  tick(harness:, at: 1300)
  lists(harness)
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "PatchRejected"
  assert kind == "Pod"
  assert message
    == "knarr.io/applied: the apiserver rejected knarr's patch with 422; the previous annotations stay and knarr tries again no sooner than the patch interval"
  let yield = patch_of(next(harness), "1")
  assert string.contains(yield, "\\\"yielded\\\":\\\"999\\\"")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "AnnotationYielded"
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_patch_rejections_total{deployment=\"refused-yield\",purpose=\"yield\"} 1\n",
  )
  stop_root(set)
}

// ownership Rejected and observability Events Rejected, Catalogue Patches:
// a 403 on a yield is a rejection at once, PatchRejected for purpose yield
// on the Pod, counted under purpose yield and as rejected on
// knarr_patches_total; the yield was not accepted, so no AnnotationYielded
// and no yield counted.
pub fn a_403_on_a_yield_raises_patch_rejected_for_the_yield_test() -> Nil {
  let harness =
    harness("rejected-yield", [
      PodFixture(..pod("1"), annotations: conflicting()),
    ])
  put(harness.table, "patch_status", "403")
  let set = start(harness)

  lists(harness)
  let yield = patch_of(next(harness), "1")
  assert string.contains(yield, "\\\"yielded\\\":\\\"999\\\"")
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "PatchRejected"
  assert kind == "Pod"
  assert message
    == "knarr.io/applied: the apiserver rejected knarr's patch with 403; the previous annotations stay and knarr tries again no sooner than the patch interval"
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_patch_rejections_total{deployment=\"rejected-yield\",purpose=\"yield\"} 1\n",
  )
  assert string.contains(
    exposition,
    patches(deployment: "rejected-yield", purpose: "yield", result: "rejected")
      <> "1\n",
  )
  assert !string.contains(
    exposition,
    "knarr_yields_total{deployment=\"rejected-yield\"",
  )
  stop_root(set)
}

// ownership Event, k8s_client Verbs, observability Catalogue Standing and
// Patches: a yield answered 200 with a body that gives no view is an
// accepted yield, so AnnotationYielded is raised from the pre-yield view
// and the yield is counted, as accepted; reconcile Sequence: nothing more
// is due on the pod until the next LIST, so neither the poll after it nor
// a patcher wake past the interval sends anything, and that LIST's yielded
// view yields no second time.
pub fn an_accepted_yield_without_a_view_is_reported_and_ends_the_turn_test() -> Nil {
  let harness =
    harness("yield-unseen", [
      PodFixture(..pod("1"), annotations: conflicting()),
    ])
  put(harness.table, "patched:1", "not json")
  let set = start(harness)

  lists(harness)
  let yield = patch_of(next(harness), "1")
  assert string.contains(yield, "\\\"yielded\\\":\\\"999\\\"")
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "AnnotationYielded"
  assert kind == "Pod"
  assert message
    == "controller.kubernetes.io/pod-deletion-cost: knarr applied 300 and found 999; another writer owns it now and knarr will not write it again on this pod"
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_yields_total{deployment=\"yield-unseen\",annotation=\"pod-deletion-cost\"} 1\n",
  )
  assert string.contains(
    exposition,
    patches(deployment: "yield-unseen", purpose: "yield", result: "accepted")
      <> "1\n",
  )
  wake(harness:, at: 1030)
  assert await_polls(harness:, count: 2, within: 1000)
  quiet(harness)
  patcher_wake(harness:, at: 1060)
  quiet(harness)
  set_pods(harness.table, [PodFixture(..pod("1"), annotations: yielded())])
  tick(harness:, at: 1300)
  lists(harness)
  quiet(harness)
  stop_root(set)
}

// ownership Rejected; observability Events Rejected, AlsoLogged, Cadence
// OnEntry, Logs Lines and Catalogue Patches: a 403 is a rejection at once.
// The first of a run raises one PatchRejected Event on the Pod with the
// patch's keys and the status, logs the "patch rejected" line with the
// Event's fields, and counts, as rejected on knarr_patches_total too; a
// second 403 in the run, on a turn a patch interval later, counts and
// raises nothing; an accepted patch ends the run, so the next 403 raises
// again.
pub fn a_403_raises_one_patch_rejected_event_per_run_test() -> Nil {
  let harness = harness("rejected", [pod("1")])
  put(harness.table, "patch_status", "403")
  capture_logs(harness.table)
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "PatchRejected"
  assert kind == "Pod"
  assert message
    == "controller.kubernetes.io/pod-deletion-cost, knarr.io/applied: the apiserver rejected knarr's patch with 403; the previous annotations stay and knarr tries again no sooner than the patch interval"
  quiet(harness)
  let counter = fn(value) {
    "knarr_patch_rejections_total{deployment=\"rejected\",purpose=\"apply\"} "
    <> value
    <> "\n"
  }
  let exposition = metrics.collect()
  assert string.contains(exposition, counter("1"))
  assert string.contains(
    exposition,
    patches(deployment: "rejected", purpose: "apply", result: "rejected")
      <> "1\n",
  )
  let rejected = lines(harness, "patch rejected")
  assert list.length(rejected) == 1
  assert list.all(rejected, fn(line) {
    string.ends_with(
      line,
      "\"level\":\"warning\",\"msg\":\"patch rejected\",\"reason\":\"PatchRejected\",\"deployment\":\"rejected\",\"pod\":\"1\",\"purpose\":\"apply\",\"status\":403,\"keys\":[\"controller.kubernetes.io/pod-deletion-cost\",\"knarr.io/applied\"]}\n",
    )
  })
  tick(harness:, at: 1300)
  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert string.contains(metrics.collect(), counter("2"))
  assert list.length(lines(harness, "patch rejected")) == 1
  put(harness.table, "patch_status", "200")
  tick(harness:, at: 1400)
  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  put(harness.table, "patch_status", "403")
  tick(harness:, at: 1500)
  lists(harness)
  patch_of(next(harness), "1")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "PatchRejected"
  quiet(harness)
  assert string.contains(metrics.collect(), counter("3"))
  assert list.length(lines(harness, "patch rejected")) == 2
  release_logs()
  stop_root(set)
}

// observability Cadence Restart and Events Rejected: the run is in memory
// only, so a restarted set raises PatchRejected once more on its next
// rejection; SeriesLife and lifecycle Restart Leftovers: its counter starts
// again at 0.
pub fn a_restart_raises_patch_rejected_once_more_test() -> Nil {
  let harness = harness("rejected-restart", [pod("1")])
  put(harness.table, "patch_status", "403")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "PatchRejected"
  quiet(harness)
  tick(harness:, at: 1300)
  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  stop_root(set)

  let set = start(harness)
  lists(harness)
  patch_of(next(harness), "1")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "PatchRejected"
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_patch_rejections_total{deployment=\"rejected-restart\",purpose=\"apply\"} 1\n",
  )
  stop_root(set)
}

// observability Events Rejected and k8s_client Verbs: a 200 whose body
// gives no usable view is still an accepted patch, counted as accepted, so
// it ends the run; reconcile Sequence: nothing is due on the pod until the
// next LIST, which supplies the view, and the next 403 raises PatchRejected
// again. The counter counts both rejections.
pub fn an_accepted_patch_without_a_view_ends_the_run_test() -> Nil {
  let harness = harness("rejected-unseen", [pod("1")])
  put(harness.table, "patch_status", "403")
  capture_logs(harness.table)
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "PatchRejected"
  quiet(harness)
  put(harness.table, "patch_status", "200")
  put(harness.table, "patched:1", "not json")
  tick(harness:, at: 1300)
  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    patches(deployment: "rejected-unseen", purpose: "apply", result: "accepted")
      <> "1\n",
  )
  put(harness.table, "patch_status", "403")
  tick(harness:, at: 1400)
  lists(harness)
  patch_of(next(harness), "1")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "PatchRejected"
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_patch_rejections_total{deployment=\"rejected-unseen\",purpose=\"apply\"} 2\n",
  )
  assert list.length(lines(harness, "patch rejected")) == 2
  release_logs()
  stop_root(set)
}

// observability Cadence OnEntry: a rejection run lasts while the unselected
// pod LIST shows the pod live, whether or not its Deployment is a target,
// so a Deployment that opts out for a cycle and back in announces no
// second PatchRejected; SeriesLife: the opt-out retired the Deployment's
// series once the patcher was quiet, so the counter starts again at 1.
pub fn a_run_survives_the_deployment_opting_out_and_back_in_test() -> Nil {
  let harness = harness("rejected-opt-out", [pod("1")])
  put(harness.table, "patch_status", "403")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "PatchRejected"
  quiet(harness)
  let deployments = get(harness.table, "deployments") |> should.be_ok
  put(harness.table, "deployments", items([]))
  tick(harness:, at: 1300)
  lists(harness)
  quiet(harness)
  assert await_retired("rejected-opt-out", 1000)
  put(harness.table, "deployments", deployments)
  tick(harness:, at: 1400)
  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_patch_rejections_total{deployment=\"rejected-opt-out\",purpose=\"apply\"} 1\n",
  )
  stop_root(set)
}

// ownership Adoption; observability Logs Lines, StateLines, Cadence OnEntry
// and Restart, Standing: a foreign annotation logs the "foreign annotation"
// line with its key and the value found once on entry, at the LIST that
// shows it, none while it stays, again after a restart; it raises no
// Event and counts on knarr_annotations as foreign.
pub fn a_foreign_annotation_is_logged_on_entry_and_again_after_a_restart_test() -> Nil {
  let harness =
    harness("foreign", [PodFixture(..pod("1"), annotations: foreign())])
  capture_logs(harness.table)
  let set = start(harness)

  lists(harness)
  quiet(harness)
  let foreign = lines(harness, "foreign annotation")
  assert list.length(foreign) == 1
  assert list.all(foreign, fn(line) {
    string.ends_with(
      line,
      "\"level\":\"warning\",\"msg\":\"foreign annotation\",\"deployment\":\"foreign\",\"pod\":\"1\",\"annotation\":\"pod-deletion-cost\",\"key\":\"controller.kubernetes.io/pod-deletion-cost\",\"value\":\"7\"}\n",
    )
  })
  assert string.contains(
    metrics.collect(),
    "knarr_annotations{deployment=\"foreign\",annotation=\"pod-deletion-cost\",standing=\"foreign\"} 1\n",
  )
  tick(harness:, at: 1300)
  lists(harness)
  quiet(harness)
  assert list.length(lines(harness, "foreign annotation")) == 1
  stop_root(set)

  let set = start(harness)
  lists(harness)
  quiet(harness)
  assert list.length(lines(harness, "foreign annotation")) == 2
  release_logs()
  stop_root(set)
}

// observability Cadence OnEntry and Standing, ownership Adoption: foreign
// is read from the latest views each discovery cycle, not from a reading,
// so a foreign annotation on a target with no pod IP, which is never
// polled, is logged at the LIST that shows it and counts on
// knarr_annotations as foreign. The pod gaining an IP and its first
// reading, then losing the IP again, log nothing more: it never left the
// state (32's final finding 3).
pub fn a_foreign_annotation_on_a_target_without_an_ip_is_logged_at_the_list_test() -> Nil {
  let harness =
    harness("foreign-no-ip", [
      PodFixture(..pod("1"), ip: None, annotations: foreign()),
    ])
  capture_logs(harness.table)
  let set = start(harness)

  lists(harness)
  quiet(harness)
  assert list.length(lines(harness, "foreign annotation")) == 1
  assert string.contains(
    metrics.collect(),
    "knarr_annotations{deployment=\"foreign-no-ip\",annotation=\"pod-deletion-cost\",standing=\"foreign\"} 1\n",
  )
  set_pods(harness.table, [PodFixture(..pod("1"), annotations: foreign())])
  tick(harness:, at: 1300)
  lists(harness)
  assert await_polls(harness:, count: 1, within: 1000)
  quiet(harness)
  set_pods(harness.table, [
    PodFixture(..pod("1"), ip: None, annotations: foreign()),
  ])
  tick(harness:, at: 1400)
  lists(harness)
  quiet(harness)
  assert list.length(lines(harness, "foreign annotation")) == 1
  release_logs()
  stop_root(set)
}

// observability Cadence OnEntry and reconcile Cycle: a pod the LIST shows
// under another uid is a new pod, begun as a restart begins it, so a
// foreign annotation on the replacement is logged again though it bears
// its predecessor's name and the same annotation.
pub fn a_replacement_of_a_foreign_pod_logs_its_foreign_annotation_again_test() -> Nil {
  let harness =
    harness("foreign-replaced", [PodFixture(..pod("1"), annotations: foreign())])
  capture_logs(harness.table)
  let set = start(harness)

  lists(harness)
  quiet(harness)
  assert list.length(lines(harness, "foreign annotation")) == 1
  set_pods(harness.table, [
    PodFixture(..pod("1"), uid: "u-1b", annotations: foreign()),
  ])
  tick(harness:, at: 1300)
  lists(harness)
  quiet(harness)
  assert list.length(lines(harness, "foreign annotation")) == 2
  release_logs()
  stop_root(set)
}

// observability Cadence OnEntry and reconcile Terminating: a terminating
// pod is in no state: a foreign value on it logs no line and counts on no
// standing gauge, and a rejection run on it ends at the LIST that shows it
// terminating, so the pod raises PatchRejected again once it is live
// again; it counts only in knarr_targets{kind="pods"}.
pub fn a_terminating_pod_leaves_every_state_test() -> Nil {
  let harness =
    harness("terminating", [
      PodFixture(..pod("1"), annotations: foreign(), terminating: True),
      pod("2"),
    ])
  put(harness.table, "patch_status", "403")
  capture_logs(harness.table)
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "2")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "PatchRejected"
  quiet(harness)
  assert lines(harness, "foreign annotation") == []
  let exposition = metrics.collect()
  assert string.contains(exposition, "knarr_targets{kind=\"pods\"} 2\n")
  assert !string.contains(
    exposition,
    "knarr_annotations{deployment=\"terminating\"",
  )
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: foreign(), terminating: True),
    PodFixture(..pod("2"), terminating: True),
  ])
  tick(harness:, at: 1300)
  lists(harness)
  quiet(harness)
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: foreign(), terminating: True),
    pod("2"),
  ])
  tick(harness:, at: 1400)
  lists(harness)
  patch_of(next(harness), "2")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "PatchRejected"
  quiet(harness)
  assert lines(harness, "foreign annotation") == []
  release_logs()
  stop_root(set)
}

// observability SeriesLife and config Discovery: a Deployment deleted and
// recreated under the same name between two LISTs has not left, so its
// series are rebuilt, not retired.
pub fn a_recreated_deployment_of_the_same_name_keeps_its_series_test() -> Nil {
  let harness =
    harness("recreate", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  let set = start(harness)

  lists(harness)
  quiet(harness)
  let series = "knarr_pods{deployment=\"recreate\",tier=\"1\"} 1\n"
  assert string.contains(metrics.collect(), series)
  recreate_deployment(harness.table, "dep-2")
  tick(harness:, at: 1300)
  lists(harness)
  quiet(harness)
  assert string.contains(metrics.collect(), series)
  stop_root(set)
}

const ste_key = "cluster-autoscaler.kubernetes.io/safe-to-evict"

/// A pod whose safe-to-evict reads "false" while knarr's marker applied
/// "true", and whose cost is unowned: a conflict on one owned annotation,
/// and a write due on the other once a valid reading is in.
fn safe_conflicting() -> String {
  json.object([
    #(ste_key, json.string("false")),
    #(
      marker_key,
      json.string(
        "{\"at\":\""
        <> at(1000)
        <> "\",\"safe-to-evict\":{\"applied\":\"true\",\"at\":\""
        <> at(1000)
        <> "\"}}",
      ),
    ),
  ])
  |> json.to_string
}

/// The same pod after the yield: the marker records the yield.
fn safe_yielded() -> String {
  json.object([
    #(ste_key, json.string("false")),
    #(
      marker_key,
      json.string(
        "{\"at\":\""
        <> at(1000)
        <> "\",\"safe-to-evict\":{\"at\":\""
        <> at(1000)
        <> "\",\"yielded\":\"false\"}}",
      ),
    ),
  ])
  |> json.to_string
}

/// The pod a patch request names.
fn patched_pod(request: Request(String)) -> String {
  assert request.method == http.Patch
  request.path |> string.split("/") |> list.last |> should.be_ok
}

// reconcile Sequence, budget PerPod and Pending: one patch attempt goes on
// one turn. A conflict's yield takes the pod's turn, with its Event; the
// write also due stays pending for a later turn, which the patcher grants
// once the patch interval since the yield has passed, and it is then built
// from the yield's response.
pub fn a_yield_takes_the_turn_and_the_apply_follows_on_a_later_one_test() -> Nil {
  let harness =
    harness("yield-apply", [
      PodFixture(..pod("1"), annotations: safe_conflicting()),
    ])
  put(
    harness.table,
    "patched:1",
    pod_json(PodFixture(..pod("1"), annotations: safe_yielded())),
  )
  let set = start(harness)

  lists(harness)
  let yield = patch_of(next(harness), "1")
  assert string.contains(
    yield,
    "{\"op\":\"test\",\"path\":\"/metadata/annotations/cluster-autoscaler.kubernetes.io~1safe-to-evict\",\"value\":\"false\"}",
  )
  assert string.contains(yield, "\\\"yielded\\\":\\\"false\\\"")
  assert !string.contains(yield, "\"500\"")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "AnnotationYielded"
  // The write is due, but the turn is spent on the yield.
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    patches(deployment: "yield-apply", purpose: "yield", result: "accepted")
      <> "1\n",
  )
  patcher_wake(harness:, at: 1059)
  quiet(harness)
  patcher_wake(harness:, at: 1060)
  let apply = patch_of(next(harness), "1")
  assert string.contains(apply, "\"500\"")
  assert string.contains(apply, "\\\"yielded\\\":\\\"false\\\"")
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    patches(deployment: "yield-apply", purpose: "apply", result: "accepted")
      <> "1\n",
  )
  stop_root(set)
}

// budget BackOff, PauseScope and observability Budget: a patch refused
// with 429 is counted once, as throttled on knarr_patches_total, and pauses
// every pod for the greater of the ladder and Retry-After, shown on
// knarr_paused and knarr_pause_seconds with scope patch; the next patch of
// any pod goes only once the pause has ended, the throttled change among
// them, since it stayed pending.
pub fn a_patch_429_is_counted_once_as_throttled_and_pauses_every_pod_test() -> Nil {
  let harness = harness("throttle", [pod("1"), pod("2")])
  put(harness.table, "patch_status", "429")
  put(harness.table, "patch_retry_after", "120")
  let set = start(harness)

  lists(harness)
  let throttled = patched_pod(next(harness))
  quiet(harness)
  assert await_metric(
    patches(deployment: "throttle", purpose: "apply", result: "throttled")
      <> "1\n",
    1000,
  )
  let exposition = metrics.collect()
  assert !string.contains(
    exposition,
    patches(deployment: "throttle", purpose: "apply", result: "accepted"),
  )
  // Once, as throttled: not as an error or a rejection too.
  assert !string.contains(
    exposition,
    patches(deployment: "throttle", purpose: "apply", result: "error"),
  )
  assert !string.contains(
    exposition,
    patches(deployment: "throttle", purpose: "apply", result: "rejected"),
  )
  assert string.contains(exposition, "knarr_paused{scope=\"patch\"} 1\n")
  assert string.contains(
    exposition,
    "knarr_pause_seconds{scope=\"patch\"} 120\n",
  )
  put(harness.table, "patch_status", "200")
  patcher_wake(harness:, at: 1119)
  quiet(harness)
  patcher_wake(harness:, at: 1120)
  let pods = [patched_pod(next(harness)), patched_pod(next(harness))]
  assert list.sort(pods, string.compare) == ["1", "2"]
  assert list.contains(pods, throttled)
  assert await_metric(
    patches(deployment: "throttle", purpose: "apply", result: "accepted")
      <> "2\n",
    1000,
  )
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    patches(deployment: "throttle", purpose: "apply", result: "throttled")
      <> "1\n",
  )
  assert string.contains(exposition, "knarr_paused{scope=\"patch\"} 0\n")
  assert !string.contains(
    exposition,
    patches(deployment: "throttle", purpose: "apply", result: "error"),
  )
  assert !string.contains(
    exposition,
    patches(deployment: "throttle", purpose: "apply", result: "rejected"),
  )
  quiet(harness)
  stop_root(set)
}

// budget BackOff and PerPod: the pause and the pod's last attempt count from
// the clock after the attempt returned, not from the one its request was
// built at. A patch whose 429 with Retry-After 120 arrives ten seconds after
// it was sent holds every pod for 120 seconds from its arrival.
pub fn the_pause_counts_from_the_clock_after_the_attempt_returned_test() -> Nil {
  let harness = harness("slow-429", [pod("1")])
  put(harness.table, "patch_status", "429")
  put(harness.table, "patch_retry_after", "120")
  put(harness.table, "patch_advances_now", "1010")
  let set = start(harness)

  lists(harness)
  let request = patch_of(next(harness), "1")
  assert string.contains(request, at(1000))
  quiet(harness)
  assert await_metric("knarr_pause_seconds{scope=\"patch\"} 120\n", 1000)
  put(harness.table, "patch_status", "200")
  patcher_wake(harness:, at: 1129)
  quiet(harness)
  patcher_wake(harness:, at: 1130)
  patch_of(next(harness), "1")
  quiet(harness)
  stop_root(set)
}

// budget PauseScope, ListCadence and observability Budget: a 429 on a LIST
// skips the whole cycle, keeps the previous target set, is counted once as
// throttled on knarr_lists_total, and pauses the LISTs for the greater of
// the ladder and Retry-After, shown with scope list; a tick inside the
// pause sends no LIST, while polling and patching go on; the first tick
// after the pause LISTs and clears the gauges.
pub fn a_list_429_skips_the_cycle_and_withholds_the_ticks_inside_the_pause_test() -> Nil {
  let harness = harness("list-pause", [pod("1")])
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  let throttled = "knarr_lists_total{resource=\"pods\",result=\"throttled\"}"
  let before = counter(throttled)
  put(harness.table, "list_status", "429")
  put(harness.table, "list_retry_after", "120")
  tick(harness:, at: 1300)
  assert next(harness).path == "/api/v1/namespaces/default/pods"
  quiet(harness)
  assert await_metric("knarr_paused{scope=\"list\"} 1\n", 1000)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_pause_seconds{scope=\"list\"} 120\n",
  )
  assert counter(throttled) == before + 1
  assert string.contains(exposition, "knarr_targets{kind=\"pods\"} 1\n")
  assert string.contains(
    exposition,
    "knarr_last_discovery_timestamp_seconds 1000\n",
  )
  // Inside the pause the tick is withheld; a poll and its patch are not.
  tick(harness:, at: 1350)
  quiet(harness)
  wake(harness:, at: 1350)
  assert await_polls(harness:, count: 2, within: 1000)
  patch_of(next(harness), "1")
  quiet(harness)
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
  put(harness.table, "list_status", "200")
  tick(harness:, at: 1419)
  quiet(harness)
  tick(harness:, at: 1420)
  lists(harness)
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(exposition, "knarr_paused{scope=\"list\"} 0\n")
  assert string.contains(exposition, "knarr_pause_seconds{scope=\"list\"} 0\n")
  assert string.contains(
    exposition,
    "knarr_last_discovery_timestamp_seconds 1420\n",
  )
  assert counter(throttled) == before + 1
  stop_root(set)
}

// budget PauseScope and observability Budget: knarr_paused{scope="list"} is
// 1 while the pause lasts and returns to 0 when it ends, on the reconciler's
// own timer, with no tick sent and no cycle run; the LIST chain is left as
// it was. The clock is real: a 429 with Retry-After 1 pauses the LISTs for
// one second.
pub fn the_list_pause_ends_on_its_own_timer_test() -> Nil {
  let scripted = harness("list-pause-timer", [pod("1")])
  let harness =
    Harness(
      ..scripted,
      config: reconciler.Config(..scripted.config, now: unix_milliseconds),
    )
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  put(harness.table, "list_status", "429")
  put(harness.table, "list_retry_after", "1")
  tick(harness:, at: 1300)
  assert next(harness).path == "/api/v1/namespaces/default/pods"
  assert await_metric("knarr_paused{scope=\"list\"} 1\n", 1000)
  assert await_metric("knarr_pause_seconds{scope=\"list\"} 1\n", 1000)
  assert await_metric("knarr_paused{scope=\"list\"} 0\n", 2000)
  assert await_metric("knarr_pause_seconds{scope=\"list\"} 0\n", 1000)
  quiet(harness)
  stop_root(set)
}

// budget PauseScope and ListCadence: a 429 on the replicasets LIST, the
// second of the cycle, skips the cycle as one on the first does.
pub fn a_list_429_on_the_replicasets_list_skips_the_cycle_test() -> Nil {
  a_list_429_on("replicasets")
}

// budget PauseScope and ListCadence: a 429 on the deployments LIST, the
// third of the cycle, skips the cycle as one on the first does.
pub fn a_list_429_on_the_deployments_list_skips_the_cycle_test() -> Nil {
  a_list_429_on("deployments")
}

/// A 429 on `resource`, the second or third LIST of a cycle: the LISTs
/// before it are counted as succeeded and it as throttled, the target set
/// stands, the pause is the Retry-After of 120 seconds, a tick inside it
/// sends nothing, and neither actor hears of the cycle: a pod the pod LIST showed
/// for the first time in it is not polled until the next good cycle, while
/// the pod already scheduled is polled at its rung.
fn a_list_429_on(resource: String) -> Nil {
  let steady = PodFixture(..pod("1"), annotations: marked("500", at(1000)))
  let harness = harness("list-429-" <> resource, [steady])
  let set = start(harness)

  lists(harness)
  quiet(harness)
  let paths = [
    #("pods", "/api/v1/namespaces/default/pods"),
    #("replicasets", "/apis/apps/v1/namespaces/default/replicasets"),
    #("deployments", "/apis/apps/v1/namespaces/default/deployments"),
  ]
  let #(preceding, _) =
    list.split_while(paths, fn(listed) { listed.0 != resource })
  let series = fn(resource, result) {
    "knarr_lists_total{resource=\""
    <> resource
    <> "\",result=\""
    <> result
    <> "\"}"
  }
  let throttled = series(resource, "throttled")
  let before = counter(throttled)
  let succeeded_before =
    list.map(preceding, fn(listed) { counter(series(listed.0, "succeeded")) })
  set_pods(harness.table, [steady, pod("2")])
  put(harness.table, "list_status:" <> resource, "429")
  put(harness.table, "list_retry_after", "120")
  tick(harness:, at: 1300)
  let sent = list.take(paths, list.length(preceding) + 1)
  assert list.map(sent, fn(_) { next(harness).path })
    == list.map(sent, fn(listed) { listed.1 })
  quiet(harness)
  assert await_metric("knarr_paused{scope=\"list\"} 1\n", 1000)
  assert counter(throttled) == before + 1
  assert list.map(preceding, fn(listed) {
      counter(series(listed.0, "succeeded"))
    })
    == list.map(succeeded_before, fn(count) { count + 1 })
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_pause_seconds{scope=\"list\"} 120\n",
  )
  assert string.contains(exposition, "knarr_targets{kind=\"pods\"} 1\n")
  // Inside the pause the tick is withheld; the schedule is the old one.
  tick(harness:, at: 1350)
  quiet(harness)
  wake(harness:, at: 1330)
  assert await_polls(harness:, count: 2, within: 1000)
  quiet(harness)
  assert list_of(harness.table, "polled")
    == ["10.0.0.1:8080/knarr/v1/status", "10.0.0.1:8080/knarr/v1/status"]
  put(harness.table, "list_status:" <> resource, "200")
  tick(harness:, at: 1420)
  lists(harness)
  patch_of(next(harness), "2")
  quiet(harness)
  // At 1420 pod 1's rung is due again, oldest first, then pod 2's phase.
  assert list_of(harness.table, "polled")
    == [
      "10.0.0.1:8080/knarr/v1/status",
      "10.0.0.1:8080/knarr/v1/status",
      "10.0.0.1:8080/knarr/v1/status",
      "10.0.0.2:8080/knarr/v1/status",
    ]
  let exposition = metrics.collect()
  assert string.contains(exposition, "knarr_paused{scope=\"list\"} 0\n")
  assert string.contains(exposition, "knarr_targets{kind=\"pods\"} 2\n")
  assert counter(throttled) == before + 1
  stop_root(set)
}

// budget Pending: every turn is answered once, with the turn's own key. A
// turn for a pod no LIST shows is answered nothing due, and so is a cleanup
// turn on a pod whose newest view holds nothing to release (lifecycle
// Cleanup Scope), so the patcher's one turn in flight clears and the next
// due pod gets its turn.
pub fn a_turn_for_an_unknown_pod_or_a_cleanup_with_nothing_due_is_answered_nothing_due_test() -> Nil {
  let harness = harness("ghost", [pod("1")])
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  to_patcher(
    harness,
    patcher.Due(
      pod_name: "ghost",
      purpose: budget.Apply,
      deployment: "ghost",
      interval_s: 0,
      at_ms: 1_000_000,
    ),
  )
  to_patcher(
    harness,
    patcher.Due(
      pod_name: "1",
      purpose: budget.Cleanup,
      deployment: "ghost",
      interval_s: 0,
      at_ms: 1_000_000,
    ),
  )
  set_pods(harness.table, [pod("1"), pod("2")])
  tick(harness:, at: 1000)
  lists(harness)
  patch_of(next(harness), "2")
  quiet(harness)
  stop_root(set)
}

// observability SeriesLife and lifecycle Cleanup Done: an opt-out's series
// last until its cleanup is done. The LIST that drops the Deployment makes
// its pod's owned cost due (lifecycle Cleanup Scope), held by the patch
// interval; the turn that sends it, accepted, is counted under the
// Deployment and retires nothing, since done reads the cycle's Views, which
// still show the cost owned: every series stands, knarr_annotations among
// them. The next LIST shows the pod released, so the Deployment is done and
// every series goes once the patcher is quiet.
pub fn an_opt_outs_series_last_until_its_cleanup_is_accepted_test() -> Nil {
  let harness = harness("depart", [pod("1")])
  let set = start(harness)
  let owned =
    "knarr_annotations{deployment=\"depart\",annotation=\"pod-deletion-cost\",standing=\"owned\"} 1\n"

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
  opt_out(harness.table)
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_polls_total{deployment=\"depart\",reading=\"valid\"} 1\n",
  )
  assert string.contains(
    exposition,
    patches(deployment: "depart", purpose: "apply", result: "accepted") <> "1\n",
  )
  assert string.contains(
    exposition,
    "knarr_pods{deployment=\"depart\",tier=\"0\"} 1\n",
  )
  assert string.contains(exposition, owned)
  patcher_wake(harness:, at: 1060)
  patch_of(next(harness), "1")
  settle(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    patches(deployment: "depart", purpose: "cleanup", result: "accepted")
      <> "1\n",
  )
  assert string.contains(
    exposition,
    "knarr_polls_total{deployment=\"depart\",reading=\"valid\"} 1\n",
  )
  assert string.contains(exposition, owned)
  quiet(harness)
  set_pods(harness.table, [pod("1")])
  tick(harness:, at: 1300)
  lists(harness)
  assert await_retired("depart", 1000)
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup Done and observability SeriesLife: a cleanup in flight
// for a pod that has since left the pod LIST holds its Deployment's series
// until it is answered. The cycle that no longer shows the pod finds no
// View due and departs the Deployment, but the patcher's turn for that
// cleanup is still out, so the patcher is not quiet; the answer, nothing
// due for a pod the reconciler no longer knows, lets it go. Built by
// suspending the patcher with its Wake queued before the cycle, so the turn
// is granted after the cycle, then suspending the reconciler, so the turn
// waits unanswered while the exposition is read: knarr_patches_pending,
// which the patcher itself removes when it is quiet, still stands at 0.
pub fn a_cleanup_in_flight_for_a_pod_that_left_the_list_holds_the_series_test() -> Nil {
  let harness = harness("in-flight", [pod("1")])
  let set = start(harness)
  let names = harness.config.names

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
  opt_out(harness.table)
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  let patcher_pid = pid_of(names.patcher)
  let reconciler_pid = pid_of(names.reconciler)
  system.suspend(patcher_pid)
  set_pods(harness.table, [])
  patcher_wake(harness:, at: 1060)
  tick(harness:, at: 1060)
  lists(harness)
  settled(reconciler_pid)
  system.suspend(reconciler_pid)
  system.resume(patcher_pid)
  settled(patcher_pid)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_polls_total{deployment=\"in-flight\",reading=\"valid\"} 1\n",
  )
  assert string.contains(exposition, pending("in-flight") <> "0\n")
  system.resume(reconciler_pid)
  assert await_retired("in-flight", 1000)
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup Label and observability SeriesLife: the series of the
// empty name, under which a cascade orphan's cleanup counts, live and
// retire as a Deployment's do: the accepted cleanup is counted under
// deployment "" and stands with the owned gauge until the next LIST shows
// the pod released, which makes the empty name done, and then they go.
pub fn the_empty_names_series_live_and_retire_as_a_deployments_do_test() -> Nil {
  let harness =
    harness("orphan-retire", [
      PodFixture(
        ..pod("1"),
        annotations: marked("500", at(1000)),
        owner: "other-rs",
      ),
    ])
  orphan_replica_set(harness.table)
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  settle(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    patches(deployment: "", purpose: "cleanup", result: "accepted") <> "1\n",
  )
  assert string.contains(
    exposition,
    "knarr_annotations{deployment=\"\",annotation=\"pod-deletion-cost\",standing=\"owned\"} 1\n",
  )
  quiet(harness)
  set_pods(harness.table, [PodFixture(..pod("1"), owner: "other-rs")])
  tick(harness:, at: 1300)
  lists(harness)
  assert await_retired("", 1000)
  quiet(harness)
  stop_root(set)
}

// observability SeriesLife ("whether it left it in this process or was
// never in it, as after a restart") and lifecycle Restart NoStartupStep: a
// Deployment deleted while knarr was down, its pod still marked, is never
// a target of the restarted process; its cleanup is due from the first
// complete cycle, counted under its name, and its series stand until the
// next LIST shows the pod released, then retire.
pub fn a_deployment_never_in_the_target_set_retires_once_its_cleanup_is_accepted_test() -> Nil {
  let harness =
    harness("never-target", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  let set = start(harness)

  lists(harness)
  assert await_polls(harness:, count: 1, within: 1000)
  quiet(harness)
  stop_root(set)
  put(harness.table, "deployments", items([]))
  let set = start(harness)
  lists(harness)
  patch_of(next(harness), "1")
  settle(harness)
  assert string.contains(
    metrics.collect(),
    patches(deployment: "never-target", purpose: "cleanup", result: "accepted")
      <> "1\n",
  )
  quiet(harness)
  set_pods(harness.table, [pod("1")])
  tick(harness:, at: 1300)
  lists(harness)
  assert await_retired("never-target", 1000)
  quiet(harness)
  stop_root(set)
}

// observability SeriesLife and lifecycle Cleanup Done: done is read at each
// cycle, so a quiet answering a departure a later cycle has withdrawn
// retires nothing. The Deployment is done at the opt-out's cycle, its pod
// holding nothing, so that cycle's Listed departs it and the patcher, with
// nothing of it pending, answers quiet and removes knarr_patches_pending;
// the reconciler's next cycle, already queued ahead of that quiet, finds the
// pod marked again and withdraws the departure, and its Listed registers
// the cleanup, which sets the pending gauge again. The quiet then reaches
// the reconciler and every series stands. Built by suspending the patcher
// across the first cycle and the reconciler with the second cycle's tick
// queued before the patcher is resumed, so the gap between the patcher's
// quiet and the withdrawing Listed, the residual window, is read too. No
// token is ever granted.
pub fn a_quiet_for_a_departure_a_later_cycle_withdrew_retires_nothing_test() -> Nil {
  let harness = holding("stale-quiet", [pod("1")])
  let set = start(harness)
  let names = harness.config.names
  let polls =
    "knarr_polls_total{deployment=\"stale-quiet\",reading=\"valid\"} 1\n"

  lists(harness)
  assert await_metric(polls, 1000)
  let patcher_pid = pid_of(names.patcher)
  let reconciler_pid = pid_of(names.reconciler)
  system.suspend(patcher_pid)
  opt_out(harness.table)
  tick(harness:, at: 1300)
  lists(harness)
  settled(reconciler_pid)
  system.suspend(reconciler_pid)
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
  tick(harness:, at: 1400)
  system.resume(patcher_pid)
  settled(patcher_pid)
  let exposition = metrics.collect()
  assert string.contains(exposition, polls)
  assert !string.contains(exposition, pending("stale-quiet"))
  system.resume(reconciler_pid)
  lists(harness)
  settle(harness)
  let exposition = metrics.collect()
  assert string.contains(exposition, polls)
  assert string.contains(
    exposition,
    "knarr_annotations{deployment=\"stale-quiet\",annotation=\"pod-deletion-cost\",standing=\"owned\"} 1\n",
  )
  assert string.contains(exposition, pending("stale-quiet") <> "1\n")
  quiet(harness)
  stop_root(set)
}

// observability SeriesLife ("knarr_patches_pending goes with the rest") and
// lifecycle Cleanup Done: a departure a later cycle withdraws is withdrawn
// in the patcher too, in the Listed that registers the cleanup now due, so
// a cleanup completed before the next LIST leaves knarr_patches_pending at
// 0 beside the Deployment's other series instead of removing it alone. The
// departure is outstanding: the cycle that no longer shows the opted-out
// pod departs the Deployment while the patcher's turn for that pod's
// cleanup is out. The next cycle, run before that turn is answered, shows a
// second pod of the Deployment, marked, so the Deployment is due again; the
// turn is answered nothing due, the second pod's cleanup is granted and
// accepted, and the LIST after, showing it released, finds the Deployment
// done. Built by suspending the patcher with its Wake queued before the
// first cycle, then the reconciler with the second cycle's tick queued
// before the patcher grants the turn.
pub fn a_withdrawn_departure_keeps_the_pending_gauge_with_the_rest_test() -> Nil {
  let harness = harness("withdrawn", [pod("1")])
  let set = start(harness)
  let names = harness.config.names

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
  opt_out(harness.table)
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  let patcher_pid = pid_of(names.patcher)
  let reconciler_pid = pid_of(names.reconciler)
  system.suspend(patcher_pid)
  set_pods(harness.table, [])
  patcher_wake(harness:, at: 1060)
  tick(harness:, at: 1060)
  lists(harness)
  settled(reconciler_pid)
  system.suspend(reconciler_pid)
  set_pods(harness.table, [
    PodFixture(..pod("2"), annotations: marked("500", at(1000))),
  ])
  tick(harness:, at: 1060)
  system.resume(patcher_pid)
  settled(patcher_pid)
  system.resume(reconciler_pid)
  lists(harness)
  patch_of(next(harness), "2")
  settle(harness)
  let exposition = metrics.collect()
  assert string.contains(exposition, pending("withdrawn") <> "0\n")
  assert string.contains(
    exposition,
    patches(deployment: "withdrawn", purpose: "cleanup", result: "accepted")
      <> "1\n",
  )
  assert string.contains(
    exposition,
    "knarr_polls_total{deployment=\"withdrawn\",reading=\"valid\"} 1\n",
  )
  quiet(harness)
  set_pods(harness.table, [pod("2")])
  tick(harness:, at: 1300)
  lists(harness)
  assert await_retired("withdrawn", 1000)
  quiet(harness)
  stop_root(set)
}

// observability SeriesLife and config Discovery: a Deployment that leaves
// and rejoins the target set before it retires is not retired, by the
// patcher's word or by a stray quiet: its series carry on and its counters
// are not restarted. The cleanup the opt-out's LIST makes due keeps its
// cleanup from done, so it never departs, until the rejoin, whose LIST no
// longer makes it due and puts it back in the target set.
pub fn a_deployment_that_rejoins_before_quiet_keeps_its_series_test() -> Nil {
  let harness = harness("rejoin", [pod("1")])
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
  put(harness.table, "deployments", items([]))
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  set_deployment(harness.table, "{}")
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  process.send(
    process.named_subject(harness.config.names.reconciler),
    reconciler.Quiet(deployment: "rejoin"),
  )
  patcher_wake(harness:, at: 1060)
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_polls_total{deployment=\"rejoin\",reading=\"valid\"} 2\n",
  )
  assert string.contains(
    exposition,
    patches(deployment: "rejoin", purpose: "apply", result: "accepted") <> "1\n",
  )
  assert string.contains(
    exposition,
    "knarr_pods{deployment=\"rejoin\",tier=\"1\"} 1\n",
  )
  stop_root(set)
}

// ---------------------------------------------------------------- Cleanup ---

// lifecycle Cleanup View, Scope and Label, budget Pending: a target's View
// enables pod-deletion-cost always and safe-to-evict only while its
// Deployment opts in, so the cycle after that opt-in is removed makes the
// owned safe-to-evict due, a cleanup pending under the target's Deployment.
pub fn a_removed_safe_to_evict_opt_in_makes_a_cleanup_due_under_the_targets_label_test() -> Nil {
  let harness =
    holding("ste-off", [
      PodFixture(..pod("1"), ip: None, annotations: owning_both("500", "true")),
    ])
  set_deployment(harness.table, safe_to_evict_on)
  let set = start(harness)

  lists(harness)
  quiet(harness)
  assert !string.contains(metrics.collect(), pending("ste-off"))
  set_deployment(harness.table, "{}")
  tick(harness:, at: 1300)
  lists(harness)
  assert await_metric(pending("ste-off") <> "1\n", 1000)
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup View, Label and Retry, budget PerPod: a pod of a
// Deployment that opted out is not a target, so its View enables nothing
// and the cost its marker owns is due, pending under the name its
// ReplicaSet's owner reference carries. It waits config.patch_interval from
// the pod's last attempt, not the override its Deployment set, which is not
// read once the Deployment is out of the selected LIST; its turn then sends
// the patch that removes the cost and, with no record left, the marker
// (lifecycle Cleanup Marker, ownership Released), and nothing of the
// Deployment is pending; its series stay until a LIST finds its cleanup
// done (observability SeriesLife).
pub fn an_opted_out_pods_cleanup_waits_the_install_interval_under_its_deployment_test() -> Nil {
  let harness = harness("opted-out", [pod("1")])
  set_deployment(harness.table, "{\"knarr.io/patch-interval\":\"120\"}")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
  opt_out(harness.table)
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  assert await_metric(pending("opted-out") <> "1\n", 1000)
  patcher_wake(harness:, at: 1059)
  quiet(harness)
  assert string.contains(metrics.collect(), pending("opted-out") <> "1\n")
  patcher_wake(harness:, at: 1060)
  let document = patch_of(next(harness), "1")
  assert string.contains(document, remove_of(cost_key))
  assert string.contains(document, remove_of(marker_key))
  assert !string.contains(document, remove_of(ste_key))
  assert !string.contains(document, "\"op\":\"add\"")
  assert await_metric(pending("opted-out") <> "0\n", 1000)
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup View and ownership Adoption: a View's held follows the
// newest API-returned view of the pod, and at a cycle that is the cycle's
// LIST, received after knarr's accepted patch response: a LIST still showing
// the pod as it was before the patch holds nothing and makes nothing due,
// and the LIST that shows what the accepted patch wrote makes its cost due.
pub fn a_views_held_follows_the_newest_view_at_the_cycle_test() -> Nil {
  let harness = harness("held", [pod("1")])
  put(
    harness.table,
    "patched:1",
    pod_json(PodFixture(..pod("1"), annotations: marked("500", at(1000)))),
  )
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  opt_out(harness.table)
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  assert await_exposition(
    fn(exposition) { !string.contains(exposition, pending("held")) },
    1000,
  )
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
  tick(harness:, at: 1000)
  lists(harness)
  assert await_metric(pending("held") <> "1\n", 1000)
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup View, Scope and Label: every pod the unselected pod
// LIST shows has a View, a pod of a deleted Deployment among them, labelled
// by the name its ReplicaSet's owner reference still carries, and its owned
// cost is due. A terminating pod makes nothing due, and neither does a pod
// with no marker, which holds nothing: one cleanup pending of three pods.
pub fn a_pod_of_a_deleted_deployment_is_due_and_a_terminating_or_unmarked_one_is_not_test() -> Nil {
  let harness =
    holding("deleted", [
      pod("1"),
      PodFixture(
        ..pod("2"),
        annotations: marked("500", at(1000)),
        terminating: True,
      ),
      PodFixture(..pod("3"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "deployments", items([]))
  let set = start(harness)

  lists(harness)
  assert await_metric(pending("deleted") <> "1\n", 1000)
  quiet(harness)
  assert string.contains(metrics.collect(), pending("deleted") <> "1\n")
  stop_root(set)
}

// lifecycle Cleanup Label: a marked pod whose ReplicaSet's owner names no
// Deployment, after a cascade-orphan deletion, is still cleaned up, its
// cleanup pending under the empty name.
pub fn a_cascade_orphan_is_due_a_cleanup_under_the_empty_name_test() -> Nil {
  let harness =
    holding("orphan", [
      PodFixture(
        ..pod("1"),
        annotations: marked("500", at(1000)),
        owner: "other-rs",
      ),
    ])
  orphan_replica_set(harness.table)
  let set = start(harness)

  lists(harness)
  assert await_metric(pending("") <> "1\n", 1000)
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup Scope, config Discovery: Views are built only by a
// cycle in which every LIST succeeded, so a failed cycle builds none and
// changes nothing. Before the first good cycle nothing is pending; a failed
// cycle after it leaves pending the cleanup the good one made due, though
// the pod no longer holds anything; the next good cycle drops it (budget
// Pending) and, nothing of the Deployment left due or pending, retires its
// series, the pending gauge among them (observability SeriesLife).
pub fn a_failed_list_builds_no_view_and_changes_nothing_test() -> Nil {
  let harness =
    holding("failed", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "deployments", "not json")
  let set = start(harness)

  lists(harness)
  quiet(harness)
  assert !string.contains(metrics.collect(), pending("failed"))
  put(harness.table, "deployments", items([]))
  tick(harness:, at: 1300)
  lists(harness)
  assert await_metric(pending("failed") <> "1\n", 1000)
  set_pods(harness.table, [pod("1")])
  put(harness.table, "deployments", "not json")
  tick(harness:, at: 1400)
  lists(harness)
  quiet(harness)
  assert string.contains(metrics.collect(), pending("failed") <> "1\n")
  put(harness.table, "deployments", items([]))
  tick(harness:, at: 1500)
  lists(harness)
  assert await_retired("failed", 1000)
  quiet(harness)
  stop_root(set)
}

// lifecycle Restart NoStartupStep and Cleanup Order, budget Restart: a
// started knarr has no startup pass of its own. A first cycle whose LIST
// fails enqueues nothing; the first cycle in which every LIST succeeded
// derives every due cleanup at once, all pending from that cycle's clock;
// a later cycle that finds them still due keeps when they became due.
pub fn the_first_complete_cycle_after_a_start_enqueues_every_due_cleanup_at_once_test() -> Nil {
  let harness =
    holding("startup", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
      PodFixture(..pod("2"), annotations: null_record()),
      PodFixture(
        ..pod("3"),
        annotations: marked("500", at(1000)),
        owner: "other-rs",
      ),
    ])
  orphan_replica_set(harness.table)
  put(harness.table, "deployments", "not json")
  let set = start(harness)

  lists(harness)
  quiet(harness)
  let exposition = metrics.collect()
  assert !string.contains(exposition, pending("startup"))
  assert !string.contains(exposition, pending(""))
  put(harness.table, "deployments", items([]))
  tick(harness:, at: 1300)
  lists(harness)
  assert await_metric(pending("startup") <> "2\n", 1000)
  assert await_metric(pending("") <> "1\n", 1000)
  assert await_metric("knarr_patch_pending_oldest_seconds 0\n", 1000)
  patcher_wake(harness:, at: 1330)
  assert await_metric("knarr_patch_pending_oldest_seconds 30\n", 1000)
  tick(harness:, at: 1360)
  lists(harness)
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(exposition, "knarr_patch_pending_oldest_seconds 60\n")
  assert string.contains(exposition, pending("startup") <> "2\n")
  assert string.contains(exposition, pending("") <> "1\n")
  stop_root(set)
}

// observability Standing: a pod that is not a target counts on
// knarr_annotations by its View's deployment, an annotation standing owned
// only: the value an opt-out leaves and the null record Neutral leaves
// count until cleanup drops their records, a yielded or a conflict record
// counts nowhere, and a terminating pod on no standing gauge (SeriesLife).
// No other per-Deployment gauge carries the name. No turn is granted, so
// the cleanups stay pending and send nothing.
pub fn a_pod_that_is_not_a_target_counts_its_owned_annotations_alone_test() -> Nil {
  let harness =
    holding("standing-out", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
      PodFixture(..pod("2"), annotations: null_record()),
      PodFixture(..pod("3"), annotations: yielded()),
      PodFixture(..pod("4"), annotations: conflicting()),
      PodFixture(
        ..pod("5"),
        annotations: marked("500", at(1000)),
        terminating: True,
      ),
    ])
  put(harness.table, "deployments", items([]))
  let set = start(harness)

  lists(harness)
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_annotations{deployment=\"standing-out\",annotation=\"pod-deletion-cost\",standing=\"owned\"} 2\n",
  )
  assert !string.contains(
    exposition,
    "knarr_annotations{deployment=\"standing-out\",annotation=\"pod-deletion-cost\",standing=\"yielded\"}",
  )
  assert !string.contains(
    exposition,
    "knarr_annotations{deployment=\"standing-out\",annotation=\"pod-deletion-cost\",standing=\"conflict\"}",
  )
  assert !string.contains(exposition, "knarr_pods{deployment=\"standing-out\"")
  assert !string.contains(
    exposition,
    "knarr_pods_unknown{deployment=\"standing-out\"",
  )
  assert !string.contains(
    exposition,
    "knarr_pods_contract_absent{deployment=\"standing-out\"",
  )
  assert !string.contains(
    exposition,
    "knarr_pods_not_ready_with_cost{deployment=\"standing-out\"",
  )
  stop_root(set)
}

// lifecycle Cleanup Retry, budget PerPod: a pending cleanup takes the
// interval each cycle derives before the patcher grants anything from that
// cycle. A target with a 10 s override has an apply attempt at 1000; its
// Deployment then drops the safe-to-evict opt-in, so the owned value's
// cleanup is pending, held to 1010; at 1010 the Deployment opts out, so the
// install's 60 s applies, and no cleanup turn is granted before 1060, when
// it is sent and nothing of the Deployment is pending.
pub fn a_cleanup_that_leaves_the_target_set_waits_the_install_interval_test() -> Nil {
  let harness =
    harness("short", [
      PodFixture(..pod("1"), annotations: owning_both("500", "true")),
    ])
  put(harness.table, "reading:10.0.0.1", "2000")
  set_deployment(
    harness.table,
    "{\"knarr.io/patch-interval\":\"10\",\"knarr.io/safe-to-evict\":\"true\"}",
  )
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  set_deployment(harness.table, "{\"knarr.io/patch-interval\":\"10\"}")
  tick(harness:, at: 1005)
  lists(harness)
  assert await_metric(pending("short") <> "1\n", 1000)
  quiet(harness)
  opt_out(harness.table)
  tick(harness:, at: 1010)
  lists(harness)
  quiet(harness)
  assert string.contains(metrics.collect(), pending("short") <> "1\n")
  patcher_wake(harness:, at: 1059)
  quiet(harness)
  assert string.contains(metrics.collect(), pending("short") <> "1\n")
  patcher_wake(harness:, at: 1060)
  patch_of(next(harness), "1")
  assert await_metric(pending("short") <> "0\n", 1000)
  quiet(harness)
  stop_root(set)
}

// ownership Rejected, reconcile Rejected422 and observability Events
// Rejected, Labels: a 422 kept for a pod whose Deployment opts out before
// the next LIST is classified at that LIST, though the pod is no longer a
// target: PatchRejected is raised and the rejection counted with the purpose
// it was kept for under the name its ReplicaSet's owner carries. The
// cleanup that LIST makes due, held by the interval, keeps the series.
pub fn a_kept_422_on_a_pod_that_opted_out_is_classified_at_the_next_list_test() -> Nil {
  let harness =
    harness("kept-out", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "reading:10.0.0.1", "2000")
  put(harness.table, "patch_status", "422")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  opt_out(harness.table)
  tick(harness:, at: 1030)
  lists(harness)
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "PatchRejected"
  assert kind == "Pod"
  assert string.contains(message, "rejected knarr's patch with 422;")
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_patch_rejections_total{deployment=\"kept-out\",purpose=\"apply\"} 1\n",
  )
  stop_root(set)
}

// ----------------------------------------------------------- Cleanup turn ---

/// A marker owning the cost at 500 while safe-to-evict stands yielded at
/// "false": one annotation to release and one yield to keep.
fn owned_and_yielded() -> String {
  let marker =
    "{\"at\":\""
    <> at(1000)
    <> "\",\"pod-deletion-cost\":{\"applied\":\"500\",\"at\":\""
    <> at(1000)
    <> "\"},\"safe-to-evict\":{\"at\":\""
    <> at(1000)
    <> "\",\"yielded\":\"false\"}}"
  json.object([
    #(cost_key, json.string("500")),
    #(ste_key, json.string("false")),
    #(marker_key, json.string(marker)),
  ])
  |> json.to_string
}

/// A marker owning both annotations at 1000, the cost at 500 and
/// safe-to-evict at "true", while the pod's safe-to-evict reads "false": a
/// conflict on safe-to-evict, the cost still owned.
fn safe_moved() -> String {
  let marker =
    "{\"at\":\""
    <> at(1000)
    <> "\",\"pod-deletion-cost\":{\"applied\":\"500\",\"at\":\""
    <> at(1000)
    <> "\"},\"safe-to-evict\":{\"applied\":\"true\",\"at\":\""
    <> at(1000)
    <> "\"}}"
  json.object([
    #(cost_key, json.string("500")),
    #(ste_key, json.string("false")),
    #(marker_key, json.string(marker)),
  ])
  |> json.to_string
}

/// The Deployment's ReplicaSet listed with no owner, as a cascade-orphan
/// deletion of the Deployment leaves it.
fn orphan_own_replica_set(table: Table) -> Nil {
  put(
    table,
    "replicasets",
    items(["{\"metadata\":{\"name\":\"rs\",\"uid\":\"rs-1\"}}"]),
  )
}

/// The remove of the annotation `key` as a patch document carries it.
fn remove_of(key: String) -> String {
  "{\"op\":\"remove\",\"path\":\"/metadata/annotations/"
  <> string.replace(key, "/", "~1")
  <> "\"}"
}

/// The add that rewrites the marker to the `rendered` marker text, its
/// quotes escaped as the patch document carries them.
fn marker_rewrite(rendered: String) -> String {
  "{\"op\":\"add\",\"path\":\"/metadata/annotations/knarr.io~1applied\",\"value\":\""
  <> string.replace(rendered, "\"", "\\\"")
  <> "\"}"
}

// lifecycle Cleanup Marker and Order, ownership Released, budget Pending: an
// opt-out of a pod owning both annotations makes one pending cleanup, held
// by the patch interval from the apply at 1000, and its turn sends one patch
// that removes both annotations and, with no record left, the marker.
pub fn an_opt_out_of_a_pod_owning_both_removes_both_and_the_marker_test() -> Nil {
  let harness =
    harness("clean-both", [
      PodFixture(..pod("1"), annotations: owning_both("500", "true")),
    ])
  put(harness.table, "reading:10.0.0.1", "2000")
  let both = PodFixture(..pod("1"), annotations: owning_both("2000", "true"))
  put(harness.table, "patched:1", pod_json(both))
  set_deployment(harness.table, safe_to_evict_on)
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  set_pods(harness.table, [both])
  opt_out(harness.table)
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  assert await_metric(pending("clean-both") <> "1\n", 1000)
  patcher_wake(harness:, at: 1060)
  let document = patch_of(next(harness), "1")
  assert string.contains(document, remove_of(cost_key))
  assert string.contains(document, remove_of(ste_key))
  assert string.contains(document, remove_of(marker_key))
  assert !string.contains(document, "\"op\":\"add\"")
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup Scope, Marker and Label, ownership Released: a target
// whose Deployment does not opt in to safe-to-evict while its marker owns
// one gets a cleanup that removes safe-to-evict alone and rewrites the
// marker with the cost's record kept, counted on knarr_patches_total with
// purpose cleanup under the target's Deployment.
pub fn a_removed_safe_to_evict_opt_in_is_removed_alone_and_the_marker_kept_test() -> Nil {
  let harness =
    harness("clean-ste", [
      PodFixture(..pod("1"), annotations: owning_both("500", "true")),
    ])
  put(
    harness.table,
    "patched:1",
    pod_json(PodFixture(..pod("1"), annotations: marked("500", at(1000)))),
  )
  let set = start(harness)

  lists(harness)
  let document = patch_of(next(harness), "1")
  assert string.contains(document, remove_of(ste_key))
  assert !string.contains(document, remove_of(cost_key))
  assert !string.contains(document, remove_of(marker_key))
  assert string.contains(
    document,
    marker_rewrite(
      "{\"at\":\""
      <> at(1000)
      <> "\",\"pod-deletion-cost\":{\"applied\":\"500\",\"at\":\""
      <> at(1000)
      <> "\"}}",
    ),
  )
  quiet(harness)
  assert await_metric(
    patches(deployment: "clean-ste", purpose: "cleanup", result: "accepted")
      <> "1\n",
    1000,
  )
  stop_root(set)
}

// lifecycle Cleanup Marker, ownership Released and Yield: a yielded record
// keeps the marker, so the cleanup of a pod whose Deployment was deleted
// removes the owned cost and rewrites the marker with the yield alone.
pub fn a_yielded_record_keeps_the_marker_through_a_cleanup_test() -> Nil {
  let harness =
    harness("clean-yield", [
      PodFixture(..pod("1"), annotations: owned_and_yielded()),
    ])
  put(harness.table, "deployments", items([]))
  let set = start(harness)

  lists(harness)
  let document = patch_of(next(harness), "1")
  assert string.contains(document, remove_of(cost_key))
  assert !string.contains(document, remove_of(ste_key))
  assert !string.contains(document, remove_of(marker_key))
  assert string.contains(
    document,
    marker_rewrite(
      "{\"at\":\""
      <> at(1000)
      <> "\",\"safe-to-evict\":{\"at\":\""
      <> at(1000)
      <> "\",\"yielded\":\"false\"}}",
    ),
  )
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup Scope and Marker, ownership Released: the null record
// reconcile's Neutral leaves stands owned, so a pod that is no target with
// it gets the marker-only cleanup: nothing removed from the pod but the
// marker, which no record keeps.
pub fn neutrals_null_record_gets_the_marker_only_cleanup_test() -> Nil {
  let harness =
    harness("clean-null", [PodFixture(..pod("1"), annotations: null_record())])
  put(harness.table, "deployments", items([]))
  let set = start(harness)

  lists(harness)
  let document = patch_of(next(harness), "1")
  assert string.contains(document, remove_of(marker_key))
  assert !string.contains(document, remove_of(cost_key))
  assert !string.contains(document, "\"op\":\"add\"")
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup Label, observability Catalogue Patches: the cleanup of
// a pod that is no target counts on knarr_patches_total with purpose
// cleanup under its View's deployment, the name its ReplicaSet's owner
// reference carries after the Deployment was deleted.
pub fn a_cleanup_counts_under_its_views_deployment_test() -> Nil {
  let harness =
    harness("clean-label", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "deployments", items([]))
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert await_metric(
    patches(deployment: "clean-label", purpose: "cleanup", result: "accepted")
      <> "1\n",
    1000,
  )
  stop_root(set)
}

// lifecycle Cleanup Order, budget PerPod: a pod due both an apply and a
// cleanup, its safe-to-evict opt-in gone while its cost crosses a
// threshold, makes two patches, each with its own purpose, the second a
// patch interval after the first.
pub fn a_pod_due_an_apply_and_a_cleanup_makes_two_patches_an_interval_apart_test() -> Nil {
  let harness =
    harness("clean-two", [
      PodFixture(..pod("1"), annotations: owning_both("500", "true")),
    ])
  put(harness.table, "reading:10.0.0.1", "2000")
  put(
    harness.table,
    "patched:1",
    pod_json(PodFixture(..pod("1"), annotations: marked("500", at(1000)))),
  )
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  patcher_wake(harness:, at: 1059)
  quiet(harness)
  patcher_wake(harness:, at: 1060)
  patch_of(next(harness), "1")
  quiet(harness)
  assert await_metric(
    patches(deployment: "clean-two", purpose: "cleanup", result: "accepted")
      <> "1\n",
    1000,
  )
  assert await_metric(
    patches(deployment: "clean-two", purpose: "apply", result: "accepted")
      <> "1\n",
    1000,
  )
  stop_root(set)
}

// lifecycle Cleanup View and Scope, ownership Adoption: the cleanup is
// re-derived at its turn from the pod's newest API-returned view, so an
// apply accepted between the LIST and the turn does not cost it a 422. The
// apply pending since the poll at 1030 goes at 1060, before the cleanup the
// LIST at 1040 made due; the cleanup follows at 1120 with the marker the
// apply's response holds, cost 4000, not the LIST's 2000.
pub fn a_cleanup_turn_is_built_from_the_newest_accepted_response_test() -> Nil {
  let harness =
    harness("clean-held", [
      PodFixture(..pod("1"), annotations: owning_both("500", "true")),
    ])
  put(harness.table, "reading:10.0.0.1", "2000")
  let listed = PodFixture(..pod("1"), annotations: owning_both("2000", "true"))
  put(harness.table, "patched:1", pod_json(listed))
  set_deployment(harness.table, safe_to_evict_on)
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  put(harness.table, "reading:10.0.0.1", "4000")
  wake(harness:, at: 1030)
  assert await_polls(harness:, count: 2, within: 1000)
  quiet(harness)
  set_pods(harness.table, [listed])
  set_deployment(harness.table, "{}")
  tick(harness:, at: 1040)
  lists(harness)
  quiet(harness)
  put(
    harness.table,
    "patched:1",
    pod_json(PodFixture(..pod("1"), annotations: owning_both("4000", "true"))),
  )
  patcher_wake(harness:, at: 1060)
  let apply = patch_of(next(harness), "1")
  assert string.contains(apply, "\"4000\"")
  quiet(harness)
  patcher_wake(harness:, at: 1119)
  quiet(harness)
  patcher_wake(harness:, at: 1120)
  let cleanup = patch_of(next(harness), "1")
  assert string.contains(cleanup, remove_of(ste_key))
  assert string.contains(cleanup, "\\\"applied\\\":\\\"4000\\\"")
  assert !string.contains(cleanup, "\\\"applied\\\":\\\"2000\\\"")
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup Retry, reconcile Rejected422, ownership Rejected: a
// cleanup refused with 422 is not retried before the next LIST, so nothing
// stays pending and a wake past the interval sends nothing. That LIST
// classifies the kept operations, unchanged on its view, as a rejection,
// raised as CleanupRejected with 422 (observability Events CleanupRejected),
// and makes the cleanup due again; the rebuilt patch is accepted.
pub fn a_cleanup_refused_with_422_is_rebuilt_from_the_next_list_test() -> Nil {
  let harness =
    harness("clean-422", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "deployments", items([]))
  put(harness.table, "patch_status", "422")
  let set = start(harness)

  lists(harness)
  let first = patch_of(next(harness), "1")
  quiet(harness)
  assert await_metric(
    patches(
      deployment: "clean-422",
      purpose: "cleanup",
      result: "precondition_failed",
    )
      <> "1\n",
    1000,
  )
  patcher_wake(harness:, at: 1060)
  quiet(harness)
  put(harness.table, "patch_status", "200")
  tick(harness:, at: 1300)
  lists(harness)
  let #(reason, message, _) = event_of(next(harness))
  assert reason == "CleanupRejected"
  assert string.contains(message, "rejected knarr's cleanup with 422;")
  let second = patch_of(next(harness), "1")
  assert second == first
  quiet(harness)
  assert await_metric(
    patches(deployment: "clean-422", purpose: "cleanup", result: "accepted")
      <> "1\n",
    1000,
  )
  assert string.contains(
    metrics.collect(),
    "knarr_patch_rejections_total{deployment=\"clean-422\",purpose=\"cleanup\"} 1\n",
  )
  stop_root(set)
}

// lifecycle Cleanup Retry, observability Events CleanupRejected, Cadence
// and Catalogue Patches: a cleanup rejected with 403 raises CleanupRejected,
// naming what it left, with its warning line, and stays due; it is tried
// again no sooner than the patch interval, and the second 403 in the run
// counts and raises nothing.
pub fn a_cleanup_rejected_twice_raises_one_cleanup_rejected_event_test() -> Nil {
  let harness =
    harness("clean-403", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "deployments", items([]))
  put(harness.table, "patch_status", "403")
  capture_logs(harness.table)
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "CleanupRejected"
  assert kind == "Pod"
  assert string.contains(
    message,
    "the apiserver rejected knarr's cleanup with 403; controller.kubernetes.io/pod-deletion-cost=500 stays on the pod until removed",
  )
  quiet(harness)
  patcher_wake(harness:, at: 1059)
  quiet(harness)
  patcher_wake(harness:, at: 1060)
  patch_of(next(harness), "1")
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_patch_rejections_total{deployment=\"clean-403\",purpose=\"cleanup\"} 2\n",
  )
  assert string.contains(
    exposition,
    patches(deployment: "clean-403", purpose: "cleanup", result: "rejected")
      <> "2\n",
  )
  let rejected = lines(harness, "cleanup rejected")
  assert list.length(rejected) == 1
  assert list.all(rejected, fn(line) {
    string.contains(line, "\"deployment\":\"clean-403\"")
    && string.ends_with(
      line,
      "\"left\":[\"controller.kubernetes.io/pod-deletion-cost=500\"]}\n",
    )
  })
  release_logs()
  stop_root(set)
}

// lifecycle Cleanup Retry, ownership Rejected: a 400 is a rejection at
// once, raised as CleanupRejected on the attempt, and the cleanup stays
// due, sent again a patch interval later.
pub fn a_cleanup_rejected_with_400_is_a_rejection_at_once_and_stays_due_test() -> Nil {
  let harness =
    harness("clean-400", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "deployments", items([]))
  put(harness.table, "patch_status", "400")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  let #(reason, message, _) = event_of(next(harness))
  assert reason == "CleanupRejected"
  assert string.contains(message, "rejected knarr's cleanup with 400;")
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_patch_rejections_total{deployment=\"clean-400\",purpose=\"cleanup\"} 1\n",
  )
  patcher_wake(harness:, at: 1060)
  patch_of(next(harness), "1")
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup Retry, budget BackOff: a cleanup refused with 429 stays
// due and is retried only once the pause has ended, never inside it.
pub fn a_throttled_cleanup_is_retried_only_after_the_pause_test() -> Nil {
  let harness =
    harness("clean-429", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "deployments", items([]))
  put(harness.table, "patch_status", "429")
  put(harness.table, "patch_retry_after", "120")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert await_metric(
    patches(deployment: "clean-429", purpose: "cleanup", result: "throttled")
      <> "1\n",
    1000,
  )
  put(harness.table, "patch_status", "200")
  patcher_wake(harness:, at: 1119)
  quiet(harness)
  patcher_wake(harness:, at: 1120)
  patch_of(next(harness), "1")
  quiet(harness)
  assert await_metric(
    patches(deployment: "clean-429", purpose: "cleanup", result: "accepted")
      <> "1\n",
    1000,
  )
  stop_root(set)
}

// lifecycle Cleanup Retry, observability Events Rejected: an accepted
// cleanup ends the pod's rejection run, so a rejection of the cleanup the
// next LIST makes due again raises CleanupRejected anew.
pub fn an_accepted_cleanup_ends_the_rejection_run_test() -> Nil {
  let harness =
    harness("clean-run", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "deployments", items([]))
  put(harness.table, "patch_status", "403")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "CleanupRejected"
  quiet(harness)
  put(harness.table, "patch_status", "200")
  patcher_wake(harness:, at: 1060)
  patch_of(next(harness), "1")
  quiet(harness)
  put(harness.table, "patch_status", "403")
  tick(harness:, at: 1300)
  lists(harness)
  patch_of(next(harness), "1")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "CleanupRejected"
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_patch_rejections_total{deployment=\"clean-run\",purpose=\"cleanup\"} 2\n",
  )
  assert string.contains(
    exposition,
    patches(deployment: "clean-run", purpose: "cleanup", result: "accepted")
      <> "1\n",
  )
  stop_root(set)
}

// lifecycle Cleanup Label, observability Labels, ownership Rejected: a 422
// is classified at the next LIST under the label its attempt was counted
// under, though that LIST's View names another deployment: here a
// cascade-orphan deletion empties the chain between the 422 and the LIST,
// with every field the patch tested unchanged, so the rejection counts and
// logs under "clean-422-label", not under the empty name. No View carries
// that name any more, so the cycle that counts the rejection finds it done
// and its series retire once the patcher is quiet (observability
// SeriesLife); the patcher is suspended across that cycle, so the counter
// is read before they go.
pub fn a_kept_422_is_classified_under_the_label_its_attempt_was_counted_under_test() -> Nil {
  let harness =
    harness("clean-422-label", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "deployments", items([]))
  put(harness.table, "patch_status", "422")
  capture_logs(harness.table)
  let set = start(harness)
  let empty =
    "knarr_patch_rejections_total{deployment=\"\",purpose=\"cleanup\"}"
  let before = counter(empty)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert await_metric(
    patches(
      deployment: "clean-422-label",
      purpose: "cleanup",
      result: "precondition_failed",
    )
      <> "1\n",
    1000,
  )
  orphan_own_replica_set(harness.table)
  put(harness.table, "patch_status", "200")
  let patcher_pid = pid_of(harness.config.names.patcher)
  system.suspend(patcher_pid)
  tick(harness:, at: 1300)
  lists(harness)
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "CleanupRejected"
  settled(pid_of(harness.config.names.reconciler))
  assert string.contains(
    metrics.collect(),
    "knarr_patch_rejections_total{deployment=\"clean-422-label\",purpose=\"cleanup\"} 1\n",
  )
  assert counter(empty) == before
  system.resume(patcher_pid)
  patch_of(next(harness), "1")
  assert await_retired("clean-422-label", 1000)
  quiet(harness)
  let rejected = lines(harness, "cleanup rejected")
  assert list.length(rejected) == 1
  assert list.all(rejected, string.contains(
    _,
    "\"deployment\":\"clean-422-label\"",
  ))
  release_logs()
  stop_root(set)
}

// lifecycle Cleanup View and Scope, ownership Precondition and Released: a
// 422 is not replayed but rebuilt from the next LIST's view. Here that view
// shows safe-to-evict changed under knarr, a conflict, so the 422 is no
// rejection, and the rebuilt patch releases the cost alone: no test or
// remove of safe-to-evict, and the marker rewritten with the conflict's
// record kept as found.
pub fn a_cleanup_refused_with_422_is_rebuilt_from_a_changed_view_test() -> Nil {
  let harness =
    harness("clean-422-moved", [
      PodFixture(..pod("1"), annotations: owning_both("500", "true")),
    ])
  put(harness.table, "deployments", items([]))
  put(harness.table, "patch_status", "422")
  let set = start(harness)

  lists(harness)
  let first = patch_of(next(harness), "1")
  assert string.contains(first, remove_of(ste_key))
  quiet(harness)
  set_pods(harness.table, [PodFixture(..pod("1"), annotations: safe_moved())])
  put(harness.table, "patch_status", "200")
  tick(harness:, at: 1300)
  lists(harness)
  let second = patch_of(next(harness), "1")
  assert string.contains(second, remove_of(cost_key))
  assert !string.contains(
    second,
    "\"path\":\"/metadata/annotations/cluster-autoscaler.kubernetes.io~1safe-to-evict\"",
  )
  assert !string.contains(second, remove_of(marker_key))
  assert string.contains(
    second,
    marker_rewrite(
      "{\"at\":\""
      <> at(1300)
      <> "\",\"safe-to-evict\":{\"applied\":\"true\",\"at\":\""
      <> at(1000)
      <> "\"}}",
    ),
  )
  quiet(harness)
  assert !string.contains(
    metrics.collect(),
    "knarr_patch_rejections_total{deployment=\"clean-422-moved\"",
  )
  stop_root(set)
}

// reconcile Sequence, k8s_client Verbs: an accepted patch whose body gives
// no view leaves nothing due on the pod until the next LIST, for either
// purpose. A target is due a cleanup and an apply; the cleanup goes first
// and is accepted unseen, so the apply's turn after the interval sends
// nothing; after the next LIST the apply is built from the LIST's view.
pub fn an_unseen_accepted_patch_holds_the_other_purpose_until_the_next_list_test() -> Nil {
  let harness =
    harness("unseen-both", [
      PodFixture(..pod("1"), annotations: owning_both("500", "true")),
    ])
  put(harness.table, "reading:10.0.0.1", "2000")
  put(harness.table, "patched:1", "not json")
  let set = start(harness)

  lists(harness)
  let cleanup = patch_of(next(harness), "1")
  assert string.contains(cleanup, remove_of(ste_key))
  quiet(harness)
  assert await_metric(
    patches(deployment: "unseen-both", purpose: "cleanup", result: "accepted")
      <> "1\n",
    1000,
  )
  patcher_wake(harness:, at: 1060)
  quiet(harness)
  assert !string.contains(
    metrics.collect(),
    patches(deployment: "unseen-both", purpose: "apply", result: "accepted"),
  )
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
  tick(harness:, at: 1300)
  lists(harness)
  wake(harness:, at: 1300)
  let apply = patch_of(next(harness), "1")
  assert string.contains(apply, "\"2000\"")
  assert !string.contains(apply, ste_key)
  quiet(harness)
  stop_root(set)
}

// lifecycle Cleanup Retry, budget PerPod: a cleanup that fails in transport
// is counted as an error, is no rejection, and stays due: it is sent again
// no sooner than the patch interval.
pub fn a_cleanup_that_fails_in_transport_is_retried_after_the_interval_test() -> Nil {
  let harness =
    harness("clean-transport", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "deployments", items([]))
  put(harness.table, "patch_status", "send_failed")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert await_metric(
    patches(deployment: "clean-transport", purpose: "cleanup", result: "error")
      <> "1\n",
    1000,
  )
  put(harness.table, "patch_status", "200")
  patcher_wake(harness:, at: 1059)
  quiet(harness)
  patcher_wake(harness:, at: 1060)
  patch_of(next(harness), "1")
  quiet(harness)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    patches(
      deployment: "clean-transport",
      purpose: "cleanup",
      result: "accepted",
    )
      <> "1\n",
  )
  assert !string.contains(
    exposition,
    "knarr_patch_rejections_total{deployment=\"clean-transport\"",
  )
  stop_root(set)
}

// reconcile Sequence, k8s_client Verbs: a cleanup accepted with a body that
// gives no view is accepted, and nothing more is due on the pod until the
// next LIST supplies its view, which makes the cleanup due again.
pub fn a_cleanup_accepted_without_a_view_waits_for_the_next_list_test() -> Nil {
  let harness =
    harness("clean-unseen", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "deployments", items([]))
  put(harness.table, "patched:1", "not json")
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert await_metric(
    patches(deployment: "clean-unseen", purpose: "cleanup", result: "accepted")
      <> "1\n",
    1000,
  )
  patcher_wake(harness:, at: 1060)
  quiet(harness)
  tick(harness:, at: 1300)
  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  stop_root(set)
}

// budget Restart: after the set restarts every pod is patchable at once,
// since the interval, the bucket and the pause are in memory only: the pod
// patched at this clock before the crash is patched again at it.
pub fn a_due_change_after_a_restart_gets_its_turn_at_once_test() -> Nil {
  let harness = harness("restart-due", [pod("1")])
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  let first = children(set)
  let patcher_pid = list.drop(first, 2) |> list.first |> should.be_ok
  process.kill(patcher_pid)
  let second = await_new_children(set, first)
  assert list.length(second) == 4
  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  stop_root(set)
}

/// The per-Deployment series a process before a crash set and counted,
/// which no cycle of the restarted set (no pods) sets again.
fn stale_series() -> Nil {
  metrics.set(observability.pods, ["restart", "1"], 1)
  metrics.inc(observability.polls_total, ["restart", "valid"])
  assert string.contains(
    metrics.collect(),
    "knarr_pods{deployment=\"restart\",tier=\"1\"} 1\n",
  )
}

fn no_stale_series() -> Nil {
  let exposition = metrics.collect()
  assert !string.contains(exposition, "knarr_pods{deployment=\"restart\"")
  assert !string.contains(
    exposition,
    "knarr_polls_total{deployment=\"restart\"",
  )
  assert string.contains(exposition, "# TYPE knarr_pods gauge\n")
}

// knarr Recovery and budget Restart: the set's supervisor restarts all four
// of its children together, whichever crashed, and leaves the listener; the
// root sees the listener at 0 and the set at 1 when the poller profile is
// off. observability SeriesLife: the restarted reconciler starts its
// counters at 0 and carries no per-Deployment gauge series until its first
// full cycle rebuilds them. lifecycle Restart Replica and Leftovers: a
// crashlooping knarr raises no Event and starts its counters at 0 on each
// start, which a_restart_raises_patch_rejected_once_more_test and
// contract_absent_raises_one_event_on_entry_and_again_after_a_restart_test
// read from the restarted set.
pub fn the_set_restarts_together_and_leaves_the_listener_test() -> Nil {
  let harness = harness("restart", [])
  let started =
    runtime.start(
      port: 0,
      bind: "127.0.0.1",
      poller: False,
      discovery: Some(harness.config),
    )
    |> should.be_ok

  let root_children = children(started.pid)
  assert list.length(root_children) == 2
  let listener = list.first(root_children) |> should.be_ok
  let set = list.last(root_children) |> should.be_ok
  // The factory, the scheduler, the patcher and the reconciler.
  let first = children(set)
  assert list.length(first) == 4
  lists(harness)
  stale_series()

  // The scheduler crashes: every child is replaced, the reconciler among
  // them, whose first cycle LISTs again.
  let scheduler = list.drop(first, 1) |> list.first |> should.be_ok
  process.kill(scheduler)
  let second = await_new_children(set, first)
  assert list.length(second) == 4
  lists(harness)
  assert process.is_alive(listener)
  assert children(started.pid) == [listener, set]
  no_stale_series()

  // The reconciler crashes: the same.
  stale_series()
  let reconciler = list.last(second) |> should.be_ok
  process.kill(reconciler)
  let third = await_new_children(set, second)
  assert list.length(third) == 4
  lists(harness)
  assert process.is_alive(listener)
  assert children(started.pid) == [listener, set]
  no_stale_series()
  quiet(harness)
  stop_root(started.pid)
}

// reconcile Cycle: cycles never overlap and the next tick is armed once per
// cycle. A reconciler replaced by a restart registers the same name, so a
// LIST timer the one before it armed must not reach it: the timer is the
// process's own, and one LIST chain survives a restart, not two.
pub fn the_list_timer_of_a_replaced_reconciler_does_not_tick_its_successor_test() -> Nil {
  let harness = harness("timer", [])
  let harness =
    Harness(
      ..harness,
      config: reconciler.Config(..harness.config, interval_ms: 600),
    )
  let set = start(harness)

  lists(harness)
  // The timer is armed after the first cycle; a tick's cycle running proves
  // the message before it was handled whole, timer and all, so the kill
  // cannot land before the timer exists.
  tick(harness:, at: 1000)
  lists(harness)
  let first = children(set)
  let reconciler = list.last(first) |> should.be_ok
  process.kill(reconciler)
  let second = await_new_children(set, first)
  assert list.length(second) == 4
  // The restarted reconciler's first cycle, then its first timed one.
  lists(harness)
  lists(harness)
  // A second chain, the killed process's timer landing here, would LIST
  // again within the few milliseconds the restart took.
  quiet(harness)
  stop_root(set)
}

// The application callback builds the config by position, in Erlang, so a
// field moved here would break the pod without failing a Gleam test. This
// pins the order it relies on.
pub fn positional_config_matches_the_record_test() -> Nil {
  let config =
    reconciler.config(
      host: "10.96.0.1",
      port: 443,
      namespace_file: "/ns",
      token_file: "/token",
      ca_file: "/ca.crt",
      installed:,
    )

  assert config.target == target
  assert config.namespace_file == "/ns"
  assert config.token_file == "/token"
  assert config.installed == installed
  assert config.interval_ms == 60_000
  assert config.version == "0.1.0"
  // The clock is in milliseconds, and the draw is bounded.
  assert config.now() > 1_000_000_000_000
  assert config.random(1) == 0
}
