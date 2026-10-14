//// The reconcile process against closure fakes (reconcile Loop Cycle,
//// docs/specs/reconcile.allium): a scripted apiserver answers the three
//// LISTs, the patches and the Event creates and forwards every request to
//// the test; a scripted poll answers each pod; the clock and readiness are
//// injected. Each cycle is driven by a Tick the test sends, with the timer
//// held off, and ends with the requests it made.

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
import knarr/config.{Defaults, Installed}
import knarr/k8s_client
import knarr/k8s_http
import knarr/metrics
import knarr/observability
import knarr/poller.{type Endpoint}
import knarr/reconciler
import knarr/runtime

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

@external(erlang, "reconciler_test_ffi", "await_new_child")
fn await_new_child(supervisor: Pid, previous: Pid) -> Pid

@external(erlang, "reconciler_test_ffi", "stop_actor")
fn stop_actor(pid: Pid) -> Nil

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
/// request to `requests`.
fn apiserver(
  table: Table,
  requests: Subject(Request(String)),
) -> fn(Request(String)) -> Result(Response(String), k8s_http.SendError) {
  fn(request: Request(String)) {
    process.send(requests, request)
    let resource =
      request.path |> string.split("/") |> list.last |> result.unwrap("")
    case request.method {
      http.Get ->
        case get(table, resource) {
          Ok(body) -> Ok(response.new(200) |> response.set_body(body))
          Error(Nil) -> Error(k8s_http.TlsAlert("unknown_ca"))
        }
      http.Patch -> {
        let status =
          get(table, "patch_status")
          |> result.try(int.parse)
          |> result.unwrap(200)
        let body = case get(table, "patched:" <> resource) {
          Ok(body) -> body
          Error(Nil) -> pod_json(pod(resource))
        }
        Ok(response.new(status) |> response.set_body(body))
      }
      http.Post -> Ok(response.new(201) |> response.set_body("{}"))
      // The reconciler sends no other method.
      _ -> Ok(response.new(405) |> response.set_body(""))
    }
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
      // A worker that never answers within the fan-out's wait.
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
        get(table, "now") |> result.try(int.parse) |> result.unwrap(0)
      },
      mark_ready: fn() { process.send(ready, Nil) },
      installed:,
      interval_ms: 3_600_000,
      version: "0.1.0",
    )
  Harness(table:, requests:, ready:, config:)
}

const target = k8s_client.Target(host: "10.96.0.1", port: 443)

fn start(harness: Harness) -> Subject(reconciler.Message) {
  let started = reconciler.start(harness.config) |> should.be_ok
  started.data
}

fn pid(subject: Subject(a)) -> Pid {
  process.subject_owner(subject) |> should.be_ok
}

/// The next request within a second.
fn next(harness: Harness) -> Request(String) {
  process.receive(harness.requests, 1000) |> should.be_ok
}

/// The next request within `ms`, for a cycle that waits on a poll.
fn next_within(harness: Harness, ms: Int) -> Request(String) {
  process.receive(harness.requests, ms) |> should.be_ok
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

fn tick(
  harness harness: Harness,
  actor actor: Subject(reconciler.Message),
  at at: Int,
) -> Nil {
  put(harness.table, "now", int.to_string(at))
  process.send(actor, reconciler.Tick)
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

// Loop.Cycle, Desired, Due and ownership WriteMode: one cycle lists, polls
// every target with a pod IP, and patches a busy pod with the value and
// the marker in one document; a terminating pod is polled but never
// patched; a pod without an IP is neither.
pub fn a_cycle_polls_every_target_with_an_ip_and_patches_a_busy_pod_test() -> Nil {
  let harness =
    harness("busy", [
      pod("1"),
      PodFixture(..pod("2"), ip: None),
      PodFixture(..pod("3"), terminating: True),
      PodFixture(..pod("4"), owner: "other-rs"),
    ])
  let actor = start(harness)

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
  stop_actor(pid(actor))
}

// Loop.Cycle and worker_contract Transport: a poll that produces no response
// within the fan-out's wait is that pod's timed_out reading and no other
// pod's; the readings of the pods that answered land on their own pods.
pub fn a_hanging_poll_is_timed_out_for_its_pod_alone_test() -> Nil {
  let harness = harness("hang", [pod("1"), pod("2"), pod("3")])
  put(harness.table, "reading:10.0.0.1", "1000")
  put(harness.table, "reading:10.0.0.2", "hang")
  put(harness.table, "reading:10.0.0.3", "2000")
  let actor = start(harness)

  lists(harness)
  // The first batch waits out pod 2 (poll_timeout 1: three seconds).
  let first = next_within(harness, 4500)
  let second = next_within(harness, 1000)
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
  quiet(harness)
  stop_actor(pid(actor))
}

// Loop.Due: a pod whose marker records the value its reading maps to has
// nothing due, so a second cycle sends no patch.
pub fn nothing_is_due_between_crossings_test() -> Nil {
  let harness =
    harness("steady", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  let actor = start(harness)

  lists(harness)
  quiet(harness)
  tick(harness:, actor:, at: 1300)
  lists(harness)
  quiet(harness)
  stop_actor(pid(actor))
}

// Loop.Rejected422: a 422 keeps the patch's operations until the next LIST,
// which classifies them, and the write is simply rebuilt.
pub fn a_422_is_left_to_the_next_list_test() -> Nil {
  let harness = harness("422", [pod("1")])
  put(harness.table, "patch_status", "422")
  let actor = start(harness)

  lists(harness)
  let first = patch_of(next(harness), "1")
  quiet(harness)
  put(harness.table, "patch_status", "200")
  tick(harness:, actor:, at: 1300)
  lists(harness)
  let second = patch_of(next(harness), "1")
  assert string.contains(first, "\"500\"")
  assert string.contains(second, "\"500\"")
  assert string.contains(second, at(1300))
  quiet(harness)
  stop_actor(pid(actor))
}

// Fallback.Neutral and Loop.Due: three failed readings make the pod unknown
// and the removal is sent, keeping the marker with a null record.
pub fn the_neutral_removal_follows_three_failures_test() -> Nil {
  let harness =
    harness("neutral", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  put(harness.table, "reading:10.0.0.1", "timed_out")
  let actor = start(harness)

  lists(harness)
  quiet(harness)
  tick(harness:, actor:, at: 1000)
  lists(harness)
  quiet(harness)
  tick(harness:, actor:, at: 1300)
  lists(harness)
  let document = patch_of(next(harness), "1")
  assert string.contains(
    document,
    "{\"op\":\"remove\",\"path\":\"/metadata/annotations/controller.kubernetes.io~1pod-deletion-cost\"}",
  )
  assert string.contains(document, "\\\"applied\\\":null")
  quiet(harness)
  stop_actor(pid(actor))
}

// Fallback.Absent, observability Events ContractAbsent and Cadence
// Restart: the Event is raised once on entry, with the port, path and
// reading, not again while the pod stays, and once more after a restart.
pub fn contract_absent_raises_one_event_on_entry_and_again_after_a_restart_test() -> Nil {
  let harness = harness("absent", [pod("1")])
  put(harness.table, "reading:10.0.0.1", "not_found")
  set_deployment(
    harness.table,
    "{\"knarr.io/status-port\":\"9000\",\"knarr.io/status-path\":\"/status\"}",
  )
  let actor = start(harness)

  lists(harness)
  quiet(harness)
  tick(harness:, actor:, at: 1300)
  lists(harness)
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "ContractAbsent"
  assert kind == "Deployment"
  assert message
    == "pod 1: no knarr status contract at port 9000 path /status; last reading not_found"
  quiet(harness)
  tick(harness:, actor:, at: 1330)
  lists(harness)
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_pods_contract_absent{deployment=\"absent\"} 1\n",
  )
  stop_actor(pid(actor))

  let actor = start(harness)
  lists(harness)
  quiet(harness)
  tick(harness:, actor:, at: 1630)
  lists(harness)
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "ContractAbsent"
  quiet(harness)
  stop_actor(pid(actor))
}

// Probes.Readiness: readiness latches only after a cycle in which all three
// LISTs succeed; a failed LIST ends the cycle with the previous target set.
pub fn readiness_latches_after_the_first_complete_cycle_test() -> Nil {
  let harness = harness("ready", [pod("1")])
  let deployments = get(harness.table, "deployments") |> should.be_ok
  put(harness.table, "deployments", "")
  let actor = start(harness)

  lists(harness)
  quiet(harness)
  assert process.receive(harness.ready, 200) == Error(Nil)
  put(harness.table, "deployments", deployments)
  tick(harness:, actor:, at: 1000)
  lists(harness)
  assert process.receive(harness.ready, 1000) == Ok(Nil)
  patch_of(next(harness), "1")
  stop_actor(pid(actor))
}

// k8s_client TokenReload: a token that cannot be read skips the cycle and
// logs; a later file is picked up and the token is re-read every cycle.
pub fn an_unreadable_token_skips_the_cycle_test() -> Nil {
  let harness = harness("token", [])
  delete_file(harness.config.token_file)
  capture_logs(harness.table)
  let actor = start(harness)

  quiet(harness)
  write_file(harness.config.token_file, "second-token")
  tick(harness:, actor:, at: 1000)
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
  stop_actor(pid(actor))
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
  let actor = start(harness)

  lists(harness)
  let #(reason, message, kind) = event_of(next(harness))
  assert reason == "InvalidOverride"
  assert kind == "Deployment"
  assert message
    == "knarr.io/status-port: \"abc\" is invalid, not an integer; the default stands"
  quiet(harness)
  tick(harness:, actor:, at: 1000)
  lists(harness)
  quiet(harness)
  set_deployment(
    harness.table,
    "{\"knarr.io/status-port\":\"xyz\",\"knarr.io/colour\":\"blue\"}",
  )
  tick(harness:, actor:, at: 1000)
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
  stop_actor(pid(actor))
}

// config Effective: the pods of a Deployment that opted out leave the target
// set and nothing here names them, leaving being retired (ticket 23);
// observability SeriesLife: its series are retired.
pub fn an_opt_out_names_no_pods_and_retires_the_series_test() -> Nil {
  let harness = harness("leaving", [pod("1")])
  capture_logs(harness.table)
  let actor = start(harness)

  lists(harness)
  patch_of(next(harness), "1")
  quiet(harness)
  assert string.contains(
    metrics.collect(),
    "knarr_polls_total{deployment=\"leaving\",reading=\"valid\"} 1\n",
  )
  put(harness.table, "deployments", items([]))
  tick(harness:, actor:, at: 1300)
  lists(harness)
  quiet(harness)
  release_logs()
  assert !list.any(list_of(harness.table, "logs"), fn(line) {
    string.contains(line, "\"msg\":\"pods leaving\"")
  })
  assert !string.contains(metrics.collect(), "deployment=\"leaving\"")
  stop_actor(pid(actor))
}

// observability Tiers, Standing and reconcile Gauges: the gauges are
// rebuilt each cycle from the newest views, and a terminating pod counts
// only in knarr_targets.
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
  let actor = start(harness)

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
  assert string.contains(
    exposition,
    "knarr_pods_not_ready_with_cost{deployment=\"gauges\"} 1\n",
  )
  assert string.contains(
    exposition,
    "knarr_pods_unknown{deployment=\"gauges\"} 0\n",
  )
  assert string.contains(
    exposition,
    "knarr_last_discovery_timestamp_seconds 1000\n",
  )

  // Pod 2 goes away; the tier series is rebuilt and the readiness gauge
  // drops to 0 rather than keeping a stale value.
  set_pods(harness.table, [
    PodFixture(..pod("1"), annotations: marked("1800", at(1000))),
  ])
  tick(harness:, actor:, at: 1300)
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
  stop_actor(pid(actor))
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
// built from the yield's response.
pub fn a_conflict_is_yielded_and_its_event_raised_after_the_patch_test() -> Nil {
  let harness =
    harness("yield", [PodFixture(..pod("1"), annotations: conflicting())])
  put(
    harness.table,
    "patched:1",
    pod_json(PodFixture(..pod("1"), annotations: yielded())),
  )
  let actor = start(harness)

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
    "knarr_annotations{deployment=\"yield\",annotation=\"pod-deletion-cost\",standing=\"yielded\"} 1\n",
  )
  assert string.contains(
    exposition,
    "knarr_events_total{reason=\"AnnotationYielded\",result=\"created\"} 1\n",
  )
  stop_actor(pid(actor))
}

// ownership Event and Loop.Rejected422: a yield the apiserver refuses with a
// 422 raises no Event and ends the pod's turn, and the next LIST sees the
// conflict again and yields again. The operations the 422 refused are kept
// for that LIST's classification; ticket 32 gives the classification its
// signal, so until then nothing here can tell them apart from forgotten ones.
pub fn a_refused_yield_raises_no_event_and_is_rebuilt_from_the_next_list_test() -> Nil {
  let harness =
    harness("refused-yield", [
      PodFixture(..pod("1"), annotations: conflicting()),
    ])
  put(harness.table, "patch_status", "422")
  let actor = start(harness)

  lists(harness)
  let yield = patch_of(next(harness), "1")
  assert string.contains(yield, "\\\"yielded\\\":\\\"999\\\"")
  quiet(harness)
  put(harness.table, "patch_status", "200")
  put(
    harness.table,
    "patched:1",
    pod_json(PodFixture(..pod("1"), annotations: yielded())),
  )
  tick(harness:, actor:, at: 1300)
  lists(harness)
  let yield = patch_of(next(harness), "1")
  assert string.contains(yield, "\\\"yielded\\\":\\\"999\\\"")
  let #(reason, _, _) = event_of(next(harness))
  assert reason == "AnnotationYielded"
  quiet(harness)
  stop_actor(pid(actor))
}

// observability SeriesLife and config Discovery: a Deployment deleted and
// recreated under the same name between two LISTs has not left, so its
// series are rebuilt, not retired.
pub fn a_recreated_deployment_of_the_same_name_keeps_its_series_test() -> Nil {
  let harness =
    harness("recreate", [
      PodFixture(..pod("1"), annotations: marked("500", at(1000))),
    ])
  let actor = start(harness)

  lists(harness)
  quiet(harness)
  let series = "knarr_pods{deployment=\"recreate\",tier=\"1\"} 1\n"
  assert string.contains(metrics.collect(), series)
  recreate_deployment(harness.table, "dep-2")
  tick(harness:, actor:, at: 1300)
  lists(harness)
  quiet(harness)
  assert string.contains(metrics.collect(), series)
  stop_actor(pid(actor))
}

// knarr Recovery: the reconciler's supervisor restarts it and leaves the
// listener; the root sees the listener at 0 and the reconciler at 1 when
// the poller profile is off. observability SeriesLife: the restarted process
// starts its counters at 0 and carries no per-Deployment gauge series until
// its first full cycle rebuilds them.
pub fn supervisor_restarts_the_reconciler_and_leaves_the_listener_test() -> Nil {
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
  let reconciler_supervisor = list.last(root_children) |> should.be_ok
  let reconciler = children(reconciler_supervisor) |> list.first |> should.be_ok
  lists(harness)
  // Series the process before the crash set and counted, which no cycle
  // of the restarted one (no pods) sets again.
  metrics.set(observability.pods, ["restart", "1"], 1)
  metrics.inc(observability.polls_total, ["restart", "valid"])
  assert string.contains(
    metrics.collect(),
    "knarr_pods{deployment=\"restart\",tier=\"1\"} 1\n",
  )
  process.kill(reconciler)
  let restarted = await_new_child(reconciler_supervisor, reconciler)
  assert restarted != reconciler
  assert process.is_alive(listener)
  assert children(started.pid) == [listener, reconciler_supervisor]
  let exposition = metrics.collect()
  assert !string.contains(exposition, "knarr_pods{deployment=\"restart\"")
  assert !string.contains(
    exposition,
    "knarr_polls_total{deployment=\"restart\"",
  )
  assert string.contains(exposition, "# TYPE knarr_pods gauge\n")
  lists(harness)
  stop_root(started.pid)
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
}
