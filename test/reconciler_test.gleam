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
  <> "\",\"uid\":\"u-"
  <> fixture.name
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
/// that is set, as a slow response does; a refusal of either carries
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
        let status =
          get(table, "patch_status")
          |> result.try(int.parse)
          |> result.unwrap(200)
        let body = case get(table, "patched:" <> resource) {
          Ok(body) -> body
          Error(Nil) -> pod_json(pod(resource))
        }
        Ok(
          response.new(status)
          |> response.set_body(body)
          |> retry_after(table:, key: "patch_retry_after"),
        )
      }
      http.Post -> Ok(response.new(201) |> response.set_body("{}"))
      // The reconciler sends no other method.
      _ -> Ok(response.new(405) |> response.set_body(""))
    }
  }
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

// Loop.Rejected422: a 422 keeps the patch's operations until the next LIST
// and is not retried before it: the turn leaves nothing pending, the poll
// after it hands the patcher nothing, and a patcher wake past the pod's
// interval sends nothing. The LIST classifies the operations and the write
// is simply rebuilt from the poll that follows it.
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
  let second = patch_of(next(harness), "1")
  assert string.contains(first, "\"500\"")
  assert string.contains(second, "\"500\"")
  assert string.contains(second, at(1300))
  quiet(harness)
  assert await_metric(
    patches(deployment: "422", purpose: "apply", result: "accepted") <> "1\n",
    1000,
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

// Fallback.Absent, observability Events ContractAbsent and Cadence OnEntry,
// Restart: the Event is raised once, at the poll whose reading enters the
// state, with the port, path and that reading, not again at the LISTs or
// polls while the pod stays, and once more after a restart. The gauge
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

// Probes.Readiness: readiness latches only after a cycle in which all three
// LISTs succeed; a failed LIST ends the cycle with the previous target set.
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
// observability SeriesLife: its series are retired.
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

// ownership Event and Loop.Rejected422: a yield the apiserver refuses with a
// 422 raises no Event and ends the pod's turn, nothing stays pending and no
// turn inside the LIST interval yields again; the next LIST sees the
// conflict again and yields again. The operations the 422 refused are kept
// for that LIST's classification; ticket 32 gives the classification its
// signal, so until then nothing here can tell them apart from forgotten ones.
pub fn a_refused_yield_raises_no_event_and_is_rebuilt_from_the_next_list_test() -> Nil {
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
  let yield = patch_of(next(harness), "1")
  assert string.contains(yield, "\\\"yielded\\\":\\\"999\\\"")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "AnnotationYielded"
  quiet(harness)
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
// turn, whose changes ticket 47 derives, so the patcher's one turn in
// flight clears and the next due pod gets its turn.
pub fn a_turn_for_an_unknown_pod_or_a_cleanup_is_answered_nothing_due_test() -> Nil {
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

// observability SeriesLife: a Deployment that left the target set is
// retired when the patcher says it is quiet, not at the LIST that dropped
// it, so a late response is counted before its series go. A cleanup
// pending for its pod, held by the patch interval, keeps it busy; the turn
// that finds nothing due lets it go quiet.
pub fn a_departed_deployment_is_retired_only_when_the_patcher_is_quiet_test() -> Nil {
  let harness = harness("depart", [pod("1")])
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  to_patcher(
    harness,
    patcher.Due(
      pod_name: "1",
      purpose: budget.Cleanup,
      deployment: "depart",
      interval_s: 60,
      at_ms: 1_000_000,
    ),
  )
  put(harness.table, "deployments", items([]))
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
  patcher_wake(harness:, at: 1060)
  assert await_retired("depart", 1000)
  quiet(harness)
  stop_root(set)
}

// observability SeriesLife and config Discovery: a Deployment that leaves
// and rejoins the target set before the patcher is quiet is not retired,
// by the patcher's word or by a stray quiet: its series carry on and its
// counters are not restarted.
pub fn a_deployment_that_rejoins_before_quiet_keeps_its_series_test() -> Nil {
  let harness = harness("rejoin", [pod("1")])
  let set = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  to_patcher(
    harness,
    patcher.Due(
      pod_name: "1",
      purpose: budget.Cleanup,
      deployment: "rejoin",
      interval_s: 60,
      at_ms: 1_000_000,
    ),
  )
  put(harness.table, "deployments", items([]))
  tick(harness:, at: 1000)
  lists(harness)
  quiet(harness)
  set_deployment(harness.table, "{}")
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("500", at(1000))),
  ])
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
// full cycle rebuilds them.
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
