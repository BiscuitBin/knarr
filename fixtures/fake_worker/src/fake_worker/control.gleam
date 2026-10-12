//// The control endpoint, on its own port: how a test sets a pod's cost,
//// accepting, latency and failure mode at runtime. Decoding is strict, so a
//// misspelt member fails loudly instead of being ignored.

import fake_worker/worker.{type Patch, type State, Patch}
import gleam/dict
import gleam/dynamic/decode
import gleam/http.{Get, Put}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

// Why a control body was refused.
type PatchError {
  NotAnObject
  UnknownMember(name: String)
  WrongMember(path: String, expected: String)
}

fn describe(error: PatchError) -> String {
  case error {
    NotAnObject -> "not a JSON object"
    UnknownMember(name) -> "unknown member \"" <> name <> "\""
    WrongMember(path, expected) -> path <> ": expected " <> expected
  }
}

pub type Action {
  /// Answer with the current state.
  Read
  /// Apply the patch, then answer with the new state.
  Update(Patch)
  /// Answer with this response; the state is not involved.
  Reply(Response(String))
}

const members = ["cost", "accepting", "latency_ms", "failure", "invalid_body"]

pub fn route(request: Request(String)) -> Action {
  case request.path, request.method {
    "/healthz", Get -> Reply(text(200, "ok\n"))
    "/healthz", _ -> Reply(not_allowed("GET"))
    "/control", Get -> Read
    "/control", Put ->
      case decode_patch(request.body) {
        Ok(patch) -> Update(patch)
        Error(error) ->
          Reply(text(400, "invalid control body: " <> describe(error) <> "\n"))
      }
    "/control", _ -> Reply(not_allowed("GET, PUT"))
    _, _ -> Reply(text(404, "not found\n"))
  }
}

// A JSON object naming any of the control members, and nothing else.
fn decode_patch(body: String) -> Result(Patch, PatchError) {
  use object <- result.try(
    json.parse(body, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(NotAnObject),
  )
  let unknown =
    list.find(dict.keys(object), fn(key) { !list.contains(members, key) })
  use Nil <- result.try(case unknown {
    Ok(key) -> Error(UnknownMember(key))
    Error(Nil) -> Ok(Nil)
  })
  json.parse(body, patch_decoder()) |> result.map_error(wrong_member)
}

pub fn state_response(state: State) -> Response(String) {
  json.object([
    #("cost", json.int(state.cost)),
    #("accepting", json.bool(state.accepting)),
    #("latency_ms", json.int(state.latency_ms)),
    #("failure", json.string(worker.failure_name(state.failure))),
    #("invalid_body", json.string(state.invalid_body)),
    #("terminating", json.bool(option.is_some(state.drain))),
  ])
  |> json.to_string
  |> json_response(200, _)
}

fn patch_decoder() -> decode.Decoder(Patch) {
  use cost <- decode.optional_field("cost", None, some(non_negative()))
  use accepting <- decode.optional_field("accepting", None, some(decode.bool))
  use latency_ms <- decode.optional_field(
    "latency_ms",
    None,
    some(non_negative()),
  )
  use failure <- decode.optional_field("failure", None, some(failure()))
  use invalid_body <- decode.optional_field(
    "invalid_body",
    None,
    some(decode.string),
  )
  decode.success(Patch(cost:, accepting:, latency_ms:, failure:, invalid_body:))
}

fn some(decoder: decode.Decoder(a)) -> decode.Decoder(option.Option(a)) {
  decode.map(decoder, Some)
}

fn non_negative() -> decode.Decoder(Int) {
  use value <- decode.then(decode.int)
  case value >= 0 {
    True -> decode.success(value)
    False -> decode.failure(0, "a non-negative integer")
  }
}

fn failure() -> decode.Decoder(worker.Failure) {
  use name <- decode.then(decode.string)
  case worker.parse_failure(name) {
    Ok(failure) -> decode.success(failure)
    Error(Nil) ->
      decode.failure(
        worker.NoFailure,
        "one of none, timeout, server_error, not_found, invalid, refused",
      )
  }
}

fn wrong_member(error: json.DecodeError) -> PatchError {
  case error {
    json.UnableToDecode([decode.DecodeError(expected:, path:, ..), ..]) ->
      WrongMember(string.join(path, "."), expected)
    _ -> NotAnObject
  }
}

fn not_allowed(allow: String) -> Response(String) {
  text(405, "method not allowed\n") |> response.set_header("allow", allow)
}

fn json_response(status: Int, body: String) -> Response(String) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(body)
}

fn text(status: Int, body: String) -> Response(String) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(body)
}
