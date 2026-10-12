//// The collector: the sink that outlives every worker pod. Workers put their
//// kill record at /kills/<pod> on SIGTERM; a test reads /kills once the pods
//// are gone and clears it with DELETE between runs. One record per pod, so a
//// retried or repeated delivery never counts twice.

import fake_worker/kill_record.{type KillRecord}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Put}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/string

pub type Records =
  Dict(String, KillRecord)

pub fn respond(
  request request: Request(String),
  records records: Records,
) -> #(Response(String), Records) {
  case request.path_segments(request), request.method {
    ["healthz"], Get -> #(text(200, "ok\n"), records)
    ["healthz"], _ -> #(not_allowed("GET"), records)
    ["kills"], Get -> #(list_response(records), records)
    ["kills"], Delete -> #(response.new(204), dict.new())
    ["kills"], _ -> #(not_allowed("GET, DELETE"), records)
    ["kills", pod], Put -> store(records:, pod:, body: request.body)
    ["kills", _], _ -> #(not_allowed("PUT"), records)
    _, _ -> #(text(404, "not found\n"), records)
  }
}

fn store(
  records records: Records,
  pod pod: String,
  body body: String,
) -> #(Response(String), Records) {
  case kill_record.decode(body) {
    Ok(record) if record.pod == pod -> #(
      response.new(204),
      dict.insert(records, pod, record),
    )
    Ok(_) -> #(text(400, "the record names another pod\n"), records)
    Error(error) -> #(
      text(400, "not a kill record: " <> reason(error)),
      records,
    )
  }
}

fn reason(error: json.DecodeError) -> String {
  case error {
    json.UnableToDecode([decode.DecodeError(expected:, path:, ..), ..]) ->
      string.join(path, ".") <> ": expected " <> expected <> "\n"
    _ -> "not a JSON object\n"
  }
}

fn list_response(records: Records) -> Response(String) {
  let kills =
    records
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(pair) { kill_record.to_json(pair.1) })
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(
    json.object([#("kills", json.preprocessed_array(kills))]) |> json.to_string,
  )
}

fn not_allowed(allow: String) -> Response(String) {
  text(405, "method not allowed\n") |> response.set_header("allow", allow)
}

fn text(status: Int, body: String) -> Response(String) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(body)
}
