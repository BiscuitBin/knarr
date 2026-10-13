//// The S1 probe: the token is re-read from disk on every tick, a failing
//// send leaves the process alive, its own supervisor restarts it without
//// touching the listener, and a terminating pod is never patched.

import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import knarr/k8s_client.{type Pod, Pod, Target}
import knarr/k8s_http
import knarr/runtime
import knarr/s1_probe

const pod_name = "knarr-7d4b9c-abcde"

const interval_ms = 50

@external(erlang, "s1_probe_test_ffi", "children")
fn children(supervisor: Pid) -> List(Pid)

@external(erlang, "s1_probe_test_ffi", "await_new_child")
fn await_new_child(supervisor: Pid, previous: Pid) -> Pid

@external(erlang, "s1_probe_test_ffi", "stop_probe")
fn stop_probe(pid: Pid) -> Nil

@external(erlang, "s1_probe_test_ffi", "stop_root")
fn stop_root(pid: Pid) -> Nil

@external(erlang, "s1_probe_test_ffi", "write_file")
fn write_file(path: String, content: String) -> Nil

@external(erlang, "s1_probe_test_ffi", "delete_file")
fn delete_file(path: String) -> Nil

/// A fake apiserver that forwards each request it is handed to `requests`
/// and answers a list holding this pod, or the patched pod.
fn forwarding_send(
  requests: Subject(Request(String)),
) -> fn(Request(String)) -> Result(Response(String), k8s_http.SendError) {
  fn(request: Request(String)) {
    process.send(requests, request)
    let body = case request.method {
      http.Get ->
        "{\"items\":[{\"metadata\":{\"name\":\""
        <> pod_name
        <> "\",\"uid\":\"u\"}}]}"
      _ -> "{\"metadata\":{\"name\":\"" <> pod_name <> "\",\"uid\":\"u\"}}"
    }
    Ok(response.new(200) |> response.set_body(body))
  }
}

fn files(name: String) -> #(String, String) {
  let dir = "build/s1_probe_test/" <> name
  let token_file = dir <> "/token"
  let namespace_file = dir <> "/namespace"
  write_file(namespace_file, "default\n")
  #(token_file, namespace_file)
}

fn config(
  name: String,
  send: fn(Request(String)) -> Result(Response(String), k8s_http.SendError),
) -> s1_probe.Config {
  let #(token_file, namespace_file) = files(name)
  s1_probe.Config(
    target: Target(host: "10.96.0.1", port: 443),
    namespace_file:,
    token_file:,
    pod_name:,
    interval_ms:,
    send:,
  )
}

fn authorization(request: Request(String)) -> String {
  request.get_header(request, "authorization") |> should.be_ok
}

/// The next request whose authorization header is `wanted`, within `ticks`
/// ticks; fails otherwise.
fn await_authorization(
  requests requests: Subject(Request(String)),
  wanted wanted: String,
  ticks ticks: Int,
) -> Nil {
  case authorization(next_request(requests)) == wanted, ticks {
    True, _ -> Nil
    False, 0 -> should.fail()
    False, _ -> await_authorization(requests:, wanted:, ticks: ticks - 1)
  }
}

/// The next request the probe sent, within four ticks.
fn next_request(requests: Subject(Request(String))) -> Request(String) {
  process.receive(requests, interval_ms * 4) |> should.be_ok
}

pub fn probe_rereads_the_token_file_on_every_tick_test() -> Nil {
  let requests = process.new_subject()
  let config = config("reread", forwarding_send(requests))
  write_file(config.token_file, "first-token")
  let started = s1_probe.start(config) |> should.be_ok

  let first = next_request(requests)
  assert first.method == http.Get
  assert authorization(first) == "Bearer first-token"
  assert first.path == "/api/v1/namespaces/default/pods"
  let second = next_request(requests)
  assert second.method == http.Patch
  assert second.path == "/api/v1/namespaces/default/pods/" <> pod_name
  assert request.get_header(second, "content-type")
    == Ok("application/json-patch+json")
  assert authorization(second) == "Bearer first-token"

  write_file(config.token_file, "second-token")
  await_authorization(requests:, wanted: "Bearer second-token", ticks: 6)
  stop_probe(started.pid)
}

pub fn probe_skips_the_cycle_when_the_token_cannot_be_read_test() -> Nil {
  let requests = process.new_subject()
  let config = config("unreadable", forwarding_send(requests))
  delete_file(config.token_file)
  let started = s1_probe.start(config) |> should.be_ok

  assert process.receive(requests, interval_ms * 4) == Error(Nil)
  assert process.is_alive(started.pid)
  write_file(config.token_file, "late-token")
  await_authorization(requests:, wanted: "Bearer late-token", ticks: 6)
  stop_probe(started.pid)
}

pub fn probe_skips_the_cycle_when_the_namespace_cannot_be_read_test() -> Nil {
  let requests = process.new_subject()
  let config = config("no-namespace", forwarding_send(requests))
  write_file(config.token_file, "a-token")
  delete_file(config.namespace_file)
  let started = s1_probe.start(config) |> should.be_ok

  assert process.receive(requests, interval_ms * 4) == Error(Nil)
  assert process.is_alive(started.pid)
  stop_probe(started.pid)
}

pub fn probe_stays_alive_when_send_fails_test() -> Nil {
  let requests = process.new_subject()
  let failing = fn(request: Request(String)) {
    process.send(requests, request)
    Error(k8s_http.TlsAlert("unknown_ca"))
  }
  let config = config("failing", failing)
  write_file(config.token_file, "a-token")
  let started = s1_probe.start(config) |> should.be_ok

  next_request(requests)
  next_request(requests)
  next_request(requests)
  assert process.is_alive(started.pid)
  stop_probe(started.pid)
}

pub fn probe_supervisor_restarts_the_probe_and_leaves_the_listener_test() -> Nil {
  let requests = process.new_subject()
  let config = config("restart", forwarding_send(requests))
  write_file(config.token_file, "a-token")
  let started =
    runtime.start(port: 0, bind: "127.0.0.1", probe: Some(config))
    |> should.be_ok

  let root_children = children(started.pid)
  assert list.length(root_children) == 2
  let listener = list.first(root_children) |> should.be_ok
  let probe_supervisor = list.last(root_children) |> should.be_ok
  let probe = children(probe_supervisor) |> list.first |> should.be_ok
  assert list.length(children(probe_supervisor)) == 1
  next_request(requests)

  process.kill(probe)
  let restarted = await_new_child(probe_supervisor, probe)
  assert restarted != probe
  assert process.is_alive(listener)
  assert children(started.pid) == [listener, probe_supervisor]
  next_request(requests)
  stop_root(started.pid)
}

fn pod(
  name name: String,
  annotations annotations: Option(dict.Dict(String, String)),
  deletion_timestamp deletion_timestamp: Option(String),
) -> Pod {
  Pod(
    name:,
    uid: "u-" <> name,
    annotations:,
    deletion_timestamp:,
    pod_ip: None,
    ready: True,
    owner: None,
  )
}

const live_test =
  "{\"op\":\"test\",\"path\":\"/metadata/deletionTimestamp\",\"value\":null}"

pub fn probe_adds_its_key_under_an_existing_annotations_map_test() -> Nil {
  let own =
    pod(
      name: pod_name,
      annotations: Some(dict.from_list([#("other", "x")])),
      deletion_timestamp: None,
    )

  assert s1_probe.probe_patch(
      pods: [
        pod(name: "other", annotations: None, deletion_timestamp: None),
        own,
      ],
      pod_name:,
      value: "1760000060",
    )
    == Some(
      "["
      <> live_test
      <> ",{\"op\":\"add\",\"path\":\"/metadata/annotations/knarr.io~1s1-probe\",\"value\":\"1760000060\"}]",
    )
}

pub fn probe_adds_the_map_when_the_pod_has_none_test() -> Nil {
  // A test under a missing parent fails, so the map itself is tested for
  // null and added whole (ownership WriteMode).
  assert s1_probe.probe_patch(
      pods: [pod(name: pod_name, annotations: None, deletion_timestamp: None)],
      pod_name:,
      value: "1760000060",
    )
    == Some(
      "["
      <> live_test
      <> ",{\"op\":\"test\",\"path\":\"/metadata/annotations\",\"value\":null},{\"op\":\"add\",\"path\":\"/metadata/annotations\",\"value\":{\"knarr.io/s1-probe\":\"1760000060\"}}]",
    )
}

pub fn probe_does_not_patch_a_missing_or_terminating_pod_test() -> Nil {
  let other = pod(name: "other", annotations: None, deletion_timestamp: None)
  let terminating =
    pod(
      name: pod_name,
      annotations: None,
      deletion_timestamp: Some("2026-10-09T05:00:00Z"),
    )

  assert s1_probe.probe_patch(pods: [other, terminating], pod_name:, value: "1")
    == None
  assert s1_probe.probe_patch(pods: [other], pod_name:, value: "1") == None
  assert s1_probe.probe_patch(pods: [], pod_name:, value: "1") == None
}

// The application callback builds the config by position, in Erlang, so a
// field moved here would break the pod without failing a Gleam test. This
// pins the order it relies on.
pub fn positional_config_matches_the_record_test() -> Nil {
  let config =
    s1_probe.config(
      host: "10.96.0.1",
      port: 443,
      namespace_file: "/ns",
      token_file: "/token",
      ca_file: "/ca.crt",
      pod_name: "knarr-0",
      interval_ms: 30_000,
    )

  assert config.target == Target(host: "10.96.0.1", port: 443)
  assert config.namespace_file == "/ns"
  assert config.token_file == "/token"
  assert config.pod_name == "knarr-0"
  assert config.interval_ms == 30_000
}
