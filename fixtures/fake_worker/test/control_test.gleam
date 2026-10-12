//// The control endpoint: routing and strict decoding of a patch.

import fake_worker/control
import fake_worker/worker
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn replied(action: control.Action) -> response.Response(String) {
  case action {
    control.Reply(reply) -> reply
    _ -> {
      should.fail()
      response.new(0)
    }
  }
}

fn get(path: String) -> request.Request(String) {
  request.new() |> request.set_path(path)
}

fn put(path: String, body: String) -> request.Request(String) {
  get(path) |> request.set_method(http.Put) |> request.set_body(body)
}

fn with_method(path: String, method: http.Method) -> request.Request(String) {
  get(path) |> request.set_method(method)
}

pub fn health_is_always_ok_test() -> Nil {
  let reply = replied(control.route(get("/healthz")))
  assert reply.status == 200
  assert reply.body == "ok\n"
}

pub fn get_reads_the_state_test() -> Nil {
  assert control.route(get("/control")) == control.Read
}

pub fn put_with_every_member_test() -> Nil {
  let body =
    "{\"cost\":1800,\"accepting\":false,\"latency_ms\":25,\"failure\":\"invalid\",\"invalid_body\":\"[]\"}"
  assert control.route(put("/control", body))
    == control.Update(worker.Patch(
      cost: Some(1800),
      accepting: Some(False),
      latency_ms: Some(25),
      failure: Some(worker.Invalid),
      invalid_body: Some("[]"),
    ))
}

pub fn put_with_some_members_test() -> Nil {
  assert control.route(put("/control", "{\"failure\":\"refused\"}"))
    == control.Update(
      worker.Patch(..worker.no_change(), failure: Some(worker.Refused)),
    )
  assert control.route(put("/control", "{}"))
    == control.Update(worker.no_change())
}

pub fn put_refuses_what_it_cannot_apply_test() -> Nil {
  list.each(
    [
      "", "not json", "[]", "{\"cost\":-1}", "{\"cost\":1.5}",
      "{\"cost\":\"1\"}", "{\"cost\":null}", "{\"accepting\":\"false\"}",
      "{\"latency_ms\":-5}", "{\"failure\":\"5xx\"}", "{\"invalid_body\":1}",
      "{\"accepts\":false}", "{\"cost\":1,\"extra\":true}",
    ],
    fn(body) {
      let reply = replied(control.route(put("/control", body)))
      assert reply.status == 400
      assert string.starts_with(reply.body, "invalid control body: ")
    },
  )
}

pub fn unknown_members_are_named_test() -> Nil {
  let reply = replied(control.route(put("/control", "{\"accepts\":false}")))
  assert string.contains(reply.body, "accepts")
}

pub fn routing_test() -> Nil {
  let missing = replied(control.route(get("/other")))
  assert missing.status == 404
  let post = replied(control.route(with_method("/control", http.Post)))
  assert post.status == 405
  assert response.get_header(post, "allow") == Ok("GET, PUT")
  let put_health = replied(control.route(put("/healthz", "")))
  assert put_health.status == 405
  assert response.get_header(put_health, "allow") == Ok("GET")
}

pub fn state_json_test() -> Nil {
  let state =
    worker.apply(
      worker.new(),
      worker.Patch(
        ..worker.no_change(),
        cost: Some(3),
        failure: Some(worker.Timeout),
      ),
    )
  let state_reply = control.state_response(state)
  assert state_reply.status == 200
  assert response.get_header(state_reply, "content-type")
    == Ok("application/json")
  assert state_reply.body
    == "{\"cost\":3,\"accepting\":true,\"latency_ms\":0,\"failure\":\"timeout\",\"invalid_body\":\"{\\\"cost\\\":\\\"high\\\",\\\"accepting\\\":true}\",\"terminating\":false}"
  assert state.drain == None
}
